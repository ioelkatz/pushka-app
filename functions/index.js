const admin = require("firebase-admin");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");

const stripeSecret = defineSecret("STRIPE_SECRET_KEY");
const stripeWebhookSecret = defineSecret("STRIPE_WEBHOOK_SECRET");

admin.initializeApp();

const db = admin.firestore();
const messaging = admin.messaging();

function minAmountForCurrency(currency) {
  const code = String(currency || "usd").toLowerCase();
  const minimums = {
    usd: 50,
    eur: 50,
    gbp: 30,
    cad: 50,
    ils: 200,
    mxn: 1000,
    brl: 100,
    ars: 100000,
    clp: 50000,
    cop: 200000,
  };
  return minimums[code] ?? 100;
}

function formatAmount(cents) {
  return (Number(cents) / 100).toFixed(2);
}

function computeNextWalletTopUpDate({
  frequency = "weekly",
  weekday = 1,
  dayOfMonth = 1,
  baseDate = new Date(),
}) {
  const now = new Date(baseDate);
  if (frequency === "monthly") {
    let year = now.getUTCFullYear();
    let month = now.getUTCMonth();
    let run = new Date(Date.UTC(year, month, dayOfMonth, 8, 0, 0));
    if (run <= now) {
      month += 1;
      if (month > 11) {
        month = 0;
        year += 1;
      }
      const maxDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
      run = new Date(Date.UTC(year, month, Math.min(Math.max(dayOfMonth, 1), maxDay), 8, 0, 0));
    }
    return run;
  }

  // Firestore/UI weekday uses Monday=1...Sunday=7
  const target = Math.min(Math.max(Number(weekday) || 1, 1), 7);
  let run = new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate(),
    8,
    0,
    0,
  ));

  const jsWeekday = run.getUTCDay() === 0 ? 7 : run.getUTCDay();
  let offset = target - jsWeekday;
  if (offset < 0 || (offset === 0 && run <= now)) offset += 7;
  if (offset === 0 && run <= now) offset = 7;
  run.setUTCDate(run.getUTCDate() + offset);
  return run;
}

async function getUserTokens(uid) {
  const snap = await db
    .collection("users")
    .doc(uid)
    .collection("fcmTokens")
    .get();

  return snap.docs.map((doc) => doc.id).filter(Boolean);
}

async function cleanupInvalidTokens(uid, tokens, response) {
  if (!response || !response.responses) return;
  const batch = db.batch();
  response.responses.forEach((res, idx) => {
    if (res.success) return;
    const code = res.error?.code;
    if (
      code === "messaging/registration-token-not-registered" ||
      code === "messaging/invalid-registration-token"
    ) {
      const token = tokens[idx];
      const ref = db
        .collection("users")
        .doc(uid)
        .collection("fcmTokens")
        .doc(token);
      batch.delete(ref);
    }
  });
  await batch.commit();
}

async function sendToUser(uid, payload) {
  const tokens = await getUserTokens(uid);
  if (tokens.length === 0) return { successCount: 0 };

  const response = await messaging.sendEachForMulticast({
    tokens,
    ...payload,
  });

  await cleanupInvalidTokens(uid, tokens, response);
  return response;
}

