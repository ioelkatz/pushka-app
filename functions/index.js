const admin = require("firebase-admin");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
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

/**
 * Rate-limits unauthenticated callables by client IP. Cloud Run forwards the
 * client IP via x-forwarded-for; in dev/emulator we fall back to "unknown".
 * IPs are not perfect (NAT, mobile carriers, VPN) but better than no limit.
 */
async function enforceRateLimitByIp(request, action, maxCalls, windowSeconds) {
  const fwd = request.rawRequest?.headers?.["x-forwarded-for"];
  const ip = (Array.isArray(fwd) ? fwd[0] : (fwd || "").split(",")[0])
    .trim()
    || request.rawRequest?.ip
    || "unknown";
  // Sanitize to a Firestore-safe id (max 1500 bytes; commonly < 50).
  const safeIp = ip.replace(/[^a-zA-Z0-9.:_-]/g, "_").slice(0, 100);
  await enforceRateLimit(`ip:${safeIp}`, action, maxCalls, windowSeconds);
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

// Stripe currency precisions. ZERO-decimal currencies (CLP, JPY, KRW, etc.)
// are charged in whole units — Stripe expects 5000 to mean 5000 pesos, not
// 50.00 pesos. THREE-decimal currencies (BHD, JOD, etc.) are charged in
// thousandths but must be a multiple of 10. Everything else is 2-decimal.
// Source: https://stripe.com/docs/currencies#zero-decimal
const ZERO_DECIMAL_CURRENCIES = new Set([
  "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg",
  "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf",
]);
const THREE_DECIMAL_CURRENCIES = new Set(["bhd", "jod", "kwd", "omr", "tnd"]);

/** Smallest-unit-multiplier for a currency. 1 for zero-decimal, 100 for two-decimal, 1000 for three-decimal. */
function currencyUnitDivisor(currency) {
  const code = String(currency || "usd").toLowerCase();
  if (ZERO_DECIMAL_CURRENCIES.has(code)) return 1;
  if (THREE_DECIMAL_CURRENCIES.has(code)) return 1000;
  return 100;
}

/** Formats a Stripe-smallest-unit integer as a decimal string for the given currency. */
function formatAmount(cents, currency = "usd") {
  const div = currencyUnitDivisor(currency);
  const decimals = div === 1 ? 0 : (div === 1000 ? 3 : 2);
  return (Number(cents) / div).toFixed(decimals);
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

/**
 * Computes the next run date for a recurring schedule (weekly or monthly).
 * Used by `processPushkaAutoEmpty` to advance `autoEmptyNextRunAt` after each run.
 *
 * @param {object} opts
 * @param {string} opts.frequency  "weekly" or "monthly"
 * @param {number} opts.weekday    1=Monday … 7=Sunday (Firestore/UI convention)
 * @param {number} opts.dayOfMonth 1-31; clamped to month length
 * @param {Date}   [opts.baseDate] reference "now" for testing
 * @returns {Date} next run timestamp (UTC, 08:00)
 */
function computeNextScheduleDate({
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

  // Weekly: Firestore/UI weekday uses Monday=1...Sunday=7
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

// Stuck-event TTL: if a previous delivery crashed between reserveWebhookEvent
// and finalizeWebhookEvent, the doc stays in "processing" forever and every
// Stripe retry no-ops with `alreadyProcessed=true` — silently dropping the
// event. After this many ms in `processing` we treat it as orphaned and let
// the current invocation re-attempt processing.
const WEBHOOK_PROCESSING_TTL_MS = 5 * 60 * 1000; // 5 minutes — well over function timeout

async function reserveWebhookEvent(event) {
  const eventRef = db.collection("_stripeWebhookEvents").doc(event.id);
  let alreadyProcessed = false;
  let recoveredFromStuck = false;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(eventRef);
    if (snap.exists) {
      const data = snap.data() || {};
      const status = data.status;

      // Terminal states: never reprocess.
      if (status === "processed" || status === "skipped" || status === "ignored" || status === "failed") {
        alreadyProcessed = true;
        return;
      }

      // status === "processing" — check age. The createdAt server timestamp
      // is null inside the same transaction that wrote it (FieldValue resolves
      // server-side), but on a re-delivery we'll see a real timestamp.
      const createdAtMs = data.createdAt?.toMillis?.() ?? 0;
      const ageMs = Date.now() - createdAtMs;
      if (createdAtMs > 0 && ageMs > WEBHOOK_PROCESSING_TTL_MS) {
        // Stuck — claim ownership again and let the caller re-process.
        recoveredFromStuck = true;
        tx.set(eventRef, {
          status: "processing",
          recoveredAt: admin.firestore.FieldValue.serverTimestamp(),
          recoveredFromAgeMs: ageMs,
        }, { merge: true });
        return;
      }

      // Genuinely in-flight (another handler running) OR the createdAt isn't
      // resolved yet (same-instant retry — rare). Treat as duplicate so Stripe
      // doesn't retry; the in-flight handler will finalize.
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

  if (recoveredFromStuck) {
    console.warn(`reserveWebhookEvent: recovered stuck event ${event.id} (type=${event.type})`);
  }

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

  // Load user's tenant to route payment via Stripe Connect.
  const userSnap = await db.collection("users").doc(request.auth.uid).get();
  const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
  const tenantId = userData.tenantId ?? null;

  // Refuse if an auto-empty cron run is currently mid-charge for this
  // (uid, tenantId). Without this guard, a manual "Vaciar Pushka" tap can
  // race against the cron and double-charge the same balance. The lock now
  // lives on the per-tenant `tenantState/{tenantId}` doc — a user belonging
  // to two chabads can have one tenant locked while donating to the other.
  // The lock is short-lived (released by the cron in <30s on success/failure;
  // TTL 10min on crash, applied by the cron's stale-lock check).
  if (tenantId) {
    const stateSnap = await db.collection("users").doc(request.auth.uid)
      .collection("tenantState").doc(tenantId).get();
    if (stateSnap.exists) {
      const _autoLockAt = stateSnap.data()?._autoEmptyChargeLockAt?.toMillis?.() ?? null;
      if (_autoLockAt && (Date.now() - _autoLockAt) < (10 * 60 * 1000)) {
        throw new HttpsError(
          "aborted",
          "Tu Pushka se está vaciando automáticamente en este momento. Esperá unos segundos y volvé a intentar.",
        );
      }
    }
  }

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
      const connectStatus = tenantData.stripeConnectStatus;
      const connectAccountId = tenantData.stripeConnectAccountId;
      if (connectStatus === "active" && connectAccountId) {
        tenantConnectAccountId = connectAccountId;
        tenantCommissionRate = typeof tenantData.commissionRate === "number"
          ? tenantData.commissionRate
          : 0.03;
      } else if (connectAccountId && connectStatus !== "active") {
        // Stripe Connect account exists but is not "active" (likely "restricted"
        // or "pending"). Refusing the payment is safer than silently routing
        // the donation to the platform account — that would mean the donor's
        // money goes to us, not to their tenant org. Surface the error so the
        // tenant admin notices and re-completes Stripe onboarding.
        throw new HttpsError(
          "failed-precondition",
          "Tu organización está temporalmente sin conexión con el procesador de pagos. Avisale al administrador de tu Jabad para que lo regularice.",
        );
      }
      // If connectAccountId is null AND status is not_connected: tenant never
      // set up Connect — fall through to platform-account charge (the original
      // behavior). This is intentional for tenants still in onboarding.
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
  if (purpose !== "donation" && purpose !== "pushka_empty") {
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

  // Idempotency key: uid + purpose + amount + currency + 5-minute bucket.
  // A 5-min bucket (vs 1-min) closes the boundary-straddling double-tap race
  // where two clicks at 12:00:59.500 and 12:01:00.300 land in different buckets
  // and create two PaymentIntents. With 5-min buckets, the worst-case duplicate
  // window is one straddle per 5 minutes, which is acceptable for donations.
  const idempotencyKey = `pi_${request.auth.uid}_${purpose}_${currency}_${amount}_${Math.floor(Date.now() / 300000)}`;

  // Build Stripe Connect params — only when the tenant has an active Connect account.
  // Clamp app fee defensively: a misconfigured commissionRate >= 1 would cause
  // Stripe to reject with `application_fee_amount must be less than amount`,
  // surfacing as a generic donor-facing "could not process" error. The clamp
  // keeps payments flowing even with bad config (tenant just earns more, app
  // earns less) while logging the anomaly for ops to investigate.
  const connectParams = {};
  if (tenantConnectAccountId) {
    const rawFee = Math.floor(amount * tenantCommissionRate);
    const safeFee = Math.max(1, Math.min(rawFee, amount - 1));
    if (safeFee !== rawFee) {
      console.warn("createPaymentIntent: clamped_app_fee", {
        uid: request.auth.uid, tenantId, amount, tenantCommissionRate, rawFee, safeFee,
      });
    }
    connectParams.application_fee_amount = safeFee;
    connectParams.transfer_data = { destination: tenantConnectAccountId };
  }

  const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });

  // Resolve (or create) the user's Stripe customer so the PaymentSheet
  // can show their saved cards. Same get-or-create pattern as
  // createSetupIntent: a Firestore sentinel inside a transaction
  // prevents two concurrent calls from each spawning a separate Stripe
  // customer for the same uid.
  let customerId = String(userData.stripeCustomerId || "").trim() || null;
  if (!customerId) {
    const userRef = db.collection("users").doc(request.auth.uid);
    await db.runTransaction(async (tx) => {
      const fresh = await tx.get(userRef);
      const freshId = String(fresh.data()?.stripeCustomerId || "").trim();
      if (freshId) {
        customerId = freshId;
        return;
      }
      tx.set(userRef, {
        stripeCustomerIdPending: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });
    if (!customerId) {
      try {
        const customer = await stripe.customers.create({
          email: customerEmail || undefined,
          metadata: { uid: request.auth.uid },
        }, { idempotencyKey: `customer_create_${request.auth.uid}` });
        customerId = customer.id;
        await userRef.set({
          stripeCustomerId: customerId,
          stripeCustomerIdPending: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (stripeErr) {
        await userRef.set({
          stripeCustomerIdPending: admin.firestore.FieldValue.delete(),
        }, { merge: true }).catch(() => {});
        throw stripeErr;
      }
    }
  }

  let paymentIntent;
  try {
    paymentIntent = await stripe.paymentIntents.create({
      amount,
      currency,
      customer: customerId,
      receipt_email: customerEmail || undefined,
      // Save card by default so future donations can pick it from the
      // sheet without re-entering. setup_future_usage='off_session'
      // also enables the card for the auto-empty cron path.
      setup_future_usage: "off_session",
      // Card-family only (avoids BNPL and ACH/SEPA which have async/reversible
      // settlement that our pushka-amount logic does not model). Apple Pay
      // and Google Pay are wallet-wrapped cards — Stripe surfaces them
      // automatically when "card" is enabled AND the client passes
      // applePay/googlePay config to PaymentSheet (see stripe_service.dart).
      // The wallet identifier ends up under card.wallet.type on the charge.
      payment_method_types: ["card"],
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
      tenantId: tenantId || null,
      amount,
      currency,
      purpose,
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

  // Generate a customer ephemeral key for the mobile PaymentSheet so it
  // can list the user's saved cards. The apiVersion must match what the
  // Stripe mobile SDK expects; '2024-06-20' is a stable choice that
  // works with current flutter_stripe.
  let ephemeralKeySecret = null;
  try {
    const ephemeralKey = await stripe.ephemeralKeys.create(
      { customer: customerId },
      { apiVersion: "2024-06-20" },
    );
    ephemeralKeySecret = ephemeralKey.secret;
  } catch (ekErr) {
    // Non-fatal: the payment can still proceed without saved-card listing,
    // the user just enters card details fresh as before. Log so we can
    // diagnose if this becomes a chronic issue.
    console.warn("createPaymentIntent: ephemeral key creation failed", {
      uid: request.auth.uid,
      tenantId: tenantId || null,
      customerId,
      errorType: ekErr?.type,
      errorMessage: ekErr?.message,
    });
  }

  return {
    clientSecret: paymentIntent.client_secret,
    customerId,
    ephemeralKeySecret,
  };
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

    // Dedupe by Stripe's `card.fingerprint` — a stable hash of the underlying
    // card number, scoped to the platform Stripe account. Two SetupIntents
    // for the same card on the same customer create two PaymentMethod IDs
    // but share the same fingerprint, so the user sees the card duplicated
    // in the list. Keep the DEFAULT pm if one of the dupes is default;
    // otherwise keep the most-recently-created. Detach the rest from the
    // customer (best-effort: don't fail the list call if detach fails).
    const byFingerprint = new Map();
    for (const pm of pmList.data) {
      const fp = pm.card?.fingerprint;
      if (!fp) {
        // Cards without fingerprint (rare — e.g. some non-card PMs labeled
        // as card by network mismatch) — keep all distinct ids unmodified.
        byFingerprint.set(`__nofp_${pm.id}`, [pm]);
        continue;
      }
      const existing = byFingerprint.get(fp) || [];
      existing.push(pm);
      byFingerprint.set(fp, existing);
    }

    const keep = [];
    const detachQueue = [];
    for (const group of byFingerprint.values()) {
      if (group.length === 1) {
        keep.push(group[0]);
        continue;
      }
      // Pick winner: default if present, else newest by `created` (unix sec).
      const defaultInGroup = group.find((pm) => pm.id === defaultPmId);
      const winner = defaultInGroup ||
        group.slice().sort((a, b) => (b.created || 0) - (a.created || 0))[0];
      keep.push(winner);
      for (const loser of group) {
        if (loser.id !== winner.id) detachQueue.push(loser);
      }
    }

    // Best-effort dedupe cleanup. Each detach is independent — if one fails,
    // the others still run; the user sees the deduped list either way.
    if (detachQueue.length > 0) {
      console.info("listSavedCards: deduping fingerprint dupes", {
        uid, customerId,
        kept: keep.length,
        detaching: detachQueue.length,
      });
      await Promise.all(detachQueue.map((pm) =>
        stripe.paymentMethods.detach(pm.id).catch((detachErr) => {
          console.warn("listSavedCards: detach failed", {
            uid, customerId,
            paymentMethodId: pm.id,
            errorMessage: detachErr?.message,
          });
        }),
      ));
    }

    const cards = keep.map((pm) => ({
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
      // ZERO-decimal currencies (CLP, JPY, KRW, etc.) charge in WHOLE units —
      // dividing by 100 there would store ¥50 for a ¥5000 donation.
      const amount = (intent.amount || 0) / currencyUnitDivisor(intent.currency || "usd");
      const docId = intent.id;

      // pushka_auto_empty: state already updated by the scheduled CF that
      // confirmed the charge. Just mark the event as processed.
      if (uid && purpose === "pushka_auto_empty") {
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
        // Resolve actual payment method from the latest charge. Stripe API
        // 2024-06-20+ removed `intent.charges`; the canonical reference is
        // `intent.latest_charge` (a string id). Apple Pay / Google Pay / Link
        // all report PaymentMethod.type='card' but expose the wallet
        // identifier under `card.wallet.type` — without this fetch the tx
        // would always be persisted as plain "card". Best-effort: if the
        // retrieve fails, fall back to whatever's available on the intent.
        let txPaymentMethod = "card";
        try {
          if (intent.latest_charge && typeof intent.latest_charge === "string") {
            const stripeClient = require("stripe")(stripeSecret.value());
            const charge = await stripeClient.charges.retrieve(intent.latest_charge);
            const pmDetails = charge?.payment_method_details || {};
            const pmType = pmDetails.type || (intent.payment_method_types?.[0]) || "card";
            const wallet = pmDetails.card?.wallet?.type || null;
            txPaymentMethod = wallet || pmType;
          } else {
            txPaymentMethod = (intent.payment_method_types?.[0]) || "card";
          }
        } catch (chargeErr) {
          // Non-fatal — preserve baseline "card" labeling so the tx still writes.
          console.warn("stripeWebhook: latest_charge retrieve failed", {
            paymentIntentId: intent.id,
            latestCharge: intent.latest_charge,
            errorMessage: chargeErr?.message,
          });
        }
        // tenantId comes from createPaymentIntent's metadata. Without it on
        // the tx doc, the multi-tenant history query (`where tenantId == X`)
        // silently excludes the row and the user thinks the payment never
        // landed. The cron path (processPushkaAutoEmpty) already writes
        // tenantId on its own movements; this brings the user-initiated
        // path in line.
        const txTenantId = intent.metadata?.tenantId
          ? String(intent.metadata.tenantId)
          : null;
        if (!txTenantId) {
          // Should never happen post-fix to createPaymentIntent (which always
          // stamps tenantId in metadata). Log loud rather than silently writing
          // a tenant-less tx that the multi-tenant history query will hide.
          console.warn("stripeWebhook: tenantId missing on payment_intent metadata", {
            uid,
            purpose,
            paymentIntentId: docId,
            eventId: event.id,
          });
        }
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
            ...(txTenantId ? { tenantId: txTenantId } : {}),
            description: txDesc,
            paymentMethod: txPaymentMethod,
            status: 'completed',
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });

        await finalizeWebhookEvent(eventRef, {
          status: "processed",
          uid,
          paymentIntentId: docId,
          amount,
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
      const amount = (intent.amount || 0) / currencyUnitDivisor(intent.currency || "usd");
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
      const refundedAmount = (charge.amount_refunded || 0) / currencyUnitDivisor(charge.currency || "usd");
      const currency = String(charge.currency || "usd").toUpperCase();
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
          currencyCode: currency,
          livemode: !!event.livemode,
        });

        // Write a negating transaction so admin stats reflect net donations
        // (without this, the original donation stays in totals forever even
        // after a full refund). docId namespaced by `_refund_<eventId>` so
        // duplicate webhook deliveries don't double-count.
        if (paymentIntentId && refundedAmount > 0) {
          const txRates = await getExchangeRates(null);
          const txSnap = buildCurrencySnapshot(refundedAmount, currency, txRates);
          // Negate snapshot fields too — buildCurrencySnapshot returns positive
          // amounts; flip every numeric value so MXN/USD aggregates net out.
          const negativeSnap = {};
          for (const [k, v] of Object.entries(txSnap)) {
            negativeSnap[k] = typeof v === "number" ? -v : v;
          }
          await db
            .collection("users")
            .doc(uid)
            .collection("transactions")
            .doc(`refund_${charge.id}`)
            .set({
              type: "refund",
              amount: -refundedAmount,
              currencyCode: currency,
              ...negativeSnap,
              description: "Reembolso Stripe",
              originalPaymentIntentId: paymentIntentId,
              originalChargeId: charge.id,
              skipNotification: true, // user already sees the refund in their bank
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
        }
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        uid: uid || null,
        chargeId: charge.id,
        paymentIntentId,
        amount: refundedAmount,
        outcome: "refunded",
      });
    } else if (event.type === "charge.dispute.created") {
      // Chargeback opened — money is provisionally pulled by the cardholder's
      // bank. We write a paymentEvent for visibility and a negating tx so the
      // dashboard reflects the realized loss. If the dispute is later WON, we
      // reverse this in `charge.dispute.closed` (status=won).
      const dispute = event.data.object;
      const chargeId = typeof dispute.charge === "string" ? dispute.charge : dispute.charge?.id;
      let charge = null;
      if (chargeId) {
        try { charge = await stripe.charges.retrieve(chargeId); } catch (_) { /* ignore */ }
      }
      const uid = charge ? await resolveUidFromCharge(charge, stripe) : null;
      const disputedAmount = (dispute.amount || 0) / currencyUnitDivisor(dispute.currency || charge?.currency || "usd");
      const currency = String(dispute.currency || charge?.currency || "usd").toUpperCase();
      const paymentIntentId = charge && typeof charge.payment_intent === "string"
        ? charge.payment_intent
        : (charge?.payment_intent?.id || null);

      if (uid) {
        await writeUserPaymentEvent(uid, event.id, {
          kind: "dispute_created",
          provider: "stripe",
          disputeId: dispute.id,
          chargeId,
          paymentIntentId,
          amount: disputedAmount,
          currencyCode: currency,
          reason: dispute.reason || null,
          livemode: !!event.livemode,
        });

        if (chargeId && disputedAmount > 0) {
          const txRates = await getExchangeRates(null);
          const txSnap = buildCurrencySnapshot(disputedAmount, currency, txRates);
          const negativeSnap = {};
          for (const [k, v] of Object.entries(txSnap)) {
            negativeSnap[k] = typeof v === "number" ? -v : v;
          }
          await db
            .collection("users")
            .doc(uid)
            .collection("transactions")
            .doc(`dispute_${dispute.id}`)
            .set({
              type: "chargeback",
              amount: -disputedAmount,
              currencyCode: currency,
              ...negativeSnap,
              description: "Contracargo (Stripe dispute)",
              disputeId: dispute.id,
              originalChargeId: chargeId,
              originalPaymentIntentId: paymentIntentId,
              disputeStatus: dispute.status || "needs_response",
              skipNotification: true,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
        }
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        uid: uid || null,
        disputeId: dispute.id,
        chargeId,
        amount: disputedAmount,
        outcome: "dispute_created",
      });
    } else if (event.type === "charge.dispute.closed") {
      // Dispute resolved. If we WON, reverse the negating chargeback tx.
      const dispute = event.data.object;
      const chargeId = typeof dispute.charge === "string" ? dispute.charge : dispute.charge?.id;
      let charge = null;
      if (chargeId) {
        try { charge = await stripe.charges.retrieve(chargeId); } catch (_) { /* ignore */ }
      }
      const uid = charge ? await resolveUidFromCharge(charge, stripe) : null;

      if (uid) {
        await writeUserPaymentEvent(uid, event.id, {
          kind: "dispute_closed",
          provider: "stripe",
          disputeId: dispute.id,
          chargeId,
          status: dispute.status, // "won", "lost", "warning_closed", etc.
          livemode: !!event.livemode,
        });

        // If we won, delete the negating chargeback tx so the original
        // donation re-counts in totals. If lost, leave it (loss is real).
        if (dispute.status === "won") {
          await db
            .collection("users")
            .doc(uid)
            .collection("transactions")
            .doc(`dispute_${dispute.id}`)
            .delete()
            .catch(() => { /* never written, ignore */ });
        }
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        uid: uid || null,
        disputeId: dispute.id,
        outcome: `dispute_${dispute.status || "closed"}`,
      });
    } else if (event.type === "charge.dispute.funds_withdrawn" ||
               event.type === "charge.dispute.funds_reinstated") {
      // Notification-grade events that mirror the funds movement during a
      // dispute lifecycle. The negating tx is already created in
      // dispute.created and reversed in dispute.closed (won) — these
      // sub-events serve only as a journal entry so admin reports can show
      // funds-on-hold vs. funds-restored timing without duplicating the
      // accounting impact.
      const dispute = event.data.object;
      const chargeId = typeof dispute.charge === "string" ? dispute.charge : dispute.charge?.id;
      let charge = null;
      if (chargeId) {
        try { charge = await stripe.charges.retrieve(chargeId); } catch (_) { /* ignore */ }
      }
      const uid = charge ? await resolveUidFromCharge(charge, stripe) : null;
      const isWithdrawn = event.type === "charge.dispute.funds_withdrawn";

      if (uid) {
        await writeUserPaymentEvent(uid, event.id, {
          kind: isWithdrawn ? "dispute_funds_withdrawn" : "dispute_funds_reinstated",
          provider: "stripe",
          disputeId: dispute.id,
          chargeId,
          livemode: !!event.livemode,
        });
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        uid: uid || null,
        disputeId: dispute.id,
        outcome: isWithdrawn ? "dispute_funds_withdrawn" : "dispute_funds_reinstated",
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
      const amountUsd = (fee.amount || 0) / currencyUnitDivisor(fee.currency || "usd");

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        tenantId,
        amountUsd,
        chargeId: fee.charge?.id ?? null,
        outcome: "commission_collected",
      });
    } else if (event.type === "application_fee.refunded") {
      // Commission refunded back to platform from connected account — happens
      // automatically when the underlying charge is refunded. Logged so admin
      // dashboards can reconcile platform revenue against gross donations.
      const fee = event.data.object;
      const tenantId = fee.charge?.metadata?.tenantId ?? null;
      const refundedAmount = (fee.amount_refunded || 0) /
        currencyUnitDivisor(fee.currency || "usd");

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        tenantId,
        amountUsd: refundedAmount,
        chargeId: fee.charge?.id ?? null,
        applicationFeeId: fee.id,
        outcome: "commission_refunded",
      });
    } else if (event.type === "payment_intent.canceled") {
      // User abandoned a PaymentIntent (e.g. closed PaymentSheet without
      // confirming) and Stripe auto-cancels after the timeout. Without this
      // handler the event would be marked "ignored" and clutter the
      // observability path. Track it so we can detect abnormal abandonment
      // rates (a spike usually means a UX regression).
      const intent = event.data.object;
      const uid = intent.metadata?.uid;
      const tenantId = intent.metadata?.tenantId ?? null;
      const amount = (intent.amount || 0) / currencyUnitDivisor(intent.currency || "usd");

      if (uid) {
        await writeUserPaymentEvent(uid, event.id, {
          kind: "payment_canceled",
          provider: "stripe",
          paymentIntentId: intent.id,
          amount,
          currencyCode: String(intent.currency || "usd").toUpperCase(),
          cancellationReason: intent.cancellation_reason || "user_abandoned",
          livemode: !!event.livemode,
        });
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        uid: uid || null,
        tenantId,
        paymentIntentId: intent.id,
        amount,
        outcome: "canceled",
        cancellationReason: intent.cancellation_reason || null,
      });
    } else if (event.type === "customer.subscription.deleted" ||
               event.type === "customer.subscription.updated") {
      // Tenant Stripe Billing subscription state change. Mirror the status
      // onto tenants/{tid} so the suspension/grace-period logic
      // (router redirects, processPushkaAutoEmpty gate) reacts within seconds
      // instead of waiting for the next 60s tenant-config poll.
      const sub = event.data.object;
      const tenantId = sub.metadata?.tenantId ?? null;
      const status = sub.status; // active|past_due|canceled|unpaid|trialing|...

      if (tenantId) {
        const tenantStatus =
          status === "active" || status === "trialing" ? "active" :
          status === "past_due" || status === "unpaid" ? "grace_period" :
          status === "canceled" ? "suspended" :
          null; // ignore incomplete/incomplete_expired noise
        if (tenantStatus) {
          await db.collection("tenants").doc(tenantId).set({
            status: tenantStatus,
            paymentStatus: status,
            stripeSubscriptionId: sub.id,
            ...(sub.current_period_end
              ? { billingNextDue: admin.firestore.Timestamp.fromMillis(sub.current_period_end * 1000) }
              : {}),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        }
      } else {
        console.warn("stripeWebhook: subscription event without tenantId metadata", {
          subscriptionId: sub.id,
          status,
          eventType: event.type,
        });
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        tenantId,
        subscriptionId: sub.id,
        outcome: `subscription_${status}`,
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
      console.error("stripeWebhook: Failed to finalize failed event", {
        eventId: event?.id,
        eventType: event?.type,
        finalizeErrorMessage: finalizeErr?.message,
      });
    }
    console.error("stripeWebhook: Processing failed", {
      eventId: event?.id,
      eventType: event?.type,
      errorMessage: err?.message || String(err),
    });
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

    const messages = {
      es: {
        tzedaka:       `¡Gracias por tu donación! ${fmt(amount)}`,
        pushkaEmpty:   `Tu Pushka fue vaciada. Donación: ${fmt(amount)}`,
        default:       "Nueva transacción registrada",
      },
      en: {
        tzedaka:       `Thank you for your donation! ${fmt(amount)}`,
        pushkaEmpty:   `Your Pushka was emptied. Donation: ${fmt(amount)}`,
        default:       "New transaction recorded",
      },
      fr: {
        tzedaka:       `Merci pour votre don ! ${fmt(amount)}`,
        pushkaEmpty:   `Votre Pushka a été vidée. Don : ${fmt(amount)}`,
        default:       "Nouvelle transaction enregistrée",
      },
      he: {
        tzedaka:       `תודה על תרומתך! ${fmt(amount)}`,
        pushkaEmpty:   `הפושקה שלך רוקנה. תרומה: ${fmt(amount)}`,
        default:       "עסקה חדשה נרשמה",
      },
    };

    const m = messages[lang];
    let body = m.default;
    if (type === "tzedaka") body = m.tzedaka;
    else if (type === "pushkaEmpty") body = m.pushkaEmpty;

    const tenantId = data.tenantId ?? "";
    await sendToUser(uid, {
      notification: { title: "Pushka", body },
      data: { type, amount: String(amount), tenantId },
    });
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

// ---------------------------------------------------------------------------
// onTenantBrandingUpdated — propagate tenant rebrand to per-user tenantState
// ---------------------------------------------------------------------------
// tenantState/{tenantId} docs cache appName/logoUrl/primaryColor/name from the
// parent tenant doc at join-time so the UI can render branding without an
// extra read on every screen. Without this trigger, when an admin renames or
// rebrands the tenant, all member sidebars/avatars stay frozen on the old
// values until each user manually leaves and rejoins. This watches the four
// denormalized fields and batch-updates every member's tenantState.
exports.onTenantBrandingUpdated = onDocumentUpdated(
  "tenants/{tenantId}",
  async (event) => {
    const before = event.data?.before?.data() || {};
    const after = event.data?.after?.data() || {};
    const tenantId = event.params.tenantId;

    const denormalizedFields = ["name", "appName", "logoUrl", "primaryColor"];
    const changes = {};
    for (const f of denormalizedFields) {
      if (before[f] !== after[f]) {
        // Map tenant doc field → tenantState field naming.
        const dest = f === "name"
          ? "tenantName"
          : f === "appName"
            ? "tenantAppName"
            : f === "logoUrl"
              ? "tenantLogoUrl"
              : "tenantPrimaryColor";
        changes[dest] = after[f] ?? null;
      }
    }
    if (Object.keys(changes).length === 0) return;

    // Find every tenantState pointing at this tenant. Bounded by tenant size,
    // never the global user table.
    const stateSnap = await db
      .collectionGroup("tenantState")
      .where("tenantId", "==", tenantId)
      .get();

    if (stateSnap.empty) return;

    // Firestore caps batch writes at 500. Chunk + flush.
    const updates = { ...changes, updatedAt: admin.firestore.FieldValue.serverTimestamp() };
    const docs = stateSnap.docs;
    const CHUNK = 400;
    for (let i = 0; i < docs.length; i += CHUNK) {
      const batch = db.batch();
      for (const d of docs.slice(i, i + CHUNK)) {
        batch.set(d.ref, updates, { merge: true });
      }
      await batch.commit();
    }
    console.info("onTenantBrandingUpdated: synced tenantState docs", {
      tenantId,
      changed: Object.keys(changes),
      affectedDocs: docs.length,
    });
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
// Reads from the `users/{uid}/tenantState/{tenantId}` subcollection so
// schedule + balance are per-organisation (a user belonging to two chabads
// gets two independent auto-empty cycles). Stripe credentials
// (stripeCustomerId, stripeDefaultPaymentMethodId, currencyCode, isBlocked)
// remain on the user doc. Requires a collection-group index on:
//   tenantState fields: autoEmptyNextRunAt ASC

// Stale in-flight lock TTL — if a previous run crashed between the eligibility
// transaction and the success-finalize transaction, the lock is considered
// abandoned after this and the (uid, tenantId) pair becomes eligible again.
// Tuned generously to outlast any realistic Stripe retry window.
const AUTO_EMPTY_LOCK_TTL_MS = 10 * 60 * 1000; // 10 min

// Short retry interval when a charge fails (decline, suspended tenant, blocked
// user, Connect not active). Without this, advancing the schedule before the
// charge meant a single failure silently skipped the entire monthly cycle.
const AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS = 24;

exports.processPushkaAutoEmpty = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Etc/UTC",
    secrets: [stripeSecret],
    // Single concurrent invocation prevents overlapping cron runs from
    // double-processing the same user (the schedule advance now happens AFTER
    // Stripe responds, so a slow first run + on-time second run could both
    // grab the same due users without this guard).
    maxInstances: 1,
  },
  async () => {
    if (!stripeSecret.value()) {
      console.error("processPushkaAutoEmpty: STRIPE_SECRET_KEY missing");
      return;
    }

    const nowTs = admin.firestore.Timestamp.now();

    // Per-tenant rows due. Limit 200: each iteration may issue a Stripe call
    // (1-2s) plus 2 Firestore transactions; 200 stays comfortably under the
    // function's timeout budget when paired with maxInstances:1.
    const dueStates = await db
      .collectionGroup("tenantState")
      .where("autoEmptyNextRunAt", "<=", nowTs)
      .limit(200)
      .get();

    if (dueStates.empty) {
      console.info("processPushkaAutoEmpty: no_due_states");
      return;
    }

    let processed = 0;
    let failed = 0;
    let skipped = 0;
    const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });

    for (const stateDoc of dueStates.docs) {
      const stateRef = stateDoc.ref;
      const stateDataRaw = stateDoc.data() || {};
      const uid = stateDataRaw.uid;
      const tenantId = stateDataRaw.tenantId;

      if (!uid || !tenantId) {
        console.warn("processPushkaAutoEmpty: missing uid/tenantId in state doc", { path: stateDoc.ref.path });
        continue;
      }

      const userRef = db.collection("users").doc(uid);

      // Per-iteration plan captured inside the eligibility transaction and
      // used in the charge + finalization steps.
      let plan = null;

      try {
        // ===== Step 1: Eligibility transaction =====
        // Atomically verify (uid, tenantId) is due, tenant is active, user
        // not blocked, balance + saved card present; then claim an in-flight
        // lock on the stateRef so concurrent manual "Vaciar Pushka" or a
        // delayed-cron retry cannot double-charge the same (uid, tenantId).
        // CRITICAL: schedule is NOT advanced here. It advances in the success
        // path (normal next date) or failure path (+24h retry). This was the
        // root cause of the bug where a single decline silently skipped the
        // entire monthly billing cycle.
        await db.runTransaction(async (tx) => {
          const [stateSnap, userSnap, tenantSnap] = await Promise.all([
            tx.get(stateRef),
            tx.get(userRef),
            tx.get(db.collection("tenants").doc(tenantId)),
          ]);
          if (!stateSnap.exists || !userSnap.exists) return;

          const state = stateSnap.data() || {};
          const userData = userSnap.data() || {};
          const tenantData = tenantSnap.exists ? (tenantSnap.data() || {}) : null;

          const freq = state.autoEmptyFrequency || "manual";
          if (freq === "manual") return;

          const nextRun = state.autoEmptyNextRunAt;
          if (!nextRun || nextRun.toMillis() > Date.now()) return;

          // Already-running guard. Lock is per-(uid, tenantId): a user with two
          // tenants can have both auto-empties running simultaneously — only
          // double-runs for the SAME pair are blocked. Stale locks (older than
          // TTL) are treated as abandoned and overwritten.
          const lockAt = state._autoEmptyChargeLockAt?.toMillis?.() ?? null;
          if (lockAt && (Date.now() - lockAt) < AUTO_EMPTY_LOCK_TTL_MS) {
            console.info("processPushkaAutoEmpty: skip_locked", { uid, tenantId, lockAgeMs: Date.now() - lockAt });
            return;
          }

          // Tenant doc must exist and not be suspended. createPaymentIntent
          // enforces both for the interactive flow; the cron must too. A
          // missing tenant means the org was deleted out from under the user
          // — clear the schedule entirely so the row stops appearing in the
          // due-states query (the user will be redirected to /tenant-setup
          // by the orphan-healing path in getTenantConfig).
          if (!tenantData) {
            console.warn("processPushkaAutoEmpty: tenant_missing", { uid, tenantId });
            tx.set(stateRef, {
              autoEmptyNextRunAt: null,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }
          if (tenantData.status === "suspended") {
            // Suspended → never charge. Push the schedule out 24h so we
            // re-check tomorrow without spamming Stripe.
            tx.set(stateRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
                new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
              ),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }

          // User block guard. Same gentle re-check as suspended tenant: do
          // not charge, do not advance the normal cycle, just defer 24h.
          if (userData.isBlocked === true) {
            console.warn("processPushkaAutoEmpty: user_blocked", { uid, tenantId });
            tx.set(stateRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
                new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
              ),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }

          const currentAmount = Number(state.pushkaAmount || 0);
          const minBalance = 5;
          const weekday = Number(state.autoEmptyWeekday || 1);
          const dayOfMonth = Number(state.autoEmptyDayOfMonth || 1);

          // Compute the NORMAL next-run date for use in the success path
          // (and the no-card / unsupported-currency / below-min cases that
          // are not actual failures, just "skip this cycle and move on").
          let normalNextDate;
          if (freq === "erev_rosh_chodesh") {
            normalNextDate = computeNextErevRoshChodesh(new Date());
          } else {
            normalNextDate = computeNextScheduleDate({
              frequency: freq, weekday, dayOfMonth, baseDate: new Date(),
            });
          }

          // Helper: advance schedule normally without charging.
          const advanceNormalOnly = () => {
            tx.set(stateRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(normalNextDate),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
          };

          if (currentAmount < minBalance) { advanceNormalOnly(); return; }

          const customerId = String(userData.stripeCustomerId || "").trim();
          const pmId = String(state.autoEmptyPaymentMethodId || userData.stripeDefaultPaymentMethodId || "").trim();
          if (!customerId || !pmId) {
            console.warn("processPushkaAutoEmpty: no_saved_card", { uid, tenantId });
            advanceNormalOnly();
            return;
          }

          const topOffEnabled = state.autoEmptyTopOffEnabled === true;
          const topOffAmount = topOffEnabled ? Number(state.autoEmptyTopOffAmount || 0) : 0;
          const newPushkaAmount = topOffEnabled && topOffAmount > 0 ? topOffAmount : 0;

          const rawCurrency = String(userData.currencyCode || "usd").toLowerCase().trim();
          if (!SUPPORTED_CURRENCIES.has(rawCurrency)) {
            console.warn("processPushkaAutoEmpty: unsupported_currency", { uid, tenantId, rawCurrency });
            advanceNormalOnly();
            return;
          }

          // Stripe Connect routing — same logic as createPaymentIntent. If
          // the tenant has an active Connect account, donations MUST go to
          // it (otherwise the platform pockets it). If status is set but not
          // "active", refuse to charge — admin must reconnect Stripe.
          let tenantConnectAccountId = null;
          let tenantCommissionRate = 0;
          const connectStatus = tenantData.stripeConnectStatus;
          const connectAccountId = tenantData.stripeConnectAccountId;
          if (connectStatus === "active" && connectAccountId) {
            tenantConnectAccountId = connectAccountId;
            tenantCommissionRate = typeof tenantData.commissionRate === "number"
              ? tenantData.commissionRate
              : 0.03;
          } else if (connectAccountId && connectStatus !== "active") {
            console.warn("processPushkaAutoEmpty: connect_not_active", {
              uid, tenantId, connectStatus,
            });
            tx.set(stateRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
                new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
              ),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return;
          }
          // connectAccountId == null && status != active → tenant never set
          // up Connect → fall through to platform charge (legacy behavior
          // for tenants in onboarding).

          // Capture the in-flight lock + the original due timestamp (used as
          // the Stripe idempotency key so a retry produces the same PI).
          const runTs = nextRun.toMillis();
          tx.set(stateRef, {
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

          plan = {
            amount: currentAmount,
            currency: rawCurrency,
            customerId,
            pmId,
            newPushkaAmount,
            normalNextDate,
            tenantId,
            tenantConnectAccountId,
            tenantCommissionRate,
            nextRunDateKey: String(runTs),
          };
        });

        if (!plan) { skipped += 1; continue; }

        // ===== Step 2: Off-session Stripe charge with Connect routing =====
        // Use per-currency divisor so zero-decimal currencies (CLP, JPY, KRW)
        // are not silently 100×-overcharged via the default 2-decimal cents
        // assumption. plan.amount is the user-facing major-unit value.
        const amountCents = Math.round(plan.amount * currencyUnitDivisor(plan.currency));
        const minCents = minAmountForCurrency(plan.currency);
        if (amountCents < minCents) {
          console.warn("processPushkaAutoEmpty: amount_below_stripe_minimum", {
            uid, tenantId: plan.tenantId, amountCents, minCents,
          });
          // Below minimum after lock — release lock, advance schedule normally.
          await stateRef.set({
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
            autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(plan.normalNextDate),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
          skipped += 1;
          continue;
        }

        const idempotencyKey = `pushka_auto_empty_${uid}_${plan.tenantId}_${plan.nextRunDateKey}`;
        const piParams = {
          amount: amountCents,
          currency: plan.currency,
          customer: plan.customerId,
          payment_method: plan.pmId,
          off_session: true,
          confirm: true,
          // Restrict to card so off-session charges never land on async
          // methods (BNPL/SEPA/ACH) that settle days later and cannot be
          // charged off-session anyway.
          payment_method_types: ["card"],
          error_on_requires_action: true,
          metadata: {
            uid,
            source: "pushka",
            purpose: "pushka_auto_empty",
            tenantId: plan.tenantId,
          },
        };
        if (plan.tenantConnectAccountId) {
          // Clamp app-fee defensively so a misconfigured commissionRate
          // cannot produce application_fee_amount >= amount (Stripe rejects).
          const rawFee = Math.floor(amountCents * plan.tenantCommissionRate);
          const safeFee = Math.max(1, Math.min(rawFee, amountCents - 1));
          piParams.application_fee_amount = safeFee;
          piParams.transfer_data = { destination: plan.tenantConnectAccountId };
        }

        let paymentIntent;
        try {
          paymentIntent = await stripe.paymentIntents.create(piParams, { idempotencyKey });
        } catch (stripeErr) {
          console.error("processPushkaAutoEmpty: stripe_charge_failed", {
            uid,
            tenantId: plan.tenantId,
            idempotencyKey,
            chargeId: stripeErr?.payment_intent?.latest_charge?.id || null,
            paymentIntentId: stripeErr?.payment_intent?.id || null,
            error: String(stripeErr?.message || stripeErr),
            code: stripeErr?.code,
            type: stripeErr?.type,
          });

          // ===== Failure path: release lock + 24h retry on stateRef =====
          await stateRef.set({
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
            autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
              new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
            ),
            autoEmptyConsecutiveFailures: admin.firestore.FieldValue.increment(1),
            autoEmptyLastFailureAt: admin.firestore.FieldValue.serverTimestamp(),
            autoEmptyLastFailureCode: String(stripeErr?.code || "unknown"),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

          // Notify user once per failure.
          const failLang = await getUserLanguage(uid);
          const failTitles = { es: "Vaciado fallido", en: "Empty failed", fr: "Vidage échoué", he: "הריקון נכשל" };
          const failBodies = {
            es: "No pudimos cobrar tu tarjeta para el vaciado automático. Revisá tu tarjeta en Configuración.",
            en: "We couldn't charge your card for the automatic empty. Please check your card in Settings.",
            fr: "Nous n'avons pas pu débiter votre carte pour le vidage automatique. Vérifiez votre carte dans Paramètres.",
            he: "לא הצלחנו לחייב את הכרטיס שלך לריקון האוטומטי. בדוק את הכרטיס שלך בהגדרות.",
          };
          await sendToUser(uid, {
            notification: { title: failTitles[failLang], body: failBodies[failLang] },
            data: { type: "pushkaAutoEmptyFailed", tenantId: plan.tenantId },
          }).catch(() => {});
          failed += 1;
          continue;
        }

        if (paymentIntent.status !== "succeeded") {
          console.warn("processPushkaAutoEmpty: payment_not_succeeded", {
            uid, tenantId: plan.tenantId, status: paymentIntent.status,
          });
          // Same release+retry as the failure path.
          await stateRef.set({
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
            autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
              new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
            ),
            autoEmptyConsecutiveFailures: admin.firestore.FieldValue.increment(1),
            autoEmptyLastFailureAt: admin.firestore.FieldValue.serverTimestamp(),
            autoEmptyLastFailureCode: `status_${paymentIntent.status}`,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
          failed += 1;
          continue;
        }

        // ===== Step 3 (success path): release lock, advance schedule, reset =====
        // pushkaAmount + schedule + lock + failure-tracking go on stateRef
        // (per-tenant). Transaction doc goes on userRef/transactions with the
        // tenantId field so analytics can group/filter by org.
        const emptiedAmount = plan.amount;
        const emptyPiId = paymentIntent.id;
        const emptyRates = await getExchangeRates(null);
        const emptySnap = buildCurrencySnapshot(emptiedAmount, plan.currency.toUpperCase(), emptyRates);

        try {
          await db.runTransaction(async (tx) => {
            tx.set(stateRef, {
              pushkaAmount: plan.newPushkaAmount,
              _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(plan.normalNextDate),
              autoEmptyConsecutiveFailures: 0,
              autoEmptyLastSuccessAt: admin.firestore.FieldValue.serverTimestamp(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            const movementRef = userRef.collection("transactions").doc(emptyPiId);
            tx.set(movementRef, {
              type: "pushkaEmpty",
              amount: emptiedAmount,
              currencyCode: plan.currency.toUpperCase(),
              tenantId: plan.tenantId,
              ...emptySnap,
              description: "Vaciado automático de Pushka",
              paymentMethod: "auto_card",
              status: "completed",
              skipNotification: true,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          });
        } catch (step3Err) {
          // Stripe charge succeeded but local finalize failed. Lock stays
          // set until TTL expires (10 min) — that's intentional so a retry
          // of this function does not double-charge while the doc is in an
          // inconsistent state. The PI id is logged for manual recovery.
          console.error("processPushkaAutoEmpty: step3_finalize_failed_after_charge", {
            uid, tenantId: plan.tenantId,
            paymentIntentId: emptyPiId,
            amount: emptiedAmount,
            error: String(step3Err?.message || step3Err),
          });
          failed += 1;
          continue;
        }

        // Step 4: notify success (best-effort, never blocks)
        try {
          const emptyLang = await getUserLanguage(uid);
          const emptySym = currencySymbol(plan.currency);
          const amtStr = Number(emptiedAmount).toFixed(2);
          const emptyTitles = { es: "Pushka vaciada ✡", en: "Pushka emptied ✡", fr: "Pushka vidée ✡", he: "הפושקה רוקנה ✡" };
          const emptyBodies = {
            es: `Tu Pushka fue vaciada automáticamente. Donación: ${emptySym}${amtStr}`,
            en: `Your Pushka was automatically emptied. Donation: ${emptySym}${amtStr}`,
            fr: `Votre Pushka a été vidée automatiquement. Don : ${emptySym}${amtStr}`,
            he: `הפושקה שלך רוקנה אוטומטית. תרומה: ${emptySym}${amtStr}`,
          };
          await sendToUser(uid, {
            notification: { title: emptyTitles[emptyLang], body: emptyBodies[emptyLang] },
            data: { type: "pushkaEmpty", amount: String(emptiedAmount), tenantId: plan.tenantId },
          }).catch(() => {});
        } catch (notifErr) {
          console.warn("processPushkaAutoEmpty: notification_failed", {
            uid, tenantId: plan.tenantId, error: String(notifErr?.message || notifErr),
          });
        }

        processed += 1;
      } catch (err) {
        failed += 1;
        console.error("processPushkaAutoEmpty: state_failed", {
          uid, tenantId, path: stateDoc.ref.path, error: String(err?.message || err),
        });
        // Best-effort lock release on unexpected error. Lock TTLs out anyway,
        // but releasing eagerly lets the next cron run pick it up sooner.
        try {
          await stateRef.set({
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        } catch (_) { /* swallow — lock will TTL out */ }
      }
    }

    console.info("processPushkaAutoEmpty: completed", { processed, failed, skipped });
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
 * Returns the default pushka goal for a given ISO 4217 currency code (uppercase).
 * Values mirror the Flutter UserRepository.defaultGoalForCurrency constants.
 */
function defaultGoalForCurrency(currency) {
  const goals = {
    EUR: 180, GBP: 180, CAD: 180, ILS: 770,
    MXN: 1800, BRL: 770, ARS: 180000, CLP: 180000, COP: 770000,
  };
  return goals[String(currency || "USD").toUpperCase()] ?? 180;
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

// Fresh-claims variant: reads customClaims directly from Auth, bypassing the
// 1h-stale ID token. Use for security-critical write paths (createTenant,
// deleteTenant, suspendTenant, etc.) where a recently-demoted super_admin
// must be rejected immediately, not after their token rotates.
async function callerIsSuperAdminFresh(request) {
  const uid = request.auth?.uid;
  if (!uid) return false;
  try {
    const rec = await admin.auth().getUser(uid);
    const claims = rec.customClaims || {};
    return claims.role === "super_admin" ||
      (claims.admin === true && rec.email === SUPER_ADMIN_EMAIL);
  } catch (_) {
    return false;
  }
}

/**
 * Sets role claims for a user.
 * - role: "super_admin" | "tenant_admin" | "tenant_collaborator"
 * - tenantId: required for tenant_admin and tenant_collaborator
 * - revoke: removes all admin claims
 */
exports.setAdminClaim = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    }

    await enforceRateLimit(callerUid, "setAdminClaim", 20, 3600);

    const callerRecord = await admin.auth().getUser(callerUid);
    const callerClaims = callerRecord.customClaims || {};
    // SECURITY: verify against the FRESH customClaims from Auth, not the
    // potentially-stale `request.auth.token`. A demoted super_admin would
    // still hold their old token (1h TTL) until they sign in again — they
    // must NOT be able to grant claims after demotion. We additionally
    // anchor super_admin to the canonical email.
    const callerIsSuper = callerClaims.role === "super_admin" ||
      (callerClaims.admin === true && callerRecord.email === SUPER_ADMIN_EMAIL);
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

    // setCustomUserClaims REPLACES the claims object — it does not merge.
    // This is intentional:
    //   - super_admin is cross-tenant, so we drop any prior tenantId.
    //   - revoke wipes everything; the user's Firestore tenantId is also
    //     cleared below so they don't appear as a stale tenant member.
    //   - tenant_admin / tenant_collaborator always get a fresh tenantId
    //     from the caller param (validated above).
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

    // On revoke, also clear the user's tenantId in Firestore so the rule
    // `(isTenantMember() && resource.data.tenantId == callerTenantId())`
    // can never falsely include them in tenant queries (defense-in-depth;
    // the role-claim check already blocks reads, but we keep state consistent).
    if (revoke) {
      try {
        await db.collection("users").doc(targetRecord.uid).set(
          { tenantId: admin.firestore.FieldValue.delete() },
          { merge: true },
        );
      } catch (e) {
        console.warn("setAdminClaim: failed to clear tenantId on revoke", { uid: targetRecord.uid, error: String(e?.message || e) });
      }
    }

    // Force the target's next request to refresh their ID token so the new
    // claims take effect immediately (otherwise stale tokens stay valid for
    // up to 1 hour).
    try {
      await admin.auth().revokeRefreshTokens(targetRecord.uid);
    } catch (e) {
      console.warn("setAdminClaim: failed to revoke refresh tokens", { uid: targetRecord.uid, error: String(e?.message || e) });
    }

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
  { enforceAppCheck: true },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
    const isTenantAdmin = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdmin) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    // Rate limit: this endpoint is expensive (paginates Auth or queries Firestore).
    // 30/hour is generous for dashboard polling but blocks runaway scripts.
    await enforceRateLimit(callerUid, "listAdmins", 30, 3600);

    // For tenant_admin: query Firestore users by tenantId — bounded by tenant
    // size, not total Auth users. Old behavior iterated ALL Auth users (millions
    // at scale) just to filter for one tenant.
    if (!isSuper) {
      const callerTenantId = callerClaims.tenantId;
      if (!callerTenantId) {
        throw new HttpsError("failed-precondition", "tenant_admin sin tenantId.");
      }
      const usersSnap = await db
        .collection("users")
        .where("tenantId", "==", callerTenantId)
        .get();

      // Hydrate roles from Auth (only for the tenant's users).
      const admins = [];
      await Promise.all(usersSnap.docs.map(async (doc) => {
        try {
          const authUser = await admin.auth().getUser(doc.id);
          const claims = authUser.customClaims ?? {};
          if (claims.role || claims.admin === true) {
            admins.push({
              uid: authUser.uid,
              email: authUser.email,
              displayName: authUser.displayName,
              role: claims.role ?? (claims.admin ? "super_admin" : null),
              tenantId: claims.tenantId ?? null,
            });
          }
        } catch (_) {
          // User in Firestore but not in Auth — skip silently.
        }
      }));
      return { admins };
    }

    // super_admin: needs the full list across all tenants. Paginate Auth with a hard cap.
    const allUsers = [];
    let pageToken;
    let pages = 0;
    const MAX_PAGES = 50; // 50 * 1000 = 50k users hard cap
    do {
      const listResult = await admin.auth().listUsers(1000, pageToken);
      allUsers.push(...listResult.users);
      pageToken = listResult.pageToken;
      pages += 1;
      if (pages >= MAX_PAGES) {
        console.warn("listAdmins: hit MAX_PAGES cap; results truncated", { pages, totalSoFar: allUsers.length });
        break;
      }
    } while (pageToken);

    const admins = allUsers
      .filter((u) => u.customClaims?.admin === true || u.customClaims?.role)
      .map((u) => ({
        uid: u.uid,
        email: u.email,
        displayName: u.displayName,
        role: u.customClaims?.role ?? (u.customClaims?.admin ? "super_admin" : null),
        tenantId: u.customClaims?.tenantId ?? null,
      }));

    return { admins };
  }
);

// ---------------------------------------------------------------------------
// Admin: getAdminStats — aggregated stats for the dashboard Overview
// ---------------------------------------------------------------------------

exports.getAdminStats = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "getAdminStats", 60, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
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

    // Bound the transaction scan: dashboard only displays the last 12 months
    // anyway. Scanning the full collectionGroup unbounded OOMs the function
    // once the project reaches ~100k+ historical txs and runs up Firestore
    // read costs on every dashboard view.
    // `totalAllTimeMXN` becomes "totalLast12MonthsMXN" — UI labeling stays
    // accurate since the dashboard already only charts 12 months.
    const sinceTs = admin.firestore.Timestamp.fromDate(startOf12Months);
    const TX_HARD_CAP = 50000; // safety cap; alerts if hit so we know to migrate to aggregation
    const [usersSnap, txSnap] = await Promise.all([
      usersQuery.get(),
      db.collectionGroup("transactions")
        .where("createdAt", ">=", sinceTs)
        .limit(TX_HARD_CAP)
        .get(),
    ]);
    if (txSnap.size >= TX_HARD_CAP) {
      console.warn(`getAdminStats: hit TX_HARD_CAP=${TX_HARD_CAP} for tenant=${filterTenantId ?? "all"} — totals are truncated; migrate to pre-aggregated counters`);
    }

    const mxnRate = rates["MXN"] ?? 17.1; // units of MXN per 1 USD

    // Build user metadata map for enriching transaction data
    const userMap = {};
    for (const d of usersSnap.docs) {
      const u = d.data();
      const currency = String(u.currencyCode || "USD").toUpperCase();
      const rate = rates[currency] ?? 1;
      userMap[d.id] = {
        displayName: u.displayName || u.email || d.id,
        email: u.email || "",
        currencyCode: currency,
      };
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
      monthlyBuckets[key] = { totalMXN: 0, count: 0, tzedaka: 0, pushkaEmpty: 0 };
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
  { enforceAppCheck: true },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "getRecentTransactions", 60, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
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

    // Use Firestore's index instead of fetch-all-then-sort. When filtering by
    // tenant we can take advantage of the (tenantId ASC, createdAt DESC)
    // collection-group composite index, dropping the read cost from O(2000)
    // to O(200). Older legacy txs lacking tenantId are excluded (super_admin
    // unfiltered view still sees them via the orderBy(createdAt) path).
    const FETCH_CAP = 500;
    const txSnap = filterTenantId
      ? await db
          .collectionGroup("transactions")
          .where("tenantId", "==", filterTenantId)
          .orderBy("createdAt", "desc")
          .limit(FETCH_CAP)
          .get()
      : await db
          .collectionGroup("transactions")
          .orderBy("createdAt", "desc")
          .limit(FETCH_CAP)
          .get();

    const usersSnap = await usersQuery.get();

    const userMap = {};
    usersSnap.docs.forEach((d) => {
      const u = d.data();
      userMap[d.id] = { displayName: u.displayName || u.email || d.id, email: u.email || "" };
    });

    // Defense-in-depth: confirm tx owner exists in userMap when tenant-filtering.
    // The query above already restricts via tenantId on the doc, so this
    // tightens against legacy txs whose tenantId stamp drifted from the
    // owner's current tenant.
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

    // Already ordered desc by Firestore — slice for hard UI cap.
    return txs.slice(0, 200);
  }
);

// ---------------------------------------------------------------------------
// Admin: getFailedPayments — recent payment failures (last 30 days)
// ---------------------------------------------------------------------------

exports.getFailedPayments = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
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

    let snap;
    try {
      snap = await db.collection("_stripeWebhookEvents")
        .where("status", "==", "failed")
        .where("createdAt", ">=", since)
        .get();
    } catch (_) {
      // Collection doesn't exist or missing composite index — return empty
      return [];
    }

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
  { enforceAppCheck: true },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    // Use FRESH custom claims, not the 1h-stale ID token, for this
    // security-critical write. A demoted admin's old token must not be able to
    // block users for the remainder of its TTL.
    const callerRecord = await admin.auth().getUser(callerUid);
    const callerClaims = callerRecord.customClaims || {};
    const isSuper = callerClaims.role === "super_admin" ||
      (callerClaims.admin === true && callerRecord.email === SUPER_ADMIN_EMAIL);
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

    // Force every cached ID token to be considered invalid on next API call.
    // Without this, a blocked user's existing token (already refreshed in the
    // last hour) keeps passing all callable function auth checks and rule
    // evaluations until natural expiry. `revokeRefreshTokens` flips the
    // `auth_time` floor on the user's tokens; subsequent `verifyIdToken`
    // calls with `checkRevoked: true` will reject them. Same defense applied
    // in setAdminClaim.
    if (isBlocked) {
      try {
        await admin.auth().revokeRefreshTokens(uid);
      } catch (e) {
        console.warn("setUserBlocked: failed to revoke refresh tokens", {
          uid, error: String(e?.message || e),
        });
      }
    }

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

// ---------------------------------------------------------------------------
// deleteAccount — GDPR right-to-be-forgotten (caller deletes their own account).
//
// Self-service only: a user can ONLY delete their own uid. Admin-side blocks
// flow through `setUserBlocked` instead (preserves audit trail). This endpoint
// burns:
//   - All Stripe subscriptions on the user's customer
//   - The Stripe Customer object (which detaches all saved cards/PMs)
//   - users/{uid} + every subcollection (transactions, reminders, fcmTokens,
//     tenantState, paymentEvents, savedCards, _rateLimits/{uid_*})
//   - profile_photos/{uid}.jpg from Storage
//   - The Firebase Auth user record (irreversible — same email can't recover
//     the account, must re-register)
//
// Writes a tombstone to `_deletedAccounts/{uid}` so re-registration with the
// same email can be detected, and so legal/compliance has a retention record
// (uid + deletedAt + reason) for the statutory period without the PII.
// ---------------------------------------------------------------------------
exports.deleteAccount = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");

    // Stricter rate limit than the others — account deletion should never be
    // automated. 3/day is enough for the legitimate "deleted by mistake →
    // re-registered → re-deleted" path; anything beyond is suspicious.
    await enforceRateLimit(uid, "deleteAccount", 3, 86400);

    // Force fresh ID-token verification: the user must have refreshed within
    // the last 5 minutes (i.e. just re-authenticated in the client). Stripe-
    // backed irreversible action requires recent auth proof.
    const recentAuthSec = request.auth?.token?.auth_time ?? 0;
    if (Date.now() / 1000 - recentAuthSec > 300) {
      throw new HttpsError(
        "failed-precondition",
        "Volvé a iniciar sesión y reintentá la eliminación.",
      );
    }

    const userRef = db.collection("users").doc(uid);
    const userSnap = await userRef.get();
    const userData = userSnap.exists ? userSnap.data() || {} : {};
    const stripeCustomerId = userData.stripeCustomerId || null;
    const email = userData.email || null;

    // ---- 1. Stripe cleanup (best-effort; don't block deletion on it) ----
    let stripeCleanup = { customerDeleted: false, subscriptionsCanceled: 0 };
    if (stripeCustomerId && stripeSecret.value()) {
      try {
        const stripe = require("stripe")(stripeSecret.value());
        // Cancel any active subscriptions
        const subs = await stripe.subscriptions.list({
          customer: stripeCustomerId,
          status: "active",
          limit: 100,
        });
        for (const sub of subs.data) {
          try {
            await stripe.subscriptions.cancel(sub.id);
            stripeCleanup.subscriptionsCanceled += 1;
          } catch (subErr) {
            console.warn("deleteAccount: subscription cancel failed", {
              uid, subscriptionId: sub.id, errorMessage: subErr?.message,
            });
          }
        }
        // Delete customer (detaches all saved PMs)
        await stripe.customers.del(stripeCustomerId);
        stripeCleanup.customerDeleted = true;
      } catch (stripeErr) {
        // Stripe failures are logged but DO NOT block deletion. The platform
        // operator can clean up the orphan Stripe customer manually if needed.
        console.error("deleteAccount: Stripe cleanup failed", {
          uid,
          stripeCustomerId,
          errorMessage: stripeErr?.message,
        });
      }
    }

    // ---- 2. Firestore subcollection delete (recursive batch) ----
    const subCollections = [
      "transactions", "reminders", "fcmTokens", "tenantState",
      "paymentEvents", "savedCards",
    ];
    let docsDeleted = 0;
    for (const subName of subCollections) {
      const subRef = userRef.collection(subName);
      // Iterate in chunks of 400 to stay under Firestore batch limit (500).
      let lastDoc = null;
      while (true) {
        let q = subRef.orderBy("__name__").limit(400);
        if (lastDoc) q = q.startAfter(lastDoc);
        const snap = await q.get();
        if (snap.empty) break;
        const batch = db.batch();
        snap.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
        docsDeleted += snap.size;
        if (snap.size < 400) break;
        lastDoc = snap.docs[snap.docs.length - 1];
      }
    }

    // ---- 3. Storage cleanup (profile photo) ----
    let storageDeleted = false;
    try {
      const bucket = admin.storage().bucket();
      const photoRef = bucket.file(`profile_photos/${uid}.jpg`);
      const [exists] = await photoRef.exists();
      if (exists) {
        await photoRef.delete();
        storageDeleted = true;
      }
    } catch (storageErr) {
      console.warn("deleteAccount: storage cleanup failed", {
        uid, errorMessage: storageErr?.message,
      });
    }

    // ---- 4. Per-uid rate-limit doc cleanup (so re-registered uid starts fresh) ----
    try {
      const rlSnap = await db.collection("_rateLimits")
        .where(admin.firestore.FieldPath.documentId(), ">=", `${uid}_`)
        .where(admin.firestore.FieldPath.documentId(), "<", `${uid}_~`)
        .get();
      if (!rlSnap.empty) {
        const batch = db.batch();
        rlSnap.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
      }
    } catch (rlErr) {
      // Rate limit cleanup is non-critical — leftover docs auto-expire by TTL.
      console.warn("deleteAccount: rate-limit cleanup failed", {
        uid, errorMessage: rlErr?.message,
      });
    }

    // ---- 5. Tombstone (compliance retention) ----
    // Store the BARE MINIMUM: uid + deletion timestamp + reason. NO PII.
    // Re-registration with the same email is allowed but tombstone persists
    // to satisfy "did this uid exist?" forensic questions during the
    // statutory retention period.
    await db.collection("_deletedAccounts").doc(uid).set({
      uid,
      deletedAt: admin.firestore.FieldValue.serverTimestamp(),
      reason: "user_request",
      stripeCustomerCleaned: stripeCleanup.customerDeleted,
      subscriptionsCanceled: stripeCleanup.subscriptionsCanceled,
      docsDeleted,
      storageDeleted,
    });

    // ---- 6. Delete the parent user doc itself ----
    await userRef.delete().catch(() => { /* idempotent */ });

    // ---- 7. Delete Firebase Auth user (irreversible) ----
    // This MUST be last — once gone, the client's request.auth is invalidated
    // for any retry. Failure here would leave an orphan Auth record but all
    // data is already gone, so the user can't access anything anyway.
    await admin.auth().deleteUser(uid);

    console.info("deleteAccount: completed", {
      uid,
      email: _redactEmail(email || ""),
      docsDeleted,
      stripeCleanup,
      storageDeleted,
    });

    return {
      success: true,
      docsDeleted,
      stripeCleanup,
      storageDeleted,
    };
  },
);

// ---------------------------------------------------------------------------
// exportUserData — GDPR right-to-data-portability (caller exports their own data).
//
// Returns a JSON object containing every Firestore document that belongs to
// this user (profile + all subcollections). Data is normalized: Timestamps
// → ISO 8601 strings, DocumentReferences → path strings, server-internal
// refs (_paths, byte fields) stripped. Client can save the result locally
// or share it as a file.
//
// Self-service only (caller can only export their OWN uid). Rate-limited at
// 5/day to discourage automated scraping but generous enough for a user
// who lost the file or wants periodic backups.
// ---------------------------------------------------------------------------
exports.exportUserData = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    await enforceRateLimit(uid, "exportUserData", 5, 86400);

    // Recursively serialize Firestore values into a JSON-safe shape.
    // - Timestamps → ISO 8601 strings (always UTC; client converts on display)
    // - DocumentReferences → reference path strings
    // - GeoPoints → { latitude, longitude }
    // - Bytes → base64 string (with size prefix so the consumer knows it was binary)
    // - Plain objects/arrays → recursive descent
    function _serialize(value) {
      if (value === null || value === undefined) return null;
      if (value instanceof admin.firestore.Timestamp) {
        return value.toDate().toISOString();
      }
      if (value instanceof admin.firestore.GeoPoint) {
        return { latitude: value.latitude, longitude: value.longitude };
      }
      if (value instanceof admin.firestore.DocumentReference) {
        return value.path;
      }
      if (Buffer.isBuffer(value)) {
        return { __binary: true, base64: value.toString("base64"), bytes: value.length };
      }
      if (Array.isArray(value)) return value.map(_serialize);
      if (typeof value === "object") {
        const out = {};
        for (const [k, v] of Object.entries(value)) out[k] = _serialize(v);
        return out;
      }
      return value;
    }

    const userRef = db.collection("users").doc(uid);
    const userSnap = await userRef.get();
    if (!userSnap.exists) {
      // No user doc yet — still return a valid envelope so the client can
      // distinguish this case from a network error.
      return {
        exportedAt: new Date().toISOString(),
        uid,
        profile: null,
        subcollections: {},
      };
    }

    const subCollectionNames = [
      "transactions", "reminders", "fcmTokens", "tenantState", "paymentEvents", "savedCards",
    ];
    const subcollections = {};
    for (const subName of subCollectionNames) {
      const snap = await userRef.collection(subName).get();
      subcollections[subName] = snap.docs.map((d) => ({
        id: d.id,
        ..._serialize(d.data() || {}),
      }));
    }

    return {
      exportedAt: new Date().toISOString(),
      uid,
      profile: _serialize(userSnap.data() || {}),
      subcollections,
      // Note for downstream consumer: saved cards live in Stripe (PaymentMethods
      // collection on the customer) — they are not duplicated to Firestore.
      // The user's stripeCustomerId is included in `profile` if they want to
      // request their data from Stripe directly.
      _meta: {
        format: "pushka-export-v1",
        notes: "Saved cards / payment methods live in Stripe; not included here. Request via Stripe support using stripeCustomerId from `profile`.",
      },
    };
  },
);

// ===========================================================================
// MULTI-MEMBERSHIP — join / switch / leave
// ===========================================================================

// ---------------------------------------------------------------------------
// joinTenant — adds the caller to a tenant's membership list.
// Idempotent: calling it twice with the same tenantId is a no-op.
// On first join: sets tenantId (active) and creates tenantState doc with
// defaults (migrating pushka state if this is the user's first tenant).
// ---------------------------------------------------------------------------
exports.joinTenant = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    await enforceRateLimit(request.auth.uid, "joinTenant", 10, 3600);

    const uid = request.auth.uid;
    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    // Validate tenant exists and is active
    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) throw new HttpsError("not-found", "Organización no encontrada.");
    const tenantData = tenantSnap.data();
    if (!["active", "trial", "grace_period"].includes(tenantData.status)) {
      throw new HttpsError("failed-precondition", "Esta organización no está disponible.");
    }

    const userRef = db.collection("users").doc(uid);
    const stateRef = userRef.collection("tenantState").doc(tenantId);

    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      const stateSnap = await tx.get(stateRef);
      if (!userSnap.exists) throw new HttpsError("not-found", "Usuario no encontrado.");

      const userData = userSnap.data();
      const existing = userData.tenantIds || (userData.tenantId ? [userData.tenantId] : []);
      const isFirst = !userData.tenantId;

      // Idempotent — already a member
      if (existing.includes(tenantId) && !isFirst) {
        // Ensure tenantId (active) is set if somehow missing
        if (!userData.tenantId) {
          tx.set(userRef, {
            tenantId,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        }
        return;
      }

      const newTenantIds = [...new Set([...existing, tenantId])];
      const patch = {
        tenantIds: newTenantIds,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      // First org ever: set as active tenant; apply tenant defaults if present
      if (isFirst) {
        patch.tenantId = tenantId;
        if (tenantData.defaultLanguage && !userData.language) {
          patch.language = tenantData.defaultLanguage;
        }
        if (tenantData.defaultCurrency && !userData.currencyCode) {
          patch.currencyCode = String(tenantData.defaultCurrency).toUpperCase();
        }
      }
      tx.set(userRef, patch, { merge: true });

      // Create tenantState doc if it doesn't exist yet
      if (!stateSnap.exists) {
        const currency = String(userData.currencyCode || tenantData.defaultCurrency || "USD").toUpperCase();
        tx.set(stateRef, {
          uid,
          tenantId,
          tenantName: tenantData.name || "",
          tenantAppName: tenantData.appName || tenantData.name || "Pushka",
          tenantLogoUrl: tenantData.logoUrl || null,
          tenantPrimaryColor: tenantData.primaryColor || null,
          // First org: migrate existing pushka state; subsequent orgs start fresh
          pushkaAmount: isFirst ? Number(userData.pushkaAmount || 0) : 0,
          pushkaGoal: isFirst
            ? Number(userData.pushkaGoal || defaultGoalForCurrency(currency))
            : defaultGoalForCurrency(currency),
          presetAmount: isFirst ? Number(userData.presetAmount || 1.0) : 1.0,
          presetAmounts: isFirst && Array.isArray(userData.presetAmounts)
            ? userData.presetAmounts : [],
          streakCount: isFirst ? Number(userData.streakCount || 0) : 0,
          lastStreakDate: isFirst ? (userData.lastStreakDate || null) : null,
          autoEmptyFrequency: "manual",
          autoEmptyWeekday: null,
          autoEmptyDayOfMonth: null,
          autoEmptyTopOffEnabled: false,
          autoEmptyTopOffAmount: null,
          autoEmptyNextRunAt: null,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // If this was the first tenant, clear autoEmptyNextRunAt on user doc
        // so the legacy scheduler no longer processes this user.
        if (isFirst) {
          tx.set(userRef, { autoEmptyNextRunAt: null }, { merge: true });
        }
      }
    });

    return { success: true, tenantId };
  }
);

// ---------------------------------------------------------------------------
// switchTenant — changes the caller's active tenant (tenantId field).
// The target tenantId must already be in the caller's tenantIds array.
// ---------------------------------------------------------------------------
exports.switchTenant = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    await enforceRateLimit(request.auth.uid, "switchTenant", 30, 3600);

    const uid = request.auth.uid;
    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    const userRef = db.collection("users").doc(uid);
    const userSnap = await userRef.get();
    if (!userSnap.exists) throw new HttpsError("not-found", "Usuario no encontrado.");

    const userData = userSnap.data();
    const tenantIds = userData.tenantIds || (userData.tenantId ? [userData.tenantId] : []);

    if (!tenantIds.includes(tenantId)) {
      throw new HttpsError("permission-denied", "No eres miembro de esa organización.");
    }

    await userRef.set({
      tenantId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    return { success: true, tenantId };
  }
);

// ---------------------------------------------------------------------------
// leaveTenant — removes the caller from a tenant's membership list.
// If the tenant being left is the active one, falls back to the first
// remaining tenant (or clears tenantId if none remain).
// ---------------------------------------------------------------------------
exports.leaveTenant = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    await enforceRateLimit(request.auth.uid, "leaveTenant", 10, 3600);

    const uid = request.auth.uid;
    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    const userRef = db.collection("users").doc(uid);

    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) throw new HttpsError("not-found", "Usuario no encontrado.");

      const userData = userSnap.data();
      const existing = userData.tenantIds || (userData.tenantId ? [userData.tenantId] : []);
      const newTenantIds = existing.filter((t) => t !== tenantId);
      const currentTenantId = userData.tenantId;

      const patch = {
        tenantIds: newTenantIds,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      // If leaving the active tenant, switch to the first remaining
      if (currentTenantId === tenantId) {
        if (newTenantIds.length > 0) {
          patch.tenantId = newTenantIds[0];
        } else {
          patch.tenantId = admin.firestore.FieldValue.delete();
        }
      }
      tx.set(userRef, patch, { merge: true });
    });

    return { success: true };
  }
);

// ===========================================================================
// MULTI-TENANT — Tenant management functions
// ===========================================================================

// Fields exposed publicly via getTenantBySlug / listDiscoverableTenants.
// `status` and `discoverable` are intentionally omitted — knowing a tenant
// is in `grace_period` or `trial` leaks billing state to the public internet.
const TENANT_PUBLIC_FIELDS = [
  "name", "slug", "appName", "welcomeText",
  "primaryColor", "secondaryColor", "logoUrl", "showPoweredBy",
  "defaultLanguage", "defaultCurrency", "defaultCountry",
  "contactEmail", "contactPhone", "privacyPolicyUrl", "termsUrl",
  "city", "neighborhood", "country",
];

// Fields exposed to authenticated users of the tenant (same as public + status
// so members can see if their own tenant is in grace_period / suspended).
const TENANT_MEMBER_FIELDS = [...TENANT_PUBLIC_FIELDS, "status"];

/**
 * Normalizes a slug to lowercase alphanumeric and validates length.
 * Does NOT check uniqueness — that must be done atomically inside a
 * transaction via the `_tenantSlugs/{slug}` lock collection (see
 * `createTenant`/`updateTenant`). Querying-then-writing without a lock
 * has a TOCTOU race that allows duplicate slugs under concurrent calls.
 */
function normalizeSlug(slug) {
  const normalized = String(slug || "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
  if (!normalized || normalized.length < 3 || normalized.length > 30) {
    throw new HttpsError("invalid-argument", "El slug debe tener entre 3 y 30 caracteres alfanuméricos.");
  }
  return normalized;
}

// ---------------------------------------------------------------------------
// createTenant — super_admin only
// ---------------------------------------------------------------------------
exports.createTenant = onCall(
  { enforceAppCheck: true },
  async (request) => {
    // Fresh-claims check (not the stale ID token) — a recently-demoted
    // super_admin must NOT be able to create tenants until they re-auth.
    if (!(await callerIsSuperAdminFresh(request))) {
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

    const normalizedSlug = normalizeSlug(slug);

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

    // Atomic create: claim the slug AND create the tenant doc in one transaction.
    // The `_tenantSlugs/{slug}` doc acts as a uniqueness lock — `tx.create()`
    // throws ALREADY_EXISTS if a concurrent call already grabbed it. Without
    // this, a query-then-write check has a TOCTOU race window.
    const tenantRef = db.collection("tenants").doc();
    const slugRef = db.collection("_tenantSlugs").doc(normalizedSlug);
    try {
      await db.runTransaction(async (tx) => {
        const slugSnap = await tx.get(slugRef);
        if (slugSnap.exists) {
          throw new HttpsError("already-exists", `El código "${normalizedSlug}" ya está en uso.`);
        }
        tx.create(slugRef, { tenantId: tenantRef.id, createdAt: now });
        tx.create(tenantRef, tenantData);
      });
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      // Firestore throws "ALREADY_EXISTS" if tx.create races on the slug doc.
      if (String(e?.code) === "6" || /ALREADY_EXISTS/i.test(String(e?.message))) {
        throw new HttpsError("already-exists", `El código "${normalizedSlug}" ya está en uso.`);
      }
      throw e;
    }

    // Assign tenant_admin claim to the admin email if they already have a Firebase account.
    // CRITICAL: setCustomUserClaims REPLACES the entire claims object — naively
    // setting `{ role, tenantId }` would silently strip a super_admin's `admin: true`
    // claim, OR move a tenant_admin from another tenant without warning. We must
    // (a) preserve unrelated claims via spread, and (b) refuse to overwrite an
    // existing tenant_admin assignment to a different tenant — the operator
    // probably typed the wrong email.
    try {
      const adminRecord = await admin.auth().getUserByEmail(adminEmail.trim());
      const existingClaims = adminRecord.customClaims ?? {};

      if (
        existingClaims.role === "tenant_admin" &&
        existingClaims.tenantId &&
        existingClaims.tenantId !== tenantRef.id
      ) {
        // Roll back the tenant we just created — this is operator error.
        await db.runTransaction(async (tx) => {
          tx.delete(tenantRef);
          tx.delete(slugRef);
        });
        throw new HttpsError(
          "failed-precondition",
          `${adminEmail} ya es admin de otro tenant. Asigna otro email o quítalo del tenant actual primero.`,
        );
      }

      await admin.auth().setCustomUserClaims(adminRecord.uid, {
        ...existingClaims,
        role: "tenant_admin",
        tenantId: tenantRef.id,
        // Preserve admin: true if they're a super_admin — they keep super_admin
        // privileges plus get tenant_admin scope for their own tenant.
      });
      await tenantRef.update({ adminUid: adminRecord.uid });
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      // User doesn't have an account yet — claims will be set when they register
      console.info(`createTenant: admin ${_redactEmail(adminEmail)} has no Firebase account yet; claims pending`);
    }

    console.info("createTenant", { id: tenantRef.id, slug: normalizedSlug, adminEmail: _redactEmail(adminEmail) });
    return { success: true, tenantId: tenantRef.id, slug: normalizedSlug };
  }
);

// ---------------------------------------------------------------------------
// backfillTenantSlugs — one-shot super_admin operation: ensure every
// existing tenant has a corresponding `_tenantSlugs/{slug}` lock doc.
//
// Tenants created before the slug-lock collection was introduced don't
// have entries in `_tenantSlugs/`. Without this backfill, a malicious
// `createTenant` call with the same slug would succeed (the lock check
// passes because the slug doc doesn't exist for the old tenant). Run
// this once per environment before allowing new createTenant traffic.
//
// Idempotent: skips slugs whose lock doc already exists for the same
// tenantId. Logs and returns a summary {scanned, created, skipped,
// conflicts} so the operator can verify.
// ---------------------------------------------------------------------------
exports.backfillTenantSlugs = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo super_admin.");
    }

    const tenantsSnap = await db.collection("tenants").get();
    let scanned = 0;
    let created = 0;
    let skipped = 0;
    const conflicts = [];
    const skippedNoSlug = [];

    for (const tenantDoc of tenantsSnap.docs) {
      scanned += 1;
      const tenantId = tenantDoc.id;
      const slugRaw = String(tenantDoc.data()?.slug || "").trim();
      if (!slugRaw) {
        skippedNoSlug.push(tenantId);
        continue;
      }
      const slug = normalizeSlug(slugRaw);
      const slugRef = db.collection("_tenantSlugs").doc(slug);
      const existing = await slugRef.get();
      if (existing.exists) {
        const ownerTenantId = existing.data()?.tenantId;
        if (ownerTenantId === tenantId) {
          skipped += 1;
        } else {
          // Slug doc exists but points at a DIFFERENT tenant — surface
          // for manual review; do not overwrite.
          conflicts.push({ slug, tenantId, ownerTenantId });
        }
        continue;
      }
      await slugRef.create({
        tenantId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        backfilled: true,
      });
      created += 1;
    }

    const summary = {
      scanned,
      created,
      skippedAlreadyExists: skipped,
      skippedNoSlug,
      conflicts,
    };
    console.info("backfillTenantSlugs: completed", summary);
    return summary;
  },
);

// ---------------------------------------------------------------------------
// getTenantBranding — super_admin (any tenant) or tenant_admin (own tenant)
// ---------------------------------------------------------------------------
exports.getTenantBranding = onCall(
  { enforceAppCheck: true },
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
  { enforceAppCheck: true },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    // Use FRESH custom claims, not the 1h-stale ID token. This endpoint writes
    // branding fields that the new onTenantBrandingUpdated trigger fans out to
    // every member's tenantState — a demoted admin must not be able to mass
    // rewrite tenant branding for the remainder of their old token TTL.
    // Anchor super_admin to the canonical email (matches callerIsSuperAdmin).
    const callerRecord = await admin.auth().getUser(callerUid);
    const callerClaims = callerRecord.customClaims || {};
    const isSuper = callerClaims.role === "super_admin" ||
      (callerClaims.admin === true && callerRecord.email === SUPER_ADMIN_EMAIL);
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

    if (updates.slug) {
      // Slug change: atomically free the old slug lock and grab the new one
      // alongside the tenant patch. Same TOCTOU protection as createTenant.
      const normalizedSlug = normalizeSlug(updates.slug);
      const oldSlug = String(snap.data()?.slug || "");
      patch.slug = normalizedSlug;

      if (normalizedSlug !== oldSlug) {
        const newSlugRef = db.collection("_tenantSlugs").doc(normalizedSlug);
        const oldSlugRef = oldSlug ? db.collection("_tenantSlugs").doc(oldSlug) : null;
        try {
          await db.runTransaction(async (tx) => {
            const newSlugSnap = await tx.get(newSlugRef);
            if (newSlugSnap.exists && newSlugSnap.data()?.tenantId !== tenantId) {
              throw new HttpsError("already-exists", `El código "${normalizedSlug}" ya está en uso.`);
            }
            if (oldSlugRef) tx.delete(oldSlugRef);
            tx.set(newSlugRef, {
              tenantId,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            tx.update(tenantRef, patch);
          });
        } catch (e) {
          if (e instanceof HttpsError) throw e;
          if (String(e?.code) === "6" || /ALREADY_EXISTS/i.test(String(e?.message))) {
            throw new HttpsError("already-exists", `El código "${normalizedSlug}" ya está en uso.`);
          }
          throw e;
        }
      } else {
        await tenantRef.update(patch);
      }
    } else {
      await tenantRef.update(patch);
    }

    console.info("updateTenant", { tenantId, fields: Object.keys(patch) });
    return { success: true, tenantId };
  }
);

// ---------------------------------------------------------------------------
// getTenantBySlug — public (no auth required), for code validation in app
// ---------------------------------------------------------------------------
exports.getTenantBySlug = onCall(
  { enforceAppCheck: true },
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
// listDiscoverableTenants — public (no auth required)
// Returns active+discoverable tenants for the search-first onboarding UI.
// Tenants with `discoverable: false` are hidden (only joinable via slug code).
// ---------------------------------------------------------------------------
// Fields exposed in the discoverable picker — strict subset of public fields.
const TENANT_DISCOVERABLE_FIELDS = [
  "name", "appName", "slug", "city", "neighborhood", "country",
  "logoUrl", "primaryColor",
];

exports.listDiscoverableTenants = onCall(
  { enforceAppCheck: true },
  async (request) => {
    // 30 calls per IP per 5 min — generous for legit picker use, blocks scrapers.
    await enforceRateLimitByIp(request, "listDiscoverableTenants", 30, 300);

    const snap = await db.collection("tenants")
      .where("status", "in", ["active", "trial", "grace_period"])
      .limit(500)
      .get();

    const tenants = [];
    for (const doc of snap.docs) {
      const data = doc.data();
      // Treat missing `discoverable` field as true for backward compat with
      // tenants created before the field existed.
      if (data.discoverable === false) continue;

      const summary = { tenantId: doc.id };
      for (const field of TENANT_DISCOVERABLE_FIELDS) {
        if (data[field] !== undefined) summary[field] = data[field];
      }
      // Country fallback: legacy `defaultCountry` if no explicit `country`.
      if (summary.country === undefined && data.defaultCountry !== undefined) {
        summary.country = data.defaultCountry;
      }
      tenants.push(summary);
    }

    // Sort by country, city, then name for stable display.
    tenants.sort((a, b) => {
      const ca = (a.country || "").localeCompare(b.country || "");
      if (ca !== 0) return ca;
      const ci = (a.city || "").localeCompare(b.city || "");
      if (ci !== 0) return ci;
      return (a.name || "").localeCompare(b.name || "");
    });

    return { tenants };
  }
);

// ---------------------------------------------------------------------------
// getTenantConfig — authenticated, returns branding for the user's own tenant.
// Also performs a lazy migration: users with a legacy single `tenantId` field
// get `tenantIds: [tenantId]` written and a `tenantState/{tenantId}` doc created
// the first time they open the app after the multi-membership rollout.
// ---------------------------------------------------------------------------
exports.getTenantConfig = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }

    const uid = request.auth.uid;
    const userRef = db.collection("users").doc(uid);
    const userSnap = await userRef.get();
    if (!userSnap.exists) throw new HttpsError("not-found", "Usuario no encontrado.");

    const userData = userSnap.data();
    const tenantId = userData?.tenantId;

    // ── Lazy migration ──────────────────────────────────────────────────────
    // User has a legacy `tenantId` but the new `tenantIds` array hasn't been
    // written yet (first launch after multi-membership rollout).
    if (tenantId && !userData.tenantIds) {
      try {
        const tenantDocSnap = await db.collection("tenants").doc(tenantId).get();
        const tenantData = tenantDocSnap.exists ? tenantDocSnap.data() : {};
        const stateRef = db.collection("users").doc(uid)
          .collection("tenantState").doc(tenantId);
        const stateSnap = await stateRef.get();
        const currency = String(userData.currencyCode || "USD").toUpperCase();

        const batch = db.batch();
        // Set tenantIds on the user doc
        batch.set(
          db.collection("users").doc(uid),
          { tenantIds: [tenantId], updatedAt: admin.firestore.FieldValue.serverTimestamp() },
          { merge: true },
        );
        // Create tenantState doc if it doesn't exist yet
        if (!stateSnap.exists) {
          batch.set(stateRef, {
            uid,
            tenantId,
            tenantName: tenantData.name || "",
            tenantAppName: tenantData.appName || tenantData.name || "Pushka",
            tenantLogoUrl: tenantData.logoUrl || null,
            tenantPrimaryColor: tenantData.primaryColor || null,
            pushkaAmount: Number(userData.pushkaAmount || 0),
            pushkaGoal: Number(userData.pushkaGoal || defaultGoalForCurrency(currency)),
            presetAmount: Number(userData.presetAmount || 1.0),
            presetAmounts: Array.isArray(userData.presetAmounts) ? userData.presetAmounts : [],
            streakCount: Number(userData.streakCount || 0),
            lastStreakDate: userData.lastStreakDate || null,
            autoEmptyFrequency: userData.autoEmptyFrequency || "manual",
            autoEmptyWeekday: userData.autoEmptyWeekday ?? null,
            autoEmptyDayOfMonth: userData.autoEmptyDayOfMonth ?? null,
            autoEmptyTopOffEnabled: userData.autoEmptyTopOffEnabled || false,
            autoEmptyTopOffAmount: userData.autoEmptyTopOffAmount ?? null,
            // Clear autoEmptyNextRunAt on user doc below — tenantState is now authoritative.
            // Copy the schedule so the tenantState-based scheduler picks it up.
            autoEmptyNextRunAt: userData.autoEmptyNextRunAt || null,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          // Nullify autoEmptyNextRunAt on user doc so the legacy scheduler skips it.
          batch.set(
            db.collection("users").doc(uid),
            { autoEmptyNextRunAt: null, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
            { merge: true },
          );
        }
        await batch.commit();
      } catch (migErr) {
        console.warn("getTenantConfig: lazy migration failed", {
          uid, error: String(migErr?.message || migErr),
        });
      }
    }

    if (!tenantId) {
      return { tenantId: null, config: null, tenantIds: [] };
    }

    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) {
      // Tenant was deleted out from under this user. Without intervention the
      // router stays on `/` because `users/{uid}.tenantId` is still set, but
      // every screen that reads tenant data shows a permanent error. Heal the
      // orphan by clearing the stale tenantId (server-side, so we bypass the
      // user-update validation that would normally block this) and return
      // null config — the client will redirect to /tenant-setup so the user
      // can pick a new org.
      try {
        await userRef.update({
          tenantId: admin.firestore.FieldValue.delete(),
          tenantIds: admin.firestore.FieldValue.arrayRemove(tenantId),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Strip tenant-scoped role claims so they don't survive re-onboarding
        // (a deleted-tenant tenant_admin shouldn't keep claims pointing at the
        // dead tenantId). Read the actual customClaims from Auth — request.auth
        // .token also includes standard JWT fields that we must not echo back.
        const authUser = await admin.auth().getUser(uid);
        const existing = authUser.customClaims ?? {};
        if (existing.tenantId === tenantId || existing.role === "tenant_admin" || existing.role === "tenant_collaborator") {
          const { tenantId: _stripTenant, role: _stripRole, ...keep } = existing;
          await admin.auth().setCustomUserClaims(uid, keep);
        }
      } catch (e) {
        console.error("getTenantConfig: failed to heal orphaned tenantId", { uid, tenantId, err: e?.message });
      }
      console.warn("getTenantConfig: orphaned tenantId cleared", { uid, tenantId });
      // Return the post-heal state (tenantIds without the dead one) so the
      // client picker doesn't try to switch to an org that no longer exists.
      const remaining = (userData.tenantIds || []).filter((id) => id !== tenantId);
      return { tenantId: null, config: null, tenantIds: remaining };
    }

    const data = tenantSnap.data();
    const tenantIds = userData.tenantIds || [tenantId];

    // If tenant is suspended, the app should show a "service unavailable" screen
    if (data.status === "suspended") {
      return { tenantId, config: null, suspended: true, tenantIds };
    }

    const config = {};
    for (const field of TENANT_MEMBER_FIELDS) {
      if (data[field] !== undefined) config[field] = data[field];
    }

    return { tenantId, config, tenantIds };
  }
);

// ---------------------------------------------------------------------------
// listTenants — super_admin only, returns all tenants with summary stats
// ---------------------------------------------------------------------------
exports.listTenants = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "listTenants", 30, 3600);

    if (!callerIsSuperAdmin(request)) {
      throw new HttpsError("permission-denied", "Solo el super administrador.");
    }

    const snap = await db.collection("tenants").orderBy("createdAt", "desc").limit(1000).get();

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
  { secrets: [stripeConnectClientId], enforceAppCheck: true },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "createStripeConnectLink", 10, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuperAdminCaller = callerIsSuperAdmin(request);
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
// Redact email for logging — keep first char + domain so we can correlate
// without spilling full PII into Cloud Logging.
function _redactEmail(email) {
  if (!email || typeof email !== "string") return "<missing>";
  const at = email.indexOf("@");
  if (at < 1) return "<invalid>";
  const local = email.slice(0, at);
  const domain = email.slice(at + 1);
  const head = local.charAt(0);
  return `${head}***@${domain}`;
}

async function sendEmail({ to, subject, html }) {
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!to || !emailRegex.test(to)) {
    console.warn("sendEmail: invalid or missing recipient address, skipping:", _redactEmail(to));
    return;
  }
  const apiKey = sendgridApiKey.value();
  if (!apiKey || apiKey.startsWith("PLACEHOLDER")) {
    console.warn("sendEmail: SENDGRID_API_KEY not set, skipping email to", _redactEmail(to));
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
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
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
// cancelTenantSubscription — super_admin cancels Stripe Billing subscription
// ---------------------------------------------------------------------------
exports.cancelTenantSubscription = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo el super administrador.");
    }

    const { tenantId } = request.data ?? {};
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) throw new HttpsError("not-found", "Tenant no encontrado.");

    const tenantData = tenantSnap.data();
    const subscriptionId = tenantData.stripeSubscriptionId;

    if (!subscriptionId) {
      throw new HttpsError("failed-precondition", "El tenant no tiene suscripción activa.");
    }

    const stripe = require("stripe")(stripeSecret.value());

    // Cancel at period end so the tenant keeps access until the billing cycle ends
    await stripe.subscriptions.update(subscriptionId, { cancel_at_period_end: true });

    await db.collection("tenants").doc(tenantId).update({
      paymentStatus: "canceling",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true };
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

    // Idempotency — Stripe retries failed webhooks for up to 3 days. Without
    // this, retried `invoice.payment_failed` events would re-send dunning
    // emails (to admin AND super_admin) on every retry.
    const { eventRef, alreadyProcessed } = await reserveWebhookEvent(event);
    if (alreadyProcessed) {
      console.info("stripeBillingWebhook: duplicate event skipped", { id: event.id, type: event.type });
      return res.json({ received: true, duplicate: true });
    }

    if (event.type === "invoice.payment_succeeded") {
      const invoice = event.data.object;
      const tenantId = invoice.subscription_details?.metadata?.tenantId
        ?? invoice.metadata?.tenantId
        ?? null;

      if (!tenantId) {
        console.warn("stripeBillingWebhook: no tenantId on invoice", invoice.id);
        await finalizeWebhookEvent(eventRef, { status: "skipped", reason: "missing_tenantId", invoiceId: invoice.id });
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

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        tenantId,
        outcome: "billing_payment_succeeded",
      });
      console.log(`Billing payment succeeded for tenant ${tenantId}`);
    } else if (event.type === "invoice.payment_failed") {
      const invoice = event.data.object;
      const tenantId = invoice.subscription_details?.metadata?.tenantId
        ?? invoice.metadata?.tenantId
        ?? null;

      if (!tenantId) {
        await finalizeWebhookEvent(eventRef, { status: "skipped", reason: "missing_tenantId", invoiceId: invoice.id });
        return res.json({ received: true });
      }

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

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        tenantId,
        outcome: "billing_payment_failed_grace_started",
      });
      console.log(`Grace period started for tenant ${tenantId}, ends ${gracePeriodEndsAt.toISOString()}`);
    } else {
      // Unhandled event type — mark as processed so we don't keep checking.
      await finalizeWebhookEvent(eventRef, { status: "skipped", reason: "unhandled_event_type" });
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

      console.log(`Sending ${daysLeft}-day grace reminder to ${_redactEmail(adminEmail)} for tenant ${doc.id}`);

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

// ---------------------------------------------------------------------------
// Android App Links verification — serves /.well-known/assetlinks.json
// Reachable at https://pushka-app-ioel.web.app/.well-known/assetlinks.json
// ---------------------------------------------------------------------------
exports.assetlinks = onRequest({ cors: true }, (req, res) => {
  // SHA-256 certificate fingerprints for both prod and dev release keystores.
  // Add debug keystores here during development if needed.
  const assetLinks = [
    {
      relation: ["delegate_permission/common.handle_all_urls"],
      target: {
        namespace: "android_app",
        package_name: "com.pushka.app",
        sha256_cert_fingerprints: [
          "12:71:ED:79:A4:BF:E9:6C:84:C3:F7:7A:29:7C:EE:17:76:89:83:7C:1E:E1:B8:F3:1A:3D:EB:16:A4:26:D1:45",
        ],
      },
    },
  ];
  res.set("Cache-Control", "no-store");
  res.json(assetLinks);
});
