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
      // Structured warn so a Cloud Logging metric ("rate_limit_hit") +
      // alert policy can fire when N callers hit limits in a short window —
      // a spike usually means an upstream incident (Stripe outage, panic
      // tap-spam, scraper) rather than ordinary user behavior. Without
      // this log the only signal was a silent 429 to the client.
      console.warn("rate_limit_hit", {
        uid, action, maxCalls, windowSeconds, callsInWindow: recentCalls.length, retryAfter,
      });
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

/**
 * Defensive read for tenant commission rate. Tenants are written with a
 * validated commissionRate (0-10%), but historical rows or manual console
 * edits can corrupt the field. We treat any value outside the safe range
 * as 0.03 (the documented default) and log loudly so ops sees the bad row.
 *
 * Critical: if this returns >= 1.0 the Stripe call would route ALL the
 * donor's money to the platform — clamping at the read site is a
 * second line of defense behind the write-time validation in createTenant.
 */
function safeTenantCommissionRate(rawRate, tenantIdForLog) {
  const r = typeof rawRate === "number" ? rawRate : NaN;
  if (Number.isFinite(r) && r >= 0 && r <= 0.10) return r;
  console.warn("safeTenantCommissionRate: invalid rate, falling back to 0.03", {
    tenantId: tenantIdForLog,
    rawRate,
    typeofRawRate: typeof rawRate,
  });
  return 0.03;
}

function minAmountForCurrency(currency) {
  const code = String(currency || "usd").toLowerCase();
  return CURRENCY_MINIMUMS[code] ?? 100;
}

