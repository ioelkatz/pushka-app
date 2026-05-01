const admin = require("firebase-admin");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");

const stripeSecret = defineSecret("STRIPE_SECRET_KEY");
const stripeWebhookSecret = defineSecret("STRIPE_WEBHOOK_SECRET");
const stripeBillingWebhookSecret = defineSecret("STRIPE_BILLING_WEBHOOK_SECRET");
const stripeConnectClientId = defineSecret("STRIPE_CONNECT_CLIENT_ID");
const sendgridApiKey = defineSecret("SENDGRID_API_KEY");

admin.initializeApp();

const db = admin.firestore();
const messaging = admin.messaging();

// ---------------------------------------------------------------------------
// Rate limiting — Firestore-backed sliding window counter
// ---------------------------------------------------------------------------
/**
 * Checks whether uid has exceeded maxCalls within windowSeconds.
 * Throws HttpsError("resource-exhausted") if the limit is exceeded.
 * Uses a single Firestore document per uid+action with atomic increment.
 */
async function enforceRateLimit(uid, action, maxCalls, windowSeconds) {
  const now = Date.now();
  const windowStart = now - windowSeconds * 1000;
  const ref = db.collection("_rateLimits").doc(`${uid}_${action}`);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() : { calls: [], updatedAt: now };

    // Keep only calls within the current window; cap length to prevent doc bloat.
    const recentCalls = (data.calls || []).filter((ts) => ts > windowStart).slice(-maxCalls * 2);

    if (recentCalls.length >= maxCalls) {
      const retryAfter = Math.ceil((recentCalls[0] + windowSeconds * 1000 - now) / 1000);
      throw new HttpsError(
        "resource-exhausted",
        `Demasiadas solicitudes. Intenta de nuevo en ${retryAfter} segundos.`
      );
    }

    recentCalls.push(now);
    tx.set(ref, { calls: recentCalls, updatedAt: now }, { merge: true });
  });
}