async function reserveWebhookEvent(event) {
  const eventRef = db.collection("_stripeWebhookEvents").doc(event.id);
  let alreadyProcessed = false;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(eventRef);
    if (snap.exists) {
      alreadyProcessed = true;
      return;
    }
    tx.set(eventRef, {
      id: event.id,
      type: event.type,
      livemode: !!event.livemode,
      status: "processing",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return { eventRef, alreadyProcessed };
}

async function finalizeWebhookEvent(eventRef, patch) {
  await eventRef.set(
    {
      ...patch,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

async function resolveUidFromCharge(charge, stripe) {
  const chargeUid = charge?.metadata?.uid;
  if (chargeUid) return chargeUid;

  const paymentIntentId = typeof charge?.payment_intent === "string" ?
    charge.payment_intent :
    charge?.payment_intent?.id;
  if (!paymentIntentId) return null;

  try {
    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
    return paymentIntent?.metadata?.uid || null;
  } catch (_) {
    return null;
  }
}

async function writeUserPaymentEvent(uid, eventId, data) {
  await db
    .collection("users")
    .doc(uid)
    .collection("paymentEvents")
    .doc(eventId)
    .set(
      {
        ...data,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
}

async function deleteQueryBatch(query) {
  const snap = await query.get();
  if (snap.empty) return 0;

  const batch = db.batch();
  snap.docs.forEach((doc) => batch.delete(doc.ref));
  await batch.commit();
  return snap.size;
}

async function summarizeRecentWebhookEvents(hours = 24, limit = 600) {
  const since = admin.firestore.Timestamp.fromDate(
    new Date(Date.now() - hours * 60 * 60 * 1000),
  );

  const snap = await db
    .collection("_stripeWebhookEvents")
    .where("createdAt", ">=", since)
    .orderBy("createdAt", "desc")
    .limit(limit)
    .get();

  let processed = 0;
  let failed = 0;
  let skipped = 0;
  let ignored = 0;
  let processing = 0;

  snap.docs.forEach((doc) => {
    const status = doc.data()?.status;
    if (status === "processed") processed += 1;
    else if (status === "failed") failed += 1;
    else if (status === "skipped") skipped += 1;
    else if (status === "ignored") ignored += 1;
    else if (status === "processing") processing += 1;
  });

  return {
    windowHours: hours,
    sampledEvents: snap.size,
    processed,
    failed,
    skipped,
    ignored,
    processing,
  };
}

exports.sendTestNotification = onCall({ enforceAppCheck: true }, async (request) => {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
  }

  const uid = request.auth.uid;
  const title = request.data?.title || "Pushka";
  const body = request.data?.body || "Notificación de prueba";

  const response = await sendToUser(uid, {
    notification: { title, body },
    data: {
      type: "test",
    },
  });

  return {
    successCount: response.successCount ?? 0,
    failureCount: response.failureCount ?? 0,
  };
});

exports.createPaymentIntent = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
  }
  if (!stripeSecret.value()) {
    throw new HttpsError("failed-precondition", "Stripe no configurado.");
  }

  const amount = Number(request.data?.amount || 0);
  const currency = (request.data?.currency || "usd").toLowerCase();
  const customerEmail = request.data?.customerEmail || null;
  const purpose = String(request.data?.purpose || "donation").toLowerCase();
  if (purpose !== "donation" && purpose !== "wallet_topup" && purpose !== "pushka_empty") {
    throw new HttpsError("invalid-argument", "Propósito de pago inválido.");
  }

  if (!Number.isFinite(amount) || amount <= 0) {
    throw new HttpsError("invalid-argument", "Monto inválido.");
  }
  if (amount > 99999999) {
    throw new HttpsError("invalid-argument", "El monto excede el límite permitido.");
  }
  const minAmount = minAmountForCurrency(currency);
  if (amount < minAmount) {
    throw new HttpsError(
      "invalid-argument",
      `Monto mínimo para ${currency.toUpperCase()} es ${formatAmount(minAmount)}.`
    );
  }

  let paymentIntent;
  try {
    const stripe = require("stripe")(stripeSecret.value());
    paymentIntent = await stripe.paymentIntents.create({
      amount,
      currency,
      receipt_email: customerEmail || undefined,
      automatic_payment_methods: { enabled: true },
      metadata: {
        uid: request.auth.uid,
        source: "pushka",
        currency,
        amount: String(amount),
        purpose,
      },
    });
  } catch (err) {
    console.error("createPaymentIntent: Stripe API error", {
      uid: request.auth.uid,
      amount,
      currency,
      errorType: err?.type,
      errorCode: err?.code,
      errorMessage: err?.message,
    });
    const userMessage = err?.type === "StripeAuthenticationError"
      ? "Error de configuración del servidor de pagos."
      : err?.type === "StripeCardError"
        ? (err.message || "Tu tarjeta fue rechazada.")
        : "No se pudo procesar el pago. Intenta de nuevo.";
    throw new HttpsError("internal", userMessage);
  }

  return { clientSecret: paymentIntent.client_secret };
});

exports.stripeWebhook = onRequest(
  { secrets: [stripeSecret, stripeWebhookSecret] },
  async (req, res) => {
  if (!stripeSecret.value()) {
    console.error("stripeWebhook: STRIPE_SECRET_KEY is missing");
    res.status(500).send("Stripe secret key not configured.");
    return;
  }
  if (!stripeWebhookSecret.value()) {
    console.error("stripeWebhook: STRIPE_WEBHOOK_SECRET is missing");
    res.status(500).send("Stripe webhook secret not configured.");
    return;
  }

  const sig = req.headers["stripe-signature"];
  if (!sig) {
    console.error("stripeWebhook: Missing stripe-signature header");
    res.status(400).send("Missing stripe-signature header.");
    return;
  }

  let event;
  const stripe = require("stripe")(stripeSecret.value());
  try {
    event = stripe.webhooks.constructEvent(
      req.rawBody,
      sig,
      stripeWebhookSecret.value(),
    );
  } catch (err) {
    console.error("stripeWebhook: Signature verification failed", err?.message || err);
    res.status(400).send(`Webhook Error: ${err.message}`);
    return;
  }

  const { eventRef, alreadyProcessed } = await reserveWebhookEvent(event);
  if (alreadyProcessed) {
    res.json({ received: true, duplicate: true });
    return;
  }

  try {
    if (event.type === "payment_intent.succeeded") {
      const intent = event.data.object;
      const uid = intent.metadata?.uid;
      const purpose = String(intent.metadata?.purpose || "donation");
      const amount = (intent.amount || 0) / 100;
      const docId = intent.id;

      if (uid && (purpose === "donation" || purpose === "pushka_empty")) {
        const txType = purpose === "pushka_empty" ? "pushkaEmpty" : "tzedaka";
        const txDesc = purpose === "pushka_empty" ? "Vaciado de Pushka (Stripe)" : "Donación Stripe";
        await db
          .collection("users")
          .doc(uid)
          .collection("transactions")
          .doc(docId)
          .set({
            type: txType,
            amount,
            description: txDesc,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });

        await finalizeWebhookEvent(eventRef, {
          status: "processed",
          uid,
          paymentIntentId: docId,
          amount,
        });
      } else if (uid && purpose === "wallet_topup") {
        await writeUserPaymentEvent(uid, event.id, {
          kind: "wallet_topup_payment_succeeded",
          provider: "stripe",
          paymentIntentId: docId,
          amount,
          livemode: !!event.livemode,
        });

        await finalizeWebhookEvent(eventRef, {
          status: "processed",
          uid,
          paymentIntentId: docId,
          amount,
          outcome: "wallet_topup_payment_succeeded",
        });
      } else {
        await finalizeWebhookEvent(eventRef, {
          status: "skipped",
          reason: "missing_uid_metadata",
          paymentIntentId: docId,
        });
        console.warn("stripeWebhook: payment_intent.succeeded without uid metadata", {
          paymentIntentId: docId,
        });
      }
    } else if (event.type === "payment_intent.payment_failed") {
      const intent = event.data.object;
      const uid = intent.metadata?.uid;
      const amount = (intent.amount || 0) / 100;
      const reason = intent.last_payment_error?.message || "payment_failed";

      if (uid) {
        await writeUserPaymentEvent(uid, event.id, {
          kind: "payment_failed",
          provider: "stripe",
          paymentIntentId: intent.id,
          amount,
          message: reason,
          livemode: !!event.livemode,
        });
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        uid: uid || null,
        paymentIntentId: intent.id,
        amount,
        outcome: "failed",
      });
    } else if (event.type === "charge.refunded") {
      const charge = event.data.object;
      const uid = await resolveUidFromCharge(charge, stripe);
      const refundedAmount = (charge.amount_refunded || 0) / 100;
      const paymentIntentId = typeof charge.payment_intent === "string" ?
        charge.payment_intent :
        charge.payment_intent?.id || null;

      if (uid) {
        await writeUserPaymentEvent(uid, event.id, {
          kind: "refund",
          provider: "stripe",
          chargeId: charge.id,
          paymentIntentId,
          amount: refundedAmount,
          livemode: !!event.livemode,
        });
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        uid: uid || null,
        chargeId: charge.id,
        paymentIntentId,
        amount: refundedAmount,
        outcome: "refunded",
      });
    } else {
      await finalizeWebhookEvent(eventRef, {
        status: "ignored",
        reason: "event_type_not_handled",
      });
    }

    res.json({ received: true });
  } catch (err) {
    await finalizeWebhookEvent(eventRef, {
      status: "failed",
      error: String(err?.message || err || "unknown_error"),
    });
    console.error("stripeWebhook: Processing failed", err?.message || err);
    res.status(500).send("Webhook processing failed.");
  }
});

exports.onTransactionCreated = onDocumentCreated(
  "users/{userId}/transactions/{transactionId}",
  async (event) => {
    const uid = event.params.userId;
    const data = event.data?.data();
    if (!data) return;

    const type = data.type || "tzedaka";
    const amount = data.amount ?? 0;
    const title = "Pushka";

    let body = "Nueva transacción registrada";
    if (type === "tzedaka") {
      body = `¡Gracias por tu donación! \$${amount}`;
    } else if (type === "pushkaEmpty") {
      body = "Tu Pushka fue vaciada";
    } else if (type === "walletFill") {
      body = `Billetera rellenada con \$${amount}`;
    }

    await sendToUser(uid, {
      notification: { title, body },
      data: {
        type,
        amount: String(amount),
      },
    });
  },
);

exports.walletTopUpFromPaymentIntent = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }

    const uid = request.auth.uid;
    const paymentIntentId = String(request.data?.paymentIntentId || "").trim();
    if (!paymentIntentId.startsWith("pi_")) {
      throw new HttpsError("invalid-argument", "paymentIntentId inválido.");
    }

    const stripe = require("stripe")(stripeSecret.value());
    const intent = await stripe.paymentIntents.retrieve(paymentIntentId);

    if (!intent || intent.status !== "succeeded") {
      throw new HttpsError("failed-precondition", "El pago aún no fue confirmado.");
    }
    if (String(intent.metadata?.uid || "") !== uid) {
      throw new HttpsError("permission-denied", "El pago no pertenece a este usuario.");
    }
    if (String(intent.metadata?.purpose || "") !== "wallet_topup") {
      throw new HttpsError("invalid-argument", "El pago no es de recarga de billetera.");
    }

    const amount = Number(intent.amount_received || intent.amount || 0) / 100;
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new HttpsError("failed-precondition", "Monto de recarga inválido.");
    }

    const consumeRef = db.collection("_walletTopUpIntents").doc(paymentIntentId);
    const userRef = db.collection("users").doc(uid);
    let updatedBalance = 0;

    await db.runTransaction(async (tx) => {
      const consumeSnap = await tx.get(consumeRef);
      if (consumeSnap.exists) {
        throw new HttpsError("already-exists", "Esta recarga ya fue aplicada.");
      }

      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) {
        throw new HttpsError("not-found", "No se encontró el usuario.");
      }
      const userData = userSnap.data() || {};
      const currentBalance = Number(userData.walletBalance || 0);
      updatedBalance = currentBalance + amount;

      tx.set(
        userRef,
        {
          walletBalance: updatedBalance,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      const movementRef = userRef.collection("transactions").doc();
      tx.set(movementRef, {
        type: "walletFill",
        amount,
        description: "Recarga de billetera con tarjeta",
        createdAt: admin.firestore.Timestamp.now(),
      });

      tx.set(consumeRef, {
        uid,
        amount,
        paymentIntentId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    return { success: true, walletBalance: updatedBalance };
  },
);

exports.walletTransfer = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }

    const senderUid = request.auth.uid;
    const targetWalletId = String(request.data?.targetWalletId || "").trim();
    const amount = Number(request.data?.amount || 0);

    if (!targetWalletId) {
      throw new HttpsError("invalid-argument", "ID destino inválido.");
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new HttpsError("invalid-argument", "Monto inválido.");
    }
    if (amount > 1000000) {
      throw new HttpsError("invalid-argument", "El monto excede el límite permitido.");
    }

    const targetQuery = await db
      .collection("users")
      .where("walletId", "==", targetWalletId)
      .limit(1)
      .get();

    if (targetQuery.empty) {
      throw new HttpsError("not-found", "No existe una billetera con ese ID.");
    }

    const receiverRef = targetQuery.docs[0].ref;
    const receiverUid = targetQuery.docs[0].id;
    if (receiverUid === senderUid) {
      throw new HttpsError("failed-precondition", "No puedes transferirte a ti mismo.");
    }

    const senderRef = db.collection("users").doc(senderUid);
    let senderBalanceAfter = 0;

    await db.runTransaction(async (tx) => {
      const senderSnap = await tx.get(senderRef);
      const receiverSnap = await tx.get(receiverRef);

      if (!senderSnap.exists || !receiverSnap.exists) {
        throw new HttpsError("not-found", "No se pudo completar la transferencia.");
      }

      const senderBalance = Number((senderSnap.data() || {}).walletBalance || 0);
      const receiverBalance = Number((receiverSnap.data() || {}).walletBalance || 0);

      if (senderBalance < amount) {
        throw new HttpsError("failed-precondition", "Saldo insuficiente.");
      }

      senderBalanceAfter = senderBalance - amount;
      const receiverBalanceAfter = receiverBalance + amount;

      tx.set(
        senderRef,
        {
          walletBalance: senderBalanceAfter,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      tx.set(
        receiverRef,
        {
          walletBalance: receiverBalanceAfter,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      tx.set(senderRef.collection("transactions").doc(), {
        type: "walletFill",
        amount: -amount,
        description: `Transferencia enviada a ${targetWalletId}`,
        createdAt: admin.firestore.Timestamp.now(),
      });

      tx.set(receiverRef.collection("transactions").doc(), {
        type: "walletFill",
        amount,
        description: "Transferencia recibida",
        createdAt: admin.firestore.Timestamp.now(),
      });
    });

    return { success: true, walletBalance: senderBalanceAfter };
  },
);

exports.addWalletContact = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }

    const uid = request.auth.uid;
    const walletId = String(request.data?.walletId || "").trim();
    if (!walletId) {
      throw new HttpsError("invalid-argument", "ID de billetera inválido.");
    }

    const ownSnap = await db.collection("users").doc(uid).get();
    if (!ownSnap.exists) {
      throw new HttpsError("not-found", "No se encontró el usuario.");
    }
    const ownWalletId = String(ownSnap.data()?.walletId || "");
    if (ownWalletId && ownWalletId === walletId) {
      throw new HttpsError("failed-precondition", "No puedes agregarte a ti mismo.");
    }

    const targetQuery = await db
      .collection("users")
      .where("walletId", "==", walletId)
      .limit(1)
      .get();
    if (targetQuery.empty) {
      throw new HttpsError("not-found", "No existe una billetera con ese ID.");
    }

    const targetDoc = targetQuery.docs[0];
    const displayName = String(targetDoc.data()?.displayName || "Contacto");
    const contactRef = db
      .collection("users")
      .doc(uid)
      .collection("walletContacts")
      .doc(walletId);

    await contactRef.set(
      {
        walletId,
        uid: targetDoc.id,
        displayName,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { success: true, walletId, displayName };
  },
);

exports.cleanupStaleFcmTokens = onSchedule(
  {
    schedule: "every day 04:00",
    timeZone: "Etc/UTC",
  },
  async () => {
    const staleBefore = admin.firestore.Timestamp.fromDate(
      new Date(Date.now() - 90 * 24 * 60 * 60 * 1000),
    );

    let totalDeleted = 0;
    while (true) {
      const deleted = await deleteQueryBatch(
        db
          .collectionGroup("fcmTokens")
          .where("lastUsedAt", "<", staleBefore)
          .limit(400),
      );
      totalDeleted += deleted;
      if (deleted === 0) break;
    }

    console.info("cleanupStaleFcmTokens: completed", { totalDeleted });
  },
);

exports.cleanupOldStripeWebhookEvents = onSchedule(
  {
    schedule: "every day 04:20",
    timeZone: "Etc/UTC",
  },
  async () => {
    const olderThan = admin.firestore.Timestamp.fromDate(
      new Date(Date.now() - 45 * 24 * 60 * 60 * 1000),
    );

    let totalDeleted = 0;
    while (true) {
      const deleted = await deleteQueryBatch(
        db
          .collection("_stripeWebhookEvents")
          .where("createdAt", "<", olderThan)
          .limit(400),
      );
      totalDeleted += deleted;
      if (deleted === 0) break;
    }

    console.info("cleanupOldStripeWebhookEvents: completed", { totalDeleted });
  },
);

exports.monitorStripeWebhookHealth = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Etc/UTC",
  },
  async () => {
    const summary = await summarizeRecentWebhookEvents(24, 800);
    const failRate = summary.sampledEvents > 0 ?
      summary.failed / summary.sampledEvents :
      0;

    if (summary.failed >= 5 || failRate >= 0.1 || summary.processing >= 10) {
      console.error("monitorStripeWebhookHealth: degraded", {
        ...summary,
        failRate: Number(failRate.toFixed(4)),
      });
      return;
    }

    console.info("monitorStripeWebhookHealth: ok", {
      ...summary,
      failRate: Number(failRate.toFixed(4)),
    });
  },
);

exports.monitorStripeWebhookStuckEvents = onSchedule(
  {
    schedule: "every 30 minutes",
    timeZone: "Etc/UTC",
  },
  async () => {
    const olderThan = admin.firestore.Timestamp.fromDate(
      new Date(Date.now() - 15 * 60 * 1000),
    );

    const snap = await db
      .collection("_stripeWebhookEvents")
      .where("status", "==", "processing")
      .limit(300)
      .get();

    if (snap.empty) {
      console.info("monitorStripeWebhookStuckEvents: ok", { stuck: 0 });
      return;
    }

    const stuckDocs = snap.docs.filter((doc) => {
      const createdAt = doc.data()?.createdAt;
      return createdAt && createdAt.seconds < olderThan.seconds;
    });

    if (stuckDocs.length === 0) {
      console.info("monitorStripeWebhookStuckEvents: ok", { stuck: 0 });
      return;
    }

    const sample = stuckDocs.slice(0, 5).map((doc) => doc.id);
    console.error("monitorStripeWebhookStuckEvents: found_stuck_events", {
      stuck: stuckDocs.length,
      sample,
    });
  },
);

exports.processWalletAutoTopUps = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Etc/UTC",
  },
  async () => {
    const nowTs = admin.firestore.Timestamp.now();
    const dueUsers = await db
      .collection("users")
      .where("walletAutoTopUpNextRunAt", "<=", nowTs)
      .limit(150)
      .get();

    if (dueUsers.empty) {
      console.info("processWalletAutoTopUps: no_due_users");
      return;
    }

    let processed = 0;
    let failed = 0;

    for (const doc of dueUsers.docs) {
      try {
        await db.runTransaction(async (tx) => {
          const userRef = doc.ref;
          const snap = await tx.get(userRef);
          if (!snap.exists) return;

          const data = snap.data() || {};
          const enabled = data.walletAutoTopUpEnabled === true;
          const nextRun = data.walletAutoTopUpNextRunAt;
          if (!enabled || !nextRun || nextRun.toMillis() > Date.now()) return;

          const amount = Number(data.walletAutoTopUpAmount || 0);
          if (!Number.isFinite(amount) || amount <= 0) {
            tx.set(
              userRef,
              {
                walletAutoTopUpEnabled: false,
                walletAutoTopUpNextRunAt: null,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
              { merge: true },
            );
            return;
          }

          const currentBalance = Number(data.walletBalance || 0);
          const frequency = String(data.walletAutoTopUpFrequency || "weekly");
          const weekday = Number(data.walletAutoTopUpWeekday || 1);
          const dayOfMonth = Number(data.walletAutoTopUpDayOfMonth || 1);

          const updatedBalance = currentBalance + amount;
          const nextDate = computeNextWalletTopUpDate({
            frequency,
            weekday,
            dayOfMonth,
            baseDate: new Date(),
          });

          tx.set(
            userRef,
            {
              walletBalance: updatedBalance,
              walletAutoTopUpNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );

          const movementRef = userRef.collection("transactions").doc();
          tx.set(movementRef, {
            type: "walletFill",
            amount,
            description: "Recarga automática de billetera",
            createdAt: admin.firestore.Timestamp.now(),
          });
        });
        processed += 1;
      } catch (err) {
        failed += 1;
        console.error("processWalletAutoTopUps: user_failed", {
          uid: doc.id,
          error: String(err?.message || err),
        });
      }
    }

    console.info("processWalletAutoTopUps: completed", { processed, failed });
  },
);


// --- Erev Rosh Chodesh lookup (Gregorian dates for years 2025-2030) ---
const erevRoshChodeshDates = {
  2025: [[0,29],[1,27],[2,29],[3,27],[4,27],[5,25],[6,25],[7,23],[9,21],[10,20],[11,19]],
  2026: [[0,18],[1,16],[2,18],[3,16],[4,16],[5,14],[6,14],[7,12],[9,10],[10,9],[11,9]],
  2027: [[0,8],[1,6],[2,8],[3,7],[4,6],[5,5],[6,4],[7,3],[8,1],[9,30],[10,29],[11,29]],
  2028: [[0,28],[1,26],[2,27],[3,25],[4,25],[5,23],[6,23],[7,21],[9,19],[10,18],[11,17]],
  2029: [[0,16],[1,14],[2,16],[3,14],[4,14],[5,12],[6,12],[7,10],[9,8],[10,7],[11,6]],
  2030: [[0,4],[1,2],[2,4],[3,3],[4,2],[5,1],[5,30],[6,30],[7,28],[9,26],[10,25],[11,25]],
};

function computeNextErevRoshChodesh(baseDate) {
  const now = new Date(baseDate);
  const year = now.getUTCFullYear();
  const candidates = [];
  for (const y of [year, year + 1]) {
    const dates = erevRoshChodeshDates[y];
    if (!dates) continue;
    for (const [m, d] of dates) {
      candidates.push(new Date(Date.UTC(y, m, d, 8, 0, 0)));
    }
  }
  for (const d of candidates) {
    if (d > now) return d;
  }
  const fallback = new Date(now);
  fallback.setUTCDate(fallback.getUTCDate() + 30);
  return fallback;
}

// --- Pushka Auto Empty (scheduled) ---
exports.processPushkaAutoEmpty = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Etc/UTC",
  },
  async () => {
    const nowTs = admin.firestore.Timestamp.now();
    const dueUsers = await db
      .collection("users")
      .where("autoEmptyNextRunAt", "<=", nowTs)
      .limit(150)
      .get();

    if (dueUsers.empty) {
      console.info("processPushkaAutoEmpty: no_due_users");
      return;
    }

    let processed = 0;
    let failed = 0;

    for (const doc of dueUsers.docs) {
      try {
        await db.runTransaction(async (tx) => {
          const userRef = doc.ref;
          const snap = await tx.get(userRef);
          if (!snap.exists) return;

          const data = snap.data() || {};
          const freq = data.autoEmptyFrequency || "manual";
          if (freq === "manual") return;

          const nextRun = data.autoEmptyNextRunAt;
          if (!nextRun || nextRun.toMillis() > Date.now()) return;

          const currentAmount = Number(data.pushkaAmount || 0);
          const minBalance = 5;

          const weekday = Number(data.autoEmptyWeekday || 1);
          const dayOfMonth = Number(data.autoEmptyDayOfMonth || 1);
          let nextDate;
          if (freq === "erev_rosh_chodesh") {
            nextDate = computeNextErevRoshChodesh(new Date());
          } else {
            nextDate = computeNextWalletTopUpDate({
              frequency: freq,
              weekday,
              dayOfMonth,
              baseDate: new Date(),
            });
          }

          if (currentAmount < minBalance) {
            tx.set(userRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }

          const amountToEmpty = currentAmount;

          tx.set(userRef, {
            pushkaAmount: 0,
            autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

          const movementRef = userRef.collection("transactions").doc();
          tx.set(movementRef, {
            type: "pushkaEmpty",
            amount: amountToEmpty,
            description: "Vaciado automatico de Pushka",
            paymentMethod: "auto",
            status: "completed",
            createdAt: admin.firestore.Timestamp.now(),
          });
        });
        processed += 1;
      } catch (err) {
        failed += 1;
        console.error("processPushkaAutoEmpty: user_failed", {
          uid: doc.id,
          error: String(err?.message || err),
        });
      }
    }

    console.info("processPushkaAutoEmpty: completed", { processed, failed });
  },
);