// Sanitize donor messages before they enter Stripe metadata or our Firestore
// records. Strips C0/C1 control chars (which can break log parsers, render
// HTML-injection vectors in any future web admin view, or trigger Stripe's
// metadata-value rejection of certain bytes). Caps at 240 chars (Stripe's
// metadata-value limit is 500; 240 leaves headroom for any prefix we add
// later). Returns "" — never null/undefined — so callers can store it
// without separate null guards.
function sanitizeDonorMessage(raw) {
  if (raw === undefined || raw === null) return "";
  // Strip all C0 + C1 control chars except plain space (0x20). Newlines,
  // tabs, BEL etc. all go — donor messages are short single-line strings.
  // eslint-disable-next-line no-control-regex
  const stripped = String(raw).replace(/[\x00-\x1F\x7F-\x9F]/g, " ");
  return stripped.trim().slice(0, 240);
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
  // Validate event id shape before using it as a Firestore doc ID. Stripe
  // event IDs are always `evt_` + 24+ alphanumeric chars. Anything else is
  // forged (signature check should have caught it; belt + suspenders) or a
  // future Stripe API change we want to notice loudly. An empty/whitespace
  // id would also collapse the dedup key (every malformed event would map
  // to the same doc and silently be skipped as duplicate).
  const id = typeof event?.id === "string" ? event.id : "";
  if (!/^evt_[A-Za-z0-9]{16,}$/.test(id)) {
    throw new Error(`reserveWebhookEvent: invalid event id "${id}"`);
  }
  const eventRef = db.collection("_stripeWebhookEvents").doc(id);
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
      // Stamp a TTL so the _stripeWebhookEvents collection doesn't grow
      // unbounded (Stripe sends thousands of events monthly). Firestore
      // auto-deletes docs whose `expiresAt` is in the past IF a TTL policy
      // is configured on this collection — must be enabled once via the
      // Firebase Console (Firestore → TTL) on `_stripeWebhookEvents.expiresAt`.
      // 90 days is enough for ops to investigate any failed event before
      // it's purged; idempotency dedup only needs the recent (< 3-day) past
      // since Stripe stops retrying after 3 days.
      expiresAt: admin.firestore.Timestamp.fromMillis(
        Date.now() + 90 * 24 * 60 * 60 * 1000,
      ),
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

async function writeActivityLog({ type, tenantId, tenantName, severity, requiresAction, data }) {
  await db.collection("_activityLog").add({
    type,
    tenantId: tenantId ?? null,
    tenantName: tenantName ?? null,
    severity,          // 'critical' | 'warning' | 'info'
    requiresAction: requiresAction ?? false,
    resolved: false,
    resolvedAt: null,
    data: data ?? {},
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

// Atomic counter increment on tenant doc — called after every confirmed donation.
// Non-blocking: failures are logged but never propagate to the caller.
async function incrementTenantRevenue(tenantId, amountUSD) {
  if (!tenantId || !Number.isFinite(amountUSD) || amountUSD <= 0) return;
  const now = new Date();
  const monthKey = `${now.getUTCFullYear()}_${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
  try {
    await db.collection("tenants").doc(tenantId).update({
      [`revenueStats.${monthKey}.revenue`]: admin.firestore.FieldValue.increment(amountUSD),
      [`revenueStats.${monthKey}.count`]:   admin.firestore.FieldValue.increment(1),
      "revenueStats.allTime.revenue":       admin.firestore.FieldValue.increment(amountUSD),
      "revenueStats.allTime.count":         admin.firestore.FieldValue.increment(1),
    });
  } catch (err) {
    console.warn("incrementTenantRevenue: failed (non-fatal)", { tenantId, amountUSD, error: String(err?.message || err) });
  }
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

  // Validate purpose up-front — needed below before tenantState lock
  // acquisition for purpose === "pushka_empty".
  const purpose = String(request.data?.purpose || "donation").toLowerCase();
  if (purpose !== "donation" && purpose !== "pushka_empty") {
    throw new HttpsError("invalid-argument", "Propósito de pago inválido.");
  }

  // Parallelize the two independent Firestore reads (block check + user
  // doc) — they were sequential and added ~150-300ms of avoidable latency.
  const [adminDataSnap, userSnap] = await Promise.all([
    db.collection("adminData").doc(request.auth.uid).get(),
    db.collection("users").doc(request.auth.uid).get(),
  ]);
  if (adminDataSnap.exists && adminDataSnap.data()?.isBlocked === true) {
    throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida. Contactá a soporte.");
  }

  const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
  const tenantId = userData.tenantId ?? null;

  // Same parallelization for tenantState lock check + tenant doc lookup —
  // both are gated on tenantId existing and otherwise independent.
  let tenantConnectAccountId = null;
  let tenantCommissionRate = 0;

  if (tenantId) {
    const [stateSnap, tenantSnap] = await Promise.all([
      db.collection("users").doc(request.auth.uid)
        .collection("tenantState").doc(tenantId).get(),
      db.collection("tenants").doc(tenantId).get(),
    ]);

    // Auto-empty cron lock: refuse if a scheduled charge is mid-flight for
    // this (uid, tenantId). Lock TTL is 10 minutes (cron releases on
    // success/failure within ~30s; the longer window catches crashes).
    //
    // For purpose === "pushka_empty" we ALSO acquire the same lock
    // transactionally, so a cron tick that lands a few hundred ms later
    // sees our lock and skips. Without this, the cron would set its lock
    // INSIDE its own transaction *after* we'd already passed our parallel
    // read, and both paths would call Stripe with different idempotency
    // keys → double-charge.
    if (stateSnap.exists) {
      const _autoLockAt = stateSnap.data()?._autoEmptyChargeLockAt?.toMillis?.() ?? null;
      if (_autoLockAt && (Date.now() - _autoLockAt) < (10 * 60 * 1000)) {
        throw new HttpsError(
          "aborted",
          "Tu Pushka se está vaciando automáticamente en este momento. Esperá unos segundos y volvé a intentar.",
        );
      }
    }
    if (purpose === "pushka_empty") {
      const stateRef = db.collection("users").doc(request.auth.uid)
        .collection("tenantState").doc(tenantId);
      try {
        await db.runTransaction(async (tx) => {
          const fresh = await tx.get(stateRef);
          const lockAt = fresh.data()?._autoEmptyChargeLockAt?.toMillis?.() ?? null;
          if (lockAt && (Date.now() - lockAt) < (10 * 60 * 1000)) {
            throw new HttpsError(
              "aborted",
              "Tu Pushka se está vaciando automáticamente en este momento. Esperá unos segundos y volvé a intentar.",
            );
          }
          tx.set(stateRef, {
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.serverTimestamp(),
            _autoEmptyChargeLockSource: "manual",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        });
      } catch (e) {
        if (e instanceof HttpsError) throw e;
        // Anything else from the transaction — refuse the payment rather
        // than risk a double-charge.
        console.error("createPaymentIntent: lock_tx_failed", {
          uid: request.auth.uid, tenantId, err: e?.message,
        });
        throw new HttpsError(
          "aborted",
          "No pudimos asegurar tu Pushka. Intentá de nuevo en unos segundos.",
        );
      }
    }

    if (tenantSnap.exists) {
      const tenantData = tenantSnap.data();
      const tenantStatus = tenantData.status;
      if (tenantStatus === "suspended") {
        throw new HttpsError("permission-denied", "El servicio de tu organización está suspendido. Contactá al administrador.");
      }
      const connectStatus = tenantData.stripeConnectStatus;
      const connectAccountId = tenantData.stripeConnectAccountId;
      if (connectStatus === "active" && connectAccountId) {
        tenantConnectAccountId = connectAccountId;
        tenantCommissionRate = safeTenantCommissionRate(
          tenantData.commissionRate,
          tenantId,
        );
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

  if (!Number.isFinite(amount) || amount <= 0) {
    throw new HttpsError("invalid-argument", "Monto inválido.");
  }
  if (amount > 99999999) {
    throw new HttpsError("invalid-argument", "El monto excede el límite permitido.");
  }

  // Donor message — sanitized (control chars stripped, 240-char cap) so it's
  // safe to round-trip through Stripe metadata + render in the admin web
  // dashboard. Optional; "" when omitted.
  const donorMessage = sanitizeDonorMessage(request.data?.donorMessage);

  // Client-supplied correlation ID — 16-char hex (8 random bytes). Threaded
  // onto Stripe metadata + every log line emitted from this function so a
  // single donation can be traced end-to-end (client → CF → Stripe → webhook
  // → Firestore tx). Validated to a strict shape so it can't smuggle
  // injection patterns through to log parsers. Generated server-side if
  // missing — older clients won't break.
  const rawCid = request.data?.correlationId;
  const correlationId = (typeof rawCid === "string" && /^[a-f0-9]{16}$/.test(rawCid))
    ? rawCid
    : require("crypto").randomBytes(8).toString("hex");

  // For pushka_empty the client passes the value to set pushkaAmount to
  // AFTER the charge confirms (webhook owns this write — see C1 audit
  // fix). Validated as a non-negative number; default 0 (full empty).
  let pushkaAmountAfter = 0;
  if (purpose === "pushka_empty") {
    const raw = request.data?.pushkaAmountAfter;
    if (raw !== undefined && raw !== null) {
      const v = Number(raw);
      if (!Number.isFinite(v) || v < 0 || v > 99999999) {
        throw new HttpsError("invalid-argument", "pushkaAmountAfter inválido.");
      }
      pushkaAmountAfter = v;
    }
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
  // Idempotency key: uid + purpose + amount + currency + 60-minute bucket.
  // The bucket size used to be 5 minutes, but the boundary race
  // (12:04:59.500 vs 12:05:00.500 land in different buckets and produce
  // two distinct PaymentIntents → potential double-charge under retry
  // spam) was easier to trigger than expected. 60 minutes makes the
  // probability of a legitimate retry crossing a bucket negligible
  // while still letting a donor make two distinct same-amount donations
  // within a single hour (Stripe will dedupe via idempotency only the
  // first; the second errors with "already used", which the client
  // surfaces as "intentá de nuevo en unos segundos").
  const idempotencyKey = `pi_${request.auth.uid}_${purpose}_${currency}_${amount}_${Math.floor(Date.now() / 3600000)}`;

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

  // Skip the dedupe pass if it ran recently. The pass touches Stripe twice
  // (customers.retrieve + paymentMethods.list) plus N more updates/detaches —
  // ~400-800ms on the critical path. State only changes when a card is
  // added or removed, so we cache `_lastPmDedupePassAt` on the user doc and
  // skip if < 2h old (was 6h — too long for power users adding multiple
  // cards in a session). Card add/remove flows clear the cache so the
  // next payment re-runs the pass.
  const lastDedupeAt = userData._lastPmDedupePassAt?.toMillis?.() ?? 0;
  const dedupeStale = (Date.now() - lastDedupeAt) > (2 * 60 * 60 * 1000);
  if (dedupeStale) try {
    const [customer, pmList] = await Promise.all([
      stripe.customers.retrieve(customerId),
      stripe.paymentMethods.list({
        customer: customerId,
        type: "card",
        limit: 100,
      }),
    ]);
    const defaultPmId = customer && !customer.deleted
      ? customer.invoice_settings?.default_payment_method || null
      : null;
    // Always-on inventory log so we can see what PaymentSheet WILL receive.
    console.info("createPaymentIntent: customer PM inventory", {
      uid: request.auth.uid,
      customerId,
      defaultPmId,
      pmCount: pmList.data.length,
      pms: pmList.data.map((pm) => ({
        id: pm.id,
        brand: pm.card?.brand,
        last4: pm.card?.last4,
        fp: pm.card?.fingerprint,
        created: pm.created,
        allowRedisplay: pm.allow_redisplay,
      })),
    });

    // Normalize `allow_redisplay` to 'always' on every saved PM. PaymentSheet
    // (Stripe Mobile SDK) HIDES PaymentMethods whose allow_redisplay is
    // 'limited' or 'unspecified' from the Saved section — even when listed
    // via Customer Sessions / ephemeralKeys. Cards saved via legacy flows or
    // attached before the field existed default to 'unspecified', producing
    // the bug "el customer tiene 2 tarjetas pero PaymentSheet muestra 1".
    // Best-effort batch update; failures don't block the PI.
    const needsRedisplayFix = pmList.data.filter(
      (pm) => pm.allow_redisplay !== "always",
    );
    if (needsRedisplayFix.length > 0) {
      console.info("createPaymentIntent: normalizing allow_redisplay", {
        uid: request.auth.uid,
        customerId,
        count: needsRedisplayFix.length,
      });
      await Promise.all(needsRedisplayFix.map((pm) =>
        stripe.paymentMethods.update(pm.id, { allow_redisplay: "always" })
          .catch((updateErr) => {
            console.warn("createPaymentIntent: allow_redisplay update failed", {
              uid: request.auth.uid,
              paymentMethodId: pm.id,
              errorMessage: updateErr?.message,
            });
          }),
      ));
    }
    const groups = new Map();
    for (const pm of pmList.data) {
      const fp = pm.card?.fingerprint;
      if (!fp) continue;
      const existing = groups.get(fp) || [];
      existing.push(pm);
      groups.set(fp, existing);
    }
    const detachIds = [];
    for (const group of groups.values()) {
      if (group.length <= 1) continue;
      const winner = group.find((pm) => pm.id === defaultPmId) ||
        group.slice().sort((a, b) => (b.created || 0) - (a.created || 0))[0];
      for (const pm of group) {
        if (pm.id !== winner.id) detachIds.push(pm.id);
      }
    }
    if (detachIds.length > 0) {
      console.info("createPaymentIntent: dedupe before sheet", {
        uid: request.auth.uid,
        customerId,
        detachCount: detachIds.length,
      });
      await Promise.all(detachIds.map((pmId) =>
        stripe.paymentMethods.detach(pmId).catch((err) => {
          console.warn("createPaymentIntent: detach failed", {
            uid: request.auth.uid, customerId, paymentMethodId: pmId, errorMessage: err?.message,
          });
        }),
      ));
    }
    // Stamp the success — fire-and-forget so it doesn't block the
    // critical path. Next call within 6h skips the whole dedupe pass.
    db.collection("users").doc(request.auth.uid).set({
      _lastPmDedupePassAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true }).catch((stampErr) => {
      console.warn("createPaymentIntent: dedupe stamp failed", {
        uid: request.auth.uid, errorMessage: stampErr?.message,
      });
    });
  } catch (dedupeErr) {
    console.warn("createPaymentIntent: dedupe pass failed (non-fatal)", {
      uid: request.auth.uid, customerId,
      errorMessage: dedupeErr?.message,
    });
  }

  // Build the PaymentIntent + CustomerSession in parallel — neither depends
  // on the other after customerId is resolved, but they were sequential and
  // each costs ~300-600ms. Promise.allSettled so a CustomerSession failure
  // doesn't kill the PaymentIntent (we fall back to ephemeralKey below).
  const piParams = {
      amount,
      currency,
      customer: customerId,
      receipt_email: customerEmail || undefined,
      // NOTE: `setup_future_usage: 'off_session'` was previously set here so
      // donation cards would auto-save for the auto-empty cron. But Stripe's
      // PaymentSheet FILTERS the customer's saved PaymentMethods to only
      // those compatible with off-session reuse when this flag is set,
      // hiding any card that hasn't been confirmed for off-session usage —
      // some test cards (and any real card that hasn't passed 3DS for
      // off-session yet) get silently omitted from the picker. The user-
      // visible bug was "Donar muestra solo 1 tarjeta cuando tengo varias".
      //
      // Cards saved via the dedicated Saved Cards flow (createSetupIntent
      // with usage='off_session') are already off-session-ready, so the
      // auto-empty cron path keeps working. The tradeoff: a card entered
      // INLINE during a one-off donation no longer auto-saves for the
      // cron — the user must save it explicitly via the Saved Cards
      // screen if they want it usable for auto-empty.
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
        // Stamp the Connect destination so the webhook can detect
        // routing drift (admin re-linked Stripe Connect mid-flight) and
        // refuse to attribute the donation to the wrong tenant.
        ...(tenantConnectAccountId
          ? { connectAccountId: tenantConnectAccountId }
          : {}),
        // For pushka_empty the webhook owns the pushkaAmount reset (avoids
        // the client-side race where the charge succeeds but the webhook
        // fails — money would be charged with no transaction record AND
        // pushka shown as empty).
        ...(purpose === "pushka_empty"
          ? { pushkaAmountAfter: String(pushkaAmountAfter) }
          : {}),
        // Donor message — only stamped when the donor wrote something. The
        // webhook copies this onto the persisted transaction so it appears
        // in History + admin dashboards.
        ...(donorMessage ? { donorMessage } : {}),
        correlationId,
      },
  };

  // Customer Sessions (Stripe's modern replacement for ephemeral keys)
  // unlock the saved-cards list inside PaymentSheet AND let us declare the
  // payment_method_save / payment_method_remove features so the SDK doesn't
  // hide cards based on inferred constraints. With plain ephemeralKeys the
  // SDK was filtering some saved cards out of the picker (observed on
  // production: a customer with Visa default + MC saw only MC). The new
  // CustomerSession.client_secret is consumed by PaymentSheet via the
  // `customerSessionClientSecret` parameter.
  //
  // We still emit the legacy ephemeralKey as a fallback for the off-chance
  // a future Stripe SDK version regresses Session support — the client
  // prefers session > ephemeralKey when both are present.
  const customerSessionParams = {
    customer: customerId,
    components: {
      mobile_payment_element: {
        enabled: true,
        features: {
          payment_method_save: "enabled",
          payment_method_remove: "enabled",
          payment_method_redisplay: "enabled",
          payment_method_allow_redisplay_filters: ["always", "limited", "unspecified"],
        },
      },
    },
  };

  // Fire both Stripe API calls concurrently. allSettled (not all) so a
  // CustomerSession failure doesn't tank the PaymentIntent — we fall back
  // to ephemeralKey in that branch.
  const [piResult, sessionResult] = await Promise.allSettled([
    stripe.paymentIntents.create(piParams, { idempotencyKey }),
    stripe.customerSessions.create(customerSessionParams),
  ]);

  if (piResult.status === "rejected") {
    const err = piResult.reason;
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
  const paymentIntent = piResult.value;

  let customerSessionClientSecret = null;
  let ephemeralKeySecret = null;
  if (sessionResult.status === "fulfilled") {
    customerSessionClientSecret = sessionResult.value.client_secret;
  } else {
    const csErr = sessionResult.reason;
    console.warn("createPaymentIntent: customer session creation failed", {
      uid: request.auth.uid,
      tenantId: tenantId || null,
      customerId,
      errorType: csErr?.type,
      errorMessage: csErr?.message,
    });
    // Fall back to legacy ephemeralKey path so saved cards still surface
    // (just with the old SDK-side filtering quirk).
    try {
      const ephemeralKey = await stripe.ephemeralKeys.create(
        { customer: customerId },
        { apiVersion: "2024-06-20" },
      );
      ephemeralKeySecret = ephemeralKey.secret;
    } catch (ekErr) {
      console.warn("createPaymentIntent: ephemeral key creation also failed", {
        uid: request.auth.uid,
        customerId,
        errorMessage: ekErr?.message,
      });
    }
  }

  return {
    clientSecret: paymentIntent.client_secret,
    customerId,
    customerSessionClientSecret,
    ephemeralKeySecret,
  };
});

// ---------------------------------------------------------------------------
// Stripe Subscription — recurring donation (monthly / weekly / etc.)
// ---------------------------------------------------------------------------
//
// Creates a Stripe Subscription with inline `price_data` for the donor's
// chosen amount + interval. Returns the latest invoice's PaymentIntent
// client secret so the client can confirm the first charge via
// PaymentSheet; subsequent charges are billed automatically off-session
// using the saved default payment method (Stripe webhook
// `invoice.payment_succeeded` writes the transaction record).
//
// Connect routing: when the tenant has an active Connect account we set
// `application_fee_percent` (subs use percent, not amount) + transfer_data
// so each invoice routes to the tenant.
exports.createDonationSubscription = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    await enforceRateLimit(request.auth.uid, "createDonationSubscription", 10, 600);
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }

    const [adminDataSnap, userSnap] = await Promise.all([
      db.collection("adminData").doc(request.auth.uid).get(),
      db.collection("users").doc(request.auth.uid).get(),
    ]);
    if (adminDataSnap.exists && adminDataSnap.data()?.isBlocked === true) {
      throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida.");
    }

    const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
    const tenantId = userData.tenantId ?? null;

    let tenantConnectAccountId = null;
    let tenantCommissionRate = 0;
    if (tenantId) {
      const tenantSnap = await db.collection("tenants").doc(tenantId).get();
      if (tenantSnap.exists) {
        const td = tenantSnap.data();
        if (td.status === "suspended") {
          throw new HttpsError("permission-denied", "El servicio de tu organización está suspendido.");
        }
        const cs = td.stripeConnectStatus;
        const cid = td.stripeConnectAccountId;
        if (cs === "active" && cid) {
          tenantConnectAccountId = cid;
          tenantCommissionRate = safeTenantCommissionRate(td.commissionRate, tenantId);
        } else if (cid && cs !== "active") {
          throw new HttpsError(
            "failed-precondition",
            "Tu organización está temporalmente sin conexión con el procesador de pagos.",
          );
        }
      }
    }

    const amount = Number(request.data?.amount || 0);
    const currency = validateCurrency(request.data?.currency || "usd");
    const interval = String(request.data?.interval || "month");
    if (interval !== "month" && interval !== "week") {
      throw new HttpsError("invalid-argument", "Intervalo inválido.");
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
        `Monto mínimo para ${currency.toUpperCase()} es ${formatAmount(minAmount)}.`,
      );
    }

    const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });

    const customerEmail = request.auth.token?.email
      ? String(request.auth.token.email).slice(0, 254)
      : null;

    let customerId = String(userData.stripeCustomerId || "").trim() || null;
    if (!customerId) {
      const userRef = db.collection("users").doc(request.auth.uid);
      try {
        const customer = await stripe.customers.create(
          {
            email: customerEmail || undefined,
            metadata: { uid: request.auth.uid },
          },
          { idempotencyKey: `customer_create_${request.auth.uid}` },
        );
        customerId = customer.id;
        await userRef.set(
          {
            stripeCustomerId: customerId,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      } catch (stripeErr) {
        console.error("createDonationSubscription: customer create failed", {
          uid: request.auth.uid,
          err: stripeErr.message,
        });
        throw new HttpsError("internal", "No se pudo crear el cliente.");
      }
    }

    const donorMessage = sanitizeDonorMessage(request.data?.donorMessage);

    // Stripe subscription items.price_data accepts a `product` ID (not the
    // top-level `product_data` shortcut). Get-or-create a single shared
    // "Pushka recurring donation" product and cache its ID in Firestore so
    // we don't create a new one on every call.
    let recurringProductId = null;
    const cfgRef = db.collection("_appConfig").doc("stripe");
    try {
      const cfgSnap = await cfgRef.get();
      if (cfgSnap.exists) {
        recurringProductId = cfgSnap.data()?.recurringProductId ?? null;
      }
    } catch (cfgErr) {
      console.error("createDonationSubscription: cfg read failed", {
        err: cfgErr.message,
        stack: cfgErr.stack,
      });
      throw new HttpsError("internal", `cfg-read: ${cfgErr.message}`);
    }
    console.info("createDonationSubscription: cfg lookup", {
      uid: request.auth.uid,
      recurringProductId,
    });
    if (!recurringProductId) {
      try {
        const product = await stripe.products.create(
          {
            name: "Pushka — Donación recurrente",
            metadata: { source: "pushka_recurring" },
          },
          { idempotencyKey: "pushka_recurring_product_v1" },
        );
        recurringProductId = product.id;
        console.info("createDonationSubscription: product created", {
          productId: recurringProductId,
        });
        try {
          await cfgRef.set(
            {
              recurringProductId,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
        } catch (writeErr) {
          console.error("createDonationSubscription: cfg write failed", {
            err: writeErr.message,
            stack: writeErr.stack,
          });
          // Non-fatal: we already have the product ID, just won't cache it.
        }
      } catch (prodErr) {
        console.error("createDonationSubscription: product create failed", {
          err: prodErr.message,
          stack: prodErr.stack,
        });
        throw new HttpsError("internal", `product-create: ${prodErr.message}`);
      }
    }

    const subParams = {
      customer: customerId,
      items: [
        {
          price_data: {
            currency: currency.toLowerCase(),
            product: recurringProductId,
            unit_amount: amount,
            recurring: { interval },
          },
        },
      ],
      payment_behavior: "default_incomplete",
      payment_settings: {
        save_default_payment_method: "on_subscription",
      },
      // Stripe API 2024-09-30+ replaced invoice.payment_intent with
      // invoice.confirmation_secret. Expand both so we work across versions.
      expand: [
        "latest_invoice.confirmation_secret",
        "latest_invoice.payment_intent",
      ],
      metadata: {
        uid: request.auth.uid,
        tenantId: tenantId || "",
        purpose: "donation_recurring",
        donorMessage,
      },
    };

    if (tenantConnectAccountId) {
      // Subscriptions accept `application_fee_percent` (Stripe computes the
      // fee from each invoice's subtotal). Clamp to [0, 99] — a misconfigured
      // 100%+ rate would have Stripe reject every invoice forever.
      subParams.application_fee_percent = Math.min(
        99,
        Math.max(0, tenantCommissionRate * 100),
      );
      subParams.transfer_data = { destination: tenantConnectAccountId };
    }

    // Pre-cleanup: cancel any existing donation_recurring subscriptions on
    // this customer before creating a new one. Two reasons:
    //   1. Stripe rejects new subs in a different currency when the customer
    //      has any active/incomplete sub in another currency:
    //        "You cannot combine currencies on a single customer."
    //      A donor who switched their preferred currency (e.g. USD → EUR)
    //      otherwise can't ever donate recurring again until the existing
    //      sub fully expires.
    //   2. We don't want two simultaneous donation subs anyway — the donor
    //      pressing "Donar mensual" while already subscribed expects to
    //      REPLACE the previous amount, not stack a second monthly charge.
    // Scope tightly to subs whose metadata.purpose === "donation_recurring"
    // so SaaS billing subscriptions or any other subs on this customer are
    // untouched. Best-effort: errors during cancel don't block the new sub
    // (Stripe will reject with a clearer "combine currencies" error if the
    // cleanup partially fails, which we surface back to the client).
    try {
      const existing = await stripe.subscriptions.list({
        customer: customerId,
        status: "all",
        limit: 100,
      });
      for (const oldSub of existing.data) {
        if (oldSub.metadata?.purpose !== "donation_recurring") continue;
        if (oldSub.status === "canceled" || oldSub.status === "incomplete_expired") continue;
        try {
          await stripe.subscriptions.cancel(oldSub.id, {
            invoice_now: false,
            prorate: false,
          });
          console.info("createDonationSubscription: cancelled prior donation sub", {
            uid: request.auth.uid,
            subId: oldSub.id,
            priorStatus: oldSub.status,
            priorCurrency: oldSub.currency,
          });
        } catch (cancelErr) {
          console.warn("createDonationSubscription: failed to cancel prior donation sub", {
            uid: request.auth.uid,
            subId: oldSub.id,
            err: cancelErr.message,
          });
        }
      }
    } catch (listErr) {
      console.warn("createDonationSubscription: failed to list prior subs", {
        uid: request.auth.uid,
        err: listErr.message,
      });
    }

    console.info("createDonationSubscription: creating sub", {
      uid: request.auth.uid,
      customerId,
      recurringProductId,
      amount,
      currency,
      interval,
      hasConnect: !!tenantConnectAccountId,
    });
    let subscription;
    try {
      subscription = await stripe.subscriptions.create(subParams);
      console.info("createDonationSubscription: sub created", {
        subId: subscription.id,
        status: subscription.status,
      });
    } catch (stripeErr) {
      console.error("createDonationSubscription: Stripe error", {
        uid: request.auth.uid,
        err: stripeErr.message,
        type: stripeErr.type,
        code: stripeErr.code,
        param: stripeErr.param,
      });
      // Translate the most common Stripe rejections to user-friendly Spanish
      // so the client can render a clean message instead of leaking raw
      // English Stripe text. Pre-cleanup above usually prevents the
      // currency-mix error, but a half-cancelled sub or one outside the
      // donation_recurring scope could still trip it.
      const msg = String(stripeErr.message || "").toLowerCase();
      if (msg.includes("combine currencies on a single customer")) {
        throw new HttpsError(
          "failed-precondition",
          "Tenés una suscripción activa en otra moneda. Cancelala desde tu cuenta antes de crear una nueva.",
        );
      }
      throw new HttpsError("internal", `sub-create: ${stripeErr.message}`);
    }

    // Newer Stripe API (2024-09-30+): invoice carries `confirmation_secret`
    // (an envelope around the same client secret + a `type` discriminator).
    // Older API: invoice has nested `payment_intent` object. Read both.
    const invoice = subscription.latest_invoice ?? null;
    const clientSecret =
      invoice?.confirmation_secret?.client_secret ??
      invoice?.payment_intent?.client_secret ??
      null;
    if (!clientSecret) {
      console.error("createDonationSubscription: no client secret", {
        invoiceKeys: invoice ? Object.keys(invoice) : null,
        hasConfirmationSecret: !!invoice?.confirmation_secret,
        hasPaymentIntent: !!invoice?.payment_intent,
        invoiceStatus: invoice?.status,
      });
      throw new HttpsError("internal", "Suscripción creada sin payment intent.");
    }

    // EphemeralKey lets PaymentSheet show saved cards. Best-effort —
    // subscription works without it, just lacks the saved-card picker.
    let ephemeralKeySecret = null;
    try {
      const ephemeralKey = await stripe.ephemeralKeys.create(
        { customer: customerId },
        { apiVersion: "2024-06-20" },
      );
      ephemeralKeySecret = ephemeralKey.secret;
    } catch (ekErr) {
      console.warn("createDonationSubscription: ephemeralKey create failed", {
        uid: request.auth.uid,
        err: ekErr.message,
      });
    }

    return {
      subscriptionId: subscription.id,
      clientSecret,
      customerId,
      ephemeralKeySecret,
    };
  },
);

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
    await enforceRateLimit(request.auth.uid, "createSetupIntent", 20, 3600);

    const uid = request.auth.uid;
    const stripe = require("stripe")(stripeSecret.value());
    const userRef = db.collection("users").doc(uid);

    // Invalidate the dedupe cache eagerly: the user is about to add a card,
    // so the next createPaymentIntent must re-run the inventory pass to
    // catch a freshly-attached duplicate before PaymentSheet sees it.
    userRef.set({
      _lastPmDedupePassAt: admin.firestore.FieldValue.delete(),
    }, { merge: true }).catch(() => {});

    // Fast path for the 99% case: the user already has a Stripe customer
    // attached. A simple read avoids the heavier Firestore transaction
    // (~50-150ms saved). The transaction below still runs for new users
    // where the race against a concurrent call matters.
    let customerId = null;
    let customerEmail = null;
    const fastSnap = await userRef.get();
    if (fastSnap.exists) {
      const fastData = fastSnap.data() || {};
      customerEmail = fastData.email || request.auth.token?.email || null;
      customerId = fastData.stripeCustomerId || null;
    }

    if (!customerId) {
      // Slow path — transactional get-or-mark-pending. Two concurrent
      // calls landing here would otherwise both create separate Stripe
      // customers for the same uid; the txn + sentinel makes one wait.
      await db.runTransaction(async (tx) => {
        const userSnap = await tx.get(userRef);
        const userData = userSnap.data() || {};
        customerEmail = userData.email || request.auth.token?.email || null;
        customerId = userData.stripeCustomerId || null;
        if (!customerId) {
          tx.set(userRef, {
            stripeCustomerIdPending: true,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        }
      });
    }

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
    await enforceRateLimit(request.auth.uid, "listSavedCards", 100, 3600);

    const uid = request.auth.uid;
    const userSnap = await db.collection("users").doc(uid).get();
    const userData = userSnap.data() ?? {};
    const customerId = userData.stripeCustomerId || null;

    if (!customerId) {
      return { cards: [], defaultPaymentMethodId: null };
    }

    const stripe = require("stripe")(stripeSecret.value());
    // customers.retrieve and paymentMethods.list are independent — running
    // them in parallel halves this prep step (~150-300ms saved on the
    // critical path of opening Saved Cards).
    const [customer, pmList] = await Promise.all([
      stripe.customers.retrieve(customerId),
      stripe.paymentMethods.list({
        customer: customerId,
        type: "card",
        limit: 100,
      }),
    ]);

    // Customer was deleted directly in Stripe — clear the stale ID and return empty.
    if (customer.deleted) {
      await db.collection("users").doc(uid).set(
        { stripeCustomerId: null, stripeCustomerIdPending: null },
        { merge: true },
      ).catch(() => {});
      return { cards: [], defaultPaymentMethodId: null };
    }

    const defaultPmId = customer.invoice_settings?.default_payment_method || null;

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
    // Cache-aware: same `_lastPmDedupePassAt` field as createPaymentIntent.
    // If a recent pass already cleaned up Stripe-side dupes, skip the
    // detach calls (in-memory dedupe still runs above for safety against
    // races, but it's a no-op when state is clean).
    const lastDedupeAt = userData._lastPmDedupePassAt?.toMillis?.() ?? 0;
    const dedupeStale = (Date.now() - lastDedupeAt) > (2 * 60 * 60 * 1000);
    if (detachQueue.length > 0 && dedupeStale) {
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
      // Stamp the success — fire-and-forget so it doesn't block the
      // response. Mirrors the pattern used in createPaymentIntent.
      db.collection("users").doc(uid).set({
        _lastPmDedupePassAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true }).catch(() => {});
    } else if (dedupeStale) {
      // No dupes found AND cache is stale → stamp anyway so the next call
      // skips the in-memory grouping cost too. (No detach needed.)
      db.collection("users").doc(uid).set({
        _lastPmDedupePassAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true }).catch(() => {});
    }

    const cards = keep.map((pm) => ({
      id: pm.id,
      brand: pm.card?.brand || "card",
      last4: pm.card?.last4 || "****",
      expMonth: pm.card?.exp_month || 0,
      expYear: pm.card?.exp_year || 0,
      isDefault: pm.id === defaultPmId,
      // Optional user-set nickname (e.g. "BBVA"). Lives in pm.metadata.nickname
      // so it's atomically attached/detached with the PaymentMethod itself —
      // no separate Firestore subcollection to keep in sync.
      nickname: pm.metadata?.nickname || null,
    }));

    return { cards, defaultPaymentMethodId: defaultPmId };
  }
);

// ---------------------------------------------------------------------------
// setPaymentMethodNickname — caller assigns / clears a nickname on one of
// their own saved PaymentMethods. Stored in pm.metadata.nickname.
// ---------------------------------------------------------------------------
exports.setPaymentMethodNickname = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }
    await enforceRateLimit(request.auth.uid, "setPaymentMethodNickname", 30, 3600);

    const pmId = String(request.data?.paymentMethodId || "").trim();
    if (!pmId) throw new HttpsError("invalid-argument", "paymentMethodId requerido.");
    // Empty string clears. Cap length so a malicious / careless input can't
    // bloat metadata storage (Stripe enforces 500 chars per metadata value;
    // we clamp tighter for sane display).
    let nickname = String(request.data?.nickname || "").trim();
    if (nickname.length > 60) nickname = nickname.substring(0, 60);

    // Verify the PM belongs to the caller's customer before mutating.
    const userSnap = await db.collection("users").doc(request.auth.uid).get();
    const customerId = userSnap.data()?.stripeCustomerId || null;
    if (!customerId) throw new HttpsError("not-found", "Stripe customer no encontrado.");
    const stripe = require("stripe")(stripeSecret.value());
    const pm = await stripe.paymentMethods.retrieve(pmId);
    if (pm.customer !== customerId) {
      throw new HttpsError("permission-denied", "Esa tarjeta no es tuya.");
    }

    await stripe.paymentMethods.update(pmId, {
      metadata: { nickname: nickname || "" },
    });
    return { success: true, nickname: nickname || null };
  },
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

    // Fetch the PM to verify ownership AND the customer to check default
    // status in parallel — they're independent and saves ~100-200ms vs the
    // prior sequential pattern.
    let pm;
    let stripeCustomer;
    try {
      [pm, stripeCustomer] = await Promise.all([
        stripe.paymentMethods.retrieve(pmId),
        stripe.customers.retrieve(customerId),
      ]);
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

    // If deleted PM was the Stripe customer's invoice default, AUTO-PROMOTE
    // a surviving PM to the new default in the same call. Without this the
    // client had to wait for: detach (~500ms) → reload (~500-1500ms) →
    // setDefault (~500ms), totalling 1.5-2.5s of perceived lag before the
    // Settings preview switched to the remaining card. Doing it server-side
    // collapses to a single round-trip and the user_doc stream pushes the
    // new default fields to all listeners in one shot.
    const wasStripeDefault =
      stripeCustomer.invoice_settings?.default_payment_method === pmId;
    const wasFirestoreDefault =
      (userSnap.data()?.stripeDefaultPaymentMethodId || null) === pmId;

    let newDefault = null; // {id, brand, last4} or null when no replacement
    if (wasStripeDefault || wasFirestoreDefault) {
      // Only fetch the surviving list if we actually need to promote — most
      // deletions are non-default cards, no need to spend a Stripe round-trip.
      const survivors = await stripe.paymentMethods.list({
        customer: customerId, type: "card", limit: 100,
      });
      // Newest survivor by creation time; null if customer has no cards left.
      const next = survivors.data
        .slice()
        .sort((a, b) => (b.created || 0) - (a.created || 0))[0] || null;

      // Run Stripe + Firestore promotion writes in parallel — they're
      // independent, each ~300-600ms; serial execution adds an avoidable
      // round trip to the delete-default-card flow.
      const promotions = [];
      if (wasStripeDefault) {
        promotions.push(stripe.customers.update(customerId, {
          invoice_settings: { default_payment_method: next?.id || null },
        }));
      }
      if (wasFirestoreDefault) {
        promotions.push(userRef.set({
          stripeDefaultPaymentMethodId: next?.id || null,
          stripeDefaultPaymentMethodLast4: next?.card?.last4 || null,
          stripeDefaultPaymentMethodBrand: next?.card?.brand || null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true }));
      }
      if (promotions.length > 0) await Promise.all(promotions);
      if (next) {
        newDefault = {
          id: next.id,
          brand: next.card?.brand || "card",
          last4: next.card?.last4 || "****",
        };
      }
    }

    // Card removed → invalidate dedupe cache so the next payment re-runs
    // the pass (otherwise the cron would still see the freshly-detached PM
    // until the 6h TTL elapses).
    userRef.set({
      _lastPmDedupePassAt: admin.firestore.FieldValue.delete(),
    }, { merge: true }).catch(() => {});

    // Clear the deleted PM from any tenantState that pinned it as the
    // auto-empty card. Without this, the cron keeps trying to charge a
    // detached PM (Stripe responds resource_missing) and the user gets
    // misleading "card declined" notifications when the truth is they
    // deleted the card. Best-effort, fire-and-forget — the cron-side
    // resource_missing handler also tolerates this state.
    db.collection("users").doc(uid).collection("tenantState")
      .where("autoEmptyPaymentMethodId", "==", pmId)
      .get()
      .then((snap) => {
        if (snap.empty) return;
        const batch = db.batch();
        for (const d of snap.docs) {
          batch.set(d.ref, {
            autoEmptyPaymentMethodId: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        }
        return batch.commit();
      })
      .catch((err) => console.warn("deletePaymentMethod: failed to clear tenantState pmId", {
        uid, pmId, err: err?.message,
      }));

    return { success: true, newDefault };
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

    // Stripe customer update + Firestore cache write are independent and
    // each ~300-600ms; running them in parallel saves a full round trip
    // off the critical path. The dedupe cache is cleared because the
    // dedupe pass picks a "winner" per fingerprint group based on which
    // card is the default — switching defaults can change the winner, so
    // the next createPaymentIntent re-runs the pass.
    await Promise.all([
      stripe.customers.update(customerId, {
        invoice_settings: { default_payment_method: pmId },
      }),
      userRef.set({
        stripeDefaultPaymentMethodId: pmId,
        stripeDefaultPaymentMethodLast4: pm.card?.last4 || null,
        stripeDefaultPaymentMethodBrand: pm.card?.brand || null,
        _lastPmDedupePassAt: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true }),
    ]);

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

  let eventRef, alreadyProcessed;
  try {
    ({ eventRef, alreadyProcessed } = await reserveWebhookEvent(event));
  } catch (reserveErr) {
    // Malformed event id — refuse to process (would otherwise pollute the
    // dedup table). 400 stops Stripe's retry loop; signature already
    // validated above, so this is a Stripe API anomaly we want eyes on.
    console.error("stripeWebhook: reserveWebhookEvent failed", {
      eventId: event?.id, type: event?.type, err: reserveErr?.message,
    });
    res.status(400).send("Invalid event id format.");
    return;
  }
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
        // Drift detection: if the tenant's Connect account changed between
        // createPaymentIntent and this webhook, log so ops can manually
        // reconcile (the funds went to the OLD destination but the
        // transaction would otherwise be attributed to the new one). We
        // still write the txn — money already moved — but flag it.
        const stampedConnect = intent.metadata?.connectAccountId
          ? String(intent.metadata.connectAccountId)
          : null;
        if (stampedConnect && txTenantId) {
          try {
            const tenantSnap = await db.collection("tenants").doc(txTenantId).get();
            const currentConnect = tenantSnap.data()?.stripeConnectAccountId ?? null;
            if (currentConnect && currentConnect !== stampedConnect) {
              console.error("stripeWebhook: connectAccountId DRIFT", {
                uid,
                tenantId: txTenantId,
                paymentIntentId: docId,
                eventId: event.id,
                stampedConnect,
                currentConnect,
              });
            }
          } catch (driftErr) {
            console.warn("stripeWebhook: drift check failed", {
              tenantId: txTenantId, err: driftErr?.message,
            });
          }
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
            // donorMessage was sanitized in createPaymentIntent before being
            // stamped on the PI metadata; re-sanitize defensively here so a
            // forged event (theoretical — Stripe signature blocks this) can't
            // smuggle control chars into Firestore.
            ...(intent.metadata?.donorMessage
              ? { donorMessage: sanitizeDonorMessage(intent.metadata.donorMessage) }
              : {}),
            // Persist the correlation ID stamped by createPaymentIntent so
            // ops can grep `[cid:xxx]` across CF logs AND find the
            // associated tx doc in Firestore. Validated shape on read.
            ...(intent.metadata?.correlationId &&
              /^[a-f0-9]{16}$/.test(intent.metadata.correlationId)
              ? { correlationId: intent.metadata.correlationId }
              : {}),
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });

        // Update pre-aggregated revenue counters on tenant doc (non-blocking)
        if (txTenantId) await incrementTenantRevenue(txTenantId, txSnap.amountUSD);

        // For pushka_empty (manual flow) the webhook owns:
        //   1. resetting pushkaAmount to the value the client computed
        //      (`pushkaAmountAfter` in metadata) — avoids the client-side
        //      race where Stripe charged but Firestore never saw it.
        //   2. releasing the manual lock acquired by createPaymentIntent.
        // Both writes happen in a single Firestore set so the donor sees
        // the new pushka balance + lock release atomically. Best-effort —
        // the 10-minute TTL on the lock catches Firestore failures.
        if (txTenantId && purpose === "pushka_empty") {
          const rawAfter = intent.metadata?.pushkaAmountAfter;
          const parsedAfter = rawAfter !== undefined && rawAfter !== null
            ? Number(rawAfter)
            : 0;
          const newPushkaAmount =
            Number.isFinite(parsedAfter) && parsedAfter >= 0
              ? parsedAfter
              : 0;
          await db.collection("users").doc(uid)
            .collection("tenantState").doc(txTenantId)
            .set({
              pushkaAmount: newPushkaAmount,
              _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
              _autoEmptyChargeLockSource: admin.firestore.FieldValue.delete(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true })
            .catch((err) => console.warn("stripeWebhook: pushkaAmount reset failed", {
              uid, txTenantId, err: err?.message,
            }));
        }

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
      const purpose = String(intent.metadata?.purpose || "donation");
      const tenantIdMeta = intent.metadata?.tenantId
        ? String(intent.metadata.tenantId)
        : null;
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

      // Release the manual pushka_empty lock on failure too — otherwise a
      // declined card would keep the user blocked from retrying for the
      // full 10-minute TTL.
      if (uid && tenantIdMeta && purpose === "pushka_empty") {
        await db.collection("users").doc(uid)
          .collection("tenantState").doc(tenantIdMeta)
          .set({
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
            _autoEmptyChargeLockSource: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true })
          .catch(() => {});
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
          // Out-of-order guard: Stripe doesn't guarantee that
          // payment_intent.succeeded arrives before charge.refunded for the
          // same charge (rare but observed under Stripe webhook backlog).
          // Without this check, the refund handler writes a negative tx for
          // a PI whose original positive tx was never written — a permanent
          // orphan in user history. Tag the row with `originalMissing` so
          // ops can spot it; admin aggregates can choose to exclude.
          const originalTxRef = db
            .collection("users").doc(uid)
            .collection("transactions").doc(paymentIntentId);
          const originalTxSnap = await originalTxRef.get();
          const originalMissing = !originalTxSnap.exists;
          if (originalMissing) {
            console.warn("stripeWebhook: refund_before_original", {
              uid, paymentIntentId, chargeId: charge.id, eventId: event.id,
              note: "negating tx written with originalMissing flag — ops should reconcile",
            });
          }

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
              ...(originalMissing ? { originalMissing: true } : {}),
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
        const tenantDocData = tenantsSnap.docs[0].data();
        const chargesEnabled = account.charges_enabled === true;
        const payoutsEnabled = account.payouts_enabled === true;
        const newConnectStatus = chargesEnabled && payoutsEnabled ? "active" : "restricted";
        const prevConnectStatus = tenantDocData.stripeConnectStatus;

        await tenantRef.update({
          stripeConnectStatus: newConnectStatus,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        if (newConnectStatus === "active" && prevConnectStatus !== "active") {
          await writeActivityLog({
            type: "stripe_connect_activated",
            tenantId: tenantsSnap.docs[0].id,
            tenantName: tenantDocData.name ?? tenantsSnap.docs[0].id,
            severity: "info",
            requiresAction: false,
            data: { accountId },
          });
        }
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
    } else if (event.type === "invoice.payment_succeeded") {
      // Donor recurring donation invoice — write the txn from the
      // subscription's metadata. (Tenant SaaS billing invoices have their
      // own dedicated handler in stripeBillingWebhook; we only act on
      // donation_recurring.)
      const invoice = event.data.object;
      const subMeta = invoice.subscription_details?.metadata
        ?? invoice.parent?.subscription_details?.metadata
        ?? null;
      const purpose = subMeta?.purpose ?? null;
      if (purpose !== "donation_recurring") {
        await finalizeWebhookEvent(eventRef, { status: "ignored", reason: "not_donation_recurring", invoiceId: invoice.id });
      } else {
        const uid = subMeta?.uid ? String(subMeta.uid) : null;
        const tenantId = subMeta?.tenantId ? String(subMeta.tenantId) : null;
        const subId = invoice.subscription
          ? (typeof invoice.subscription === "string" ? invoice.subscription : invoice.subscription.id)
          : null;
        const amountPaid = (invoice.amount_paid ?? 0) / currencyUnitDivisor(invoice.currency || "usd");
        const txCurrency = String(invoice.currency || "usd").toUpperCase();
        const docId = `inv_${invoice.id}`;
        if (uid) {
          const txRates = await getExchangeRates(null);
          const txSnap = buildCurrencySnapshot(amountPaid, txCurrency, txRates);
          await db.collection("users").doc(uid)
            .collection("transactions").doc(docId).set({
              type: "tzedaka",
              amount: amountPaid,
              currencyCode: txCurrency,
              ...txSnap,
              ...(tenantId ? { tenantId } : {}),
              description: "Donación recurrente (Stripe)",
              paymentMethod: "card",
              status: "completed",
              subscriptionId: subId,
              // Carry the donor's recurring-subscription message onto each
              // generated invoice tx so History + admin views show it.
              // Re-sanitize defensively in case a future code path skips
              // sanitization on the way in.
              ...(subMeta?.donorMessage
                ? { donorMessage: sanitizeDonorMessage(subMeta.donorMessage) }
                : {}),
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          if (tenantId) await incrementTenantRevenue(tenantId, txSnap.amountUSD);
        } else {
          console.warn("stripeWebhook: invoice.payment_succeeded without uid in subscription metadata", {
            invoiceId: invoice.id, subId,
          });
        }
        await finalizeWebhookEvent(eventRef, {
          status: "processed",
          uid: uid || null,
          tenantId,
          subscriptionId: subId,
          invoiceId: invoice.id,
          amount: amountPaid,
          outcome: "donation_recurring_invoice_paid",
        });
      }
    } else if (event.type === "invoice.payment_failed") {
      // Donor recurring donation invoice failure — log a payment_event so
      // the client can surface a "tu donación recurrente falló — actualizá
      // tu tarjeta" UI. (cleanupIncompleteDonationSubscriptions sweeps the
      // dead subscriptions after 7 days.)
      const invoice = event.data.object;
      const subMeta = invoice.subscription_details?.metadata
        ?? invoice.parent?.subscription_details?.metadata
        ?? null;
      const purpose = subMeta?.purpose ?? null;
      if (purpose !== "donation_recurring") {
        await finalizeWebhookEvent(eventRef, { status: "ignored", reason: "not_donation_recurring", invoiceId: invoice.id });
      } else {
        const uid = subMeta?.uid ? String(subMeta.uid) : null;
        const subId = invoice.subscription
          ? (typeof invoice.subscription === "string" ? invoice.subscription : invoice.subscription.id)
          : null;
        const amount = (invoice.amount_due ?? 0) / currencyUnitDivisor(invoice.currency || "usd");
        if (uid) {
          await writeUserPaymentEvent(uid, event.id, {
            kind: "donation_recurring_failed",
            provider: "stripe",
            subscriptionId: subId,
            invoiceId: invoice.id,
            amount,
            currencyCode: String(invoice.currency || "usd").toUpperCase(),
            message: invoice.last_finalization_error?.message
              ?? invoice.last_payment_error?.message
              ?? "payment_failed",
            livemode: !!event.livemode,
          });
        }
        await finalizeWebhookEvent(eventRef, {
          status: "processed",
          uid: uid || null,
          subscriptionId: subId,
          invoiceId: invoice.id,
          outcome: "donation_recurring_invoice_failed",
        });
      }
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

    // Track monthly active user — best-effort, non-blocking
    if (tenantId && uid) {
      try {
        const now = new Date();
        const monthKey = `${now.getUTCFullYear()}_${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
        const seenRef = db.collection("_monthlyActive").doc(`${monthKey}_${tenantId}_${uid}`);
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(seenRef);
          if (snap.exists) return; // already counted this month
          tx.set(seenRef, { tenantId, uid, month: monthKey });
          tx.update(db.collection("tenants").doc(tenantId), {
            activeUsersThisMonth: admin.firestore.FieldValue.increment(1),
          });
        });
      } catch (err) {
        console.warn("activeUsersThisMonth: update failed (non-fatal)", String(err?.message || err));
      }
    }
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

// Reset activeUsersThisMonth counter on all tenants on the 1st of each month.
// Also deletes _monthlyActive docs from 2 months ago to keep the collection lean.
exports.resetMonthlyActiveUsers = onSchedule(
  { schedule: "0 0 1 * *", timeZone: "Etc/UTC" },
  async () => {
    const tenantsSnap = await db.collection("tenants").get();
    const BATCH_SIZE = 400;
    let batch = db.batch();
    let count = 0;
    for (const doc of tenantsSnap.docs) {
      batch.update(doc.ref, { activeUsersThisMonth: 0 });
      if (++count % BATCH_SIZE === 0) { await batch.commit(); batch = db.batch(); }
    }
    if (count % BATCH_SIZE !== 0) await batch.commit();

    // Clean up _monthlyActive docs from 2 months ago
    const now = new Date();
    const twoMonthsAgo = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 2, 1));
    const oldKey = `${twoMonthsAgo.getUTCFullYear()}_${String(twoMonthsAgo.getUTCMonth() + 1).padStart(2, "0")}`;
    let deleted = 0;
    let hasMore = true;
    while (hasMore) {
      const snap = await db.collection("_monthlyActive")
        .where("month", "==", oldKey)
        .limit(400)
        .get();
      if (snap.empty) { hasMore = false; break; }
      const b = db.batch();
      snap.docs.forEach((d) => b.delete(d.ref));
      await b.commit();
      deleted += snap.size;
      hasMore = snap.size === 400;
    }
    console.info("resetMonthlyActiveUsers: complete", { tenantsReset: tenantsSnap.size, monthlyActiveDeleted: deleted });
  },
);