// Exhaustive list of currencies accepted by the app and their Stripe minimum
// charge amounts (in the smallest currency unit, e.g. cents).
// Any currency NOT in this map is rejected before reaching Stripe.
const CURRENCY_MINIMUMS = {
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

const SUPPORTED_CURRENCIES = new Set(Object.keys(CURRENCY_MINIMUMS));

/**
 * Validates that `currency` is a supported ISO 4217 code (lowercase).
 * Throws HttpsError("invalid-argument") if not.
 * Returns the normalised lowercase code.
 */
function validateCurrency(currency) {
  const code = String(currency || "").toLowerCase().trim();
  if (!SUPPORTED_CURRENCIES.has(code)) {
    throw new HttpsError(
      "invalid-argument",
      `Moneda no soportada: ${code || "(vacío)"}. Monedas válidas: ${[...SUPPORTED_CURRENCIES].join(", ")}.`
    );
  }
  return code;
}

function minAmountForCurrency(currency) {
  const code = String(currency || "usd").toLowerCase();
  return CURRENCY_MINIMUMS[code] ?? 100;
}

function formatAmount(cents) {
  return (Number(cents) / 100).toFixed(2);
}

/**
 * Returns a display symbol for the given ISO 4217 currency code (lowercase).
 * Falls back to the uppercased code itself for any unknown currency.
 */
function currencySymbol(code) {
  const symbols = {
    usd: "$", eur: "€", gbp: "£", cad: "CA$", ils: "₪",
    mxn: "MX$", brl: "R$", ars: "AR$", clp: "CL$", cop: "COP$",
  };
  return symbols[String(code || "usd").toLowerCase()] ?? String(code || "USD").toUpperCase();
}

/**
 * Returns the user's currency code from Firestore (lowercase), defaulting to "usd".
 */
async function getUserCurrency(uid) {
  try {
    const snap = await db.collection("users").doc(uid).get();
    const code = String(snap.data()?.currencyCode || "usd").toLowerCase().trim();
    return SUPPORTED_CURRENCIES.has(code) ? code : "usd";
  } catch (_) {
    return "usd";
  }
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
    const maxDayCurrent = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
    let run = new Date(Date.UTC(year, month, Math.min(Math.max(dayOfMonth, 1), maxDayCurrent), 8, 0, 0));
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
  run.setUTCDate(run.getUTCDate() + offset);
  return run;
}

async function getUserLanguage(uid) {
  try {
    const snap = await db.collection("users").doc(uid).get();
    const lang = snap.data()?.language;
    if (lang === "en" || lang === "fr" || lang === "he") return lang;
  } catch (_) { /* default */ }
  return "es";
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

  // 5 test notifications per hour per user
  await enforceRateLimit(request.auth.uid, "sendTestNotification", 5, 3600);

  const uid = request.auth.uid;
  // Strip control characters (including null bytes) before truncating.
  // eslint-disable-next-line no-control-regex
  const sanitize = (s) => String(s || "").replace(/[\x00-\x1F\x7F]/g, " ").trim();
  const title = sanitize(request.data?.title || "Pushka").slice(0, 100);
  const body = sanitize(request.data?.body || "Notificación de prueba").slice(0, 500);

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
  // 10 payment attempts per 10 minutes per user
  await enforceRateLimit(request.auth.uid, "createPaymentIntent", 10, 600);
  if (!stripeSecret.value()) {
    throw new HttpsError("failed-precondition", "Stripe no configurado.");
  }

  // Block payments for suspended users
  const adminDataSnap = await db.collection("adminData").doc(request.auth.uid).get();
  if (adminDataSnap.exists && adminDataSnap.data()?.isBlocked === true) {
    throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida. Contactá a soporte.");
  }

  // Load user's tenant to route payment via Stripe Connect
  const userSnap = await db.collection("users").doc(request.auth.uid).get();
  const tenantId = userSnap.exists ? (userSnap.data()?.tenantId ?? null) : null;
  let tenantConnectAccountId = null;
  let tenantCommissionRate = 0;
  let tenantStatus = null;

  if (tenantId) {
    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (tenantSnap.exists) {
      const tenantData = tenantSnap.data();
      tenantStatus = tenantData.status;
      if (tenantStatus === "suspended") {
        throw new HttpsError("permission-denied", "El servicio de tu organización está suspendido. Contactá al administrador.");
      }
      if (
        tenantData.stripeConnectStatus === "active" &&
        tenantData.stripeConnectAccountId
      ) {
        tenantConnectAccountId = tenantData.stripeConnectAccountId;
        tenantCommissionRate = typeof tenantData.commissionRate === "number"
          ? tenantData.commissionRate
          : 0.03;
      }
    }
  }

  const amount = Number(request.data?.amount || 0);
  // Validate currency against supported list before touching Stripe.
  const currency = validateCurrency(request.data?.currency || "usd");
  // Use the email from the verified Firebase ID token — never trust client-supplied
  // email, as it could be another user's address (Stripe would send them the receipt).
  const customerEmail = request.auth.token?.email
    ? String(request.auth.token.email).slice(0, 254)
    : null;
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

  // Idempotency key: uid + purpose + amount + currency + minute-bucket.
  // The minute bucket means a retry within the same minute reuses the same PI,
  // while a genuine second charge (new minute) gets a fresh PI.
  const idempotencyKey = `pi_${request.auth.uid}_${purpose}_${currency}_${amount}_${Math.floor(Date.now() / 60000)}`;

  // Build Stripe Connect params — only when the tenant has an active Connect account
  const connectParams = {};
  if (tenantConnectAccountId) {
    const appFee = Math.max(1, Math.floor(amount * tenantCommissionRate));
    connectParams.application_fee_amount = appFee;
    connectParams.transfer_data = { destination: tenantConnectAccountId };
  }

  let paymentIntent;
  try {
    const stripe = require("stripe")(stripeSecret.value());
    paymentIntent = await stripe.paymentIntents.create({
      amount,
      currency,
      receipt_email: customerEmail || undefined,
      automatic_payment_methods: { enabled: true },
      ...connectParams,
      metadata: {
        uid: request.auth.uid,
        source: "pushka",
        currency,
        amount: String(amount),
        purpose,
        ...(tenantId ? { tenantId } : {}),
      },
    }, { idempotencyKey });
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

// ---------------------------------------------------------------------------
// Stripe Customer — SetupIntent (save card for future off-session charges)
// ---------------------------------------------------------------------------

exports.createSetupIntent = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }
    await enforceRateLimit(request.auth.uid, "createSetupIntent", 5, 3600);

    const uid = request.auth.uid;
    const stripe = require("stripe")(stripeSecret.value());
    const userRef = db.collection("users").doc(uid);

    // Resolve (or create) Stripe customer inside a Firestore transaction to
    // prevent a race condition where two concurrent calls both find
    // stripeCustomerId === null and each create a separate Stripe customer.
    let customerId = null;
    let customerEmail = null;
    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      const userData = userSnap.data() || {};
      customerEmail = userData.email || request.auth.token?.email || null;
      customerId = userData.stripeCustomerId || null;
      if (!customerId) {
        // Create customer outside the transaction body is unsafe;
        // we mark a "pending" placeholder first so a concurrent call
        // reading inside its own transaction sees it and waits for the real ID.
        // Instead, we write a sentinel so the second concurrent call skips creation.
        // Pattern: write a temporary marker, then overwrite after Stripe responds.
        // Using a separate key prevents the second call from also creating a customer.
        tx.set(userRef, {
          stripeCustomerIdPending: true,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    });

    if (!customerId) {
      // Use a Stripe idempotency key keyed to the UID so concurrent calls produce
      // exactly one customer regardless of how many reach this point.
      try {
        const customer = await stripe.customers.create({
          email: customerEmail || undefined,
          metadata: { uid },
        }, { idempotencyKey: `customer_create_${uid}` });
        customerId = customer.id;
        await userRef.set({
          stripeCustomerId: customerId,
          stripeCustomerIdPending: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (stripeErr) {
        // Clear the pending sentinel so the next attempt is not blocked.
        await userRef.set({
          stripeCustomerIdPending: admin.firestore.FieldValue.delete(),
        }, { merge: true }).catch(() => {});
        throw stripeErr;
      }
    }

    // Idempotency key: uid + minute bucket — retries within the same minute
    // reuse the same SetupIntent instead of creating an orphaned one.
    const siIdempotencyKey = `si_${uid}_${Math.floor(Date.now() / 60000)}`;
    const setupIntent = await stripe.setupIntents.create({
      customer: customerId,
      payment_method_types: ["card"],
      usage: "off_session",
      metadata: { uid },
    }, { idempotencyKey: siIdempotencyKey });

    return { clientSecret: setupIntent.client_secret };
  }
);

// ---------------------------------------------------------------------------
// List saved cards for current user
// ---------------------------------------------------------------------------

exports.listSavedCards = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }
    // 30 card-list calls per hour per user
    await enforceRateLimit(request.auth.uid, "listSavedCards", 30, 3600);

    const uid = request.auth.uid;
    const userSnap = await db.collection("users").doc(uid).get();
    const customerId = userSnap.data()?.stripeCustomerId || null;

    if (!customerId) {
      return { cards: [], defaultPaymentMethodId: null };
    }

    const stripe = require("stripe")(stripeSecret.value());
    const customer = await stripe.customers.retrieve(customerId);

    // Customer was deleted directly in Stripe — clear the stale ID and return empty.
    if (customer.deleted) {
      await db.collection("users").doc(uid).set(
        { stripeCustomerId: null, stripeCustomerIdPending: null },
        { merge: true },
      ).catch(() => {});
      return { cards: [], defaultPaymentMethodId: null };
    }

    const defaultPmId = customer.invoice_settings?.default_payment_method || null;

    // Fetch all cards (limit: 100; practical ceiling — no user has >100 saved cards).
    // Stripe's default page size is 10, which would silently omit extra cards.
    const pmList = await stripe.paymentMethods.list({
      customer: customerId,
      type: "card",
      limit: 100,
    });

    const cards = pmList.data.map((pm) => ({
      id: pm.id,
      brand: pm.card?.brand || "card",
      last4: pm.card?.last4 || "****",
      expMonth: pm.card?.exp_month || 0,
      expYear: pm.card?.exp_year || 0,
      isDefault: pm.id === defaultPmId,
    }));

    return { cards, defaultPaymentMethodId: defaultPmId };
  }
);

// ---------------------------------------------------------------------------
// Delete a saved payment method
// ---------------------------------------------------------------------------

exports.deletePaymentMethod = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }
    // 10 PM deletions per hour per user
    await enforceRateLimit(request.auth.uid, "deletePaymentMethod", 10, 3600);

    const uid = request.auth.uid;
    const pmId = String(request.data?.paymentMethodId || "").trim();
    if (!pmId.startsWith("pm_")) {
      throw new HttpsError("invalid-argument", "paymentMethodId inválido.");
    }

    const stripe = require("stripe")(stripeSecret.value());
    const userRef = db.collection("users").doc(uid);
    const userSnap = await userRef.get();
    const customerId = userSnap.data()?.stripeCustomerId || null;

    if (!customerId) {
      throw new HttpsError("not-found", "No hay cliente Stripe para este usuario.");
    }

    // Retrieve PM — it may no longer exist if already deleted on another device.
    let pm;
    try {
      pm = await stripe.paymentMethods.retrieve(pmId);
    } catch (stripeErr) {
      if (stripeErr.statusCode === 404 || stripeErr.code === "resource_missing") {
        return { success: true }; // Already gone — idempotent success.
      }
      throw new HttpsError("internal", "Error al verificar el método de pago.");
    }

    // PM already detached (customer === null) — treat as idempotent success.
    if (pm.customer === null) {
      return { success: true };
    }

    if (pm.customer !== customerId) {
      throw new HttpsError("permission-denied", "Este método de pago no pertenece a tu cuenta.");
    }

    // Detach — a concurrent request may have beaten us; that's fine.
    try {
      await stripe.paymentMethods.detach(pmId);
    } catch (stripeErr) {
      if (stripeErr.statusCode !== 404 && stripeErr.code !== "resource_missing") {
        throw new HttpsError("internal", "Error al eliminar el método de pago.");
      }
      // Race: already detached between retrieve and detach — success.
    }

    // If deleted PM was the Stripe customer's invoice default, clear it there too.
    // Otherwise future off-session charges that rely on invoice_settings.default_payment_method
    // will fail because the PM is now detached.
    const stripeCustomer = await stripe.customers.retrieve(customerId);
    if (stripeCustomer.invoice_settings?.default_payment_method === pmId) {
      await stripe.customers.update(customerId, {
        invoice_settings: { default_payment_method: null },
      });
    }

    // If deleted PM was the Firestore-cached default, clear it from Firestore
    const defaultPmId = userSnap.data()?.stripeDefaultPaymentMethodId || null;
    if (defaultPmId === pmId) {
      await userRef.set({
        stripeDefaultPaymentMethodId: null,
        stripeDefaultPaymentMethodLast4: null,
        stripeDefaultPaymentMethodBrand: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    return { success: true };
  }
);

// ---------------------------------------------------------------------------
// Set a payment method as default for off-session charges
// ---------------------------------------------------------------------------

exports.setDefaultPaymentMethod = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }
    // 20 default-PM changes per hour per user
    await enforceRateLimit(request.auth.uid, "setDefaultPaymentMethod", 20, 3600);

    const uid = request.auth.uid;
    const pmId = String(request.data?.paymentMethodId || "").trim();
    if (!pmId.startsWith("pm_")) {
      throw new HttpsError("invalid-argument", "paymentMethodId inválido.");
    }

    const stripe = require("stripe")(stripeSecret.value());
    const userRef = db.collection("users").doc(uid);
    const userSnap = await userRef.get();
    const customerId = userSnap.data()?.stripeCustomerId || null;

    if (!customerId) {
      throw new HttpsError("not-found", "No hay cliente Stripe para este usuario.");
    }

    const pm = await stripe.paymentMethods.retrieve(pmId);
    if (pm.customer !== customerId) {
      throw new HttpsError("permission-denied", "Este método de pago no pertenece a tu cuenta.");
    }

    // Update Stripe Customer's default payment method
    await stripe.customers.update(customerId, {
      invoice_settings: { default_payment_method: pmId },
    });

    // Cache brand/last4 in Firestore for display in settings
    await userRef.set({
      stripeDefaultPaymentMethodId: pmId,
      stripeDefaultPaymentMethodLast4: pm.card?.last4 || null,
      stripeDefaultPaymentMethodBrand: pm.card?.brand || null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    return { success: true };
  }
);

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

      // wallet_auto_topup / pushka_auto_empty: state already updated by the
      // scheduled CF that confirmed the charge. Just mark the event as processed.
      if (uid && (purpose === "wallet_auto_topup" || purpose === "pushka_auto_empty")) {
        await finalizeWebhookEvent(eventRef, {
          status: "processed",
          uid,
          paymentIntentId: docId,
          amount,
          outcome: purpose,
        });
      } else if (uid && (purpose === "donation" || purpose === "pushka_empty")) {
        const txType = purpose === "pushka_empty" ? "pushkaEmpty" : "tzedaka";
        const txDesc = purpose === "pushka_empty" ? "Vaciado de Pushka (Stripe)" : "Donación Stripe";
        const txCurrency = String(intent.currency || "usd").toUpperCase();
        const txRates = await getExchangeRates(null);
        const txSnap = buildCurrencySnapshot(amount, txCurrency, txRates);
        await db
          .collection("users")
          .doc(uid)
          .collection("transactions")
          .doc(docId)
          .set({
            type: txType,
            amount,
            currencyCode: txCurrency,
            ...txSnap,
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
          currencyCode: String(intent.currency || "usd").toUpperCase(),
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
    } else if (event.type === "account.updated") {
      // Stripe Connect: connected account status changed (charges/payouts enabled/disabled)
      const account = event.data.object;
      const accountId = account.id;

      const tenantsSnap = await db.collection("tenants")
        .where("stripeConnectAccountId", "==", accountId)
        .limit(1)
        .get();

      if (!tenantsSnap.empty) {
        const tenantRef = tenantsSnap.docs[0].ref;
        const chargesEnabled = account.charges_enabled === true;
        const payoutsEnabled = account.payouts_enabled === true;
        const newConnectStatus = chargesEnabled && payoutsEnabled ? "active" : "restricted";

        await tenantRef.update({
          stripeConnectStatus: newConnectStatus,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        accountId,
        outcome: "account_updated",
      });
    } else if (event.type === "application_fee.created") {
      // Our commission was collected — log for tracking
      const fee = event.data.object;
      const tenantId = fee.charge?.metadata?.tenantId ?? null;
      const amountUsd = (fee.amount || 0) / 100;

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        tenantId,
        amountUsd,
        chargeId: fee.charge?.id ?? null,
        outcome: "commission_collected",
      });
    } else {
      await finalizeWebhookEvent(eventRef, {
        status: "ignored",
        reason: "event_type_not_handled",
      });
    }

    res.json({ received: true });
  } catch (err) {
    try {
      await finalizeWebhookEvent(eventRef, {
        status: "failed",
        error: String(err?.message || err || "unknown_error"),
      });
    } catch (finalizeErr) {
      console.error("stripeWebhook: Failed to finalize failed event", finalizeErr?.message);
    }
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

    // Scheduled jobs (auto-empty, auto-topup) send their own notification
    if (data.skipNotification === true) return;

    // Rate-limit transaction notifications to prevent a client that spams
    // client-writable transaction types (tzedaka / pushkaEmpty) from flooding
    // their own device (and burning Cloud Messaging quota).
    // 30 notifications per hour is well above any legitimate usage.
    try {
      await enforceRateLimit(uid, "onTransactionCreated", 30, 3600);
    } catch (_) {
      // Silently drop the notification — do NOT rethrow, as that would cause
      // the Firestore trigger to retry indefinitely.
      return;
    }

    // Detect user language and currency from profile
    let lang = "es";
    let sym = "$";
    try {
      const userSnap = await admin.firestore().collection("users").doc(uid).get();
      const userData = userSnap.data() || {};
      const userLang = userData.language;
      if (userLang === "en" || userLang === "fr" || userLang === "he") lang = userLang;
      const rawCode = String(userData.currencyCode || "usd").toLowerCase().trim();
      sym = currencySymbol(SUPPORTED_CURRENCIES.has(rawCode) ? rawCode : "usd");
    } catch (_) { /* default to Spanish / USD */ }

    const fmt = (n) => `${sym}${Number(n).toFixed(2)}`;
    const abs = Math.abs(Number(amount));

    const messages = {
      es: {
        tzedaka:       `¡Gracias por tu donación! ${fmt(amount)}`,
        pushkaEmpty:   `Tu Pushka fue vaciada. Donación: ${fmt(amount)}`,
        walletFillPos: `Billetera recargada con ${fmt(amount)}`,
        walletFillNeg: `Transferencia enviada: ${fmt(abs)}`,
        default:       "Nueva transacción registrada",
      },
      en: {
        tzedaka:       `Thank you for your donation! ${fmt(amount)}`,
        pushkaEmpty:   `Your Pushka was emptied. Donation: ${fmt(amount)}`,
        walletFillPos: `Wallet topped up with ${fmt(amount)}`,
        walletFillNeg: `Transfer sent: ${fmt(abs)}`,
        default:       "New transaction recorded",
      },
      fr: {
        tzedaka:       `Merci pour votre don ! ${fmt(amount)}`,
        pushkaEmpty:   `Votre Pushka a été vidée. Don : ${fmt(amount)}`,
        walletFillPos: `Portefeuille rechargé de ${fmt(amount)}`,
        walletFillNeg: `Transfert envoyé : ${fmt(abs)}`,
        default:       "Nouvelle transaction enregistrée",
      },
      he: {
        tzedaka:       `תודה על תרומתך! ${fmt(amount)}`,
        pushkaEmpty:   `הפושקה שלך רוקנה. תרומה: ${fmt(amount)}`,
        walletFillPos: `הארנק נטען ב-${fmt(amount)}`,
        walletFillNeg: `העברה נשלחה: ${fmt(abs)}`,
        default:       "עסקה חדשה נרשמה",
      },
    };

    const m = messages[lang];
    let body = m.default;
    if (type === "tzedaka") body = m.tzedaka;
    else if (type === "pushkaEmpty") body = m.pushkaEmpty;
    else if (type === "walletFill" && amount >= 0) body = m.walletFillPos;
    else if (type === "walletFill" && amount < 0) body = m.walletFillNeg;

    const tenantId = data.tenantId ?? "";
    await sendToUser(uid, {
      notification: { title: "Pushka", body },
      data: { type, amount: String(amount), tenantId },
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

    // 20 top-up confirmations per hour per user
    await enforceRateLimit(request.auth.uid, "walletTopUpFromPaymentIntent", 20, 3600);

    const uid = request.auth.uid;

    // Block suspended users from claiming wallet top-ups
    const adminDataSnap = await db.collection("adminData").doc(uid).get();
    if (adminDataSnap.exists && adminDataSnap.data()?.isBlocked === true) {
      throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida. Contactá a soporte.");
    }

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

    const wfCurrency = String(intent.currency || "usd").toUpperCase();
    const wfRates = await getExchangeRates(null);
    const wfSnap = buildCurrencySnapshot(amount, wfCurrency, wfRates);

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
      updatedBalance = Math.round((currentBalance + amount) * 100) / 100;

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
        currencyCode: wfCurrency,
        ...wfSnap,
        description: "Recarga de billetera con tarjeta",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
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
    // 20 transfers per hour per user
    await enforceRateLimit(request.auth.uid, "walletTransfer", 20, 3600);

    const senderUid = request.auth.uid;

    // Block transfers for suspended users
    const senderAdminSnap = await db.collection("adminData").doc(senderUid).get();
    if (senderAdminSnap.exists && senderAdminSnap.data()?.isBlocked === true) {
      throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida. Contactá a soporte.");
    }

    const targetWalletId = String(request.data?.targetWalletId || "").trim();
    const rawAmount = Number(request.data?.amount || 0);
    // Round to 2 decimal places to avoid floating-point precision issues.
    const amount = Math.round(rawAmount * 100) / 100;

    if (!targetWalletId || !/^\d{8}$/.test(targetWalletId)) {
      throw new HttpsError("invalid-argument", "ID destino debe ser de 8 dígitos.");
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
    const transferRates = await getExchangeRates(null);

    await db.runTransaction(async (tx) => {
      const senderSnap = await tx.get(senderRef);
      const receiverSnap = await tx.get(receiverRef);

      if (!senderSnap.exists || !receiverSnap.exists) {
        throw new HttpsError("not-found", "No se pudo completar la transferencia.");
      }

      // Re-validate that the receiver's walletId hasn't changed since the
      // pre-transaction query (walletIds should be immutable, but verify defensively).
      if ((receiverSnap.data() || {}).walletId !== targetWalletId) {
        throw new HttpsError("not-found", "La billetera destino ya no existe.");
      }

      const senderBalance = Number((senderSnap.data() || {}).walletBalance || 0);
      const receiverBalance = Number((receiverSnap.data() || {}).walletBalance || 0);

      if (senderBalance < amount) {
        throw new HttpsError("failed-precondition", "Saldo insuficiente.");
      }

      senderBalanceAfter = Math.round((senderBalance - amount) * 100) / 100;
      const receiverBalanceAfter = Math.round((receiverBalance + amount) * 100) / 100;

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

      const senderCurrency = String((senderSnap.data() || {}).currencyCode || "USD").toUpperCase();
      const receiverCurrency = String((receiverSnap.data() || {}).currencyCode || "USD").toUpperCase();
      const senderTenantId = (senderSnap.data() || {}).tenantId ?? null;
      const receiverTenantId = (receiverSnap.data() || {}).tenantId ?? null;
      const senderCurrSnap = buildCurrencySnapshot(amount, senderCurrency, transferRates);
      const receiverCurrSnap = buildCurrencySnapshot(amount, receiverCurrency, transferRates);

      tx.set(senderRef.collection("transactions").doc(), {
        type: "walletFill",
        amount: -amount,
        currencyCode: senderCurrency,
        ...senderCurrSnap,
        amountUSD: -senderCurrSnap.amountUSD,
        amountMXN: -senderCurrSnap.amountMXN,
        tenantId: senderTenantId,
        description: `Transferencia enviada a ${targetWalletId}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(receiverRef.collection("transactions").doc(), {
        type: "walletFill",
        amount,
        currencyCode: receiverCurrency,
        ...receiverCurrSnap,
        tenantId: receiverTenantId,
        description: "Transferencia recibida",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    return { success: true, walletBalance: senderBalanceAfter };
  },
);

exports.walletRequestTransfer = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    // 30 requests per hour per user
    await enforceRateLimit(request.auth.uid, "walletRequestTransfer", 30, 3600);

    const requesterUid = request.auth.uid;

    // Block requests from suspended users
    const reqAdminSnap = await db.collection("adminData").doc(requesterUid).get();
    if (reqAdminSnap.exists && reqAdminSnap.data()?.isBlocked === true) {
      throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida. Contactá a soporte.");
    }

    const fromWalletId = String(request.data?.fromWalletId || "").trim();
    const rawAmount = Number(request.data?.amount || 0);
    // Round to 2 decimal places to avoid floating-point precision issues.
    const amount = Math.round(rawAmount * 100) / 100;

    if (!fromWalletId || !/^\d{8}$/.test(fromWalletId)) {
      throw new HttpsError("invalid-argument", "ID de billetera debe ser de 8 dígitos.");
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new HttpsError("invalid-argument", "Monto inválido.");
    }
    if (amount > 1000000) {
      throw new HttpsError("invalid-argument", "El monto excede el límite permitido.");
    }

    // Resolve target user by walletId
    const targetQuery = await db
      .collection("users")
      .where("walletId", "==", fromWalletId)
      .limit(1)
      .get();

    if (targetQuery.empty) {
      throw new HttpsError("not-found", "No existe una billetera con ese ID.");
    }

    const targetUid = targetQuery.docs[0].id;
    if (targetUid === requesterUid) {
      throw new HttpsError("failed-precondition", "No puedes solicitarte a ti mismo.");
    }

    // Get requester wallet ID and currency to display in notification
    const requesterSnap = await db.collection("users").doc(requesterUid).get();
    const requesterWalletId = String(requesterSnap.data()?.walletId || "");
    if (!requesterWalletId || !/^\d{8}$/.test(requesterWalletId)) {
      throw new HttpsError("not-found", "Tu billetera no está configurada correctamente.");
    }
    const requesterCurrencyCode = String(requesterSnap.data()?.currencyCode || "usd").toLowerCase().trim();
    const requesterSym = currencySymbol(SUPPORTED_CURRENCIES.has(requesterCurrencyCode) ? requesterCurrencyCode : "usd");

    // Write pending request to target user
    await db.collection("users").doc(targetUid).collection("walletRequests").add({
      fromUid: requesterUid,
      fromWalletId: requesterWalletId,
      amount,
      currency: requesterCurrencyCode,
      status: "pending",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Notify target user (in their language)
    const targetLang = await getUserLanguage(targetUid);
    const requestTitles = { es: "Solicitud de Tzedaká", en: "Tzedakah Request", fr: "Demande de Tzedaka", he: "בקשת צדקה" };
    const requestBodies = {
      es: `${requesterWalletId} te solicita ${requesterSym}${amount.toFixed(2)}`,
      en: `${requesterWalletId} is requesting ${requesterSym}${amount.toFixed(2)} from you`,
      fr: `${requesterWalletId} vous demande ${requesterSym}${amount.toFixed(2)}`,
      he: `${requesterWalletId} מבקש ${requesterSym}${amount.toFixed(2)} ממך`,
    };
    await sendToUser(targetUid, {
      notification: {
        title: requestTitles[targetLang],
        body: requestBodies[targetLang],
      },
      data: { type: "wallet_request", amount: String(amount), fromWalletId: requesterWalletId },
    }).catch(() => {});

    return { success: true };
  },
);

// ---------------------------------------------------------------------------
// Accept a pending wallet payment request (caller = target user who was asked)
// ---------------------------------------------------------------------------

exports.acceptWalletRequest = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    await enforceRateLimit(request.auth.uid, "acceptWalletRequest", 20, 3600);

    const uid = request.auth.uid;

    // Block transfers for suspended users
    const acceptorAdminSnap = await db.collection("adminData").doc(uid).get();
    if (acceptorAdminSnap.exists && acceptorAdminSnap.data()?.isBlocked === true) {
      throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida. Contactá a soporte.");
    }

    const requestId = String(request.data?.requestId || "").trim();
    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId inválido.");
    }

    const requestRef = db.collection("users").doc(uid).collection("walletRequests").doc(requestId);

    // All reads — including requestRef status — happen INSIDE the transaction.
    // This closes the TOCTOU race where two concurrent acceptWalletRequest calls
    // both pass a pre-transaction status check and both execute the debit.
    let fromUid = "";
    let amount = 0;
    let fromWalletId = "";
    await db.runTransaction(async (tx) => {
      // Re-read the request inside the transaction so Firestore serialises
      // concurrent accept calls on this document.
      const requestSnap = await tx.get(requestRef);

      if (!requestSnap.exists) {
        throw new HttpsError("not-found", "Solicitud no encontrada.");
      }

      const reqData = requestSnap.data() || {};
      if (reqData.status !== "pending") {
        throw new HttpsError("failed-precondition", "Esta solicitud ya fue procesada.");
      }

      fromUid = String(reqData.fromUid || "");
      amount = Number(reqData.amount || 0);
      fromWalletId = String(reqData.fromWalletId || "");

      if (!fromUid || !Number.isFinite(amount) || amount <= 0) {
        throw new HttpsError("internal", "Datos de solicitud inválidos.");
      }
      if (amount > 1000000) {
        throw new HttpsError("invalid-argument", "El monto de la solicitud excede el límite permitido.");
      }

      const senderRef = db.collection("users").doc(uid);
      const receiverRef = db.collection("users").doc(fromUid);

      const senderSnap = await tx.get(senderRef);
      const receiverSnap = await tx.get(receiverRef);

      if (!senderSnap.exists || !receiverSnap.exists) {
        throw new HttpsError("not-found", "No se pudo completar la transferencia.");
      }

      const senderBalance = Number((senderSnap.data() || {}).walletBalance || 0);
      if (senderBalance < amount) {
        throw new HttpsError("failed-precondition", "Saldo insuficiente.");
      }

      const receiverBalance = Number((receiverSnap.data() || {}).walletBalance || 0);
      const senderWalletId = String((senderSnap.data() || {}).walletId || uid);

      tx.set(senderRef, {
        walletBalance: Math.round((senderBalance - amount) * 100) / 100,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      tx.set(receiverRef, {
        walletBalance: Math.round((receiverBalance + amount) * 100) / 100,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      const reqRates = await getExchangeRates(null);
      const senderCurrCode = String((senderSnap.data() || {}).currencyCode || "USD").toUpperCase();
      const receiverCurrCode = String((receiverSnap.data() || {}).currencyCode || "USD").toUpperCase();
      const reqSenderCurrSnap = buildCurrencySnapshot(amount, senderCurrCode, reqRates);
      const reqReceiverCurrSnap = buildCurrencySnapshot(amount, receiverCurrCode, reqRates);
      const senderTenantId = (senderSnap.data() || {}).tenantId ?? null;
      const receiverTenantId = (receiverSnap.data() || {}).tenantId ?? null;

      tx.set(senderRef.collection("transactions").doc(), {
        type: "walletFill",
        amount: -amount,
        currencyCode: senderCurrCode,
        ...reqSenderCurrSnap,
        amountUSD: -reqSenderCurrSnap.amountUSD,
        amountMXN: -reqSenderCurrSnap.amountMXN,
        tenantId: senderTenantId,
        description: `Solicitud aceptada — enviado a ${fromWalletId}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(receiverRef.collection("transactions").doc(), {
        type: "walletFill",
        amount,
        currencyCode: receiverCurrCode,
        ...reqReceiverCurrSnap,
        tenantId: receiverTenantId,
        description: `Solicitud aceptada — recibido de ${senderWalletId}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Mark request as accepted atomically with the balance update.
      tx.set(requestRef, {
        status: "accepted",
        resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    // Notify the requester (in their language)
    const receiverLang = await getUserLanguage(fromUid);
    const acceptCurrency = await getUserCurrency(fromUid);
    const acceptSym = currencySymbol(acceptCurrency);
    const acceptTitles = { es: "Solicitud aceptada ✓", en: "Request accepted ✓", fr: "Demande acceptée ✓", he: "הבקשה אושרה ✓" };
    const acceptBodies = {
      es: `Tu solicitud de ${acceptSym}${amount.toFixed(2)} fue aceptada.`,
      en: `Your request for ${acceptSym}${amount.toFixed(2)} was accepted.`,
      fr: `Votre demande de ${acceptSym}${amount.toFixed(2)} a été acceptée.`,
      he: `בקשתך ל-${acceptSym}${amount.toFixed(2)} אושרה.`,
    };
    await sendToUser(fromUid, {
      notification: { title: acceptTitles[receiverLang], body: acceptBodies[receiverLang] },
      data: { type: "walletFill", amount: String(amount) },
    }).catch(() => {});

    return { success: true };
  },
);

// ---------------------------------------------------------------------------
// Reject a pending wallet payment request
// ---------------------------------------------------------------------------

exports.rejectWalletRequest = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    await enforceRateLimit(request.auth.uid, "rejectWalletRequest", 20, 3600);

    const uid = request.auth.uid;

    // Block action for suspended users (consistency with accept)
    const rejectAdminSnap = await db.collection("adminData").doc(uid).get();
    if (rejectAdminSnap.exists && rejectAdminSnap.data()?.isBlocked === true) {
      throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida. Contactá a soporte.");
    }

    const requestId = String(request.data?.requestId || "").trim();
    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId inválido.");
    }

    const requestRef = db.collection("users").doc(uid).collection("walletRequests").doc(requestId);

    // Use a transaction to atomically check status and set rejected,
    // preventing a race condition where two simultaneous calls both succeed.
    let reqData = {};
    await db.runTransaction(async (tx) => {
      const requestSnap = await tx.get(requestRef);

      if (!requestSnap.exists) {
        throw new HttpsError("not-found", "Solicitud no encontrada.");
      }

      reqData = requestSnap.data() || {};
      if (reqData.status !== "pending") {
        throw new HttpsError("failed-precondition", "Esta solicitud ya fue procesada.");
      }

      tx.set(requestRef, {
        status: "rejected",
        resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    // Optionally notify the requester
    const fromUid = String(reqData.fromUid || "");
    const amount = Number(reqData.amount || 0);
    if (fromUid) {
      const rejectLang = await getUserLanguage(fromUid);
      const rejectCurrency = await getUserCurrency(fromUid);
      const rejectSym = currencySymbol(rejectCurrency);
      const rejectTitles = { es: "Solicitud rechazada", en: "Request rejected", fr: "Demande rejetée", he: "הבקשה נדחתה" };
      const rejectBodies = {
        es: `Tu solicitud de ${rejectSym}${amount.toFixed(2)} fue rechazada.`,
        en: `Your request for ${rejectSym}${amount.toFixed(2)} was rejected.`,
        fr: `Votre demande de ${rejectSym}${amount.toFixed(2)} a été rejetée.`,
        he: `בקשתך ל-${rejectSym}${amount.toFixed(2)} נדחתה.`,
      };
      await sendToUser(fromUid, {
        notification: { title: rejectTitles[rejectLang], body: rejectBodies[rejectLang] },
        data: { type: "walletRequestRejected", amount: String(amount) },
      }).catch(() => {});
    }

    return { success: true };
  },
);

exports.addWalletContact = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }

    // 30 contact additions per hour per user
    await enforceRateLimit(request.auth.uid, "addWalletContact", 30, 3600);

    const uid = request.auth.uid;
    const walletId = String(request.data?.walletId || "").trim();
    if (!walletId || !/^\d{8}$/.test(walletId)) {
      throw new HttpsError("invalid-argument", "ID de billetera debe ser de 8 dígitos numéricos.");
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

    // Enforce same-tenant isolation for wallet contacts
    const ownTenantId = ownSnap.data()?.tenantId ?? null;
    const targetTenantId = targetDoc.data()?.tenantId ?? null;
    if (ownTenantId && targetTenantId && ownTenantId !== targetTenantId) {
      throw new HttpsError("not-found", "No existe una billetera con ese ID.");
    }

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
    const MAX_BATCHES = 100; // 100 × 400 = 40,000 max deletions per run
    let batches = 0;
    while (batches++ < MAX_BATCHES) {
      const deleted = await deleteQueryBatch(
        db
          .collectionGroup("fcmTokens")
          .where("lastUsedAt", "<", staleBefore)
          .limit(400),
      );
      totalDeleted += deleted;
      if (deleted === 0) break;
    }
    if (batches >= MAX_BATCHES) {
      console.warn("cleanupStaleFcmTokens: hit batch limit, may need another run");
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
    const MAX_BATCHES = 100;
    let batches = 0;
    while (batches++ < MAX_BATCHES) {
      const deleted = await deleteQueryBatch(
        db
          .collection("_stripeWebhookEvents")
          .where("createdAt", "<", olderThan)
          .limit(400),
      );
      totalDeleted += deleted;
      if (deleted === 0) break;
    }
    if (batches >= MAX_BATCHES) {
      console.warn("cleanupOldStripeWebhookEvents: hit batch limit, may need another run");
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
    secrets: [stripeSecret],
  },
  async () => {
    if (!stripeSecret.value()) {
      console.error("processWalletAutoTopUps: STRIPE_SECRET_KEY missing");
      return;
    }

    const nowTs = admin.firestore.Timestamp.now();
    // Pre-filter on walletAutoTopUpEnabled to avoid burning the 150-doc page
    // limit on users who have disabled auto top-up but still have a stale nextRunAt.
    const dueUsers = await db
      .collection("users")
      .where("walletAutoTopUpEnabled", "==", true)
      .where("walletAutoTopUpNextRunAt", "<=", nowTs)
      .limit(150)
      .get();

    if (dueUsers.empty) {
      console.info("processWalletAutoTopUps: no_due_users");
      return;
    }

    let processed = 0;
    let failed = 0;
    const stripe = require("stripe")(stripeSecret.value());

    for (const doc of dueUsers.docs) {
      let chargeData = null; // captured inside transaction, used outside
      try {
        // Step 1: Firestore transaction — verify due, grab data, advance schedule.
        // Does NOT update the balance yet (that happens only after Stripe confirms).
        await db.runTransaction(async (tx) => {
          const userRef = doc.ref;
          const snap = await tx.get(userRef);
          if (!snap.exists) return;

          const data = snap.data() || {};
          if (data.walletAutoTopUpEnabled !== true) return;
          const nextRun = data.walletAutoTopUpNextRunAt;
          if (!nextRun || nextRun.toMillis() > Date.now()) return;

          const amount = Number(data.walletAutoTopUpAmount || 0);
          if (!Number.isFinite(amount) || amount <= 0) {
            // Invalid config — disable to stop retrying
            tx.set(userRef, {
              walletAutoTopUpEnabled: false,
              walletAutoTopUpNextRunAt: null,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }

          const customerId = String(data.stripeCustomerId || "").trim();
          const pmId = String(data.stripeDefaultPaymentMethodId || "").trim();
          if (!customerId || !pmId) {
            // No saved card — advance schedule and skip charge
            console.warn("processWalletAutoTopUps: no_saved_card", { uid: doc.id });
            const frequency = String(data.walletAutoTopUpFrequency || "weekly");
            const weekday = Number(data.walletAutoTopUpWeekday || 1);
            const dayOfMonth = Number(data.walletAutoTopUpDayOfMonth || 1);
            const nextDate = computeNextWalletTopUpDate({ frequency, weekday, dayOfMonth, baseDate: new Date() });
            tx.set(userRef, {
              walletAutoTopUpNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }

          const frequency = String(data.walletAutoTopUpFrequency || "weekly");
          const weekday = Number(data.walletAutoTopUpWeekday || 1);
          const dayOfMonth = Number(data.walletAutoTopUpDayOfMonth || 1);
          const nextDate = computeNextWalletTopUpDate({ frequency, weekday, dayOfMonth, baseDate: new Date() });

          // Validate currency from user profile before it reaches Stripe.
          // If the stored value is not in the supported list, skip this user.
          const rawCurrency = String(data.currencyCode || "usd").toLowerCase().trim();
          if (!SUPPORTED_CURRENCIES.has(rawCurrency)) {
            console.warn("processWalletAutoTopUps: unsupported_currency", { uid: doc.id, rawCurrency });
            tx.set(userRef, {
              walletAutoTopUpNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }
          const currency = rawCurrency;

          // Capture current nextRunAt as a stable key for Stripe idempotency.
          // Using the scheduled run timestamp (truncated to seconds) ensures
          // crash-and-retry never creates a duplicate charge for the same cycle.
          const runTs = nextRun.toMillis();

          // Advance schedule now — charge happens outside the transaction
          tx.set(userRef, {
            walletAutoTopUpNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

          chargeData = { amount, currency, customerId, pmId, nextRunDateKey: String(runTs) };
        });

        if (!chargeData) continue;

        // Step 2: Off-session Stripe charge
        const amountCents = Math.round(chargeData.amount * 100);
        const minCents = minAmountForCurrency(chargeData.currency);
        if (amountCents < minCents) {
          console.warn("processWalletAutoTopUps: amount_below_minimum", { uid: doc.id, amountCents, minCents });
          continue;
        }

        // Idempotency key: uid + scheduled run date (truncated to day) ensures
        // a crash-and-retry never double-charges the same scheduled cycle.
        const topUpIdempotencyKey = `wallet_auto_topup_${doc.id}_${chargeData.nextRunDateKey}`;

        let paymentIntent;
        try {
          paymentIntent = await stripe.paymentIntents.create({
            amount: amountCents,
            currency: chargeData.currency,
            customer: chargeData.customerId,
            payment_method: chargeData.pmId,
            off_session: true,
            confirm: true,
            error_on_requires_action: true,
            metadata: {
              uid: doc.id,
              source: "pushka",
              purpose: "wallet_auto_topup",
            },
          }, { idempotencyKey: topUpIdempotencyKey });
        } catch (stripeErr) {
          console.error("processWalletAutoTopUps: stripe_charge_failed", {
            uid: doc.id,
            error: String(stripeErr?.message || stripeErr),
            code: stripeErr?.code,
          });
          // Notify user their card was declined
          const failLang = await getUserLanguage(doc.id);
          const failTitles = { es: "Recarga fallida", en: "Refill failed", fr: "Recharge échouée", he: "הטעינה נכשלה" };
          const failBodies = {
            es: "No pudimos cargar tu tarjeta para la recarga automática. Revisá tu tarjeta en Configuración.",
            en: "We couldn't charge your card for the automatic refill. Please check your card in Settings.",
            fr: "Nous n'avons pas pu débiter votre carte pour la recharge automatique. Vérifiez votre carte dans Paramètres.",
            he: "לא הצלחנו לחייב את הכרטיס שלך לטעינה האוטומטית. בדוק את הכרטיס שלך בהגדרות.",
          };
          await sendToUser(doc.id, {
            notification: { title: failTitles[failLang], body: failBodies[failLang] },
            data: { type: "walletAutoTopUpFailed" },
          }).catch(() => {});
          failed += 1;
          continue;
        }

        if (paymentIntent.status !== "succeeded") {
          console.warn("processWalletAutoTopUps: payment_not_succeeded", { uid: doc.id, status: paymentIntent.status });
          failed += 1;
          continue;
        }

        // Step 3: Charge confirmed — update wallet balance.
        // Use the paymentIntentId as the transaction doc ID to make this step
        // idempotent: if it crashes and retries, the duplicate set() on the same
        // doc ID will be a no-op (merge: true with same data).
        const toppedUpAmount = chargeData.amount;
        const piId = paymentIntent.id;
        try {
          await db.runTransaction(async (tx) => {
            // Read the movement doc first — if it already exists this step was
            // already applied (e.g. on a CF retry), so skip the balance update
            // to prevent double-crediting.
            const movementRef = doc.ref.collection("transactions").doc(piId);
            const movementSnap = await tx.get(movementRef);
            if (movementSnap.exists) return;

            const snap = await tx.get(doc.ref);
            const currentBalance = Number(snap.data()?.walletBalance || 0);
            tx.set(doc.ref, {
              walletBalance: Math.round((currentBalance + toppedUpAmount) * 100) / 100,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            const autoTopRates = await getExchangeRates(null);
            const autoTopSnap = buildCurrencySnapshot(toppedUpAmount, chargeData.currency.toUpperCase(), autoTopRates);
            tx.set(movementRef, {
              type: "walletFill",
              amount: toppedUpAmount,
              currencyCode: chargeData.currency.toUpperCase(),
              ...autoTopSnap,
              description: "Recarga automática de billetera",
              skipNotification: true,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          });
        } catch (step3Err) {
          // CRITICAL: Stripe charge succeeded but balance update failed.
          // Log with paymentIntentId so this can be manually recovered.
          console.error("processWalletAutoTopUps: step3_balance_update_failed_after_charge", {
            uid: doc.id,
            paymentIntentId: piId,
            amount: toppedUpAmount,
            error: String(step3Err?.message || step3Err),
          });
          failed += 1;
          continue;
        }

        // Step 4: Notify success
        const topUpLang = await getUserLanguage(doc.id);
        const topUpSym = currencySymbol(chargeData.currency);
        const topUpTitles = { es: "Billetera recargada", en: "Wallet topped up", fr: "Portefeuille rechargé", he: "הארנק נטען" };
        const topUpBodies = {
          es: `Tu billetera fue recargada automáticamente con ${topUpSym}${toppedUpAmount.toFixed(2)}`,
          en: `Your wallet was automatically topped up with ${topUpSym}${toppedUpAmount.toFixed(2)}`,
          fr: `Votre portefeuille a été rechargé automatiquement de ${topUpSym}${toppedUpAmount.toFixed(2)}`,
          he: `הארנק שלך נטען אוטומטית ב-${topUpSym}${toppedUpAmount.toFixed(2)}`,
        };
        await sendToUser(doc.id, {
          notification: { title: topUpTitles[topUpLang], body: topUpBodies[topUpLang] },
          data: { type: "walletFill" },
        }).catch(() => {});

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


// --- Erev Rosh Chodesh lookup (Gregorian dates for years 2025-2035) ---
// Format: [month 0-indexed, day]. Tishrei (month 7 Hebrew) is skipped (Rosh HaShana).
const erevRoshChodeshDates = {
  2025: [[0,29],[1,27],[2,29],[3,27],[4,27],[5,25],[6,25],[7,23],[9,21],[10,20],[11,19]],
  2026: [[0,18],[1,16],[2,18],[3,16],[4,16],[5,14],[6,14],[7,12],[9,10],[10,9],[11,9]],
  2027: [[0,8],[1,6],[2,8],[3,7],[4,6],[5,5],[6,4],[7,3],[8,1],[9,30],[10,29],[11,29]],
  2028: [[0,28],[1,26],[2,27],[3,25],[4,25],[5,23],[6,23],[7,21],[9,19],[10,18],[11,17]],
  2029: [[0,16],[1,14],[2,16],[3,14],[4,14],[5,12],[6,12],[7,10],[9,8],[10,7],[11,6]],
  2030: [[0,4],[1,2],[2,4],[3,3],[4,2],[5,1],[5,30],[6,30],[7,28],[9,26],[10,25],[11,25]],
  2031: [[0,24],[1,22],[2,24],[3,22],[4,22],[5,20],[6,20],[7,18],[9,16],[10,15],[11,15]],
  2032: [[0,13],[1,12],[2,12],[3,11],[4,10],[5,9],[6,8],[7,7],[9,5],[10,3],[11,3]],
  2033: [[0,2],[1,1],[1,28],[2,30],[3,29],[4,28],[5,27],[6,26],[7,25],[9,22],[10,22],[11,21]],
  2034: [[0,21],[1,19],[2,21],[3,19],[4,19],[5,17],[6,17],[7,15],[9,13],[10,12],[11,12]],
  2035: [[0,10],[1,9],[2,11],[3,9],[4,9],[5,7],[6,7],[7,5],[9,3],[10,2],[11,1],[11,31]],
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
  candidates.sort((a, b) => a - b);
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
    secrets: [stripeSecret],
  },
  async () => {
    if (!stripeSecret.value()) {
      console.error("processPushkaAutoEmpty: STRIPE_SECRET_KEY missing");
      return;
    }

    const nowTs = admin.firestore.Timestamp.now();
    // Pre-filter on autoEmptyFrequency to avoid burning the 150-doc page limit on
    // users who have autoEmptyFrequency === "manual" but a stale past autoEmptyNextRunAt.
    // Firestore inequality + != filters don't mix with other inequalities, so we
    // use an existence-based guard: only users who have stored a non-"manual" value.
    // The transaction body still double-checks freq === "manual" as a safety net.
    // NOTE: Firestore does not allow two inequality filters on different fields
    // in the same query (e.g., "<=" on autoEmptyNextRunAt and "!=" on
    // autoEmptyFrequency). We therefore filter only on the timestamp here and
    // guard against freq === "manual" inside the transaction body (which already
    // does this). This keeps the query valid and avoids a runtime Firestore error.
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
    const stripe = require("stripe")(stripeSecret.value());

    for (const doc of dueUsers.docs) {
      let chargeData = null; // set inside transaction, used outside
      try {
        // Step 1: Firestore transaction — verify due, grab data, advance schedule.
        // Does NOT reset the pushka yet (that happens only after Stripe confirms).
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
            nextDate = computeNextWalletTopUpDate({ frequency: freq, weekday, dayOfMonth, baseDate: new Date() });
          }

          // Below minimum — advance schedule without charging
          if (currentAmount < minBalance) {
            tx.set(userRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }

          const customerId = String(data.stripeCustomerId || "").trim();
          const pmId = String(data.stripeDefaultPaymentMethodId || "").trim();
          if (!customerId || !pmId) {
            // No saved card — advance schedule without charging
            console.warn("processPushkaAutoEmpty: no_saved_card", { uid: doc.id });
            tx.set(userRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }

          const topOffEnabled = data.autoEmptyTopOffEnabled === true;
          const topOffAmount = topOffEnabled ? Number(data.autoEmptyTopOffAmount || 0) : 0;
          const newPushkaAmount = topOffEnabled && topOffAmount > 0 ? topOffAmount : 0;

          // Validate currency from user profile before it reaches Stripe.
          // If the stored value is not in the supported list, skip this user.
          const rawCurrency = String(data.currencyCode || "usd").toLowerCase().trim();
          if (!SUPPORTED_CURRENCIES.has(rawCurrency)) {
            console.warn("processPushkaAutoEmpty: unsupported_currency", { uid: doc.id, rawCurrency });
            tx.set(userRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }
          const currency = rawCurrency;

          // Capture current nextRunAt as a stable key for Stripe idempotency.
          const runTs = nextRun.toMillis();

          // Advance schedule — charge and pushka reset happen outside the transaction
          tx.set(userRef, {
            autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(nextDate),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

          chargeData = { amount: currentAmount, currency, customerId, pmId, newPushkaAmount, nextRunDateKey: String(runTs) };
        });

        if (!chargeData) continue;

        // Step 2: Off-session Stripe charge
        const amountCents = Math.round(chargeData.amount * 100);
        const minCents = minAmountForCurrency(chargeData.currency);
        if (amountCents < minCents) {
          console.warn("processPushkaAutoEmpty: amount_below_stripe_minimum", { uid: doc.id, amountCents, minCents });
          continue;
        }

        // Idempotency key: uid + scheduled run date prevents double-charges on retry.
        const emptyIdempotencyKey = `pushka_auto_empty_${doc.id}_${chargeData.nextRunDateKey}`;

        let paymentIntent;
        try {
          paymentIntent = await stripe.paymentIntents.create({
            amount: amountCents,
            currency: chargeData.currency,
            customer: chargeData.customerId,
            payment_method: chargeData.pmId,
            off_session: true,
            confirm: true,
            error_on_requires_action: true,
            metadata: {
              uid: doc.id,
              source: "pushka",
              purpose: "pushka_auto_empty",
            },
          }, { idempotencyKey: emptyIdempotencyKey });
        } catch (stripeErr) {
          console.error("processPushkaAutoEmpty: stripe_charge_failed", {
            uid: doc.id,
            error: String(stripeErr?.message || stripeErr),
            code: stripeErr?.code,
          });
          // Notify user their card was declined
          const failLang = await getUserLanguage(doc.id);
          const failTitles = { es: "Vaciado fallido", en: "Empty failed", fr: "Vidage échoué", he: "הריקון נכשל" };
          const failBodies = {
            es: "No pudimos cobrar tu tarjeta para el vaciado automático. Revisá tu tarjeta en Configuración.",
            en: "We couldn't charge your card for the automatic empty. Please check your card in Settings.",
            fr: "Nous n'avons pas pu débiter votre carte pour le vidage automatique. Vérifiez votre carte dans Paramètres.",
            he: "לא הצלחנו לחייב את הכרטיס שלך לריקון האוטומטי. בדוק את הכרטיס שלך בהגדרות.",
          };
          await sendToUser(doc.id, {
            notification: { title: failTitles[failLang], body: failBodies[failLang] },
            data: { type: "pushkaAutoEmptyFailed" },
          }).catch(() => {});
          failed += 1;
          continue;
        }

        if (paymentIntent.status !== "succeeded") {
          console.warn("processPushkaAutoEmpty: payment_not_succeeded", { uid: doc.id, status: paymentIntent.status });
          failed += 1;
          continue;
        }

        // Step 3: Charge confirmed — reset pushka and write transaction.
        // Use paymentIntentId as the transaction doc ID so a retry of this step
        // is idempotent and cannot create a duplicate record.
        const emptiedAmount = chargeData.amount;
        const emptyPiId = paymentIntent.id;
        const emptyRates = await getExchangeRates(null);
        const emptySnap = buildCurrencySnapshot(emptiedAmount, chargeData.currency.toUpperCase(), emptyRates);
        try {
          await db.runTransaction(async (tx) => {
            tx.set(doc.ref, {
              pushkaAmount: chargeData.newPushkaAmount,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            const movementRef = doc.ref.collection("transactions").doc(emptyPiId);
            tx.set(movementRef, {
              type: "pushkaEmpty",
              amount: emptiedAmount,
              currencyCode: chargeData.currency.toUpperCase(),
              ...emptySnap,
              description: "Vaciado automático de Pushka",
              paymentMethod: "auto_card",
              status: "completed",
              skipNotification: true,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          });
        } catch (step3Err) {
          // CRITICAL: Stripe charge succeeded but pushka reset failed.
          // Log with paymentIntentId so this can be manually recovered.
          console.error("processPushkaAutoEmpty: step3_reset_failed_after_charge", {
            uid: doc.id,
            paymentIntentId: emptyPiId,
            amount: emptiedAmount,
            error: String(step3Err?.message || step3Err),
          });
          failed += 1;
          continue;
        }

        // Step 4: Notify success
        try {
          const emptyLang = await getUserLanguage(doc.id);
          const emptySym = currencySymbol(chargeData.currency);
          const amtStr = Number(emptiedAmount).toFixed(2);
          const emptyTitles = { es: "Pushka vaciada ✡", en: "Pushka emptied ✡", fr: "Pushka vidée ✡", he: "הפושקה רוקנה ✡" };
          const emptyBodies = {
            es: `Tu Pushka fue vaciada automáticamente. Donación: ${emptySym}${amtStr}`,
            en: `Your Pushka was automatically emptied. Donation: ${emptySym}${amtStr}`,
            fr: `Votre Pushka a été vidée automatiquement. Don : ${emptySym}${amtStr}`,
            he: `הפושקה שלך רוקנה אוטומטית. תרומה: ${emptySym}${amtStr}`,
          };
          await sendToUser(doc.id, {
            notification: { title: emptyTitles[emptyLang], body: emptyBodies[emptyLang] },
            data: { type: "pushkaEmpty", amount: String(emptiedAmount) },
          }).catch(() => {});
        } catch (notifErr) {
          console.warn("processPushkaAutoEmpty: notification_failed", { uid: doc.id, error: String(notifErr?.message || notifErr) });
        }

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

// ---------------------------------------------------------------------------
// Currency snapshot helper
// ---------------------------------------------------------------------------

/**
 * Given an amount in currencyCode and today's rates map, returns a frozen
 * snapshot of USD and MXN equivalents to embed in every transaction document.
 * This ensures historical figures never drift when exchange rates change.
 * rates: map from getExchangeRates (currencyCode → units per 1 USD).
 */
function buildCurrencySnapshot(amount, currencyCode, rates) {
  const code = String(currencyCode || "USD").toUpperCase();
  const rawRate = rates[code] ?? 1;
  const rate = (rawRate > 0) ? rawRate : 1;  // guard: never divide by zero
  const mxnRate = rates["MXN"] ?? 17.1;
  const amountUSD = code === "USD" ? amount : amount / rate;
  const amountMXN = amountUSD * mxnRate;
  return {
    amountUSD:         Math.round(amountUSD * 100) / 100,
    amountMXN:         Math.round(amountMXN * 100) / 100,
    exchangeRateToUSD: Math.round((1 / rate) * 1_000_000) / 1_000_000,
    exchangeRateToMXN: Math.round((mxnRate / rate) * 1_000_000) / 1_000_000,
  };
}

// ---------------------------------------------------------------------------
// Exchange rate helpers — cached in Firestore _exchangeRates/{YYYY-MM-DD}
// ---------------------------------------------------------------------------

/**
 * Fetches USD-based exchange rates, always cross-validating two independent sources:
 *   Primary:   open.er-api.com  (multi-provider aggregator, best LatAm coverage)
 *   Secondary: frankfurter.app  (ECB-based, fully independent)
 *
 * Both sources are fetched in parallel. If they agree within 2% on MXN and EUR,
 * the primary is used (more complete coverage). If they diverge, a warning is
 * logged and the primary is still used — frankfurter is the safety net, not the override.
 * If the primary fails or produces implausible values, frankfurter is used as fallback.
 * If both fail, hardcoded fallback rates are returned.
 *
 * Results are cached in Firestore _exchangeRates/{YYYY-MM-DD} to avoid repeat fetches.
 * Returns a map: currencyCode (uppercase) → units per 1 USD.
 */
async function getExchangeRates(dateStr) {
  const key = dateStr ?? new Date().toISOString().slice(0, 10);
  const ref = db.collection("_exchangeRates").doc(key);

  const snap = await ref.get();
  if (snap.exists) return snap.data().rates;

  const FALLBACK_RATES = {
    USD: 1, EUR: 0.93, GBP: 0.79, CAD: 1.37,
    ILS: 3.70, MXN: 17.1, BRL: 5.0,
    ARS: 900, CLP: 930, COP: 4000,
  };

  // Range guards for key currencies — catches API bugs and extreme outliers.
  // Ranges are intentionally wide to allow real market moves.
  const PLAUSIBLE_RANGES = {
    MXN: [10, 35],
    EUR: [0.65, 1.30],
    GBP: [0.55, 1.10],
    ILS: [2.5, 6.0],
  };

  function isPlausible(rates) {
    for (const [code, [min, max]] of Object.entries(PLAUSIBLE_RANGES)) {
      const v = rates[code];
      if (!v || v < min || v > max) {
        console.warn(`getExchangeRates: implausible ${code}=${v} (expected ${min}–${max})`);
        return false;
      }
    }
    return true;
  }

  // Fetch from frankfurter.app (ECB-based). Returns rates relative to USD.
  async function fetchFrankfurter() {
    const res = await fetch("https://api.frankfurter.app/latest?from=USD");
    const data = await res.json();
    if (!data.rates) throw new Error("Frankfurter: no rates field");
    const rates = { ...data.rates, USD: 1 };
    return rates;
  }

  // Fetch from open.er-api.com (primary, multi-provider aggregator).
  async function fetchOpenER() {
    const res = await fetch("https://open.er-api.com/v6/latest/USD");
    const data = await res.json();
    if (data.result !== "success") throw new Error("ExchangeRate-API: result not success");
    return { ...data.rates, USD: 1 };
  }

  // Cross-validate: check that a shared key differs by less than maxDiff (fraction).
  function pctDiff(a, b, key) {
    if (!a[key] || !b[key]) return null;
    return Math.abs(a[key] - b[key]) / a[key];
  }

  try {
    const [primaryResult, secondaryResult] = await Promise.allSettled([
      fetchOpenER(),
      fetchFrankfurter(),
    ]);

    const primary   = primaryResult.status   === "fulfilled" ? primaryResult.value   : null;
    const secondary = secondaryResult.status === "fulfilled" ? secondaryResult.value : null;

    if (!primary && !secondary) {
      console.error("getExchangeRates: both sources failed, using hardcoded fallback");
      return FALLBACK_RATES;
    }

    if (!primary) {
      console.warn("getExchangeRates: primary (open.er-api.com) failed, using frankfurter");
      const rates = secondary;
      if (!isPlausible(rates)) return FALLBACK_RATES;
      await ref.set({ rates, source: "frankfurter_only", fetchedAt: admin.firestore.FieldValue.serverTimestamp() });
      return rates;
    }

    if (!secondary) {
      console.warn("getExchangeRates: secondary (frankfurter) failed, using primary only");
    } else {
      // Both succeeded — cross-validate MXN and EUR (2% tolerance)
      const mxnDiff = pctDiff(primary, secondary, "MXN");
      const eurDiff = pctDiff(primary, secondary, "EUR");
      const MAX_DIFF = 0.02;
      if ((mxnDiff !== null && mxnDiff > MAX_DIFF) || (eurDiff !== null && eurDiff > MAX_DIFF)) {
        console.warn("getExchangeRates: sources diverge beyond 2%", {
          primary_MXN: primary["MXN"], secondary_MXN: secondary["MXN"],
          primary_EUR: primary["EUR"], secondary_EUR: secondary["EUR"],
        });
        // Sources disagree — still use primary but do NOT cache so next transaction re-checks
        if (!isPlausible(primary)) return FALLBACK_RATES;
        return primary;
      }
    }

    if (!isPlausible(primary)) {
      console.warn("getExchangeRates: primary implausible, using fallback");
      return FALLBACK_RATES;
    }

    // All good — cache and return primary
    await ref.set({
      rates: primary,
      source: secondary ? "dual_validated" : "primary_only",
      fetchedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return primary;

  } catch (err) {
    console.error("getExchangeRates: unexpected error, using fallback", String(err?.message || err));
    return FALLBACK_RATES;
  }
}

/**
 * Given an amount in `currencyCode` (uppercase), returns the equivalent in USD.
 */
async function convertToUSD(amount, currencyCode) {
  const code = String(currencyCode || "USD").toUpperCase();
  if (code === "USD") return amount;
  const rates = await getExchangeRates(null);
  const rate = rates[code];
  if (!rate) {
    console.warn(`convertToUSD: no exchange rate for currency "${code}", returning null`);
    return null;
  }
  return amount / rate;
}

// ---------------------------------------------------------------------------
// Admin: setAdminClaim — grant or revoke admin/tenant access
// ---------------------------------------------------------------------------

// Only Ioel is super_admin. This email can never be demoted.
const SUPER_ADMIN_EMAIL = "ioelkatz@gmail.com";

/**
 * Checks whether a request comes from a super_admin.
 * Accepts both the legacy `admin: true` claim and the new `role: "super_admin"`.
 */
function callerIsSuperAdmin(request) {
  const claims = request.auth?.token ?? {};
  return claims.role === "super_admin" || (claims.admin === true && request.auth?.token?.email === SUPER_ADMIN_EMAIL);
}

/**
 * Sets role claims for a user.
 * - role: "super_admin" | "tenant_admin" | "tenant_collaborator"
 * - tenantId: required for tenant_admin and tenant_collaborator
 * - revoke: removes all admin claims
 */
exports.setAdminClaim = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    }

    await enforceRateLimit(callerUid, "setAdminClaim", 20, 3600);

    const callerRecord = await admin.auth().getUser(callerUid);
    const callerClaims = callerRecord.customClaims || {};
    const callerIsSuper = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const callerIsTenantAdmin = callerClaims.role === "tenant_admin";

    if (!callerIsSuper && !callerIsTenantAdmin) {
      throw new HttpsError("permission-denied", "Solo administradores pueden gestionar accesos.");
    }

    const { targetEmail, role, tenantId, revoke } = request.data;
    if (!targetEmail) throw new HttpsError("invalid-argument", "targetEmail requerido.");

    const validRoles = ["super_admin", "tenant_admin", "tenant_collaborator"];
    if (!revoke && !validRoles.includes(role)) {
      throw new HttpsError("invalid-argument", `role debe ser uno de: ${validRoles.join(", ")}`);
    }

    // Only super_admin can assign super_admin or operate across tenants
    if (!callerIsSuper) {
      if (role === "super_admin") {
        throw new HttpsError("permission-denied", "Solo el super administrador puede asignar ese rol.");
      }
      // tenant_admin can only manage collaborators of their own tenant
      if (tenantId && tenantId !== callerClaims.tenantId) {
        throw new HttpsError("permission-denied", "Solo puedes gestionar colaboradores de tu organización.");
      }
      if (role === "tenant_admin") {
        throw new HttpsError("permission-denied", "Solo el super administrador puede asignar tenant_admin.");
      }
    }

    // Super admin email can never be revoked
    if (revoke && targetEmail === SUPER_ADMIN_EMAIL) {
      throw new HttpsError("permission-denied", "No se pueden revocar los permisos del super administrador.");
    }

    const targetRecord = await admin.auth().getUserByEmail(targetEmail);

    let newClaims;
    if (revoke) {
      newClaims = {};
    } else if (role === "super_admin") {
      newClaims = { role: "super_admin", admin: true };
    } else if (role === "tenant_admin") {
      if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido para tenant_admin.");
      newClaims = { role: "tenant_admin", tenantId };
    } else if (role === "tenant_collaborator") {
      if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido para tenant_collaborator.");
      newClaims = { role: "tenant_collaborator", tenantId };
    }

    await admin.auth().setCustomUserClaims(targetRecord.uid, newClaims);

    console.info("setAdminClaim", {
      callerUid,
      callerEmail: callerRecord.email,
      targetEmail,
      role: revoke ? "revoked" : role,
      tenantId: tenantId ?? null,
    });
    return { success: true, uid: targetRecord.uid, role: revoke ? null : role };
  }
);

// ---------------------------------------------------------------------------
// Admin: listAdmins — returns all users with admin custom claim
// ---------------------------------------------------------------------------

exports.listAdmins = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const isTenantAdmin = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdmin) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    // Paginate through all Firebase Auth users (max 1000 per page)
    const allUsers = [];
    let pageToken;
    do {
      const listResult = await admin.auth().listUsers(1000, pageToken);
      allUsers.push(...listResult.users);
      pageToken = listResult.pageToken;
    } while (pageToken);

    let admins;
    if (isSuper) {
      admins = allUsers
        .filter((u) => u.customClaims?.admin === true || u.customClaims?.role)
        .map((u) => ({
          uid: u.uid,
          email: u.email,
          displayName: u.displayName,
          role: u.customClaims?.role ?? (u.customClaims?.admin ? "super_admin" : null),
          tenantId: u.customClaims?.tenantId ?? null,
        }));
    } else {
      const callerTenantId = callerClaims.tenantId;
      admins = allUsers
        .filter((u) => u.customClaims?.tenantId === callerTenantId)
        .map((u) => ({
          uid: u.uid,
          email: u.email,
          displayName: u.displayName,
          role: u.customClaims?.role,
          tenantId: u.customClaims?.tenantId,
        }));
    }
    return { admins };
  }
);

// ---------------------------------------------------------------------------
// Admin: getAdminStats — aggregated stats for the dashboard Overview
// ---------------------------------------------------------------------------

exports.getAdminStats = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "getAdminStats", 30, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const isTenantAdminRole = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdminRole) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    // filterTenantId: if super_admin passes a tenantId param, filter to that tenant;
    // if tenant_admin, always filter to their own tenant.
    const filterTenantId = isTenantAdminRole
      ? callerClaims.tenantId
      : (request.data?.tenantId ?? null);

    const now = new Date();
    const startOfMonth    = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
    const startOfLastMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
    const startOfYear     = new Date(Date.UTC(now.getUTCFullYear(), 0, 1));
    const startOf12Months = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 11, 1));

    const rates = await getExchangeRates(null);

    // Fetch users — filtered by tenant if needed
    const usersQuery = filterTenantId
      ? db.collection("users").where("tenantId", "==", filterTenantId)
      : db.collection("users");

    const [usersSnap, txSnap] = await Promise.all([
      usersQuery.get(),
      db.collectionGroup("transactions").get(),
    ]);

    const mxnRate = rates["MXN"] ?? 17.1; // units of MXN per 1 USD

    // Build user metadata map for enriching transaction data
    const userMap = {};
    let totalWalletBalanceMXN = 0;
    for (const d of usersSnap.docs) {
      const u = d.data();
      const currency = String(u.currencyCode || "USD").toUpperCase();
      const rate = rates[currency] ?? 1;
      userMap[d.id] = {
        displayName: u.displayName || u.email || d.id,
        email: u.email || "",
        currencyCode: currency,
      };
      // wallet balance is in the user's currency; convert to MXN via USD
      if (u.walletBalance) totalWalletBalanceMXN += (u.walletBalance / rate) * mxnRate;
    }

    const totalUsersCount = usersSnap.size;
    let newUsersThisMonth = 0;
    let newUsersLastMonth = 0;
    for (const d of usersSnap.docs) {
      const createdAt = d.data().createdAt?.toDate?.() ?? null;
      if (!createdAt) continue;
      if (createdAt >= startOfMonth) newUsersThisMonth++;
      else if (createdAt >= startOfLastMonth) newUsersLastMonth++;
    }

    // Monthly buckets for last 12 months — all values in MXN
    const monthlyBuckets = {};
    for (let i = 11; i >= 0; i--) {
      const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1));
      const key = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
      monthlyBuckets[key] = { totalMXN: 0, count: 0, tzedaka: 0, pushkaEmpty: 0, walletFill: 0 };
    }

    let totalMonthMXN = 0;
    let totalLastMonthMXN = 0;
    let totalYearMXN = 0;
    let totalAllTimeMXN = 0;
    const topDonorsMap = {};
    const topDonorsThisMonthMap = {};
    const currencyTotals = {};         // MXN equivalent, for sorting/percentage
    const currencyTotalsOriginal = {}; // sum in original currency, for display
    const activeThisMonthSet = new Set();

    // Build set of tenant user IDs for fast filtering when scoped to a tenant
    const tenantUserIds = filterTenantId ? new Set(usersSnap.docs.map((d) => d.id)) : null;

    for (const txDoc of txSnap.docs) {
      const tx = txDoc.data();
      if (tx.type === "walletFill" && tx.amount < 0) continue; // skip outgoing transfers

      const uid = txDoc.ref.parent.parent?.id;
      if (!uid) continue;

      // When scoped to a tenant, skip transactions from users outside it
      if (tenantUserIds && !tenantUserIds.has(uid)) continue;

      const userMeta = userMap[uid] || { displayName: uid, email: "", currencyCode: "USD" };
      const txCurrency = String(tx.currencyCode || userMeta.currencyCode).toUpperCase();

      // Priority: frozen snapshot → frozen USD converted → live rate fallback
      let amountMXN;
      if (tx.amountMXN != null) {
        amountMXN = tx.amountMXN;
      } else if (tx.amountUSD != null) {
        amountMXN = tx.amountUSD * mxnRate;
      } else {
        const txRate = rates[txCurrency] ?? 1;
        amountMXN = (tx.amount / txRate) * mxnRate;
      }

      const txDate = tx.createdAt?.toDate?.() ?? new Date(tx.createdAt);
      const monthKey = `${txDate.getUTCFullYear()}-${String(txDate.getUTCMonth() + 1).padStart(2, "0")}`;

      if (txDate >= startOfMonth) activeThisMonthSet.add(uid);

      if (monthlyBuckets[monthKey]) {
        monthlyBuckets[monthKey].totalMXN += amountMXN;
        monthlyBuckets[monthKey].count++;
        if (tx.type === "tzedaka") monthlyBuckets[monthKey].tzedaka += amountMXN;
        else if (tx.type === "pushkaEmpty") monthlyBuckets[monthKey].pushkaEmpty += amountMXN;
        else monthlyBuckets[monthKey].walletFill += amountMXN;
      }

      totalAllTimeMXN += amountMXN;
      if (txDate >= startOfMonth) totalMonthMXN += amountMXN;
      if (txDate >= startOfLastMonth && txDate < startOfMonth) totalLastMonthMXN += amountMXN;
      if (txDate >= startOfYear) totalYearMXN += amountMXN;

      currencyTotals[txCurrency] = (currencyTotals[txCurrency] || 0) + amountMXN;
      currencyTotalsOriginal[txCurrency] = (currencyTotalsOriginal[txCurrency] || 0) + (tx.amount ?? 0);

      if (tx.type === "tzedaka" || tx.type === "pushkaEmpty") {
        if (!topDonorsMap[uid]) {
          topDonorsMap[uid] = {
            uid,
            displayName: userMeta.displayName,
            email: userMeta.email,
            currencyCode: userMeta.currencyCode,
            totalMXN: 0,
            count: 0,
          };
        }
        topDonorsMap[uid].totalMXN += amountMXN;
        topDonorsMap[uid].count++;

        if (txDate >= startOfMonth) {
          if (!topDonorsThisMonthMap[uid]) {
            topDonorsThisMonthMap[uid] = {
              uid,
              displayName: userMeta.displayName,
              email: userMeta.email,
              currencyCode: userMeta.currencyCode,
              totalMXN: 0,
              count: 0,
            };
          }
          topDonorsThisMonthMap[uid].totalMXN += amountMXN;
          topDonorsThisMonthMap[uid].count++;
        }
      }
    }

    const topDonors = Object.values(topDonorsMap)
      .sort((a, b) => b.totalMXN - a.totalMXN)
      .slice(0, 10);

    const topDonorsThisMonth = Object.values(topDonorsThisMonthMap)
      .sort((a, b) => b.totalMXN - a.totalMXN)
      .slice(0, 5);

    const monthlyStats = Object.entries(monthlyBuckets).map(([key, v]) => {
      const [year, month] = key.split("-");
      const date = new Date(Date.UTC(Number(year), Number(month) - 1, 1));
      const label = date.toLocaleDateString("es-ES", { month: "short", year: "numeric" });
      return { month: key, label, ...v };
    });

    const monthGrowth = totalLastMonthMXN > 0
      ? ((totalMonthMXN - totalLastMonthMXN) / totalLastMonthMXN) * 100
      : null;

    return {
      totalUsersCount,
      activeThisMonth: activeThisMonthSet.size,
      newUsersThisMonth,
      newUsersLastMonth,
      totalMonthMXN,
      totalLastMonthMXN,
      totalYearMXN,
      totalAllTimeMXN,
      totalWalletBalanceMXN,
      monthGrowth,
      monthlyStats,
      topDonors,
      topDonorsThisMonth,
      currencyTotals,
      currencyTotalsOriginal,
    };
  }
);

// ---------------------------------------------------------------------------
// Admin: getRecentTransactions — last N transactions across all users
// ---------------------------------------------------------------------------

exports.getRecentTransactions = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const isTenantAdminRole = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdminRole) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    const filterTenantId = isTenantAdminRole
      ? callerClaims.tenantId
      : (request.data?.tenantId ?? null);

    const { filterType, filterCurrency, searchText } = request.data ?? {};

    const rates = await getExchangeRates(null);
    const mxnRate = rates["MXN"] ?? 17.1;

    const usersQuery = filterTenantId
      ? db.collection("users").where("tenantId", "==", filterTenantId)
      : db.collection("users");

    const [txSnap, usersSnap] = await Promise.all([
      db.collectionGroup("transactions").get(),
      usersQuery.get(),
    ]);

    const userMap = {};
    usersSnap.docs.forEach((d) => {
      const u = d.data();
      userMap[d.id] = { displayName: u.displayName || u.email || d.id, email: u.email || "" };
    });

    // Only include transactions whose owner is in the userMap (respects tenant filter)
    let txs = txSnap.docs
      .filter((d) => {
        const uid = d.ref.parent.parent?.id ?? "";
        return !filterTenantId || userMap[uid] !== undefined;
      })
      .map((d) => {
        const tx = d.data();
        const uid = d.ref.parent.parent?.id ?? "";
        const user = userMap[uid] ?? { displayName: uid, email: "" };
        let amountMXN = tx.amountMXN;
        if (amountMXN == null && tx.amountUSD != null) amountMXN = tx.amountUSD * mxnRate;
        if (amountMXN == null) {
          const txRate = rates[String(tx.currencyCode || "USD").toUpperCase()] ?? 1;
          amountMXN = (tx.amount / txRate) * mxnRate;
        }
        const createdAt = tx.createdAt?.toDate?.() ?? new Date(0);
        return {
          id: d.id,
          uid,
          displayName: user.displayName,
          email: user.email,
          type: tx.type ?? "tzedaka",
          amount: tx.amount ?? 0,
          currencyCode: String(tx.currencyCode || "USD").toUpperCase(),
          amountMXN: Math.round((amountMXN || 0) * 100) / 100,
          description: tx.description ?? "",
          createdAt: createdAt.toISOString(),
        };
      });

    if (filterType) txs = txs.filter((t) => t.type === filterType);
    if (filterCurrency) txs = txs.filter((t) => t.currencyCode === String(filterCurrency).toUpperCase());
    if (searchText) {
      const q = String(searchText).toLowerCase();
      txs = txs.filter((t) =>
        t.displayName.toLowerCase().includes(q) ||
        t.email.toLowerCase().includes(q)
      );
    }

    txs.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
    return txs.slice(0, 200);
  }
);

// ---------------------------------------------------------------------------
// Admin: getFailedPayments — recent payment failures (last 30 days)
// ---------------------------------------------------------------------------

exports.getFailedPayments = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const isTenantAdminRole = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdminRole) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    const filterTenantId = isTenantAdminRole
      ? callerClaims.tenantId
      : (request.data?.tenantId ?? null);

    const since = admin.firestore.Timestamp.fromDate(
      new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)
    );

    const snap = await db.collection("_stripeWebhookEvents")
      .where("status", "==", "failed")
      .where("createdAt", ">=", since)
      .get();

    let failed = snap.docs
      .map((d) => {
        const ev = d.data();
        return {
          id: d.id,
          uid: ev.uid ?? "",
          amount: ev.amount ?? 0,
          paymentIntentId: ev.paymentIntentId ?? d.id,
          createdAt: ev.createdAt?.toDate?.()?.toISOString() ?? new Date().toISOString(),
        };
      })
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
      .slice(0, 50);

    const uids = [...new Set(failed.map((f) => f.uid).filter(Boolean))];
    const userSnaps = await Promise.all(uids.map((uid) => db.collection("users").doc(uid).get()));
    const userMap = {};
    userSnaps.forEach((s) => {
      if (s.exists) {
        const u = s.data();
        userMap[s.id] = {
          displayName: u.displayName || u.email || s.id,
          email: u.email || "",
          tenantId: u.tenantId ?? null,
        };
      }
    });

    // Filter by tenant if needed
    if (filterTenantId) {
      failed = failed.filter((f) => userMap[f.uid]?.tenantId === filterTenantId);
    }

    return failed.map((f) => ({
      ...f,
      displayName: userMap[f.uid]?.displayName ?? f.uid,
      email: userMap[f.uid]?.email ?? "",
    }));
  }
);

// ---------------------------------------------------------------------------
// Admin: setUserBlocked — disable/enable Firebase Auth account + write adminData
// ---------------------------------------------------------------------------

exports.setUserBlocked = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const isTenantAdminRole = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdminRole) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    const uid = String(request.data?.uid || "").trim();
    const isBlocked = Boolean(request.data?.isBlocked);
    const notes = request.data?.notes !== undefined ? String(request.data.notes) : undefined;

    if (!uid) throw new HttpsError("invalid-argument", "uid requerido.");

    // Tenant admins can only block users in their own tenant
    if (isTenantAdminRole) {
      const targetSnap = await db.collection("users").doc(uid).get();
      if (!targetSnap.exists || targetSnap.data()?.tenantId !== callerClaims.tenantId) {
        throw new HttpsError("permission-denied", "Solo puedes gestionar usuarios de tu organización.");
      }
    }

    // Disable/enable the Firebase Auth account — this prevents login entirely
    await admin.auth().updateUser(uid, { disabled: isBlocked });

    // Write isBlocked to the user's own document so the Flutter app can react
    // in real-time via its Firestore listener and sign out immediately.
    await db.collection("users").doc(uid).update({ isBlocked });

    // Write to adminData for UI display and audit trail
    const adminDataPatch = {
      isBlocked,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedBy: request.auth.token?.email ?? request.auth.uid,
    };
    if (notes !== undefined) adminDataPatch.notes = notes;

    await db.collection("adminData").doc(uid).set(adminDataPatch, { merge: true });

    return { success: true, uid, isBlocked };
  }
);

// ===========================================================================
// MULTI-TENANT — Tenant management functions
// ===========================================================================

// Fields exposed publicly (for app branding preview before registration)
const TENANT_PUBLIC_FIELDS = [
  "name", "slug", "appName", "welcomeText",
  "primaryColor", "secondaryColor", "logoUrl", "showPoweredBy",
  "defaultLanguage", "defaultCurrency", "defaultCountry",
  "contactEmail", "contactPhone", "privacyPolicyUrl", "termsUrl",
  "city", "country", "status",
];

// Fields exposed to authenticated users of the tenant (same as public + a bit more)
const TENANT_MEMBER_FIELDS = [...TENANT_PUBLIC_FIELDS];

/**
 * Validates that a slug is URL-safe and not already taken.
 * Returns the normalized slug or throws.
 */
async function validateSlug(slug, excludeTenantId = null) {
  const normalized = String(slug || "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
  if (!normalized || normalized.length < 3 || normalized.length > 30) {
    throw new HttpsError("invalid-argument", "El slug debe tener entre 3 y 30 caracteres alfanuméricos.");
  }
  const existing = await db.collection("tenants").where("slug", "==", normalized).limit(1).get();
  if (!existing.empty && existing.docs[0].id !== excludeTenantId) {
    throw new HttpsError("already-exists", `El código "${normalized}" ya está en uso.`);
  }
  return normalized;
}

// ---------------------------------------------------------------------------
// createTenant — super_admin only
// ---------------------------------------------------------------------------
exports.createTenant = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    if (callerClaims.role !== "super_admin" && callerClaims.admin !== true) {
      throw new HttpsError("permission-denied", "Solo el super administrador puede crear tenants.");
    }

    const {
      name, slug, appName, welcomeText,
      primaryColor, secondaryColor, logoUrl,
      defaultLanguage, defaultCurrency, defaultCountry,
      contactEmail, contactPhone, privacyPolicyUrl, termsUrl,
      city, country,
      adminEmail,
      commissionRate, planPrice,
    } = request.data ?? {};

    if (!name || !slug || !adminEmail) {
      throw new HttpsError("invalid-argument", "name, slug y adminEmail son requeridos.");
    }

    const normalizedSlug = await validateSlug(slug);

    const now = admin.firestore.FieldValue.serverTimestamp();

    const tenantData = {
      // Identity
      name: String(name).trim(),
      slug: normalizedSlug,
      status: "active",

      // Branding
      appName: String(appName || name).trim(),
      welcomeText: String(welcomeText || "").trim() || null,
      primaryColor: /^#[0-9A-Fa-f]{6}$/.test(String(primaryColor || "")) ? String(primaryColor).trim() : "#E8A87C",
      secondaryColor: /^#[0-9A-Fa-f]{6}$/.test(String(secondaryColor || "")) ? String(secondaryColor).trim() : "#D4A843",
      logoUrl: String(logoUrl || "").trim() || null,
      showPoweredBy: true,

      // Localization
      defaultLanguage: String(defaultLanguage || "es"),
      defaultCurrency: String(defaultCurrency || "USD").toUpperCase(),
      defaultCountry: String(defaultCountry || "").trim() || null,

      // Legal / Contact
      contactEmail: String(contactEmail || adminEmail).trim() || null,
      contactPhone: String(contactPhone || "").trim() || null,
      privacyPolicyUrl: String(privacyPolicyUrl || "").trim() || null,
      termsUrl: String(termsUrl || "").trim() || null,
      city: String(city || "").trim() || null,
      country: String(country || "").trim() || null,

      // Stripe Connect — set later via OAuth
      stripeConnectAccountId: null,
      stripeConnectStatus: "not_connected",
      commissionRate: typeof commissionRate === "number" ? commissionRate : 0.03,

      // Billing — set later when subscription is created
      planPrice: typeof planPrice === "number" ? planPrice : 99,
      stripeSubscriptionId: null,
      stripeCustomerId: null,
      paymentStatus: "trial",
      billingCycleStart: now,
      billingNextDue: null,
      gracePeriodEndsAt: null,

      // Admin
      adminEmail: String(adminEmail).trim(),
      adminUid: null,  // set when admin logs in for the first time
      createdAt: now,
      updatedAt: now,
      createdBy: request.auth.uid,
    };

    const docRef = await db.collection("tenants").add(tenantData);

    // Assign tenant_admin claim to the admin email if they already have a Firebase account
    try {
      const adminRecord = await admin.auth().getUserByEmail(adminEmail.trim());
      await admin.auth().setCustomUserClaims(adminRecord.uid, {
        role: "tenant_admin",
        tenantId: docRef.id,
      });
      await docRef.update({ adminUid: adminRecord.uid });
    } catch (e) {
      // User doesn't have an account yet — claims will be set when they register
      console.info(`createTenant: admin ${adminEmail} has no Firebase account yet; claims pending`);
    }

    console.info("createTenant", { id: docRef.id, slug: normalizedSlug, adminEmail });
    return { success: true, tenantId: docRef.id, slug: normalizedSlug };
  }
);

// ---------------------------------------------------------------------------
// getTenantBranding — super_admin (any tenant) or tenant_admin (own tenant)
// ---------------------------------------------------------------------------
exports.getTenantBranding = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const isTenantAdmin = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdmin) {
      throw new HttpsError("permission-denied", "Acceso denegado.");
    }

    const tenantId = isSuper
      ? (request.data?.tenantId ?? null)
      : callerClaims.tenantId;

    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    const snap = await db.collection("tenants").doc(tenantId).get();
    if (!snap.exists) throw new HttpsError("not-found", "Tenant no encontrado.");

    const data = snap.data();
    const fields = [
      "name", "slug", "appName", "welcomeText",
      "primaryColor", "secondaryColor", "logoUrl", "showPoweredBy",
      "defaultLanguage", "defaultCurrency", "defaultCountry",
      "contactEmail", "contactPhone", "privacyPolicyUrl", "termsUrl",
      "city", "country",
    ];
    const branding = { tenantId: snap.id };
    for (const f of fields) {
      if (data[f] !== undefined) branding[f] = data[f];
    }
    return branding;
  }
);

// ---------------------------------------------------------------------------
// updateTenant — super_admin (all fields) or tenant_admin (branding only)
// ---------------------------------------------------------------------------
exports.updateTenant = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const isTenantAdmin = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdmin) {
      throw new HttpsError("permission-denied", "Acceso denegado.");
    }

    const { tenantId, ...updates } = request.data ?? {};
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    // Tenant admin can only edit their own tenant
    if (isTenantAdmin && callerClaims.tenantId !== tenantId) {
      throw new HttpsError("permission-denied", "Solo podés editar tu propia organización.");
    }

    const tenantRef = db.collection("tenants").doc(tenantId);
    const snap = await tenantRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Tenant no encontrado.");

    // Super admin: all fields. Tenant admin: branding only.
    const brandingFields = [
      "appName", "welcomeText",
      "primaryColor", "secondaryColor", "logoUrl", "showPoweredBy",
      "defaultLanguage", "defaultCurrency", "defaultCountry",
      "contactEmail", "contactPhone", "privacyPolicyUrl", "termsUrl",
      "city", "country",
    ];
    const superOnlyFields = [
      "name", "status", "commissionRate", "planPrice",
      "stripeConnectAccountId", "stripeConnectStatus",
      "stripeSubscriptionId", "stripeCustomerId", "paymentStatus",
      "billingNextDue", "gracePeriodEndsAt", "billingCycleStart",
      "adminEmail", "adminUid",
    ];
    const allowed = isSuper ? [...brandingFields, ...superOnlyFields] : brandingFields;

    // If slug is being updated, validate uniqueness
    let normalizedSlug;
    if (updates.slug) {
      normalizedSlug = await validateSlug(updates.slug, tenantId);
    }

    // Fields where empty string means "not set" — store null instead of ""
    const nullableStringFields = new Set([
      "logoUrl", "welcomeText", "contactEmail", "contactPhone",
      "privacyPolicyUrl", "termsUrl", "defaultCountry", "city", "country",
    ]);

    // Hex color fields — must be exactly #rrggbb
    const hexColorFields = new Set(["primaryColor", "secondaryColor"]);
    const hexRe = /^#[0-9A-Fa-f]{6}$/;

    const patch = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };
    for (const key of allowed) {
      if (!(key in updates)) continue;
      let val = updates[key];
      if (typeof val === "string") {
        val = val.trim();
        if (nullableStringFields.has(key) && val === "") val = null;
        if (hexColorFields.has(key) && !hexRe.test(val)) continue; // skip invalid hex
      }
      patch[key] = val;
    }
    if (normalizedSlug) patch.slug = normalizedSlug;

    await tenantRef.update(patch);

    console.info("updateTenant", { tenantId, fields: Object.keys(patch) });
    return { success: true, tenantId };
  }
);

// ---------------------------------------------------------------------------
// getTenantBySlug — public (no auth required), for code validation in app
// ---------------------------------------------------------------------------
exports.getTenantBySlug = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const slug = String(request.data?.slug || "")
      .toLowerCase()
      .replace(/[^a-z0-9]/g, "");

    if (!slug) throw new HttpsError("invalid-argument", "slug requerido.");

    const snap = await db.collection("tenants")
      .where("slug", "==", slug)
      .where("status", "in", ["active", "trial", "grace_period"])
      .limit(1)
      .get();

    if (snap.empty) {
      throw new HttpsError("not-found", "Organización no encontrada o inactiva.");
    }

    const doc = snap.docs[0];
    const data = doc.data();

    // Return only public branding fields — never Stripe keys or billing details
    const publicData = {};
    for (const field of TENANT_PUBLIC_FIELDS) {
      if (data[field] !== undefined) publicData[field] = data[field];
    }

    return { tenantId: doc.id, ...publicData };
  }
);

// ---------------------------------------------------------------------------
// getTenantConfig — authenticated, returns branding for the user's own tenant
// ---------------------------------------------------------------------------
exports.getTenantConfig = onCall(
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }

    const userSnap = await db.collection("users").doc(request.auth.uid).get();
    if (!userSnap.exists) throw new HttpsError("not-found", "Usuario no encontrado.");

    const tenantId = userSnap.data()?.tenantId;
    if (!tenantId) {
      // User has no tenant yet — return null config
      return { tenantId: null, config: null };
    }

    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) throw new HttpsError("not-found", "Organización no encontrada.");

    const data = tenantSnap.data();

    // If tenant is suspended, the app should show a "service unavailable" screen
    if (data.status === "suspended") {
      return { tenantId, config: null, suspended: true };
    }

    const config = {};
    for (const field of TENANT_MEMBER_FIELDS) {
      if (data[field] !== undefined) config[field] = data[field];
    }

    return { tenantId, config };
  }
);

// ---------------------------------------------------------------------------
// listTenants — super_admin only, returns all tenants with summary stats
// ---------------------------------------------------------------------------
exports.listTenants = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "listTenants", 30, 3600);

    const callerClaims = request.auth?.token ?? {};
    if (callerClaims.role !== "super_admin" && callerClaims.admin !== true) {
      throw new HttpsError("permission-denied", "Solo el super administrador.");
    }

    const snap = await db.collection("tenants").get();

    const tenants = snap.docs.map((d) => {
      const data = d.data();
      return {
        tenantId: d.id,
        name: data.name,
        slug: data.slug,
        appName: data.appName,
        status: data.status,
        paymentStatus: data.paymentStatus,
        stripeConnectStatus: data.stripeConnectStatus,
        commissionRate: data.commissionRate,
        planPrice: data.planPrice,
        adminEmail: data.adminEmail,
        city: data.city,
        country: data.country,
        createdAt: data.createdAt?.toDate?.()?.toISOString() ?? null,
        billingNextDue: data.billingNextDue?.toDate?.()?.toISOString() ?? null,
        gracePeriodEndsAt: data.gracePeriodEndsAt?.toDate?.()?.toISOString() ?? null,
      };
    });

    return { tenants };
  }
);

// ---------------------------------------------------------------------------
// createStripeConnectLink — super_admin or tenant_admin generates OAuth URL
// ---------------------------------------------------------------------------
exports.createStripeConnectLink = onCall(
  { secrets: [stripeConnectClientId], enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "createStripeConnectLink", 10, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuperAdminCaller = callerClaims.role === "super_admin" || callerClaims.admin === true;
    const isTenantAdminCaller = callerClaims.role === "tenant_admin";

    if (!isSuperAdminCaller && !isTenantAdminCaller) {
      throw new HttpsError("permission-denied", "Acceso denegado.");
    }

    // super_admin passes tenantId; tenant_admin uses their own
    const tenantId = isSuperAdminCaller
      ? request.data?.tenantId
      : callerClaims.tenantId;

    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    const clientId = stripeConnectClientId.value();
    if (!clientId) throw new HttpsError("failed-precondition", "Stripe Connect no configurado.");

    // Generate a state token for CSRF protection — store it in Firestore
    const crypto = require("crypto");
    const state = crypto.randomBytes(20).toString("hex");

    await db.collection("tenants").doc(tenantId).update({
      stripeConnectOAuthState: state,
      stripeConnectOAuthStateCreatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const redirectUri = `https://us-central1-pushka-app-ioel.cloudfunctions.net/handleStripeConnectOAuth`;
    const params = new URLSearchParams({
      response_type: "code",
      client_id: clientId,
      scope: "read_write",
      state,
      redirect_uri: redirectUri,
    });

    return { url: `https://connect.stripe.com/oauth/authorize?${params.toString()}` };
  }
);

// ---------------------------------------------------------------------------
// handleStripeConnectOAuth — HTTP callback from Stripe after tenant authorizes
// ---------------------------------------------------------------------------
exports.handleStripeConnectOAuth = onRequest(
  { secrets: [stripeSecret, stripeConnectClientId] },
  async (req, res) => {
    // Stripe sends a GET with ?code=xxx&state=xxx (or ?error=xxx on denial)
    const { code, state, error } = req.query;

    if (error) {
      console.warn("Stripe Connect OAuth denied:", error);
      return res.redirect(`https://pushka-admin.web.app/tenants?connect=denied`);
    }

    if (!code || !state) {
      return res.status(400).send("Parámetros inválidos.");
    }

    // Find the tenant with this state token (CSRF check)
    const tenantsSnap = await db.collection("tenants")
      .where("stripeConnectOAuthState", "==", state)
      .limit(1)
      .get();

    if (tenantsSnap.empty) {
      console.error("No tenant found for Stripe Connect state:", state);
      return res.status(400).send("Estado inválido o expirado.");
    }

    const tenantDoc = tenantsSnap.docs[0];
    const tenantId = tenantDoc.id;

    // Validate state is not older than 24 hours
    const stateCreatedAt = tenantDoc.data().stripeConnectOAuthStateCreatedAt?.toDate?.();
    if (!stateCreatedAt || Date.now() - stateCreatedAt.getTime() > 86400000) {
      await tenantDoc.ref.update({ stripeConnectOAuthState: null });
      return res.status(400).send("Enlace expirado. Genera uno nuevo desde el panel.");
    }

    // Exchange code for access_token and stripe_user_id
    try {
      const stripe = require("stripe")(stripeSecret.value());
      const response = await stripe.oauth.token({
        grant_type: "authorization_code",
        code,
      });

      const stripeConnectAccountId = response.stripe_user_id;

      await tenantDoc.ref.update({
        stripeConnectAccountId,
        stripeConnectStatus: "active",
        stripeConnectOAuthState: null,
        stripeConnectOAuthStateCreatedAt: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`Stripe Connect activated for tenant ${tenantId}: ${stripeConnectAccountId}`);
      return res.redirect(`https://pushka-admin.web.app/tenants/${tenantId}?connect=success`);
    } catch (err) {
      console.error("Stripe Connect OAuth exchange error:", err);
      return res.status(500).send("Error al conectar con Stripe. Intentá de nuevo.");
    }
  }
);

// ===========================================================================
// FASE 4 — BILLING
// ===========================================================================

const SUPER_ADMIN_NOTIFICATION_EMAIL = "ioelkatz@gmail.com";
const SENDGRID_FROM = "ioelkatz@gmail.com";

// ---------------------------------------------------------------------------
// sendEmail — internal helper using SendGrid
// ---------------------------------------------------------------------------
async function sendEmail({ to, subject, html }) {
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!to || !emailRegex.test(to)) {
    console.warn("sendEmail: invalid or missing recipient address, skipping:", to);
    return;
  }
  const apiKey = sendgridApiKey.value();
  if (!apiKey || apiKey.startsWith("PLACEHOLDER")) {
    console.warn("sendEmail: SENDGRID_API_KEY not set, skipping email to", to);
    return;
  }
  const fetch = (await import("node-fetch")).default;
  const res = await fetch("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      personalizations: [{ to: [{ email: to }] }],
      from: { email: SENDGRID_FROM, name: "Pushka" },
      subject,
      content: [{ type: "text/html", value: html }],
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    console.error("sendEmail error:", res.status, body);
  }
}

// ---------------------------------------------------------------------------
// createTenantSubscription — super_admin creates Stripe Billing subscription
// ---------------------------------------------------------------------------
exports.createTenantSubscription = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    if (callerClaims.role !== "super_admin" && callerClaims.admin !== true) {
      throw new HttpsError("permission-denied", "Solo el super administrador.");
    }

    const { tenantId } = request.data ?? {};
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) throw new HttpsError("not-found", "Tenant no encontrado.");

    const tenantData = tenantSnap.data();
    const planPrice = tenantData.planPrice ?? 0;
    const adminEmail = tenantData.adminEmail;

    if (!planPrice || planPrice <= 0) {
      throw new HttpsError("invalid-argument", "El plan no tiene precio configurado.");
    }
    if (!adminEmail) {
      throw new HttpsError("invalid-argument", "El tenant no tiene email de administrador.");
    }

    const stripe = require("stripe")(stripeSecret.value());

    // Create or reuse Stripe customer
    let stripeCustomerId = tenantData.stripeCustomerId;
    if (!stripeCustomerId) {
      const customer = await stripe.customers.create({
        email: adminEmail,
        name: tenantData.name,
        metadata: { tenantId },
      });
      stripeCustomerId = customer.id;
    }

    // Create a price for this tenant (one-time price object, per-tenant)
    const price = await stripe.prices.create({
      currency: "usd",
      unit_amount: Math.round(planPrice * 100),
      recurring: { interval: "month" },
      product_data: { name: `Pushka SaaS — ${tenantData.name}` },
    });

    // Create subscription (starts trial, customer must add payment method)
    const subscription = await stripe.subscriptions.create({
      customer: stripeCustomerId,
      items: [{ price: price.id }],
      payment_behavior: "default_incomplete",
      payment_settings: { save_default_payment_method: "on_subscription" },
      expand: ["latest_invoice.payment_intent"],
      metadata: { tenantId },
    });

    const now = new Date();
    const nextDue = new Date(now);
    nextDue.setMonth(nextDue.getMonth() + 1);

    // Use "pending_payment" — subscription is incomplete until customer
    // adds a payment method and the first invoice is confirmed via webhook.
    await db.collection("tenants").doc(tenantId).update({
      stripeCustomerId,
      stripeSubscriptionId: subscription.id,
      paymentStatus: "pending_payment",
      billingCycleStart: admin.firestore.Timestamp.fromDate(now),
      billingNextDue: admin.firestore.Timestamp.fromDate(nextDue),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const clientSecret = subscription.latest_invoice?.payment_intent?.client_secret ?? null;
    return { subscriptionId: subscription.id, clientSecret };
  }
);

// ---------------------------------------------------------------------------
// Stripe Billing Webhook — invoice.payment_succeeded / invoice.payment_failed
// ---------------------------------------------------------------------------
exports.stripeBillingWebhook = onRequest(
  { secrets: [stripeSecret, stripeBillingWebhookSecret] },
  async (req, res) => {
    const stripe = require("stripe")(stripeSecret.value());

    const sig = req.headers["stripe-signature"];
    if (!sig) {
      console.error("stripeBillingWebhook: missing stripe-signature header");
      return res.status(400).send("Missing stripe-signature header.");
    }

    const billingSecret = stripeBillingWebhookSecret.value();
    if (!billingSecret || billingSecret.startsWith("PLACEHOLDER")) {
      console.error("stripeBillingWebhook: STRIPE_BILLING_WEBHOOK_SECRET not configured");
      return res.status(500).send("Webhook secret not configured.");
    }

    let event;
    try {
      event = stripe.webhooks.constructEvent(req.rawBody, sig, billingSecret);
    } catch (err) {
      console.error("stripeBillingWebhook: signature verification failed", err?.message);
      return res.status(400).send(`Webhook Error: ${err.message}`);
    }

    if (event.type === "invoice.payment_succeeded") {
      const invoice = event.data.object;
      const tenantId = invoice.subscription_details?.metadata?.tenantId
        ?? invoice.metadata?.tenantId
        ?? null;

      if (!tenantId) {
        console.warn("stripeBillingWebhook: no tenantId on invoice", invoice.id);
        return res.json({ received: true });
      }

      const nextDue = new Date(invoice.period_end * 1000);
      await db.collection("tenants").doc(tenantId).update({
        paymentStatus: "current",
        status: "active",
        billingNextDue: admin.firestore.Timestamp.fromDate(nextDue),
        gracePeriodEndsAt: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`Billing payment succeeded for tenant ${tenantId}`);
    } else if (event.type === "invoice.payment_failed") {
      const invoice = event.data.object;
      const tenantId = invoice.subscription_details?.metadata?.tenantId
        ?? invoice.metadata?.tenantId
        ?? null;

      if (!tenantId) return res.json({ received: true });

      const gracePeriodEndsAt = new Date();
      gracePeriodEndsAt.setDate(gracePeriodEndsAt.getDate() + 30);

      const tenantSnap = await db.collection("tenants").doc(tenantId).get();
      const tenantData = tenantSnap.data() ?? {};

      await db.collection("tenants").doc(tenantId).update({
        paymentStatus: "grace_period",
        gracePeriodEndsAt: admin.firestore.Timestamp.fromDate(gracePeriodEndsAt),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Email al admin del tenant
      try {
        await sendEmail({
          to: tenantData.adminEmail,
          subject: "Problema con tu pago — Pushka",
          html: `
            <p>Hola,</p>
            <p>Hubo un problema al procesar el pago de tu suscripción a Pushka.</p>
            <p>Tenés <strong>30 días</strong> para regularizar el pago antes de que el servicio sea suspendido.</p>
            <p>Por favor contactá a tu administrador o actualizá tu método de pago.</p>
            <p>— Equipo Pushka</p>
          `,
        });
      } catch (emailErr) {
        console.error("Failed to send grace period email to tenant:", emailErr);
      }

      // Email al super_admin
      try {
        await sendEmail({
          to: SUPER_ADMIN_NOTIFICATION_EMAIL,
          subject: `⚠️ Pago fallido — ${tenantData.name ?? tenantId}`,
          html: `
            <p>El tenant <strong>${tenantData.name ?? tenantId}</strong> (${tenantData.adminEmail}) tiene un pago fallido.</p>
            <p>Período de gracia hasta: ${gracePeriodEndsAt.toLocaleDateString("es-MX")}.</p>
            <p><a href="https://pushka-admin.web.app/tenants/${tenantId}">Ver en el panel</a></p>
          `,
        });
      } catch (emailErr) {
        console.error("Failed to send grace period alert to super admin:", emailErr);
      }

      console.log(`Grace period started for tenant ${tenantId}, ends ${gracePeriodEndsAt.toISOString()}`);
    }

    res.json({ received: true });
  }
);

// ---------------------------------------------------------------------------
// checkGracePeriods — scheduled daily: sends reminder emails + suspends
// ---------------------------------------------------------------------------
exports.checkGracePeriods = onSchedule(
  { schedule: "every 24 hours", secrets: [sendgridApiKey] },
  async () => {
    const now = new Date();

    const snap = await db.collection("tenants")
      .where("paymentStatus", "==", "grace_period")
      .get();

    for (const doc of snap.docs) {
      const data = doc.data();
      const gracePeriodEndsAt = data.gracePeriodEndsAt?.toDate?.();
      if (!gracePeriodEndsAt) continue;

      const daysLeft = Math.ceil((gracePeriodEndsAt - now) / (1000 * 60 * 60 * 24));
      const adminEmail = data.adminEmail;
      const tenantName = data.name ?? doc.id;

      // Suspend if grace period expired
      if (daysLeft <= 0) {
        await doc.ref.update({
          paymentStatus: "suspended",
          status: "suspended",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`Tenant ${doc.id} suspended — grace period expired.`);

        try {
          await sendEmail({
            to: adminEmail,
            subject: "Tu servicio Pushka fue suspendido",
            html: `
              <p>Hola,</p>
              <p>Tu servicio Pushka ha sido suspendido por falta de pago.</p>
              <p>Para reactivarlo, contactá a soporte.</p>
              <p>— Equipo Pushka</p>
            `,
          });
        } catch (e) {
          console.error("suspension email failed:", e);
        }
        continue;
      }

      // Reminder emails at 30, 20, 10, 5 days — deduplicated by day
      const REMINDER_DAYS = [30, 20, 10, 5];
      if (!REMINDER_DAYS.includes(daysLeft)) continue;

      const todayKey = now.toISOString().slice(0, 10); // "YYYY-MM-DD"
      const lastSentKey = data.lastReminderEmailSentAt?.toDate?.()?.toISOString?.()?.slice(0, 10);
      if (lastSentKey === todayKey) {
        console.log(`Skipping duplicate reminder for tenant ${doc.id} — already sent today`);
        continue;
      }

      console.log(`Sending ${daysLeft}-day grace reminder to ${adminEmail} for tenant ${doc.id}`);

      try {
        await sendEmail({
          to: adminEmail,
          subject: `Recordatorio: tu suscripción Pushka vence en ${daysLeft} días`,
          html: `
            <p>Hola,</p>
            <p>Tu suscripción a <strong>${tenantName} Pushka</strong> vence en <strong>${daysLeft} días</strong>.</p>
            <p>Por favor actualizá tu método de pago para evitar la suspensión del servicio.</p>
            <p>— Equipo Pushka</p>
          `,
        });
        await doc.ref.update({
          lastReminderEmailSentAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (e) {
        console.error("reminder email failed:", e);
      }
    }
  }
);