/**
 * Cancel donor recurring subscriptions that never made it past the
 * "incomplete" first-invoice payment. Default Stripe behavior is to leave
 * them in "incomplete" forever — the donor sees nothing happen, the org
 * sees nothing collect, and the subscription rots. We sweep daily and
 * cancel anything that's been incomplete for more than 7 days. The
 * webhook for invoice.payment_failed already notifies the user; this
 * cleans up the trail.
 *
 * Scoped to subscriptions with metadata.purpose === "donation_recurring"
 * so we don't touch SaaS billing subscriptions.
 */
exports.cleanupIncompleteDonationSubscriptions = onSchedule(
  {
    schedule: "every day 03:30",
    timeZone: "Etc/UTC",
    secrets: [stripeSecret],
    timeoutSeconds: 540,
  },
  async () => {
    if (!stripeSecret.value()) {
      console.error("cleanupIncompleteDonationSubscriptions: STRIPE_SECRET_KEY missing");
      return;
    }
    const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });
    const cutoffSec = Math.floor((Date.now() - 7 * 24 * 60 * 60 * 1000) / 1000);
    let canceled = 0;
    let scanned = 0;
    let skipped = 0;
    let cursor;
    do {
      const page = await stripe.subscriptions.list({
        status: "incomplete",
        limit: 100,
        ...(cursor ? { starting_after: cursor } : {}),
      });
      for (const sub of page.data) {
        scanned += 1;
        if (sub.created > cutoffSec) { skipped += 1; continue; }
        if (sub.metadata?.purpose !== "donation_recurring") { skipped += 1; continue; }
        try {
          await stripe.subscriptions.cancel(sub.id);
          canceled += 1;
          console.info("cleanupIncompleteDonationSubscriptions: canceled", {
            subId: sub.id, uid: sub.metadata?.uid, ageDays:
              Math.floor((Date.now() / 1000 - sub.created) / 86400),
          });
        } catch (e) {
          console.warn("cleanupIncompleteDonationSubscriptions: cancel failed", {
            subId: sub.id, err: e?.message,
          });
        }
      }
      cursor = page.has_more ? page.data[page.data.length - 1].id : undefined;
    } while (cursor);
    console.info("cleanupIncompleteDonationSubscriptions: completed", {
      scanned, canceled, skipped,
    });
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
//
// SAFETY: Even if this TTL fires while an in-flight Stripe charge is still
// processing (theoretical 10-min stall), the Stripe idempotencyKey on the
// charge call (`pushka_auto_empty_${uid}_${tenantId}_${nextRunDateKey}`)
// guarantees Stripe returns the SAME PaymentIntent on the retry — no
// double-charge. The lock is best-effort coordination, not the safety net.
// If you ever shorten the idempotency key window or change its inputs to
// include something more volatile than nextRunAt, this assumption breaks.
const AUTO_EMPTY_LOCK_TTL_MS = 10 * 60 * 1000; // 10 min

// Short retry interval when a charge fails (decline, suspended tenant, blocked
// user, Connect not active). Without this, advancing the schedule before the
// charge meant a single failure silently skipped the entire monthly cycle.
const AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS = 24;

async function _runPushkaAutoEmptyTick() {
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

          const accumulatedAmount = Number(state.pushkaAmount || 0);
          const weekday = Number(state.autoEmptyWeekday || 1);
          const dayOfMonth = Number(state.autoEmptyDayOfMonth || 1);

          // Compute the NORMAL next-run date for use in the success path
          // (and the no-card / unsupported-currency cases that are not
          // actual failures, just "skip this cycle and move on").
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

          // Min-balance gate removed by product decision: previously the
          // cron would skip the cycle if pushkaAmount < $5. Now even tiny
          // balances get charged (the per-currency Stripe minimum check
          // below still applies and will skip if BELOW Stripe's actual
          // floor — e.g. $0.50 USD).

          const customerId = String(userData.stripeCustomerId || "").trim();
          const pmId = String(state.autoEmptyPaymentMethodId || userData.stripeDefaultPaymentMethodId || "").trim();
          if (!customerId || !pmId) {
            console.warn("processPushkaAutoEmpty: no_saved_card", { uid, tenantId });
            advanceNormalOnly();
            return;
          }

          const topOffEnabled = state.autoEmptyTopOffEnabled === true;
          const topOffAmount = topOffEnabled ? Number(state.autoEmptyTopOffAmount || 0) : 0;
          // Charge semantics:
          //   - top-off ON  → charge the recurring amount the donor set
          //                   (topOffAmount), independent of the accumulated
          //                   pushka balance.
          //   - top-off OFF → charge whatever has accumulated in the pushka.
          // After the charge succeeds the local pushka resets to 0 either way
          // so the next cycle starts from a clean slate.
          const currentAmount = topOffEnabled && topOffAmount > 0
            ? topOffAmount
            : accumulatedAmount;
          const newPushkaAmount = 0;

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
            tenantCommissionRate = safeTenantCommissionRate(
              tenantData.commissionRate,
              tenantId,
            );
          } else if (connectAccountId && connectStatus !== "active") {
            console.warn("processPushkaAutoEmpty: connect_not_active", {
              uid, tenantId, connectStatus,
            });
            tx.set(stateRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
                new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
              ),
              // Surface a payment_event the client can read to show a
              // banner: "tu organización está desconectada del procesador
              // de pagos — el vaciado automático no corrió". Without this
              // the donor sees nothing happen for weeks.
              _lastAutoEmptySkipReason: "tenant_connect_not_active",
              _lastAutoEmptySkipAt: admin.firestore.FieldValue.serverTimestamp(),
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

          // Optional designación the donor picked when configuring the
          // auto-empty schedule. Stamped into PaymentIntent.metadata so the
          // org can attribute the recurring donation to a program.
          const donationReasonRaw = state.autoEmptyDonationReason;
          const donationReason = (typeof donationReasonRaw === "string" &&
              donationReasonRaw.trim().length > 0)
            ? donationReasonRaw.trim().slice(0, 80)
            : null;

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
            donationReason,
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
            // Per-tick correlation ID so ops can grep a single auto-empty
            // run across processPushkaAutoEmpty + stripeWebhook +
            // Firestore tx writes. Generated server-side (no client
            // involved in this flow).
            correlationId: require("crypto").randomBytes(8).toString("hex"),
            ...(plan.tenantConnectAccountId
              ? { connectAccountId: plan.tenantConnectAccountId }
              : {}),
            ...(plan.donationReason ? { donationReason: plan.donationReason } : {}),
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

          // PM was deleted/detached/tainted between schedule-set and cron
          // tick: clear the pinned PM so the user's NEW default takes over
          // on the next run (otherwise the cron keeps charging a ghost PM
          // forever and the user gets misleading "card declined" notifications).
          //
          // Detect three flavors:
          //   - `resource_missing` — PM was detached/deleted via Stripe API
          //   - `payment_method_unactivated` — legacy code, same idea
          //   - StripeInvalidRequestError with a message indicating the PM
          //     is unusable off-session because it was used in a destination
          //     charge to a Connect account WITHOUT being pre-attached to a
          //     Customer (Stripe taints the PM after such a charge). Real
          //     prod log seen 2026-05-06 on tenant 'chabad-buenosaires':
          //     "...shared with a connected account without Customer
          //     attachment, or was detached from a Customer..." — code is
          //     undefined for this case so we have to substring-match.
          const pmGoneMsg = String(stripeErr?.message || "").toLowerCase();
          // Specific failure-reason label so dashboards / metrics can
          // distinguish "user deleted card" from "card tainted by prior
          // Connect destination charge". Both remediate the same way
          // (clear pinned PM) but the second case requires the user to
          // re-save the card via SetupIntent — generic "card declined"
          // notification is misleading.
          let pmGoneReason = null;
          if (stripeErr?.code === "resource_missing") {
            pmGoneReason = "pm_deleted";
          } else if (stripeErr?.code === "payment_method_unactivated") {
            pmGoneReason = "pm_unactivated";
          } else if (
            pmGoneMsg.includes("detached from a customer") ||
            pmGoneMsg.includes("without customer attachment")
          ) {
            pmGoneReason = "pm_unusable_offsession";
          }
          const pmGone = pmGoneReason !== null;
          if (pmGone) {
            await stateRef.set({
              autoEmptyPaymentMethodId: admin.firestore.FieldValue.delete(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
          }

          // ===== Failure path: release lock + 24h retry on stateRef =====
          await stateRef.set({
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
            autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
              new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
            ),
            autoEmptyConsecutiveFailures: admin.firestore.FieldValue.increment(1),
            autoEmptyLastFailureAt: admin.firestore.FieldValue.serverTimestamp(),
            autoEmptyLastFailureCode: pmGoneReason ?? String(stripeErr?.code || "unknown"),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

          // Notify user once per failure.
          const failLang = await getUserLanguage(uid);
          const failTitles = { es: "Vaciado fallido", en: "Empty failed", fr: "Vidage échoué", he: "הריקון נכשל" };
          // Two distinct messages — the generic one for declines/expired
          // cards, and a more specific one for "your card cannot be reused
          // off-session" (Stripe Connect PM-tainting). The latter requires
          // the user to re-save their card via the Saved Cards screen so
          // it gets attached to the Customer with `usage: 'off_session'`.
          const failBodies = pmGone ? {
            es: "Tu tarjeta no se puede usar para vaciados automáticos. Volvé a guardarla en Configuración → Tarjetas guardadas.",
            en: "Your card can't be used for automatic empties. Please re-save it via Settings → Saved Cards.",
            fr: "Votre carte ne peut pas être utilisée pour les vidages automatiques. Réenregistrez-la via Paramètres → Cartes enregistrées.",
            he: "לא ניתן להשתמש בכרטיס שלך לריקונים אוטומטיים. שמור אותו מחדש דרך הגדרות → כרטיסים שמורים.",
          } : {
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
        // Update pre-aggregated revenue counters after successful commit (non-blocking)
        await incrementTenantRevenue(plan.tenantId, emptySnap.amountUSD);

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
}

exports.processPushkaAutoEmpty = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Etc/UTC",
    secrets: [stripeSecret],
    maxInstances: 1,
  },
  _runPushkaAutoEmptyTick,
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
  { enforceAppCheck: false },
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

    // Resolve target early — needed for protection checks and claims write.
    const targetRecord = await admin.auth().getUserByEmail(targetEmail);
    const targetExistingClaims = targetRecord.customClaims || {};

    if (!callerIsSuper) {
      if (role === "super_admin") {
        throw new HttpsError("permission-denied", "Solo el super administrador puede asignar ese rol.");
      }
      if (!callerClaims.tenantId) {
        throw new HttpsError("permission-denied", "Tu cuenta no está asociada a ninguna organización.");
      }
      const effectiveTenantId = tenantId || callerClaims.tenantId;
      if (effectiveTenantId !== callerClaims.tenantId) {
        throw new HttpsError("permission-denied", "Solo puedes gestionar tu propia organización.");
      }
      // Only the first tenant admin can revoke access
      if (revoke) {
        const tenantDoc = await db.collection("tenants").doc(callerClaims.tenantId).get();
        const isFirstAdmin = tenantDoc.exists && tenantDoc.data().adminEmail === callerRecord.email;
        if (!isFirstAdmin) {
          throw new HttpsError("permission-denied", "Solo el primer administrador puede revocar accesos.");
        }
      }
    }

    // Super admin email can never be revoked
    if (revoke && targetEmail === SUPER_ADMIN_EMAIL) {
      throw new HttpsError("permission-denied", "No se pueden revocar los permisos del super administrador.");
    }

    // First tenant admin of an org can never be revoked
    if (revoke && targetExistingClaims.tenantId) {
      const tenantDoc = await db.collection("tenants").doc(targetExistingClaims.tenantId).get();
      if (tenantDoc.exists && tenantDoc.data().adminEmail === targetEmail) {
        throw new HttpsError("permission-denied", "No se puede revocar al primer administrador de la organización.");
      }
    }

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

    // Maintain tenants/{tenantId}/team subcollection for tenant roles
    const teamTenantId = revoke ? (targetExistingClaims.tenantId ?? tenantId) : tenantId;
    if (teamTenantId && (revoke || role === "tenant_admin" || role === "tenant_collaborator")) {
      const teamRef = db.collection("tenants").doc(teamTenantId).collection("team").doc(targetRecord.uid);
      try {
        if (revoke) {
          await teamRef.delete();
        } else {
          await teamRef.set({
            uid: targetRecord.uid,
            email: targetRecord.email,
            displayName: targetRecord.displayName ?? null,
            role,
            addedAt: admin.firestore.FieldValue.serverTimestamp(),
            addedBy: callerUid,
          });
        }
      } catch (e) {
        console.warn("setAdminClaim: failed to update team subcollection", { error: String(e?.message || e) });
      }
    }

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
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
    const isTenantAdmin = callerClaims.role === "tenant_admin";
    const isTenantMember = isTenantAdmin || callerClaims.role === "tenant_collaborator";
    if (!isSuper && !isTenantMember) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    // Rate limit: this endpoint is expensive (paginates Auth or queries Firestore).
    // 30/hour is generous for dashboard polling but blocks runaway scripts.
    await enforceRateLimit(callerUid, "listAdmins", 30, 3600);

    // Helper: build tenant team list from subcollection + first admin from tenant doc
    async function buildTenantTeam(tid) {
      const [teamSnap, tenantDoc] = await Promise.all([
        db.collection("tenants").doc(tid).collection("team").get(),
        db.collection("tenants").doc(tid).get(),
      ]);
      const admins = teamSnap.docs.map((d) => ({ ...d.data() }));
      const firstEmail = tenantDoc.exists ? tenantDoc.data().adminEmail : null;
      if (firstEmail) {
        const existing = admins.find((a) => a.email === firstEmail);
        if (existing) {
          existing.isFirst = true;
        } else {
          try {
            const firstRec = await admin.auth().getUserByEmail(firstEmail);
            admins.unshift({ uid: firstRec.uid, email: firstRec.email, displayName: firstRec.displayName ?? null, role: "tenant_admin", isFirst: true });
          } catch (_) {
            admins.unshift({ uid: firstEmail, email: firstEmail, displayName: null, role: "tenant_admin", isFirst: true });
          }
        }
      }
      return admins;
    }

    // tenant_admin / tenant_collaborator: return their own org's team
    if (!isSuper) {
      const callerTenantId = callerClaims.tenantId;
      if (!callerTenantId) throw new HttpsError("failed-precondition", "Cuenta sin tenantId.");
      return { admins: await buildTenantTeam(callerTenantId) };
    }

    // super_admin with tenantId param: return that org's team
    const requestedTenantId = request.data?.tenantId ?? null;
    if (requestedTenantId) {
      return { admins: await buildTenantTeam(requestedTenantId) };
    }

    // super_admin with no tenantId: return only super admins (paginate Auth)
    const allUsers = [];
    let pageToken;
    let pages = 0;
    const MAX_PAGES = 50;
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
      .filter((u) => u.customClaims?.role === "super_admin" || (u.customClaims?.admin === true && !u.customClaims?.tenantId))
      .map((u) => ({
        uid: u.uid,
        email: u.email,
        displayName: u.displayName,
        role: "super_admin",
        tenantId: null,
      }));

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
    await enforceRateLimit(callerUid, "getAdminStats", 60, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
    const isTenantMember = callerClaims.role === "tenant_admin" || callerClaims.role === "tenant_collaborator";
    if (!isSuper && !isTenantMember) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    // filterTenantId: if super_admin passes a tenantId param, filter to that tenant;
    // if tenant member (admin or collaborator), always filter to their own tenant.
    const filterTenantId = isTenantMember
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
    // Push the tenantId filter down to Firestore when scoped — without this
    // the dashboard reads every tenant's transactions then filters in-memory
    // by tenantUserIds, which scales O(total_txs) instead of O(tenant_txs).
    // Composite index (tenantId + createdAt DESC) is declared in
    // firestore.indexes.json. Falls back to the unscoped read for super_admin
    // viewing the global dashboard.
    let txQuery = db.collectionGroup("transactions")
      .where("createdAt", ">=", sinceTs);
    if (filterTenantId) {
      txQuery = txQuery.where("tenantId", "==", filterTenantId);
    }
    const [usersSnap, txSnap] = await Promise.all([
      usersQuery.get(),
      txQuery.limit(TX_HARD_CAP).get(),
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

    // Monthly buckets for last 12 months — all values in USD
    const monthlyBuckets = {};
    for (let i = 11; i >= 0; i--) {
      const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1));
      const key = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
      monthlyBuckets[key] = { totalUSD: 0, count: 0, tzedaka: 0, pushkaEmpty: 0 };
    }

    let totalMonthUSD = 0;
    let totalLastMonthUSD = 0;
    let totalYearUSD = 0;
    let totalAllTimeUSD = 0;
    const topDonorsMap = {};
    const topDonorsThisMonthMap = {};
    const currencyTotals = {};         // USD equivalent, for sorting/percentage
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

      // Priority: frozen USD snapshot → derive from MXN snapshot → live rate fallback
      let amountUSD;
      if (tx.amountUSD != null) {
        amountUSD = tx.amountUSD;
      } else if (tx.amountMXN != null) {
        amountUSD = tx.amountMXN / mxnRate;
      } else {
        const txRate = rates[txCurrency] ?? 1;
        amountUSD = tx.amount / txRate;
      }

      const txDate = tx.createdAt?.toDate?.() ?? new Date(tx.createdAt);
      const monthKey = `${txDate.getUTCFullYear()}-${String(txDate.getUTCMonth() + 1).padStart(2, "0")}`;

      if (txDate >= startOfMonth) activeThisMonthSet.add(uid);

      if (monthlyBuckets[monthKey]) {
        monthlyBuckets[monthKey].totalUSD += amountUSD;
        monthlyBuckets[monthKey].count++;
        if (tx.type === "tzedaka") monthlyBuckets[monthKey].tzedaka += amountUSD;
        else if (tx.type === "pushkaEmpty") monthlyBuckets[monthKey].pushkaEmpty += amountUSD;
      }

      totalAllTimeUSD += amountUSD;
      if (txDate >= startOfMonth) totalMonthUSD += amountUSD;
      if (txDate >= startOfLastMonth && txDate < startOfMonth) totalLastMonthUSD += amountUSD;
      if (txDate >= startOfYear) totalYearUSD += amountUSD;

      currencyTotals[txCurrency] = (currencyTotals[txCurrency] || 0) + amountUSD;
      currencyTotalsOriginal[txCurrency] = (currencyTotalsOriginal[txCurrency] || 0) + (tx.amount ?? 0);

      if (tx.type === "tzedaka" || tx.type === "pushkaEmpty") {
        if (!topDonorsMap[uid]) {
          topDonorsMap[uid] = {
            uid,
            displayName: userMeta.displayName,
            email: userMeta.email,
            currencyCode: userMeta.currencyCode,
            totalUSD: 0,
            count: 0,
          };
        }
        topDonorsMap[uid].totalUSD += amountUSD;
        topDonorsMap[uid].count++;

        if (txDate >= startOfMonth) {
          if (!topDonorsThisMonthMap[uid]) {
            topDonorsThisMonthMap[uid] = {
              uid,
              displayName: userMeta.displayName,
              email: userMeta.email,
              currencyCode: userMeta.currencyCode,
              totalUSD: 0,
              count: 0,
            };
          }
          topDonorsThisMonthMap[uid].totalUSD += amountUSD;
          topDonorsThisMonthMap[uid].count++;
        }
      }
    }

    const topDonors = Object.values(topDonorsMap)
      .sort((a, b) => b.totalUSD - a.totalUSD)
      .slice(0, 10);

    const topDonorsThisMonth = Object.values(topDonorsThisMonthMap)
      .sort((a, b) => b.totalUSD - a.totalUSD)
      .slice(0, 5);

    const monthlyStats = Object.entries(monthlyBuckets).map(([key, v]) => {
      const [year, month] = key.split("-");
      const date = new Date(Date.UTC(Number(year), Number(month) - 1, 1));
      const label = date.toLocaleDateString("es-ES", { month: "short", year: "numeric" });
      return { month: key, label, ...v };
    });

    const monthGrowth = totalLastMonthUSD > 0
      ? ((totalMonthUSD - totalLastMonthUSD) / totalLastMonthUSD) * 100
      : null;

    return {
      totalUsersCount,
      activeThisMonth: activeThisMonthSet.size,
      newUsersThisMonth,
      newUsersLastMonth,
      totalMonthUSD,
      totalLastMonthUSD,
      totalYearUSD,
      totalAllTimeUSD,
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
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "getRecentTransactions", 60, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
    const isTenantMember = callerClaims.role === "tenant_admin" || callerClaims.role === "tenant_collaborator";
    if (!isSuper && !isTenantMember) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    const filterTenantId = isTenantMember
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
        let amountUSD = tx.amountUSD;
        if (amountUSD == null && tx.amountMXN != null) amountUSD = tx.amountMXN / mxnRate;
        if (amountUSD == null) {
          const txRate = rates[String(tx.currencyCode || "USD").toUpperCase()] ?? 1;
          amountUSD = tx.amount / txRate;
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
          amountUSD: Math.round((amountUSD || 0) * 100) / 100,
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
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "getFailedPayments", 30, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
    const isTenantMember = callerClaims.role === "tenant_admin" || callerClaims.role === "tenant_collaborator";
    if (!isSuper && !isTenantMember) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    const filterTenantId = isTenantMember
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
  { enforceAppCheck: false },
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
    await enforceRateLimit(callerUid, "setUserBlocked", 20, 3600);

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
// TEMP DEBUG: caller inspects their own Stripe customer's payment-method
// list as Stripe sees it right now. Used to diagnose discrepancies between
// listSavedCards and PaymentSheet's saved-cards listing. Remove once the
// off-session-cards bug is closed.
exports.debugInspectCustomerPMs = onCall(
  { secrets: [stripeSecret], enforceAppCheck: true },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "auth requerido");
    const userSnap = await db.collection("users").doc(uid).get();
    const customerId = userSnap.data()?.stripeCustomerId || null;
    if (!customerId) return { customerId: null, error: "no_customer" };
    const stripe = require("stripe")(stripeSecret.value());
    const customer = await stripe.customers.retrieve(customerId);
    const defaultPmId = customer && !customer.deleted
      ? customer.invoice_settings?.default_payment_method || null
      : null;
    const pmList = await stripe.paymentMethods.list({
      customer: customerId, type: "card", limit: 100,
    });
    return {
      customerId,
      customerDeleted: customer && customer.deleted ? true : false,
      defaultPmId,
      pmCount: pmList.data.length,
      pms: pmList.data.map((pm) => ({
        id: pm.id,
        brand: pm.card?.brand || null,
        last4: pm.card?.last4 || null,
        fingerprint: pm.card?.fingerprint || null,
        expMonth: pm.card?.exp_month || null,
        expYear: pm.card?.exp_year || null,
        created: pm.created,
        isDefault: pm.id === defaultPmId,
      })),
    };
  },
);

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
      // First org ever: set as active tenant; apply the tenant's defaults
      // unconditionally. createUserDocument seeds language='es' and
      // currencyCode='USD' as placeholders, so the prior `&& !userData.X`
      // guards never fired — the local-currency-default behavior the UI
      // promises was silently broken. On first tenant join the user is
      // committing to that org, so the tenant's locale is the right
      // baseline; the user can still override it later in Settings.
      if (isFirst) {
        patch.tenantId = tenantId;
        if (tenantData.defaultLanguage) {
          patch.language = tenantData.defaultLanguage;
        }
        if (tenantData.defaultCurrency) {
          patch.currencyCode = String(tenantData.defaultCurrency).toUpperCase();
        }
        if (tenantData.defaultCountry) {
          patch.currencyCountry = tenantData.defaultCountry;
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

      // Atomic totalUsers counter — only for genuinely new members
      tx.update(db.collection("tenants").doc(tenantId), {
        totalUsers: admin.firestore.FieldValue.increment(1),
      });
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
      const wasMember = existing.includes(tenantId);
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

      // Decrement totalUsers only if user was actually a member
      if (wasMember) {
        tx.update(db.collection("tenants").doc(tenantId), {
          totalUsers: admin.firestore.FieldValue.increment(-1),
        });
      }
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
  "donationReasons",
];

// Fields exposed to authenticated users of the tenant (same as public + status
// so members can see if their own tenant is in grace_period / suspended).
const TENANT_MEMBER_FIELDS = [...TENANT_PUBLIC_FIELDS, "status"];

// Fallback donationReasons list. Returned by getTenantConfig (and the public
// branding endpoints) when a tenant doc has no donationReasons set, so every
// org gets a sensible default destinación picker out of the box. The
// backfillDonationReasonsChabad CF stamps this same list onto each tenant doc.
const DEFAULT_CHABAD_DONATION_REASONS = [
  "Donde más se necesite",
  "Comida para familias",
  "Estudios de Torá",
  "Festividades",
  "Edificio / Beit Jabad",
  "Becas para niños",
];

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
  { enforceAppCheck: false, secrets: [stripeConnectClientId, sendgridApiKey] },
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

    // commissionRate is the slice the platform keeps off each donation
    // (e.g. 0.03 = 3 %). The Stripe API max for application_fee_percent
    // is 100 %, but real platforms never get close. Cap at 10 % defensively
    // — anything above that is almost certainly a misconfiguration that
    // would silently siphon donor money to the platform.
    if (commissionRate !== undefined && commissionRate !== null) {
      if (
        typeof commissionRate !== "number" ||
        !Number.isFinite(commissionRate) ||
        commissionRate < 0 ||
        commissionRate > 0.10
      ) {
        throw new HttpsError(
          "invalid-argument",
          "commissionRate debe ser un número entre 0 y 0.10 (0 a 10 %).",
        );
      }
    }
    if (planPrice !== undefined && planPrice !== null) {
      if (
        typeof planPrice !== "number" ||
        !Number.isFinite(planPrice) ||
        planPrice < 0 ||
        planPrice > 100000
      ) {
        throw new HttpsError("invalid-argument", "planPrice inválido.");
      }
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

    // Provision admin account + claims.
    // CRITICAL: setCustomUserClaims REPLACES the entire claims object — naively
    // setting `{ role, tenantId }` would silently strip a super_admin's `admin: true`
    // claim, OR move a tenant_admin from another tenant without warning. We must
    // (a) preserve unrelated claims via spread, and (b) refuse to overwrite an
    // existing tenant_admin assignment to a different tenant — the operator
    // probably typed the wrong email.
    let passwordSetupLink = null;
    try {
      let adminRecord;
      try {
        adminRecord = await admin.auth().getUserByEmail(adminEmail.trim());
      } catch (notFound) {
        if (notFound.code === "auth/user-not-found") {
          // Create the account now so the password-setup link in the welcome email works immediately.
          adminRecord = await admin.auth().createUser({
            email: adminEmail.trim(),
            emailVerified: false,
            displayName: String(appName || name).trim(),
          });
        } else {
          throw notFound;
        }
      }

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

      // Generate a password-setup link (Firebase password reset) for the welcome email.
      try {
        passwordSetupLink = await admin.auth().generatePasswordResetLink(adminEmail.trim());
      } catch (e) {
        console.warn("createTenant: generatePasswordResetLink failed:", e.message);
      }
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      console.warn(`createTenant: account provisioning error for ${_redactEmail(adminEmail)}:`, e.message);
    }

    console.info("createTenant", { id: tenantRef.id, slug: normalizedSlug, adminEmail: _redactEmail(adminEmail) });

    // Generate Stripe Connect link and send welcome email — errors are logged, never thrown.
    const adminPanelUrl = "https://pushka-admin.web.app";
    let stripeConnectUrl = null;
    try {
      const clientId = stripeConnectClientId.value();
      if (clientId && !clientId.startsWith("PLACEHOLDER")) {
        const crypto = require("crypto");
        const state = crypto.randomBytes(20).toString("hex");
        await tenantRef.update({
          stripeConnectOAuthState: state,
          stripeConnectOAuthStateCreatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        const redirectUri = "https://us-central1-pushka-app-ioel.cloudfunctions.net/handleStripeConnectOAuth";
        const params = new URLSearchParams({
          response_type: "code",
          client_id: clientId,
          scope: "read_write",
          state,
          redirect_uri: redirectUri,
        });
        stripeConnectUrl = `https://connect.stripe.com/oauth/authorize?${params.toString()}`;
      }
    } catch (e) {
      console.warn("createTenant: Stripe Connect link generation failed:", e.message);
    }

    try {
      await sendEmail({
        to: adminEmail.trim(),
        subject: `Bienvenido/a a ${tenantData.appName} — Tu panel está listo`,
        html: buildTenantWelcomeEmail({
          appName: tenantData.appName,
          adminEmail: adminEmail.trim(),
          adminPanelUrl,
          passwordSetupLink,
          stripeConnectUrl,
        }),
      });
    } catch (e) {
      console.warn("createTenant: welcome email failed:", e.message);
    }

    await writeActivityLog({
      type: "new_tenant",
      tenantId: tenantRef.id,
      tenantName: tenantData.name,
      severity: "info",
      requiresAction: false,
      data: { adminEmail: adminEmail.trim(), appName: tenantData.appName, slug: normalizedSlug },
    });

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
  { enforceAppCheck: false },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo super_admin.");
    }

    // Sentinel: write a doc when this completes successfully so a later
    // operator can see it has already run (and ops can grep
    // `_backfillRuns/tenantSlugs` to confirm pre-launch readiness).
    // Idempotent: re-running is harmless because the per-slug check below
    // skips already-correct entries; the sentinel just records the latest run.
    const sentinelRef = db.collection("_backfillRuns").doc("tenantSlugs");
    const sentinelSnap = await sentinelRef.get();
    const previousRun = sentinelSnap.exists
      ? {
          completedAt: sentinelSnap.data()?.completedAt?.toDate?.()?.toISOString() ?? null,
          createdLastRun: sentinelSnap.data()?.created ?? null,
        }
      : null;

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
      previousRun, // null on first run; otherwise prior completedAt/created
    };
    console.info("backfillTenantSlugs: completed", summary);
    // Stamp sentinel — only if there were no conflicts (a conflicting slug
    // means the backfill is incomplete; keep the prior sentinel state so
    // ops know reconciliation is still pending).
    if (conflicts.length === 0) {
      await sentinelRef.set({
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
        scanned,
        created,
        skippedAlreadyExists: skipped,
        skippedNoSlug,
        runByUid: request.auth?.uid ?? null,
      }, { merge: true });
    }
    return summary;
  },
);

// ---------------------------------------------------------------------------
// backfillDonationReasonsChabad — one-shot super_admin operation: stamp the
// default Chabad-style DEFAULT_CHABAD_DONATION_REASONS on every tenant that
// doesn't already have one configured. Idempotent (skips tenants where the
// field is a non-empty array). Optional: getTenantConfig already returns the
// same fallback at read-time, so the backfill is mainly for keeping the
// admin-facing tenant docs self-describing.
// ---------------------------------------------------------------------------
exports.backfillDonationReasonsChabad = onCall(
  { enforceAppCheck: true },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo super_admin.");
    }

    const tenantsSnap = await db.collection("tenants").get();
    let scanned = 0;
    let updated = 0;
    let skipped = 0;

    for (const tenantDoc of tenantsSnap.docs) {
      scanned += 1;
      const existing = tenantDoc.data()?.donationReasons;
      if (Array.isArray(existing) && existing.length > 0) {
        skipped += 1;
        continue;
      }
      await tenantDoc.ref.set({
        donationReasons: DEFAULT_CHABAD_DONATION_REASONS,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      updated += 1;
    }

    const summary = { scanned, updated, skippedAlreadyConfigured: skipped };
    console.info("backfillDonationReasonsChabad: completed", summary);
    return summary;
  },
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
      "setupFee", "setupFeeDate", "subscriptionMonthlyAmount",
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
      // Mirror createTenant's defensive bounds on financial fields. A
      // commissionRate >= 1 would let the platform skim 100 %+ of donations;
      // an unbounded planPrice could be set to e.g. 10 ** 9 by accident.
      // Tenant_admin already can't write these (filtered by `allowed`), but
      // a super_admin typo here would silently corrupt billing for every
      // donor of this tenant — fail loud instead.
      if (key === "commissionRate") {
        if (typeof val !== "number" || !Number.isFinite(val) || val < 0 || val > 0.10) {
          throw new HttpsError("invalid-argument", "commissionRate debe ser un número entre 0 y 0.10 (0 a 10 %).");
        }
      }
      if (key === "planPrice" || key === "setupFee" || key === "subscriptionMonthlyAmount") {
        if (val !== null && (typeof val !== "number" || !Number.isFinite(val) || val < 0 || val > 100000)) {
          throw new HttpsError("invalid-argument", `${key} inválido.`);
        }
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
    // Rate-limit by IP to slow slug enumeration. App Check alone isn't a
    // brute-force defense — a determined attacker with a valid debug token
    // could iterate dictionary slugs ("jabad", "jabadmexico", ...) and
    // discover tenant existence. 60/5min is generous for legit join flows
    // (a user typically tries 1–3 slugs before giving up) but caps a
    // scraping client at ~17k attempts/day per IP.
    await enforceRateLimitByIp(request, "getTenantBySlug", 60, 300);

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
    // Default donationReasons to the Chabad fallback when the tenant doc
    // doesn't have one (or has an empty array). Keeps every org's donation
    // flow with a usable destinación picker out of the box; admins can
    // override by writing the field on the tenant doc.
    if (!Array.isArray(config.donationReasons) || config.donationReasons.length === 0) {
      config.donationReasons = DEFAULT_CHABAD_DONATION_REASONS;
    }

    return { tenantId, config, tenantIds };
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
    await enforceRateLimit(callerUid, "listTenants", 60, 3600);

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
// getSuperAdminDashboard — per-tenant stats for the super admin view
// ---------------------------------------------------------------------------
exports.getSuperAdminDashboard = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    if (!callerIsSuperAdmin(request)) throw new HttpsError("permission-denied", "Solo el super administrador.");
    await enforceRateLimit(callerUid, "getSuperAdminDashboard", 60, 3600);

    const now = new Date();

    const tenantsSnap = await db.collection("tenants").get();

    // Helper: sum revenueStats monthly buckets for the last N months (current month = i=0).
    // monthsBack=1 → current month only, monthsBack=3 → current + 2 back, etc.
    function sumMonths(revenueStats, monthsBack) {
      let total = 0;
      for (let i = 0; i < monthsBack; i++) {
        const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1));
        const key = `${d.getUTCFullYear()}_${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
        total += (revenueStats[key]?.revenue || 0);
      }
      return total;
    }

    const tenantStats = await Promise.all(
      tenantsSnap.docs.map(async (tenantDoc) => {
        const tid        = tenantDoc.id;
        const tenantData = tenantDoc.data();
        const tenantName = tenantData.name ?? tid;
        const appName    = tenantData.appName ?? tenantName;
        const revenueStats = tenantData.revenueStats || {};

        // totalUsers and activeUsersThisMonth are pre-aggregated on the tenant doc —
        // no user/transaction queries needed. O(1) per tenant.
        const totalUsers      = typeof tenantData.totalUsers === "number" ? tenantData.totalUsers : 0;
        const activeThisMonth = typeof tenantData.activeUsersThisMonth === "number" ? tenantData.activeUsersThisMonth : 0;

        return {
          tenantId:   tid,
          tenantName,
          appName,
          totalUsers,
          activeThisMonth,
          revenueLastMonth:          Math.round(sumMonths(revenueStats, 1)  * 100) / 100,
          revenueLastThreeMonths:    Math.round(sumMonths(revenueStats, 3)  * 100) / 100,
          revenueLastSixMonths:      Math.round(sumMonths(revenueStats, 6)  * 100) / 100,
          revenueLastYear:           Math.round(sumMonths(revenueStats, 12) * 100) / 100,
          revenueAllTime:            Math.round((revenueStats.allTime?.revenue || 0) * 100) / 100,
          status:                    tenantData.status ?? "active",
          paymentStatus:             tenantData.paymentStatus ?? null,
          gracePeriodEndsAt:         tenantData.gracePeriodEndsAt?.toDate?.()?.toISOString() ?? null,
          stripeConnectStatus:       tenantData.stripeConnectStatus ?? null,
          commissionRate:            tenantData.commissionRate ?? 0,
          setupFee:                  tenantData.setupFee ?? 0,
          setupFeeDate:              tenantData.setupFeeDate ?? null,
          subscriptionMonthlyAmount: tenantData.subscriptionMonthlyAmount ?? 0,
          tenantCreatedAt:           tenantData.createdAt?.toDate?.()?.toISOString() ?? null,
        };
      })
    );

    return { stats: tenantStats };
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
    // Write path (creates a Stripe Connect OAuth link tied to a tenant) —
    // must reject a recently-demoted super_admin immediately, not after the
    // 1h ID-token cache expires. Fresh check reads customClaims directly
    // from Auth.
    const isSuperAdminCaller = await callerIsSuperAdminFresh(request);
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
// buildTenantWelcomeEmail — HTML email sent to new tenant admins on onboarding
// ---------------------------------------------------------------------------
function buildTenantWelcomeEmail({ appName, adminEmail, adminPanelUrl, passwordSetupLink, stripeConnectUrl }) {
  const stepNum = (n) => passwordSetupLink ? String(n) : String(n - 1);

  const passwordBlock = passwordSetupLink
    ? `<div style="background:#f8fafc;border-radius:12px;padding:20px;margin-bottom:16px;border-left:4px solid #3b82f6;">
        <p style="margin:0 0 6px;font-weight:700;color:#1e293b;font-size:14px;">1. Configurá tu contraseña</p>
        <p style="margin:0 0 14px;color:#64748b;font-size:13px;line-height:1.5;">Hacé clic para crear tu contraseña y acceder al panel de control.</p>
        <a href="${passwordSetupLink}" style="display:inline-block;background:#3b82f6;color:#fff;padding:11px 22px;border-radius:8px;text-decoration:none;font-size:13px;font-weight:600;">Crear contraseña →</a>
      </div>`
    : "";

  const panelStep = passwordSetupLink ? "2" : "1";
  const stripeStep = passwordSetupLink ? "3" : "2";

  const stripeBlock = stripeConnectUrl
    ? `<div style="background:#f8fafc;border-radius:12px;padding:20px;margin-bottom:16px;border-left:4px solid #8b5cf6;">
        <p style="margin:0 0 6px;font-weight:700;color:#1e293b;font-size:14px;">${stripeStep}. Conectá tu cuenta de Stripe</p>
        <p style="margin:0 0 14px;color:#64748b;font-size:13px;line-height:1.5;">Para recibir los pagos de tus donantes directamente en tu cuenta bancaria.</p>
        <a href="${stripeConnectUrl}" style="display:inline-block;background:#8b5cf6;color:#fff;padding:11px 22px;border-radius:8px;text-decoration:none;font-size:13px;font-weight:600;">Conectar Stripe →</a>
      </div>`
    : "";

  return `<!DOCTYPE html>
<html lang="es">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:32px 16px;background:#f1f5f9;font-family:Inter,Arial,Helvetica,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
  <table width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border-radius:20px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,0.08);">
    <tr>
      <td style="background:linear-gradient(135deg,#1e3a5f 0%,#1e40af 100%);padding:36px 40px;text-align:center;">
        <p style="margin:0 0 10px;color:#93c5fd;font-size:12px;letter-spacing:1.5px;text-transform:uppercase;font-weight:600;">Plataforma de donaciones</p>
        <h1 style="margin:0;color:#ffffff;font-size:26px;font-weight:700;line-height:1.2;">${appName}</h1>
        <p style="margin:12px 0 0;color:#bfdbfe;font-size:14px;">Tu panel de control ya está activo ✓</p>
      </td>
    </tr>
    <tr>
      <td style="padding:36px 40px;">
        <p style="margin:0 0 6px;color:#1e293b;font-size:15px;font-weight:600;">¡Bienvenido/a!</p>
        <p style="margin:0 0 28px;color:#64748b;font-size:14px;line-height:1.6;">
          Tu organización <strong style="color:#1e293b;">${appName}</strong> está configurada en la plataforma.
          Seguí estos pasos para empezar a recibir donaciones.
        </p>

        ${passwordBlock}

        <div style="background:#f8fafc;border-radius:12px;padding:20px;margin-bottom:16px;border-left:4px solid #10b981;">
          <p style="margin:0 0 6px;font-weight:700;color:#1e293b;font-size:14px;">${panelStep}. Accedé al panel de control</p>
          <p style="margin:0 0 4px;color:#64748b;font-size:13px;">Tu email de acceso: <strong style="color:#1e293b;">${adminEmail}</strong></p>
          <p style="margin:0 0 14px;color:#64748b;font-size:13px;line-height:1.5;">Desde acá vas a ver métricas, donaciones y configuración de tu organización.</p>
          <a href="${adminPanelUrl}" style="display:inline-block;background:#10b981;color:#fff;padding:11px 22px;border-radius:8px;text-decoration:none;font-size:13px;font-weight:600;">Ir al panel →</a>
        </div>

        ${stripeBlock}

        <div style="margin-top:32px;padding-top:24px;border-top:1px solid #e2e8f0;text-align:center;">
          <p style="margin:0;color:#94a3b8;font-size:12px;line-height:1.6;">
            ¿Tenés dudas? Contactá a tu asesor de Pushka.<br>
            Este email fue generado automáticamente al activar tu organización.
          </p>
        </div>
      </td>
    </tr>
  </table>
  </td></tr></table>
</body>
</html>`;
}

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
  { secrets: [stripeSecret], enforceAppCheck: false },
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
    let eventRef, alreadyProcessed;
    try {
      ({ eventRef, alreadyProcessed } = await reserveWebhookEvent(event));
    } catch (reserveErr) {
      console.error("stripeBillingWebhook: reserveWebhookEvent failed", {
        eventId: event?.id, type: event?.type, err: reserveErr?.message,
      });
      return res.status(400).send("Invalid event id format.");
    }
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

      const tenantSnapPS = await db.collection("tenants").doc(tenantId).get();
      const tenantNamePS = tenantSnapPS.data()?.name ?? tenantId;
      const amountPaid = (invoice.amount_paid ?? 0) / 100;
      await writeActivityLog({
        type: "payment_succeeded",
        tenantId,
        tenantName: tenantNamePS,
        severity: "info",
        requiresAction: false,
        data: { amountUSD: amountPaid, invoiceId: invoice.id, nextDue: nextDue.toISOString() },
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

      await writeActivityLog({
        type: "payment_failed",
        tenantId,
        tenantName: tenantData.name ?? tenantId,
        severity: "critical",
        requiresAction: true,
        data: {
          adminEmail: tenantData.adminEmail ?? null,
          gracePeriodEndsAt: gracePeriodEndsAt.toISOString(),
          invoiceId: invoice.id,
        },
      });

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

        await writeActivityLog({
          type: "tenant_suspended",
          tenantId: doc.id,
          tenantName: tenantName,
          severity: "critical",
          requiresAction: true,
          data: { adminEmail: adminEmail ?? null, reason: "grace_period_expired" },
        });

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


// ---------------------------------------------------------------------------
// resolveActivityItem — super_admin marks an activity log item as resolved
// ---------------------------------------------------------------------------
exports.resolveActivityItem = onCall(
  { enforceAppCheck: false },
  async (request) => {
    // Write path — use the Auth-fresh check so a recently-demoted admin
    // can't keep marking activity items resolved during the ID-token TTL.
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo el super administrador.");
    }
    const { id } = request.data ?? {};
    if (!id || typeof id !== "string") {
      throw new HttpsError("invalid-argument", "id requerido.");
    }
    const ref = db.collection("_activityLog").doc(id);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Item no encontrado.");
    await ref.update({
      resolved: true,
      resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { success: true };
  }
);
