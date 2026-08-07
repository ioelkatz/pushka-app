const admin = require("firebase-admin");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated, onDocumentUpdated, onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { DateTime } = require("luxon");

const stripeSecret = defineSecret("STRIPE_SECRET_KEY");
const stripeWebhookSecret = defineSecret("STRIPE_WEBHOOK_SECRET");
const stripeBillingWebhookSecret = defineSecret("STRIPE_BILLING_WEBHOOK_SECRET");
const stripeConnectClientId = defineSecret("STRIPE_CONNECT_CLIENT_ID");
const sendgridApiKey = defineSecret("SENDGRID_API_KEY");

admin.initializeApp();

const db = admin.firestore();
const messaging = admin.messaging();

// In-memory per-instance cache of tenant appName, used by onTransactionCreated
// to avoid a Firestore read on every donation notification. TTL keeps stale
// data bounded (onTenantBrandingUpdated propagates changes within seconds via
// user-side denorm; this fallback tolerates a few-minute lag on the title).
const _tenantAppNameCache = new Map();
const TENANT_APPNAME_TTL_MS = 5 * 60 * 1000; // 5 minutes

// ---------------------------------------------------------------------------
// Stripe error shape helpers
// ---------------------------------------------------------------------------
/**
 * True when a Stripe error indicates the referenced resource no longer exists
 * on Stripe's side (customer deleted, mode mismatch, stale ID from a restore).
 * Callers use this to distinguish "the customer is genuinely gone → clear our
 * cached ID and rebuild" from a generic Stripe outage that should be retried.
 */
function _isStripeResourceMissing(e) {
  if (!e) return false;
  if (e.statusCode === 404) return true;
  if (e.code === "resource_missing") return true;
  if (e.type === "StripeInvalidRequestError" &&
      typeof e.raw?.code === "string" &&
      e.raw.code.includes("resource_missing")) return true;
  return false;
}

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
 *
 * Round-6 audit HIGH fix: X-Forwarded-For is a chain "client, proxy1, proxy2".
 * The client controls the FIRST entry (they can prepend fake values), so
 * picking the leftmost lets an attacker bypass the rate limit trivially by
 * rotating fake IPs. On Cloud Functions / Cloud Run, the RIGHTMOST entry is
 * the trusted edge-proxy IP that fronted the request — use that instead.
 * Fall back to raw connection IP (also trusted) when the header is absent.
 */
async function enforceRateLimitByIp(request, action, maxCalls, windowSeconds) {
  const fwd = request.rawRequest?.headers?.["x-forwarded-for"];
  const chain = (Array.isArray(fwd) ? fwd.join(",") : (fwd || ""))
    .split(",").map((s) => s.trim()).filter((s) => s.length > 0);
  // Rightmost entry = trusted edge (Cloud Run adds one hop). Anything to
  // the left is client-supplied and forgeable.
  const ip = chain.length > 0
    ? chain[chain.length - 1]
    : (request.rawRequest?.ip || "unknown");
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

// Max PRÁCTICO por transacción en la unidad menor de cada moneda
// (~USD $1000 equivalent). Pre-launch sideload hardening: sin App Check
// robusto de Play Integrity/App Attest, un attacker con cuenta Firebase
// válida podía llamar createPaymentIntent con amountCents: 99999999
// (=~$999k USD). Ahora el server rechaza cualquier monto por encima del
// tope realista de la moneda. Tenants con casos legítimos > $1000 USD
// deberían usar el flujo de subscription mensual o contactarnos para
// aumentar el cap.
// NOTE on units: values are in Stripe's smallest unit for the currency.
//   - 2-decimal currencies (usd/eur/mxn/brl/ils/…): value / 100 = major amount
//   - zero-decimal currencies (clp/jpy/krw/…): value == major amount
//   - three-decimal currencies (bhd/jod/…): value / 1000 = major amount
// Round-4 audit fix: `clp: 90000000` was 100× the intended cap (~USD $100k
// instead of ~USD $1k) because CLP is zero-decimal, not 2-decimal.
const CURRENCY_MAX_AMOUNTS = {
  usd: 100000,     // $1000
  eur: 100000,     // €1000
  gbp: 80000,      // £800
  cad: 130000,     // C$1300
  ils: 350000,     // ₪3500
  mxn: 2000000,    // MX$20000 (~USD $1000)
  brl: 500000,     // R$5000
  ars: 100000000,  // AR$1M (~USD $1000)
  clp: 900000,     // CLP $900000 (zero-decimal → value == amount, ~USD $1000)
  cop: 400000000,  // COP $4M (~USD $1000) — 2-decimal, value/100 = COP major
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
/**
 * Direct Charges helper: resolve the connect-account customer context for a
 * given uid. Reads users/{uid}.tenantId, then tenants/{tid}.stripeConnectAccountId,
 * then users/{uid}/tenantState/{tid}.stripeConnectCustomerId.
 *
 * Returns { tenantId, tenantConnectAccountId, stripeReqOpts, tenantStateRef,
 * customerId } or null when the user has no active tenant / connect setup.
 *
 * customerId may be null even when the rest is set — caller should decide
 * whether to create-or-fail. All Stripe API calls MUST spread stripeReqOpts
 * as the options arg so the request targets the connected account instead of
 * the platform. Missing this is the #1 direct-charges bug — Stripe returns
 * "no such customer" because customers live per-account, not on the platform.
 */
async function _resolveConnectCustomerContext(uid) {
  const userSnap = await db.collection("users").doc(uid).get();
  const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
  const tenantId = userData.tenantId ?? null;
  if (!tenantId) return null;

  const tenantSnap = await db.collection("tenants").doc(tenantId).get();
  const tenantData = tenantSnap.exists ? (tenantSnap.data() ?? {}) : {};
  const tenantConnectAccountId = tenantData.stripeConnectAccountId || null;
  if (!tenantConnectAccountId || tenantData.stripeConnectStatus !== "active") {
    return null;
  }

  const tenantStateRef = db.collection("users").doc(uid)
    .collection("tenantState").doc(tenantId);
  const tenantStateSnap = await tenantStateRef.get();
  const customerId = tenantStateSnap.data()?.stripeConnectCustomerId || null;

  return {
    tenantId,
    tenantConnectAccountId,
    stripeReqOpts: { stripeAccount: tenantConnectAccountId },
    tenantStateRef,
    tenantStateSnap,
    customerId,
    userData,
  };
}

function safeTenantCommissionRate(rawRate, tenantIdForLog) {
  // Accepts 0–30% (matches the admin web validator in TenantDetailPage).
  // Pre-fix the backend only accepted up to 10% and silently clamped to 3%
  // when over — admin web could let super_admin set 0.25 and donors would
  // unknowingly be charged 0.03. Now super_admin's intent is honored.
  // commissionRate === 0 is supported explicitly (free tier, no platform fee).
  const r = typeof rawRate === "number" ? rawRate : NaN;
  if (Number.isFinite(r) && r >= 0 && r <= 0.30) return r;
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

// Segundo tope, complementa el check numérico global. Fallback conservador
// para monedas no listadas: 100000 cents (~$1000 USD equivalent aproximado).
function maxAmountForCurrency(currency) {
  const code = String(currency || "usd").toLowerCase();
  return CURRENCY_MAX_AMOUNTS[code] ?? 100000;
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

// Returns [{ token, platform }] — platform ∈ 'android' | 'ios' | 'web' |
// undefined (legacy tokens without the field). sendToUser routes payloads
// differently by platform to prevent the "double notification" bug in web
// (browser auto-shows the notification block AND the SW's onBackgroundMessage
// handler also calls showNotification). Native builds still need the
// notification block because their OS displays it while the app is closed
// via the SDK's built-in handler (avoids requiring Flutter background isolate).
async function getUserTokens(uid, opts = {}) {
  // Blocked users (setUserBlocked CF writes users/{uid}.isBlocked) should NOT
  // receive any pushes — otherwise reminders and payment notifications keep
  // reaching them and expose data they shouldn't see. Weekly summaries go via
  // email (see the digest CF further down) so they don't route through here.
  // Check BEFORE the fcmTokens read so we short-circuit early. Non-fatal: if
  // the check itself fails, fall through and let the send happen (better
  // than silently dropping notifications on a transient Firestore blip).
  //
  // Round-10 audit fix (MEDIUM #3): callers that already checked isBlocked
  // (e.g. processDueReminders pre-filters uids once per tick) can skip the
  // internal re-check by passing `skipBlockedCheck: true`. Without this,
  // the pre-filter is redundant — same uid billed twice per fire.
  if (opts.skipBlockedCheck !== true) {
    try {
      const userSnap = await db.collection("users").doc(uid).get();
      if (userSnap.exists && userSnap.data()?.isBlocked === true) {
        return [];
      }
    } catch (_) { /* fall through */ }
  }

  // Round-6 audit LOW fix: cap at 500 tokens. FCM sendEachForMulticast has
  // a 500-token hard limit per call; a user with more (e.g. a bug that
  // wrote per-launch instead of per-device) would silently fail-send to
  // everyone above the cap. Prefer most-recently-used so active devices
  // still receive pushes.
  const snap = await db
    .collection("users")
    .doc(uid)
    .collection("fcmTokens")
    .orderBy("lastUsedAt", "desc")
    .limit(500)
    .get()
    .catch(async (_) => {
      // Fallback if the lastUsedAt index is missing on legacy user docs —
      // plain read up to 500 (no ordering) is still better than the
      // unbounded original.
      return db.collection("users").doc(uid).collection("fcmTokens").limit(500).get();
    });

  return snap.docs
    .map((doc) => ({ token: doc.id, platform: doc.get("platform") }))
    .filter((t) => t.token);
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

// Web-safe payload: hoist notification.title/body into data.* and drop the
// notification block entirely. The firebase-messaging-sw.js reads
// data.title/data.body as fallbacks and calls self.registration.showNotification
// once — no duplicate. Native tokens (or unknown platform, treated as native
// for backwards-compat safety) keep the notification block so the OS can
// display while the app is closed.
function flattenPayloadForWeb(payload) {
  const notif = payload.notification || {};
  const flatData = {
    ...(payload.data || {}),
    ...(notif.title ? { title: String(notif.title) } : {}),
    ...(notif.body ? { body: String(notif.body) } : {}),
  };
  const cleaned = { ...payload, data: flatData };
  delete cleaned.notification;
  return cleaned;
}

async function sendToUser(uid, payload, opts = {}) {
  // opts.skipBlockedCheck: caller (e.g. processDueReminders) has already
  // filtered blocked uids for this tick — avoid billing the same read twice.
  const tokenInfos = await getUserTokens(uid, opts);
  if (tokenInfos.length === 0) return { successCount: 0 };

  // Split tokens by web vs native. Unknown platform falls into native (safe
  // default per adversarial review R-4: notification block preserves iOS
  // wake-app behavior; the worst case is a legacy user with an unclassified
  // Chrome token seeing the old-behavior duplicate — same as today).
  const webTokens = tokenInfos
    .filter((t) => t.platform === "web")
    .map((t) => t.token);
  const nativeTokens = tokenInfos
    .filter((t) => t.platform !== "web")
    .map((t) => t.token);

  const sends = [];
  if (nativeTokens.length > 0) {
    sends.push(
      messaging
        .sendEachForMulticast({ tokens: nativeTokens, ...payload })
        .then((response) => cleanupInvalidTokens(uid, nativeTokens, response).then(() => response))
    );
  }
  if (webTokens.length > 0) {
    const webPayload = flattenPayloadForWeb(payload);
    sends.push(
      messaging
        .sendEachForMulticast({ tokens: webTokens, ...webPayload })
        .then((response) => cleanupInvalidTokens(uid, webTokens, response).then(() => response))
    );
  }

  const results = await Promise.all(sends);
  const successCount = results.reduce((n, r) => n + (r.successCount || 0), 0);
  return { successCount, responses: results };
}

// Stuck-event TTL: if a previous delivery crashed between reserveWebhookEvent
// and finalizeWebhookEvent, the doc stays in "processing" forever and every
// Stripe retry no-ops with `alreadyProcessed=true` — silently dropping the
// event. After this many ms in `processing` we treat it as orphaned and let
// the current invocation re-attempt processing.
const WEBHOOK_PROCESSING_TTL_MS = 5 * 60 * 1000; // 5 minutes — well over function timeout

// Direct Charges platform commission calculator. Single source of truth so
// createPaymentIntent, createDonationSubscription, createCheckoutSession and
// processPushkaAutoEmpty all clamp the same way. Returns:
//   null            → do NOT set application_fee_amount (commissionRate=0 or
//                      rounding produced 0 — the chabadmexico 0% path).
//   { fee, ... }    → set application_fee_amount = fee.
//
// Enforcing this via a helper (not three inline copies) is what keeps the
// Apple non-profit fee waiver contract: if any future change accidentally
// starts skimming from Jym Inc., the unit tests around this function fail.
function computeApplicationFeeAmount(amountMinor, commissionRate) {
  if (!Number.isFinite(amountMinor) || amountMinor <= 0) return null;
  if (!Number.isFinite(commissionRate) || commissionRate <= 0) return null;
  const rawFee = Math.floor(amountMinor * commissionRate);
  if (rawFee <= 0) return null;
  const safeFee = Math.min(rawFee, amountMinor - 1);
  return { fee: safeFee, rawFee, clamped: safeFee !== rawFee };
}

// Test hook — exposes internal helpers to the unit test suite without
// forcing the whole module to load Firebase credentials. Kept private-ish
// via a namespaced key so nothing outside `functions/test/**` uses it.
module.exports.__testables = { computeApplicationFeeAmount };

// Shared revenue mutator — runs inside a caller-provided transaction.
// Reads the tenant doc, computes flat + nested deltas, and writes them
// atomically alongside whatever else the caller commits in the same tx
// (usually the eventRef guard flag). This is what makes the guard truly
// atomic: no window where the flag is set but the counters aren't.
//
// stampDate controls which nested bucket receives the delta:
//   - undefined (default) → stamp under the CURRENT month/year (fresh donation).
//   - Date instance      → stamp under that date's month/year (dispute reinstate,
//                          refund of a prior-month donation). Keeps the nested
//                          allTime + suma-de-meses net-accurate.
//
// Flat top-level fields (monthRevenueUSD / yearRevenueUSD / allTimeRevenueUSD)
// only change when the stamped bucket matches the tenant's current bucket key
// — refunds/reinstates that fall outside the current month don't time-travel
// the "this month" real-time KPI. allTimeRevenueUSD always shifts (clamped ≥ 0).
function _applyRevenueMutationInTx(tx, tenantRef, tenantSnap, amountUSD, direction, stampDate) {
  const now = new Date();
  const nowMonthKey = `${now.getUTCFullYear()}_${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
  const nowYearKey  = `${now.getUTCFullYear()}`;
  const stamp = stampDate instanceof Date ? stampDate : now;
  const stampMonthKey = `${stamp.getUTCFullYear()}_${String(stamp.getUTCMonth() + 1).padStart(2, "0")}`;
  const stampYearKey  = `${stamp.getUTCFullYear()}`;
  const isFreshDonation = direction === "increment" && !stampDate;

  const data = tenantSnap.exists ? tenantSnap.data() : {};
  const prevMonthKey = data?.monthYearKey || null;
  const prevYearKey  = data?.yearKey || null;
  const prevMonth = Number(data?.monthRevenueUSD) || 0;
  const prevYear  = Number(data?.yearRevenueUSD)  || 0;
  const prevAll   = Number(data?.allTimeRevenueUSD) || 0;

  const sign = direction === "decrement" ? -1 : 1;
  const delta = sign * amountUSD;

  let monthValue;
  let yearValue;
  if (isFreshDonation) {
    monthValue = prevMonthKey === nowMonthKey ? prevMonth + amountUSD : amountUSD;
    yearValue  = prevYearKey  === nowYearKey  ? prevYear  + amountUSD : amountUSD;
  } else {
    // Only shift the flat bucket when the stamped delta belongs to the SAME
    // bucket the tenant is currently accumulating into. This fixes the
    // divergence where a Feb refund of a Jan donation used to decrement
    // allTime but leave the flat monthRevenueUSD stale.
    const monthMatches = prevMonthKey === stampMonthKey && prevMonthKey === nowMonthKey;
    const yearMatches  = prevYearKey  === stampYearKey  && prevYearKey  === nowYearKey;
    monthValue = monthMatches ? Math.max(0, prevMonth + delta) : prevMonth;
    yearValue  = yearMatches  ? Math.max(0, prevYear  + delta) : prevYear;
  }
  const allValue = Math.max(0, prevAll + delta);

  const updates = {
    // Nested map — stamped under stampMonthKey so historical buckets stay
    // net-accurate. Fresh donations also bump the count.
    [`revenueStats.${stampMonthKey}.revenue`]: admin.firestore.FieldValue.increment(delta),
    "revenueStats.allTime.revenue":            admin.firestore.FieldValue.increment(delta),
    monthRevenueUSD: monthValue,
    yearRevenueUSD: yearValue,
    allTimeRevenueUSD: allValue,
  };
  if (isFreshDonation) {
    updates[`revenueStats.${stampMonthKey}.count`] = admin.firestore.FieldValue.increment(1);
    updates["revenueStats.allTime.count"]          = admin.firestore.FieldValue.increment(1);
    updates.monthYearKey = nowMonthKey;
    updates.yearKey      = nowYearKey;
    updates.lastDonationAt = admin.firestore.FieldValue.serverTimestamp();
  } else {
    if (!prevMonthKey) updates.monthYearKey = nowMonthKey;
    if (!prevYearKey)  updates.yearKey      = nowYearKey;
  }
  tx.set(tenantRef, updates, { merge: true });
}

// BUG #3/#7/#8/#9 fix + Round-2 audit follow-ups: fully-atomic idempotent
// revenue mutation. Reads the eventRef guard AND the tenant doc, applies
// both the guard flag and the flat+nested counter deltas in a SINGLE
// transaction. Two consequences vs the old two-phase design:
//
//   1. If the transaction fails (Firestore contention, network hiccup,
//      instance crash), NEITHER the guard nor the counters change. The
//      error propagates → the outer webhook catches → status='failed' →
//      Stripe retries → next delivery gets a clean shot at both writes.
//      No more silent under-application when the guard tx succeeds but
//      the counter mutation dies afterward.
//
//   2. Stripe retries are correctly deduped: on the second delivery the
//      tx reads revenueApplied=true and no-ops.
//
// Callers should NOT wrap this in a swallowing try/catch — that would
// re-open the silent-loss hole. If a caller absolutely needs to survive
// a Firestore failure (very rare), let the outer webhook handler retry.
async function applyRevenueDeltaOnce(eventRef, tenantId, amountUSD, direction /* 'increment' | 'decrement' */, opts = {}) {
  if (!tenantId || !Number.isFinite(amountUSD) || amountUSD <= 0) return false;
  const stampDate = opts.originalDate instanceof Date ? opts.originalDate : null;
  let applied = false;
  await db.runTransaction(async (tx) => {
    const tenantRef = db.collection("tenants").doc(tenantId);
    const evSnap = await tx.get(eventRef);
    if (evSnap.exists && evSnap.data()?.revenueApplied === true) return;
    const tenantSnap = await tx.get(tenantRef);
    _applyRevenueMutationInTx(tx, tenantRef, tenantSnap, amountUSD, direction, stampDate);
    tx.set(eventRef, {
      revenueApplied: true,
      revenueAppliedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    applied = true;
  });
  return applied;
}

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
      if (status === "processed" || status === "skipped" || status === "ignored") {
        alreadyProcessed = true;
        return;
      }

      // Previously-failed events: allow Stripe retries to re-process them.
      // Without this, a transient Firestore failure during webhook processing
      // would permanently lose the event — Stripe retries are silently dropped,
      // and confirmed payments would never be written to Firestore.
      if (status === "failed") {
        recoveredFromStuck = true;
        tx.set(eventRef, {
          status: "processing",
          recoveredFromFailed: true,
          recoveredAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
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

async function resolveUidFromCharge(charge, stripe, reqOpts = {}) {
  // Direct Charges: sub-object retrieves must include {stripeAccount} when
  // the source charge came from a connected account. Callers in the webhook
  // pass reqOpts = { stripeAccount: event.account }; other callers can pass
  // {} for platform-only lookups.
  const chargeUid = charge?.metadata?.uid;
  if (chargeUid) return chargeUid;

  const paymentIntentId = typeof charge?.payment_intent === "string" ?
    charge.payment_intent :
    charge?.payment_intent?.id;
  if (paymentIntentId) {
    try {
      const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId, reqOpts);
      const piUid = paymentIntent?.metadata?.uid;
      if (piUid) return piUid;
    } catch (_) { /* fall through to invoice/subscription lookup */ }
  }

  const invoiceId = typeof charge?.invoice === "string"
    ? charge.invoice
    : charge?.invoice?.id;
  if (invoiceId) {
    try {
      const invoice = await stripe.invoices.retrieve(invoiceId, reqOpts);
      const subId = typeof invoice?.subscription === "string"
        ? invoice.subscription
        : invoice?.subscription?.id;
      if (subId) {
        const sub = await stripe.subscriptions.retrieve(subId, reqOpts);
        if (sub?.metadata?.uid) return sub.metadata.uid;
      }
    } catch (_) { /* ignore */ }
  }
  return null;
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
  // ttlAt: lets us flip on a Firestore TTL policy without code changes.
  // Critical / requires-action entries are kept indefinitely (set null) so
  // ops never lose an unresolved alert. Everything else expires after 90
  // days — plenty for audit + reconciliation, beyond which Cloud Logging
  // (1y default) is the long-term record.
  const isPermanent = severity === "critical" || requiresAction === true;
  const ninetyDaysMs = 90 * 24 * 60 * 60 * 1000;
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
    ttlAt: isPermanent ? null : admin.firestore.Timestamp.fromMillis(Date.now() + ninetyDaysMs),
  });

  // Fire-and-forget email alert for critical events. Existing chargeback
  // + tenant billing alerts already email separately; this catches the
  // long-tail (stripe_connect_restricted, drift detection, backfill
  // conflicts, etc). Deduped by type+ref via a rate-limit sentinel so
  // a burst doesn't spam the inbox.
  if (severity === "critical" || requiresAction === true) {
    try {
      const dataObj = data && typeof data === "object" ? data : {};
      const refId = dataObj.transactionId || dataObj.tenantId || dataObj.id ||
        dataObj.chargeId || dataObj.paymentIntentId || tenantId || "global";
      const alertKey = `${type}:${refId}`
        .replace(/[/#[\]*]/g, "_")
        .slice(0, 300); // Firestore doc id constraints
      const alertRef = db.collection("_activityAlertRate").doc(alertKey);
      const snap = await alertRef.get().catch(() => null);
      const now = Date.now();
      const lastSentMs = snap?.exists ? (snap.data()?.lastSent?.toMillis?.() || 0) : 0;
      const ALERT_COOLDOWN_MS = 15 * 60 * 1000; // 15 min per unique (type, ref)
      if (now - lastSentMs > ALERT_COOLDOWN_MS) {
        const severityLabel = severity === "critical" ? "CRITICAL" : "Action required";
        const subject = `[Pushka] ${severityLabel}: ${type}`;
        const escape = (s) => String(s ?? "")
          .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
          .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
        let dataJson = "";
        try {
          dataJson = JSON.stringify(dataObj, null, 2).slice(0, 4000);
        } catch (_) {
          dataJson = "(unserializable)";
        }
        const html = `
          <div style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:20px;">
            <h2 style="color:#DC2626;">${escape(subject)}</h2>
            <p><strong>Type:</strong> ${escape(type)}</p>
            <p><strong>Severity:</strong> ${escape(severity)}</p>
            <p><strong>Requires action:</strong> ${requiresAction ? "yes" : "no"}</p>
            <p><strong>Ref ID:</strong> ${escape(refId)}</p>
            <p><strong>Tenant:</strong> ${escape(tenantName || tenantId || "—")}</p>
            <p><strong>Timestamp:</strong> ${new Date().toISOString()}</p>
            <p><strong>Data:</strong></p>
            <pre style="background:#F3F4F6;padding:12px;border-radius:6px;font-size:12px;overflow:auto;">${escape(dataJson)}</pre>
            <p><a href="https://chabad-admin.web.app/activity">Ver en admin panel →</a></p>
            <p style="color:#666;font-size:12px;margin-top:24px;">
              Cooldown: 15 min por (type, refId). Los mismos eventos repetidos no re-envían email.
            </p>
          </div>
        `;
        // Best-effort — never fail the log write on email failure.
        await sendEmail({ to: SUPER_ADMIN_EMAIL, subject, html });
        await alertRef.set({
          lastSent: admin.firestore.FieldValue.serverTimestamp(),
          type,
          refId,
        }, { merge: true });
      }
    } catch (e) {
      console.warn("writeActivityLog: alert email failed", { message: e?.message, type });
    }
  }
}

// Atomic counter increment on tenant doc — called for UNGUARDED contexts
// (auto-empty pushka, one-off recovery). Webhook handlers should use
// applyRevenueDeltaOnce instead so the guard flag + counters commit atomically.
// Non-blocking: failures are logged but never propagate to the caller.
async function incrementTenantRevenue(tenantId, amountUSD) {
  if (!tenantId || !Number.isFinite(amountUSD) || amountUSD <= 0) return;
  try {
    await db.runTransaction(async (tx) => {
      const ref = db.collection("tenants").doc(tenantId);
      const snap = await tx.get(ref);
      _applyRevenueMutationInTx(tx, ref, snap, amountUSD, "increment", null);
    });
  } catch (err) {
    console.warn("incrementTenantRevenue: failed (non-fatal)", { tenantId, amountUSD, error: String(err?.message || err) });
  }
}

/**
 * Decrement tenant revenue on refund/chargeback so admin dashboards reflect
 * net donations. Does NOT decrement `count` — the count is kept as "gross
 * transactions" for trend analysis; the refund itself counts as a separate
 * negative tx in the user's history.
 *
 * `originalDate` (optional): when provided, the nested map delta is stamped
 * under the ORIGINAL month bucket instead of "now" — keeps allTime + suma-de-
 * meses accurate when the refund crosses a month boundary. Flat top-level
 * fields still only move for the current bucket (real-time KPI policy).
 */
async function decrementTenantRevenue(tenantId, amountUSD, originalDate = null) {
  if (!tenantId || !Number.isFinite(amountUSD) || amountUSD <= 0) return;
  try {
    await db.runTransaction(async (tx) => {
      const ref = db.collection("tenants").doc(tenantId);
      const snap = await tx.get(ref);
      _applyRevenueMutationInTx(tx, ref, snap, amountUSD, "decrement", originalDate);
    });
  } catch (err) {
    console.warn("decrementTenantRevenue: failed (non-fatal)", { tenantId, amountUSD, error: String(err?.message || err) });
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

exports.sendTestNotification = onCall({ enforceAppCheck: false }, async (request) => {
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
      click_action: "/settings",
    },
  });

  return {
    successCount: response.successCount ?? 0,
    failureCount: response.failureCount ?? 0,
  };
});

exports.createPaymentIntent = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
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
      // Pre-Connect-onboarding rejection (BUG-018, Audit Round 4 Phase 3).
      // Previously: tenant without Connect setup → charge fell through to the
      // platform Stripe account. That silently kept donor money in the
      // platform's bucket instead of the tenant's, requiring manual transfer.
      // New behavior: reject with a clear error so the tenant_admin completes
      // onboarding BEFORE inviting donors.
      if (!connectAccountId) {
        throw new HttpsError(
          "failed-precondition",
          "Esta organización todavía no completó la configuración de pagos. " +
          "Avisale al administrador para que active Stripe Connect.",
        );
      }
    } else {
      // Tenant doc missing entirely — defensive. createPaymentIntent shouldn't
      // be reachable without a tenant, but guard so we never silently bill the
      // platform account.
      throw new HttpsError(
        "failed-precondition",
        "Esta organización no existe o no está disponible.",
      );
    }
  } else {
    // User has no tenant attached → no charge possible. The donation flow
    // assumes a tenant context for the application_fee + Connect routing.
    throw new HttpsError(
      "failed-precondition",
      "Para donar necesitás unirte a una organización primero.",
    );
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
  // Cap por currency (~USD $1000 equivalent). Pre-launch sideload hardening
  // ver CURRENCY_MAX_AMOUNTS arriba. El cap global 99999999 sigue como
  // segunda red por si CURRENCY_MAX_AMOUNTS quedara desactualizado.
  const maxForCurrency = maxAmountForCurrency(currency);
  if (amount > maxForCurrency) {
    console.warn("createPaymentIntent: amount exceeds per-currency cap", {
      uid: request.auth.uid, tenantId, currency, amount, maxForCurrency,
    });
    throw new HttpsError(
      "invalid-argument",
      `El monto excede el máximo permitido por transacción (${currency.toUpperCase()}).`
    );
  }
  if (amount > 99999999) {
    throw new HttpsError("invalid-argument", "El monto excede el límite permitido.");
  }

  // Donor message — sanitized (control chars stripped, 240-char cap) so it's
  // safe to round-trip through Stripe metadata + render in the admin web
  // dashboard. Optional; "" when omitted.
  const donorMessage = sanitizeDonorMessage(request.data?.donorMessage);

  // Donation designation (e.g. "Familias necesitadas", "Estudio de Torá").
  // Sanitized + capped at 80 chars (Stripe metadata value limit is 500;
  // 80 keeps headroom + matches the cap used in cron auto-empty path).
  // Optional; null when omitted so we don't pollute the metadata with empty
  // strings.
  const donationReasonRaw = request.data?.donationReason;
  const donationReason = (typeof donationReasonRaw === "string" &&
      donationReasonRaw.trim().length > 0)
    // eslint-disable-next-line no-control-regex
    ? donationReasonRaw.replace(/[\x00-\x1F\x7F-\x9F]/g, " ").trim().slice(0, 80)
    : null;

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
  // Idempotency key: uid + correlationId. The client (StripeService.pay)
  // generates a fresh correlationId per donation attempt; retries of the
  // SAME attempt (network blip, app backgrounded mid-call) reuse the same
  // ID and Stripe dedupes them into one PaymentIntent. Distinct attempts
  // get distinct keys → both go through.
  //
  // The previous (uid + purpose + amount + currency + hour_bucket) scheme
  // looked safer for double-charge prevention but failed in practice:
  // Stripe ALSO checks that the request body is identical when a key is
  // reused. Fields like application_fee_amount, metadata.tenantId, and
  // transfer_data.destination naturally vary between attempts (commission
  // rate changes, tenant switch, etc.), so retries hit
  // StripeIdempotencyError "Keys for idempotent requests can only be used
  // with the same parameters they were first used with" and the user saw
  // a generic "No se pudo procesar el pago".
  //
  // Double-tap protection lives in the client (`_processing` guard).
  const idempotencyKey = `pi_${request.auth.uid}_${correlationId}`;

  // DIRECT CHARGES MODEL: the PaymentIntent is created directly on the
  // connected account (via Stripe-Account header). Consequences:
  // - Stripe receipts/refund emails/dispute notices use the CONNECTED
  //   account's branding, NOT the platform's (fixes "Receipt from AI systems |
  //   ioel katz" issue).
  // - Merchant of record IS the connected account (Rab / Jym Inc.), not Ioel.
  // - No transfer_data / on_behalf_of needed — those are for destination charges.
  // - application_fee_amount is still valid; skimming a commission for the
  //   platform. Left in for future multi-tenant scenarios; today (0%) it's a
  //   no-op.
  const connectParams = {};
  if (tenantConnectAccountId) {
    const appFee = computeApplicationFeeAmount(amount, tenantCommissionRate);
    if (appFee) {
      if (appFee.clamped) {
        console.warn("createPaymentIntent: clamped_app_fee", {
          uid: request.auth.uid, tenantId, amount, tenantCommissionRate,
          rawFee: appFee.rawFee, safeFee: appFee.fee,
        });
      }
      connectParams.application_fee_amount = appFee.fee;
    }
  }

  const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });
  // stripeReqOpts — spread into EVERY Stripe API call in this function so the
  // request executes on the connected account. Missing this on any call causes
  // "customer not found" errors because customers live per-account in Connect.
  const stripeReqOpts = { stripeAccount: tenantConnectAccountId };

  // Resolve (or create) the donor's Stripe customer inside the CONNECTED
  // account (Rab / Jym Inc.). With Direct Charges, customers are scoped
  // per-account — each connected account has its own customer namespace.
  // We store the connect-account customer under users/{uid}/tenantState/{tenantId}
  // instead of the flat users/{uid}.stripeCustomerId (which was the
  // platform customer, now deprecated).
  //
  // Same sentinel-in-transaction pattern as before to prevent two concurrent
  // calls from spawning duplicate customers.
  const tenantStateRef = db.collection("users").doc(request.auth.uid)
    .collection("tenantState").doc(tenantId);
  const tenantStateSnap = await tenantStateRef.get();
  let customerId = String(tenantStateSnap.data()?.stripeConnectCustomerId || "").trim() || null;
  if (!customerId) {
    await db.runTransaction(async (tx) => {
      const fresh = await tx.get(tenantStateRef);
      const freshId = String(fresh.data()?.stripeConnectCustomerId || "").trim();
      if (freshId) {
        customerId = freshId;
        return;
      }
      tx.set(tenantStateRef, {
        stripeConnectCustomerIdPending: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });
    if (!customerId) {
      try {
        const customer = await stripe.customers.create({
          email: customerEmail || undefined,
          metadata: { uid: request.auth.uid, tenantId },
        }, {
          idempotencyKey: `customer_create_${request.auth.uid}_${tenantId}`,
          stripeAccount: tenantConnectAccountId,
        });
        customerId = customer.id;
        await tenantStateRef.set({
          stripeConnectCustomerId: customerId,
          stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (stripeErr) {
        await tenantStateRef.set({
          stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
        }, { merge: true }).catch(() => {});
        throw stripeErr;
      }
    }
  }

  // Skip the dedupe pass if it ran recently. The pass touches Stripe twice
  // (customers.retrieve + paymentMethods.list) plus N more updates/detaches —
  // ~400-800ms on the critical path. State only changes when a card is
  // added or removed, so we cache `_lastPmDedupePassAt` on the tenantState
  // doc (per-tenant now that customers are per-tenant) and skip if < 2h old.
  const lastDedupeAt = tenantStateSnap.data()?._lastPmDedupePassAt?.toMillis?.() ?? 0;
  const dedupeStale = (Date.now() - lastDedupeAt) > (2 * 60 * 60 * 1000);
  if (dedupeStale) try {
    const [customer, pmList] = await Promise.all([
      stripe.customers.retrieve(customerId, stripeReqOpts),
      stripe.paymentMethods.list({
        customer: customerId,
        type: "card",
        limit: 100,
      }, stripeReqOpts),
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
        stripe.paymentMethods.update(pm.id, { allow_redisplay: "always" }, stripeReqOpts)
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
        stripe.paymentMethods.detach(pmId, stripeReqOpts).catch((err) => {
          console.warn("createPaymentIntent: detach failed", {
            uid: request.auth.uid, customerId, paymentMethodId: pmId, errorMessage: err?.message,
          });
        }),
      ));
    }
    // Stamp the success on tenantState (per-tenant now) — fire-and-forget.
    tenantStateRef.set({
      _lastPmDedupePassAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true }).catch((stampErr) => {
      console.warn("createPaymentIntent: dedupe stamp failed", {
        uid: request.auth.uid, errorMessage: stampErr?.message,
      });
    });
  } catch (dedupeErr) {
    // Stale-customer self-heal during dedupe: if the cached customerId
    // points at a customer Stripe no longer knows (hard-deleted / mode
    // mismatch), clear the stale IDs, mint a fresh customer on the
    // connected account, and continue with the new customerId.
    if (_isStripeResourceMissing(dedupeErr)) {
      console.warn("createPaymentIntent: stale connect customerId in dedupe — clearing and regenerating", {
        uid: request.auth.uid, staleCustomerId: customerId,
        errorMessage: dedupeErr?.message,
      });
      await tenantStateRef.set({
        stripeConnectCustomerId: admin.firestore.FieldValue.delete(),
        stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
        stripeConnectDefaultPaymentMethodId: admin.firestore.FieldValue.delete(),
        stripeConnectDefaultPaymentMethodLast4: admin.firestore.FieldValue.delete(),
        stripeConnectDefaultPaymentMethodBrand: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true }).catch(() => {});
      try {
        const freshCustomer = await stripe.customers.create({
          email: customerEmail || undefined,
          metadata: { uid: request.auth.uid, tenantId },
        }, {
          idempotencyKey: `customer_create_${request.auth.uid}_${tenantId}_r1`,
          stripeAccount: tenantConnectAccountId,
        });
        customerId = freshCustomer.id;
        await tenantStateRef.set({
          stripeConnectCustomerId: customerId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (createErr) {
        console.error("createPaymentIntent: recreate connect customer failed after dedupe stale", {
          uid: request.auth.uid, errorMessage: createErr?.message,
        });
        throw new HttpsError("internal", "No se pudo preparar el pago. Intentá de nuevo.");
      }
    } else {
      console.warn("createPaymentIntent: dedupe pass failed (non-fatal)", {
        uid: request.auth.uid, customerId,
        errorMessage: dedupeErr?.message,
      });
    }
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
        // Donation designation chosen by the donor (e.g. "Familias necesitadas").
        // Webhook copies this onto the transaction so admin dashboards can
        // break revenue down by destination.
        ...(donationReason ? { donationReason } : {}),
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

  // Fire both Stripe API calls concurrently on the CONNECTED account.
  let [piResult, sessionResult] = await Promise.allSettled([
    stripe.paymentIntents.create(piParams, { idempotencyKey, stripeAccount: tenantConnectAccountId }),
    stripe.customerSessions.create(customerSessionParams, stripeReqOpts),
  ]);

  // Stale-customer self-heal for paymentIntents.create on the connected
  // account: if customerId is stale, clear from tenantState, mint fresh
  // customer on connected, and retry once.
  if (piResult.status === "rejected" && _isStripeResourceMissing(piResult.reason)) {
    console.warn("createPaymentIntent: stale connect customerId — clearing and retrying once", {
      uid: request.auth.uid, staleCustomerId: customerId,
      errorMessage: piResult.reason?.message,
    });
    await tenantStateRef.set({
      stripeConnectCustomerId: admin.firestore.FieldValue.delete(),
      stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
      stripeConnectDefaultPaymentMethodId: admin.firestore.FieldValue.delete(),
      stripeConnectDefaultPaymentMethodLast4: admin.firestore.FieldValue.delete(),
      stripeConnectDefaultPaymentMethodBrand: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true }).catch(() => {});
    try {
      const freshCustomer = await stripe.customers.create({
        email: customerEmail || undefined,
        metadata: { uid: request.auth.uid, tenantId },
      }, {
        idempotencyKey: `customer_create_${request.auth.uid}_${tenantId}_pi_r1`,
        stripeAccount: tenantConnectAccountId,
      });
      customerId = freshCustomer.id;
      piParams.customer = customerId;
      customerSessionParams.customer = customerId;
      await tenantStateRef.set({
        stripeConnectCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    } catch (createErr) {
      console.error("createPaymentIntent: recreate connect customer failed", {
        uid: request.auth.uid, errorMessage: createErr?.message,
      });
      throw new HttpsError("internal", "No se pudo preparar el pago. Intentá de nuevo.");
    }
    [piResult, sessionResult] = await Promise.allSettled([
      stripe.paymentIntents.create(piParams, { idempotencyKey: `${idempotencyKey}_r1`, stripeAccount: tenantConnectAccountId }),
      stripe.customerSessions.create(customerSessionParams, stripeReqOpts),
    ]);
  }

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
    // Release the auto-empty lock claimed for purpose === "pushka_empty"
    // (lines ~627-657) before bubbling the error up. Otherwise the lock
    // would persist for its full 10-min TTL after a Stripe failure, blocking
    // every subsequent payment attempt with "Tu Pushka se está vaciando
    // automáticamente" — a poor UX for retryable failures (network blips,
    // card declines, etc.). Best-effort: a lock-release failure here just
    // means the user waits the TTL, no double-charge risk.
    if (purpose === "pushka_empty" && tenantId) {
      try {
        await db.collection("users").doc(request.auth.uid)
          .collection("tenantState").doc(tenantId)
          .set({
            _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
            _autoEmptyChargeLockSource: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
      } catch (lockReleaseErr) {
        console.warn("createPaymentIntent: lock_release_after_stripe_error_failed", {
          uid: request.auth.uid, tenantId, err: lockReleaseErr?.message,
        });
      }
    }
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
        { apiVersion: "2024-06-20", stripeAccount: tenantConnectAccountId },
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
    // Connect account the client SDK must be initialized on. The Flutter
    // client sets Stripe.stripeAccountId = connectAccountId BEFORE calling
    // PaymentSheet — without it the sheet requests the customer on the
    // platform (where it doesn't exist) and errors.
    connectAccountId: tenantConnectAccountId,
  };
});

// ---------------------------------------------------------------------------
// releaseManualPushkaEmptyLock — let the client free the lock it claimed
// ---------------------------------------------------------------------------
// When createPaymentIntent({purpose:"pushka_empty"}) succeeds, the CF claims
// _autoEmptyChargeLockAt on the (uid, tenantId) tenantState doc to block the
// cron from double-charging. If the donor then dismisses or errors out of
// PaymentSheet (StripeException, network, app crash), no webhook fires, and
// the lock would persist for its full 10-min TTL — locking out every other
// payment flow ("Tu Pushka se está vaciando automáticamente"). The client
// calls this CF in its catch/finally to release the lock proactively.
//
// Safety: only releases locks with _autoEmptyChargeLockSource === "manual"
// so a racing cron lock (source: undefined / "scheduled") is never cleared.
exports.releaseManualPushkaEmptyLock = onCall(
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    await enforceRateLimit(request.auth.uid, "releaseManualPushkaEmptyLock", 30, 600);

    // tenantId is optional — fall back to the user's active tenant. The
    // client may not always have it handy when reacting to a PaymentSheet
    // exception, and the server already knows the donor's primary tenant.
    let tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) {
      const userSnap = await db.collection("users").doc(request.auth.uid).get();
      tenantId = String(userSnap.data()?.tenantId || "").trim();
    }
    if (!tenantId) return { released: false, reason: "no_tenant" };

    const stateRef = db.collection("users").doc(request.auth.uid)
      .collection("tenantState").doc(tenantId);
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(stateRef);
        if (!snap.exists) return;
        const source = snap.data()?._autoEmptyChargeLockSource;
        // Only release manual locks. A racing scheduled-cron lock (source
        // unset or "scheduled") MUST stay claimed — clearing it would let
        // the next createPaymentIntent slip through and double-charge.
        if (source !== "manual") return;
        tx.set(stateRef, {
          _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
          _autoEmptyChargeLockSource: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      });
    } catch (err) {
      console.warn("releaseManualPushkaEmptyLock: tx failed (non-fatal)", {
        uid: request.auth.uid, tenantId, err: err?.message,
      });
    }
    return { released: true };
  },
);

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
  { secrets: [stripeSecret], enforceAppCheck: false },
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

    // Client-supplied correlation ID, used to scope the Stripe idempotency key
    // to a single donor attempt. Validate to a strict 16-hex shape so it can't
    // smuggle log-injection patterns; fall back to a server-generated value
    // for older clients that don't send it.
    const rawCid = request.data?.correlationId;
    const correlationId = (typeof rawCid === "string" && /^[a-f0-9]{16}$/.test(rawCid))
      ? rawCid
      : require("crypto").randomBytes(8).toString("hex");

    const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
    const tenantId = userData.tenantId ?? null;

    // Refuse recurring donations for tenants without Connect setup.
    if (!tenantId) {
      throw new HttpsError(
        "failed-precondition",
        "Tu cuenta no está asociada a ninguna organización.",
      );
    }
    const ctx = await _resolveConnectCustomerContext(request.auth.uid);
    if (!ctx) {
      throw new HttpsError(
        "failed-precondition",
        "Tu organización no tiene pagos configurados. Avisale al administrador.",
      );
    }
    const { tenantConnectAccountId, stripeReqOpts, tenantStateRef } = ctx;
    // safeTenantCommissionRate from the tenant doc — ctx.userData is the
    // caller's user doc, but commissionRate lives on the tenant doc.
    const tenantDataForCommission = await db.collection("tenants").doc(tenantId).get();
    const tenantDataOnce = tenantDataForCommission.data() || {};
    // Round-6 audit HIGH fix: refuse recurring donations for suspended
    // tenants. createPaymentIntent has this guard; createDonationSubscription
    // was missing it — a donor could sub $18/month to a tenant that had
    // its Connect account revoked, resulting in immediate payment failures
    // and confused donor charges.
    if (tenantDataOnce.status === "suspended") {
      throw new HttpsError(
        "failed-precondition",
        "Esta organización está temporalmente suspendida. No se pueden crear donaciones recurrentes.",
      );
    }
    const tenantCommissionRate = safeTenantCommissionRate(
      tenantDataOnce.commissionRate, tenantId);

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
    // Per-currency cap: without this a malicious authenticated user could
    // create a $999,999/month recurring subscription. Mirrors the check
    // already enforced on createPaymentIntent + createCheckoutSession.
    const maxAmount = maxAmountForCurrency(currency);
    if (amount > maxAmount) {
      throw new HttpsError(
        "invalid-argument",
        `Monto máximo para ${currency.toUpperCase()} es ${formatAmount(maxAmount)}.`,
      );
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

    let customerId = ctx.customerId;
    if (!customerId) {
      try {
        const customer = await stripe.customers.create(
          {
            email: customerEmail || undefined,
            metadata: { uid: request.auth.uid, tenantId },
          },
          {
            idempotencyKey: `customer_create_${request.auth.uid}_${tenantId}`,
            stripeAccount: tenantConnectAccountId,
          },
        );
        customerId = customer.id;
        await tenantStateRef.set(
          {
            stripeConnectCustomerId: customerId,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      } catch (stripeErr) {
        console.error("createDonationSubscription: connect customer create failed", {
          uid: request.auth.uid, tenantId,
          err: stripeErr.message,
        });
        throw new HttpsError("internal", "No se pudo crear el cliente.");
      }
    }

    const donorMessage = sanitizeDonorMessage(request.data?.donorMessage);

    // Donation designation — sanitized + 80-char cap, same shape as
    // createPaymentIntent. Stamped on the subscription metadata so every
    // generated invoice's transaction inherits it via the webhook.
    const donationReasonRaw = request.data?.donationReason;
    const donationReason = (typeof donationReasonRaw === "string" &&
        donationReasonRaw.trim().length > 0)
      // eslint-disable-next-line no-control-regex
      ? donationReasonRaw.replace(/[\x00-\x1F\x7F-\x9F]/g, " ").trim().slice(0, 80)
      : null;

    // Direct Charges: products live PER connected account (Stripe scopes
    // products by account like customers). Cache the product ID per-account
    // in _tenantStripe/{acctId}.recurringProductId so we don't re-create on
    // every call AND so tenants don't share product IDs (which would fail
    // because product X on account A does not exist on account B).
    let recurringProductId = null;
    const acctCfgRef = db.collection("_tenantStripe").doc(tenantConnectAccountId);
    try {
      const acctCfgSnap = await acctCfgRef.get();
      if (acctCfgSnap.exists) {
        recurringProductId = acctCfgSnap.data()?.recurringProductId ?? null;
      }
    } catch (cfgErr) {
      console.error("createDonationSubscription: acct cfg read failed", {
        err: cfgErr.message,
      });
      throw new HttpsError("internal", `cfg-read: ${cfgErr.message}`);
    }
    if (!recurringProductId) {
      try {
        const product = await stripe.products.create(
          {
            name: "Pushka — Donación recurrente",
            metadata: { source: "pushka_recurring" },
          },
          {
            idempotencyKey: `pushka_recurring_product_${tenantConnectAccountId}`,
            stripeAccount: tenantConnectAccountId,
          },
        );
        recurringProductId = product.id;
        console.info("createDonationSubscription: connect product created", {
          productId: recurringProductId,
          connectAccountId: tenantConnectAccountId,
        });
        try {
          await acctCfgRef.set(
            {
              recurringProductId,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
        } catch (writeErr) {
          console.error("createDonationSubscription: acct cfg write failed (non-fatal)", {
            err: writeErr.message,
          });
        }
      } catch (prodErr) {
        console.error("createDonationSubscription: connect product create failed", {
          err: prodErr.message,
          connectAccountId: tenantConnectAccountId,
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
        ...(donationReason ? { donationReason } : {}),
        // Stamp the Connect destination so the invoice.payment_succeeded
        // drift-detection fallback (invoice.parent.subscription_details
        // .metadata.connectAccountId) can catch cases where transfer_data
        // on the invoice is missing/rotated but the sub was originally
        // pinned to a specific tenant Connect account.
        ...(tenantConnectAccountId
          ? { connectAccountId: tenantConnectAccountId }
          : {}),
      },
    };

    // Direct Charges: the subscription is created ON the connected account
    // (via Stripe-Account header). No transfer_data / on_behalf_of needed —
    // the sub lives natively in the tenant's account. application_fee_percent
    // still applies for optional platform commission (0 today = no-op).
    if (tenantCommissionRate > 0) {
      subParams.application_fee_percent = Math.min(
        99,
        Math.max(0, tenantCommissionRate * 100),
      );
    }

    // Pre-cleanup: clean up ABANDONED prior attempts so a stuck `incomplete`
    // sub from a previous tap doesn't block the new create with Stripe's
    // "cannot combine currencies" error.
    //   - `incomplete` / `incomplete_expired`: the donor opened PaymentSheet
    //     once and dismissed it without confirming. The sub never charged a
    //     cent. Safe to cancel — we're freeing the abandoned attempt so the
    //     donor can retry (potentially in a different currency).
    //   - `active` / `trialing` / `past_due`: REAL ongoing donation. We do
    //     NOT silently cancel — that would surprise the donor (they think
    //     they're still subscribed, money keeps flowing, then suddenly
    //     stops). Surface a clear error instead so the donor knows to
    //     cancel manually first.
    //   - `canceled` / other terminal: skip, no action needed.
    // Scope tightly to subs whose metadata.purpose === "donation_recurring"
    // so SaaS billing subscriptions or any other subs on this customer are
    // untouched.
    try {
      const existing = await stripe.subscriptions.list({
        customer: customerId,
        status: "all",
        limit: 100,
      }, stripeReqOpts);
      for (const oldSub of existing.data) {
        if (oldSub.metadata?.purpose !== "donation_recurring") continue;
        const status = oldSub.status;
        if (status !== "incomplete" && status !== "incomplete_expired") {
          continue;
        }
        try {
          // Stripe SDK cancel signature: (id, params?, options?). Pass {}
          // for params so stripeReqOpts lands in the options slot as a
          // header rather than being body-encoded.
          await stripe.subscriptions.cancel(oldSub.id, {}, stripeReqOpts);
          console.info("createDonationSubscription: cancelled abandoned incomplete sub", {
            uid: request.auth.uid,
            subId: oldSub.id,
            priorStatus: status,
            priorCurrency: oldSub.currency,
          });
        } catch (cancelErr) {
          console.warn("createDonationSubscription: failed to cancel incomplete sub", {
            uid: request.auth.uid,
            subId: oldSub.id,
            err: cancelErr.message,
          });
        }
      }
    } catch (cleanupErr) {
      // Stale-customer self-heal for the list call: if the cached customerId
      // points at a customer Stripe no longer knows (hard-deleted / mode
      // mismatch), clear the stale IDs so the retry-once block on
      // subscriptions.create below can mint a fresh customer. Continue with
      // an empty subs list — there was nothing to cancel anyway (the old
      // customer is gone from Stripe's perspective).
      if (_isStripeResourceMissing(cleanupErr)) {
        console.warn("createDonationSubscription: stale connect customerId in list — clearing", {
          uid: request.auth.uid, tenantId, staleCustomerId: customerId,
          errorMessage: cleanupErr?.message,
        });
        try {
          await tenantStateRef.set({
            stripeConnectCustomerId: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodId: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodLast4: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodBrand: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        } catch (_) { /* best-effort */ }
        // BUG #19 fix: proactively mint a fresh customer HERE so the
        // subscriptions.create call below succeeds on first attempt.
        // Previously subParams.customer still held the doomed id, causing a
        // guaranteed extra Stripe roundtrip through the stale-heal retry.
        try {
          const freshCustomer = await stripe.customers.create({
            email: customerEmail || undefined,
            metadata: { uid: request.auth.uid, tenantId },
          }, {
            idempotencyKey: `customer_create_${request.auth.uid}_${tenantId}_sub_precleanup`,
            stripeAccount: tenantConnectAccountId,
          });
          customerId = freshCustomer.id;
          subParams.customer = customerId;
          await tenantStateRef.set({
            stripeConnectCustomerId: customerId,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        } catch (recreateErr) {
          // If we can't recreate here, let the sub-create's stale-heal try —
          // guaranteed to fail with resource_missing which triggers its own retry.
          console.warn("createDonationSubscription: pre-cleanup recreate failed, falling back to inline retry", {
            uid: request.auth.uid, tenantId, err: recreateErr?.message,
          });
        }
      } else {
        console.warn("createDonationSubscription: cleanup pass failed", {
          uid: request.auth.uid,
          err: cleanupErr.message,
        });
      }
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
    // Idempotency key scoped to the donor's correlationId — retries of the
    // same attempt (network blip) reuse the key and Stripe dedupes; new
    // attempts get fresh keys so we don't reuse a Stripe response that may
    // already point at a sub our pre-cleanup pass cancelled (which would
    // surface as "PaymentSheet cannot set up a PaymentIntent in status
    // 'canceled'" client-side).
    const subIdempotencyKey = `sub_${request.auth.uid}_${tenantId}_${correlationId}`;
    let subscription;
    let subRetryCount = 0;
    while (true) {
      const attemptKey = subRetryCount === 0
        ? subIdempotencyKey
        : `sub_create_${request.auth.uid}_${tenantId}_r${subRetryCount}`;
      try {
        subscription = await stripe.subscriptions.create(subParams, {
          idempotencyKey: attemptKey,
          stripeAccount: tenantConnectAccountId,
        });
        console.info("createDonationSubscription: sub created", {
          subId: subscription.id,
          status: subscription.status,
          retry: subRetryCount,
          connectAccountId: tenantConnectAccountId,
        });
        break;
      } catch (stripeErr) {
        if (subRetryCount === 0 && _isStripeResourceMissing(stripeErr)) {
          console.warn("createDonationSubscription: stale connect customerId — clearing and retrying once", {
            uid: request.auth.uid, tenantId, staleCustomerId: customerId,
            errorMessage: stripeErr?.message,
          });
          await tenantStateRef.set({
            stripeConnectCustomerId: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodId: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodLast4: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodBrand: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true }).catch(() => {});
          try {
            const freshCustomer = await stripe.customers.create({
              email: customerEmail || undefined,
              metadata: { uid: request.auth.uid, tenantId },
            }, {
              idempotencyKey: `customer_create_${request.auth.uid}_${tenantId}_sub_r1`,
              stripeAccount: tenantConnectAccountId,
            });
            customerId = freshCustomer.id;
            subParams.customer = customerId;
            await tenantStateRef.set({
              stripeConnectCustomerId: customerId,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
          } catch (createErr) {
            console.error("createDonationSubscription: recreate connect customer failed", {
              uid: request.auth.uid, tenantId, errorMessage: createErr?.message,
            });
            throw new HttpsError("internal", "No se pudo preparar tu suscripción. Intentá de nuevo.");
          }
          subRetryCount += 1;
          continue;
        }
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

    // CustomerSession (modern) + EphemeralKey (legacy fallback) — both allow
    // PaymentSheet to show saved cards. flutter_stripe v12 prefers
    // customerSessionClientSecret; we return both so the client can pick whichever
    // is available. Best-effort — subscription works without either.
    let ephemeralKeySecret = null;
    let customerSessionClientSecret = null;
    await Promise.all([
      stripe.customerSessions
        .create({
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
        }, stripeReqOpts)
        .then((cs) => {
          customerSessionClientSecret = cs.client_secret;
        })
        .catch((csErr) => {
          console.warn("createDonationSubscription: customerSession create failed", {
            uid: request.auth.uid,
            err: csErr.message,
          });
        }),
      stripe.ephemeralKeys
        .create({ customer: customerId }, {
          apiVersion: "2024-06-20",
          stripeAccount: tenantConnectAccountId,
        })
        .then((ek) => {
          ephemeralKeySecret = ek.secret;
        })
        .catch((ekErr) => {
          console.warn("createDonationSubscription: ephemeralKey create failed", {
            uid: request.auth.uid,
            err: ekErr.message,
          });
        }),
    ]);

    return {
      subscriptionId: subscription.id,
      clientSecret,
      customerId,
      ephemeralKeySecret,
      customerSessionClientSecret,
      // Client needs this to set Stripe.stripeAccountId before initPaymentSheet.
      connectAccountId: tenantConnectAccountId,
    };
  },
);

// ---------------------------------------------------------------------------
// Donation subscriptions — list + cancel for the calling user
// ---------------------------------------------------------------------------

exports.listDonationSubscriptions = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    const uid = request.auth.uid;
    await enforceRateLimit(uid, "listDonationSubscriptions", 60, 3600);
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }

    // Round-4 audit HIGH fix: previously this CF only listed subs for the
    // ACTIVE tenant's connect customer, so a user who joined a second
    // tenant lost visibility of a recurring donation to the first one —
    // Stripe kept charging monthly with no cancel button anywhere.
    //
    // Iterate over every tenantId the user belongs to, resolve the
    // per-tenant connect customer, and merge all their subs into one list.
    const userSnap = await db.collection("users").doc(uid).get();
    const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
    const tenantIds = Array.isArray(userData.tenantIds)
      ? userData.tenantIds.filter((t) => typeof t === "string" && t.length > 0)
      : (userData.tenantId ? [userData.tenantId] : []);
    if (tenantIds.length === 0) return { subscriptions: [] };

    const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });
    const ACTIVE_STATUSES = new Set(["active", "trialing", "past_due"]);

    // Resolve per-tenant customerId + connect account for each tenant the
    // user belongs to. Skip tenants without an active connect account
    // (subs cannot exist there in Direct Charges model).
    const perTenant = await Promise.all(tenantIds.map(async (tid) => {
      try {
        const tenantSnap = await db.collection("tenants").doc(tid).get();
        const tenantData = tenantSnap.exists ? (tenantSnap.data() ?? {}) : {};
        const connectAccountId = tenantData.stripeConnectAccountId;
        if (!connectAccountId || tenantData.stripeConnectStatus !== "active") return null;
        const stateSnap = await db.collection("users").doc(uid)
          .collection("tenantState").doc(tid).get();
        const customerId = String(stateSnap.data()?.stripeConnectCustomerId || "").trim();
        if (!customerId) return null;
        return {
          tenantId: tid,
          tenantName: String(tenantData.name || ""),
          tenantAppName: String(tenantData.appName || ""),
          customerId,
          stripeReqOpts: { stripeAccount: connectAccountId },
        };
      } catch (err) {
        console.warn("listDonationSubscriptions: tenant_ctx_failed", {
          uid, tenantId: tid, error: String(err?.message || err),
        });
        return null;
      }
    }));

    const validCtxs = perTenant.filter(Boolean);
    if (validCtxs.length === 0) return { subscriptions: [] };

    // Fetch subs for each tenant in parallel. Failures per-tenant don't
    // block the others — just skip that tenant with a warning.
    const results = await Promise.all(validCtxs.map(async (ctx) => {
      try {
        const subs = await stripe.subscriptions.list({
          customer: ctx.customerId,
          status: "all",
          limit: 100,
        }, ctx.stripeReqOpts);
        return subs.data
          .filter((s) => s.metadata?.purpose === "donation_recurring" && ACTIVE_STATUSES.has(s.status))
          .map((s) => {
            const item = s.items?.data?.[0];
            const price = item?.price;
            const cpe = s.current_period_end ?? item?.current_period_end ?? null;
            return {
              id: s.id,
              status: s.status,
              currency: (price?.currency || s.currency || "").toLowerCase(),
              amount: Number(price?.unit_amount || 0),
              interval: price?.recurring?.interval || "month",
              currentPeriodEnd: cpe ? cpe * 1000 : null,
              tenantId: ctx.tenantId,
              tenantName: ctx.tenantName,
              tenantAppName: ctx.tenantAppName,
              cancelAtPeriodEnd: !!s.cancel_at_period_end,
            };
          });
      } catch (err) {
        console.warn("listDonationSubscriptions: stripe_list_failed", {
          uid, tenantId: ctx.tenantId, error: String(err?.message || err),
        });
        return [];
      }
    }));

    return { subscriptions: results.flat() };
  },
);

exports.cancelDonationSubscription = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }
    const uid = request.auth.uid;
    await enforceRateLimit(uid, "cancelDonationSubscription", 20, 3600);

    const subId = String(request.data?.subscriptionId || "").trim();
    if (!subId.startsWith("sub_")) {
      throw new HttpsError("invalid-argument", "ID de suscripción inválido.");
    }

    // Round-4 audit HIGH fix: previously we only searched the ACTIVE
    // tenant's connect account. A user who joined a second tenant and
    // wanted to cancel a lingering sub in the first tenant hit
    // "Suscripción no encontrada" — dead-end. Now iterate every tenant
    // the user belongs to and cancel wherever the sub is found.
    const userSnap = await db.collection("users").doc(uid).get();
    const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
    const tenantIds = Array.isArray(userData.tenantIds)
      ? userData.tenantIds.filter((t) => typeof t === "string" && t.length > 0)
      : (userData.tenantId ? [userData.tenantId] : []);
    if (tenantIds.length === 0) {
      throw new HttpsError("failed-precondition", "No tenés organización activa.");
    }

    const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });
    let sub = null;
    let stripeReqOpts = null;
    for (const tid of tenantIds) {
      try {
        const tenantSnap = await db.collection("tenants").doc(tid).get();
        const tenantData = tenantSnap.exists ? (tenantSnap.data() ?? {}) : {};
        const connectAccountId = tenantData.stripeConnectAccountId;
        if (!connectAccountId || tenantData.stripeConnectStatus !== "active") continue;
        const opts = { stripeAccount: connectAccountId };
        try {
          sub = await stripe.subscriptions.retrieve(subId, opts);
          stripeReqOpts = opts;
          break;
        } catch (_) {
          // Sub doesn't live in this tenant's Stripe account — try the next.
          continue;
        }
      } catch (err) {
        console.warn("cancelDonationSubscription: tenant_lookup_failed", {
          uid, tenantId: tid, error: String(err?.message || err),
        });
      }
    }
    if (!sub || !stripeReqOpts) {
      throw new HttpsError("not-found", "Suscripción no encontrada.");
    }

    // Ownership + scope guard.
    if (sub.metadata?.uid !== request.auth.uid) {
      throw new HttpsError("permission-denied", "No tenés permiso para cancelar esta suscripción.");
    }
    if (sub.metadata?.purpose !== "donation_recurring") {
      throw new HttpsError("failed-precondition", "Esta suscripción no se puede cancelar desde acá.");
    }

    if (sub.status === "canceled") {
      return { ok: true, alreadyCanceled: true };
    }

    try {
      // SDK cancel signature: (id, params?, options?). Empty {} for params
      // so stripeReqOpts lands as options (header) not body.
      await stripe.subscriptions.cancel(subId, {}, stripeReqOpts);
    } catch (e) {
      console.error("cancelDonationSubscription: stripe cancel failed", {
        uid: request.auth.uid, subId,
        err: e.message,
      });
      throw new HttpsError("internal", "No se pudo cancelar la suscripción.");
    }
    return { ok: true };
  },
);

// ---------------------------------------------------------------------------
// Stripe Customer — SetupIntent (save card for future off-session charges)
// ---------------------------------------------------------------------------

exports.createSetupIntent = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }
    await enforceRateLimit(request.auth.uid, "createSetupIntent", 20, 3600);

    // Client-supplied correlation ID — scopes the Stripe idempotency key to a
    // single attempt so retries within the same minute don't reuse a key whose
    // SetupIntent was canceled (which would surface as "PaymentSheet cannot
    // set up SetupIntent in status canceled" client-side). Strict 16-hex
    // shape, server-generated fallback for older clients.
    const rawCid = request.data?.correlationId;
    const correlationId = (typeof rawCid === "string" && /^[a-f0-9]{16}$/.test(rawCid))
      ? rawCid
      : require("crypto").randomBytes(8).toString("hex");

    const uid = request.auth.uid;
    const stripe = require("stripe")(stripeSecret.value());
    const userRef = db.collection("users").doc(uid);

    // Resolve tenant + connect account. Direct charges MUST have a tenant
    // context because customers live per-connected-account.
    const userSnap = await userRef.get();
    const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
    const tenantId = userData.tenantId ?? null;
    if (!tenantId) {
      throw new HttpsError("failed-precondition", "Para guardar una tarjeta necesitás unirte a una organización primero.");
    }
    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    const tenantData = tenantSnap.exists ? (tenantSnap.data() ?? {}) : {};
    const tenantConnectAccountId = tenantData.stripeConnectAccountId || null;
    if (!tenantConnectAccountId || tenantData.stripeConnectStatus !== "active") {
      throw new HttpsError("failed-precondition", "La organización no tiene pagos configurados.");
    }
    const stripeReqOpts = { stripeAccount: tenantConnectAccountId };

    const tenantStateRef = userRef.collection("tenantState").doc(tenantId);
    // Invalidate the dedupe cache on the tenantState (per-tenant now).
    tenantStateRef.set({
      _lastPmDedupePassAt: admin.firestore.FieldValue.delete(),
    }, { merge: true }).catch(() => {});

    // Fast path: connect customer already resolved for this (uid, tenant).
    let customerId = null;
    const customerEmail = request.auth.token?.email || userData.email || null;
    const fastStateSnap = await tenantStateRef.get();
    if (fastStateSnap.exists) {
      customerId = fastStateSnap.data()?.stripeConnectCustomerId || null;
    }

    if (!customerId) {
      // Slow path — transactional sentinel prevents duplicate customers on
      // concurrent calls.
      await db.runTransaction(async (tx) => {
        const stateSnap = await tx.get(tenantStateRef);
        customerId = stateSnap.data()?.stripeConnectCustomerId || null;
        if (!customerId) {
          tx.set(tenantStateRef, {
            stripeConnectCustomerIdPending: true,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        }
      });
    }

    if (!customerId) {
      try {
        const customer = await stripe.customers.create({
          email: customerEmail || undefined,
          metadata: { uid, tenantId },
        }, {
          idempotencyKey: `customer_create_${uid}_${tenantId}`,
          stripeAccount: tenantConnectAccountId,
        });
        customerId = customer.id;
        await tenantStateRef.set({
          stripeConnectCustomerId: customerId,
          stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (stripeErr) {
        await tenantStateRef.set({
          stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
        }, { merge: true }).catch(() => {});
        throw stripeErr;
      }
    }

    // SetupIntent with stale-customer self-heal (mirror pattern of
    // createPaymentIntent).
    let setupIntent;
    let retryCount = 0;
    while (true) {
      const siIdempotencyKey = retryCount === 0
        ? `si_${uid}_${tenantId}_${correlationId}`
        : `si_${uid}_${tenantId}_${correlationId}_r${retryCount}`;
      try {
        setupIntent = await stripe.setupIntents.create({
          customer: customerId,
          payment_method_types: ["card"],
          usage: "off_session",
          metadata: { uid, tenantId },
        }, { idempotencyKey: siIdempotencyKey, stripeAccount: tenantConnectAccountId });
        break;
      } catch (siErr) {
        if (retryCount === 0 && _isStripeResourceMissing(siErr)) {
          console.warn("createSetupIntent: stale connect customerId — clearing and retrying once", {
            uid, tenantId, staleCustomerId: customerId, errorMessage: siErr?.message,
          });
          await tenantStateRef.set({
            stripeConnectCustomerId: admin.firestore.FieldValue.delete(),
            stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodId: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodLast4: admin.firestore.FieldValue.delete(),
            stripeConnectDefaultPaymentMethodBrand: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true }).catch(() => {});
          try {
            // BUG #4 + #11 fix: unified stale-heal idempotency key across
            // all callables. Previously used Date.now() which changes on
            // every retry → Stripe treats each attempt as a new customer
            // create. Also standardized suffix `_si_r1` (setup-intent retry)
            // so parallel stale-heals from createPaymentIntent (_pi_r1),
            // createDonationSubscription (_sub_r1), and createSetupIntent
            // (_si_r1) don't collide on the same (uid, tenantId).
            const freshCustomer = await stripe.customers.create({
              email: customerEmail || undefined,
              metadata: { uid, tenantId },
            }, {
              idempotencyKey: `customer_create_${uid}_${tenantId}_si_r1`,
              stripeAccount: tenantConnectAccountId,
            });
            customerId = freshCustomer.id;
            await tenantStateRef.set({
              stripeConnectCustomerId: customerId,
              stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
          } catch (createErr) {
            console.error("createSetupIntent: recreate connect customer failed", {
              uid, tenantId, errorMessage: createErr?.message,
            });
            throw new HttpsError("internal", "No se pudo preparar tu método de pago. Intentá de nuevo.");
          }
          retryCount += 1;
          continue;
        }
        throw siErr;
      }
    }

    return {
      clientSecret: setupIntent.client_secret,
      connectAccountId: tenantConnectAccountId,
    };
  }
);

// ---------------------------------------------------------------------------
// List saved cards for current user
// ---------------------------------------------------------------------------

exports.listSavedCards = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
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
    console.info("listSavedCards: entry", { uid });
    // Direct Charges: customers live per connected account, not on the platform.
    // Resolve tenantId → tenantConnectAccountId → customer from tenantState.
    const userSnap = await db.collection("users").doc(uid).get();
    const userData = userSnap.data() ?? {};
    const tenantId = userData.tenantId ?? null;
    if (!tenantId) {
      console.info("listSavedCards: no_tenant", { uid });
      return { cards: [], defaultPaymentMethodId: null };
    }
    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    const tenantData = tenantSnap.exists ? (tenantSnap.data() ?? {}) : {};
    const tenantConnectAccountId = tenantData.stripeConnectAccountId || null;
    if (!tenantConnectAccountId || tenantData.stripeConnectStatus !== "active") {
      console.info("listSavedCards: no_connect_or_inactive", {
        uid, tenantId,
        hasAcct: !!tenantConnectAccountId,
        status: tenantData.stripeConnectStatus,
      });
      return { cards: [], defaultPaymentMethodId: null };
    }
    const stripeReqOpts = { stripeAccount: tenantConnectAccountId };
    const tenantStateRef = db.collection("users").doc(uid)
      .collection("tenantState").doc(tenantId);
    const tenantStateSnap = await tenantStateRef.get();
    const customerId = tenantStateSnap.data()?.stripeConnectCustomerId || null;
    console.info("listSavedCards: resolved_context", {
      uid, tenantId, tenantConnectAccountId, customerId,
      tenantStateExists: tenantStateSnap.exists,
    });

    if (!customerId) {
      console.info("listSavedCards: no_customer_in_tenantState", { uid, tenantId });
      return { cards: [], defaultPaymentMethodId: null };
    }

    const stripe = require("stripe")(stripeSecret.value());
    console.info("listSavedCards: before_stripe_calls", { uid, customerId });
    let customer;
    let pmList;
    try {
      [customer, pmList] = await Promise.all([
        stripe.customers.retrieve(customerId, stripeReqOpts),
        stripe.paymentMethods.list({
          customer: customerId,
          type: "card",
          limit: 100,
        }, stripeReqOpts),
      ]);
      console.info("listSavedCards: stripe_calls_ok", {
        uid, customerId,
        customerFound: !customer.deleted,
        pmCount: pmList.data.length,
      });
    } catch (stripeErr) {
      console.error("listSavedCards: stripe_call_failed", {
        uid, tenantId, customerId,
        stripeAccount: tenantConnectAccountId,
        errorType: stripeErr?.type,
        errorCode: stripeErr?.code,
        errorMessage: stripeErr?.message,
        statusCode: stripeErr?.statusCode,
        rawError: String(stripeErr).slice(0, 500),
      });
      if (_isStripeResourceMissing(stripeErr)) {
        console.warn("listSavedCards: stale connect customerId (resource_missing) — clearing", {
          uid, tenantId, customerId,
        });
        await tenantStateRef.set({
          stripeConnectCustomerId: admin.firestore.FieldValue.delete(),
          stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
          stripeConnectDefaultPaymentMethodId: admin.firestore.FieldValue.delete(),
          stripeConnectDefaultPaymentMethodLast4: admin.firestore.FieldValue.delete(),
          stripeConnectDefaultPaymentMethodBrand: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true }).catch(() => {});
        return { cards: [], defaultPaymentMethodId: null };
      }
      throw stripeErr;
    }

    // Customer was deleted directly in Stripe — clear the stale ID and return empty.
    // BUG #18 fix: symmetric with the resource_missing branch above — also
    // clear the cached default-PM fields, otherwise the wallet screen keeps
    // showing "Visa •••• 4242" after the customer is gone.
    if (customer.deleted) {
      await tenantStateRef.set({
        stripeConnectCustomerId: admin.firestore.FieldValue.delete(),
        stripeConnectCustomerIdPending: admin.firestore.FieldValue.delete(),
        stripeConnectDefaultPaymentMethodId: admin.firestore.FieldValue.delete(),
        stripeConnectDefaultPaymentMethodLast4: admin.firestore.FieldValue.delete(),
        stripeConnectDefaultPaymentMethodBrand: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true }).catch(() => {});
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
    const lastDedupeAt = tenantStateSnap.data()?._lastPmDedupePassAt?.toMillis?.() ?? 0;
    const dedupeStale = (Date.now() - lastDedupeAt) > (2 * 60 * 60 * 1000);
    // Subscription-pinning guard: if a "loser" PM is currently the
    // default_payment_method of an active subscription, detaching it silently
    // breaks the next invoice (Stripe drops the reference → invoice fails →
    // donor sees a scary "tarjeta declinada" that isn't really about their
    // card). Skip those losers and log a warning — accepting a visible
    // duplicate is strictly better than breaking a recurring donation.
    let pinnedPmIds = new Set();
    if (detachQueue.length > 0 && dedupeStale) {
      try {
        const subsList = await stripe.subscriptions.list({
          customer: customerId, status: "all", limit: 100,
        }, stripeReqOpts);
        const ACTIVE_SUB_STATUSES = new Set(["active", "trialing", "past_due", "unpaid"]);
        for (const s of subsList.data || []) {
          if (!ACTIVE_SUB_STATUSES.has(s.status)) continue;
          const pinned = typeof s.default_payment_method === "string"
            ? s.default_payment_method
            : s.default_payment_method?.id;
          if (pinned) pinnedPmIds.add(pinned);
        }
      } catch (subListErr) {
        // Non-fatal — if we can't enumerate subs, be conservative and
        // don't detach anything this pass (safer than breaking a sub).
        console.warn("listSavedCards: sub-pin check failed — skipping detach pass", {
          uid, customerId, errorMessage: subListErr?.message,
        });
        pinnedPmIds = new Set(detachQueue.map((pm) => pm.id));
      }
    }
    const safeDetachQueue = detachQueue.filter((pm) => !pinnedPmIds.has(pm.id));
    const skippedForPin = detachQueue.length - safeDetachQueue.length;
    if (skippedForPin > 0) {
      console.warn("listSavedCards: skipping detach of PMs pinned to active subs", {
        uid, customerId, skippedCount: skippedForPin,
      });
    }
    if (safeDetachQueue.length > 0 && dedupeStale) {
      console.info("listSavedCards: deduping fingerprint dupes", {
        uid, tenantId, customerId,
        kept: keep.length,
        detaching: safeDetachQueue.length,
        skippedForPin,
      });
      await Promise.all(safeDetachQueue.map((pm) =>
        stripe.paymentMethods.detach(pm.id, stripeReqOpts).catch((detachErr) => {
          console.warn("listSavedCards: detach failed", {
            uid, tenantId, customerId,
            paymentMethodId: pm.id,
            errorMessage: detachErr?.message,
          });
        }),
      ));
      tenantStateRef.set({
        _lastPmDedupePassAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true }).catch(() => {});
    } else if (dedupeStale) {
      tenantStateRef.set({
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

    // Round-3 audit fix: self-heal the tenantState mirror against Stripe
    // truth. If setDefaultPaymentMethod's Firestore write ever fell out of
    // sync with Stripe (network hiccup, deleted-in-dashboard, etc), this
    // pass corrects it — Stripe is authoritative for
    // invoice_settings.default_payment_method. Best-effort: never fails the
    // list call on a Firestore hiccup.
    try {
      const mirrorPmId = tenantStateSnap.data()?.stripeConnectDefaultPaymentMethodId || null;
      if (mirrorPmId !== defaultPmId) {
        const defaultPm = defaultPmId ? keep.find((pm) => pm.id === defaultPmId) : null;
        await tenantStateRef.set({
          stripeConnectDefaultPaymentMethodId: defaultPmId || admin.firestore.FieldValue.delete(),
          stripeConnectDefaultPaymentMethodLast4: defaultPm?.card?.last4 || admin.firestore.FieldValue.delete(),
          stripeConnectDefaultPaymentMethodBrand: defaultPm?.card?.brand || admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    } catch (mirrorErr) {
      console.warn("listSavedCards: mirror self-heal failed (non-fatal)", {
        uid, tenantId, error: String(mirrorErr?.message || mirrorErr),
      });
    }

    return { cards, defaultPaymentMethodId: defaultPmId };
  }
);

// ---------------------------------------------------------------------------
// setPaymentMethodNickname — caller assigns / clears a nickname on one of
// their own saved PaymentMethods. Stored in pm.metadata.nickname.
// ---------------------------------------------------------------------------
exports.setPaymentMethodNickname = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
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

    // Direct Charges: verify PM belongs to caller's connect-account customer.
    const ctx = await _resolveConnectCustomerContext(request.auth.uid);
    if (!ctx || !ctx.customerId) {
      throw new HttpsError("not-found", "Stripe customer no encontrado.");
    }
    const stripe = require("stripe")(stripeSecret.value());
    const pm = await stripe.paymentMethods.retrieve(pmId, ctx.stripeReqOpts);
    if (pm.customer !== ctx.customerId) {
      throw new HttpsError("permission-denied", "Esa tarjeta no es tuya.");
    }

    await stripe.paymentMethods.update(pmId, {
      metadata: { nickname: nickname || "" },
    }, ctx.stripeReqOpts);
    return { success: true, nickname: nickname || null };
  },
);

// ---------------------------------------------------------------------------
// Delete a saved payment method
// ---------------------------------------------------------------------------

exports.deletePaymentMethod = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
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
    const ctx = await _resolveConnectCustomerContext(uid);
    if (!ctx || !ctx.customerId) {
      throw new HttpsError("not-found", "No hay cliente Stripe para este usuario.");
    }
    const { customerId, stripeReqOpts, tenantStateRef, tenantId } = ctx;

    // Fetch PM + customer in parallel on the connected account.
    let pm;
    let stripeCustomer;
    try {
      [pm, stripeCustomer] = await Promise.all([
        stripe.paymentMethods.retrieve(pmId, stripeReqOpts),
        stripe.customers.retrieve(customerId, stripeReqOpts),
      ]);
    } catch (stripeErr) {
      if (_isStripeResourceMissing(stripeErr)) {
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

    // Last-card + active-recurring guard: if detaching this PM would leave
    // the customer with ZERO cards AND they have an active donation
    // subscription, the next invoice cycle silently fails
    // (invoice.payment_failed → cleanupIncompleteDonationSubscriptions
    // eventually cancels, but the donor never realizes their recurring
    // giving stopped). Block the delete and tell them to cancel the sub
    // first from the "Mis donaciones" screen.
    try {
      const [survivorsList, activeSubsList] = await Promise.all([
        stripe.paymentMethods.list({ customer: customerId, type: "card", limit: 100 }, stripeReqOpts),
        stripe.subscriptions.list({ customer: customerId, status: "all", limit: 100 }, stripeReqOpts),
      ]);
      const survivorCount = (survivorsList.data || []).filter((p) => p.id !== pmId).length;
      if (survivorCount === 0) {
        const ACTIVE_SUB_STATUSES = new Set(["active", "trialing", "past_due"]);
        const activeRecurring = (activeSubsList.data || []).filter((s) =>
          ACTIVE_SUB_STATUSES.has(s.status) &&
          (s.metadata?.purpose === "donation_recurring" ||
           s.metadata?.type === "donation_recurring"),
        );
        if (activeRecurring.length > 0) {
          console.warn("deletePaymentMethod: blocked — last card with active recurring donations", {
            uid, customerId, pmId, activeSubCount: activeRecurring.length,
          });
          throw new HttpsError(
            "failed-precondition",
            "No podés borrar tu última tarjeta mientras tenés donaciones recurrentes activas. Cancelá primero desde Mis donaciones.",
          );
        }
      }
    } catch (guardErr) {
      // Re-throw HttpsErrors so client sees the friendly message.
      if (guardErr instanceof HttpsError) throw guardErr;
      // Any other error here (Stripe outage) — log but don't block the
      // delete. The user can retry; the cleanup cron will still catch a
      // truly broken sub within 7 days.
      console.warn("deletePaymentMethod: last-card guard check failed (non-fatal)", {
        uid, pmId, errorMessage: guardErr?.message,
      });
    }

    // Detach on the connected account.
    try {
      await stripe.paymentMethods.detach(pmId, stripeReqOpts);
    } catch (stripeErr) {
      if (!_isStripeResourceMissing(stripeErr)) {
        throw new HttpsError("internal", "Error al eliminar el método de pago.");
      }
    }

    // Auto-promote if deleted PM was the default.
    const wasStripeDefault =
      stripeCustomer.invoice_settings?.default_payment_method === pmId;
    const wasFirestoreDefault =
      (ctx.tenantStateSnap.data()?.stripeConnectDefaultPaymentMethodId || null) === pmId;

    let newDefault = null;
    if (wasStripeDefault || wasFirestoreDefault) {
      const survivors = await stripe.paymentMethods.list({
        customer: customerId, type: "card", limit: 100,
      }, stripeReqOpts);
      const next = survivors.data
        .slice()
        .sort((a, b) => (b.created || 0) - (a.created || 0))[0] || null;

      const promotions = [];
      if (wasStripeDefault) {
        promotions.push(stripe.customers.update(customerId, {
          invoice_settings: { default_payment_method: next?.id || null },
        }, stripeReqOpts));
      }
      if (wasFirestoreDefault) {
        promotions.push(tenantStateRef.set({
          stripeConnectDefaultPaymentMethodId: next?.id || null,
          stripeConnectDefaultPaymentMethodLast4: next?.card?.last4 || null,
          stripeConnectDefaultPaymentMethodBrand: next?.card?.brand || null,
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

    // Invalidate dedupe cache on tenantState so next payment re-runs the pass.
    tenantStateRef.set({
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
  { secrets: [stripeSecret], enforceAppCheck: false },
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
    const ctx = await _resolveConnectCustomerContext(uid);
    if (!ctx || !ctx.customerId) {
      throw new HttpsError("not-found", "No hay cliente Stripe para este usuario.");
    }
    const { customerId, stripeReqOpts, tenantStateRef } = ctx;

    const pm = await stripe.paymentMethods.retrieve(pmId, stripeReqOpts);
    if (pm.customer !== customerId) {
      throw new HttpsError("permission-denied", "Este método de pago no pertenece a tu cuenta.");
    }

    // Round-3 audit fix: Stripe first, then Firestore mirror. The old
    // Promise.all could commit the Firestore cache pointing at a pmId
    // Stripe never accepted (rate limit, Radar block, api_connection_error)
    // — leaving the UI showing the wrong card as default while any flow
    // that reuses invoice_settings.default_payment_method would still
    // charge the OLD card. Stripe is the truth; the mirror is a cache.
    await stripe.customers.update(customerId, {
      invoice_settings: { default_payment_method: pmId },
    }, stripeReqOpts);
    try {
      await tenantStateRef.set({
        stripeConnectDefaultPaymentMethodId: pmId,
        stripeConnectDefaultPaymentMethodLast4: pm.card?.last4 || null,
        stripeConnectDefaultPaymentMethodBrand: pm.card?.brand || null,
        _lastPmDedupePassAt: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    } catch (mirrorErr) {
      // Stripe already accepted the change — self-heals on next
      // listSavedCards call (which re-derives the mirror from Stripe truth).
      console.warn("setDefaultPaymentMethod: mirror write failed (non-fatal)", {
        uid, pmId, error: String(mirrorErr?.message || mirrorErr),
      });
    }

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
    // Signature failures during a fresh deploy are EXPECTED for up to 3
    // days after a signing secret rotation: Stripe keeps retrying events
    // that were queued with the old secret. Log at WARN (not ERROR) so
    // alerts don't fire on transient rotation-window noise. If persistent
    // failures still show up past that window, it's likely a real
    // misconfiguration (webhook endpoint pointing here without our secret)
    // and worth investigating manually via `firebase functions:log`.
    //
    // Also surface enough header context to correlate with the Stripe
    // dashboard events → deliveries view: sig prefix + body size + IP,
    // without leaking the raw signature (which is a HMAC and pointless
    // in logs anyway).
    const sigPreview = String(sig || "").split(",")[0] || "";
    console.warn("stripeWebhook: Signature verification failed (likely secret-rotation retry noise)", {
      error: err?.message || String(err),
      sigTimestampChunk: sigPreview,
      bodySize: req.rawBody?.length ?? 0,
      remoteIp: req.headers["x-forwarded-for"] || req.ip,
    });
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

  // Direct Charges: events from a connected account carry event.account set
  // to that account id. When present, every stripe.<resource>.retrieve in
  // this handler MUST include {stripeAccount: event.account} because the
  // sub-object (charge, PI, invoice, etc.) lives in the connected account
  // namespace, not the platform. Without this, retrieves return
  // resource_missing and downstream fields (payment_method wallet type,
  // application_fee amount, etc.) silently default to fallback values.
  const acctReqOpts = event.account ? { stripeAccount: event.account } : {};

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
            const charge = await stripeClient.charges.retrieve(intent.latest_charge, acctReqOpts);
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
              // BUG-022 fix: surface drift in the super_admin activity feed so
              // ops sees it instead of having to scrape Cloud Logging. The
              // money already moved to `stampedConnect` (the old account) but
              // the tenant attribution points at `currentConnect`.
              try {
                await writeActivityLog({
                  type: "stripe_connect_account_drift",
                  tenantId: txTenantId,
                  tenantName: tenantSnap.data()?.name ?? txTenantId,
                  severity: "error",
                  requiresAction: true,
                  data: {
                    uid,
                    paymentIntentId: docId,
                    eventId: event.id,
                    stampedConnect,
                    currentConnect,
                  },
                });
              } catch (logErr) {
                console.warn("stripeWebhook: drift activityLog failed", { err: logErr?.message });
              }
            }
          } catch (driftErr) {
            console.warn("stripeWebhook: drift check failed", {
              tenantId: txTenantId, err: driftErr?.message,
            });
          }
        }
        const txRates = await getExchangeRates(null);
        const txSnap = buildCurrencySnapshot(amount, txCurrency, txRates);

        // Round-11 audit IMPORTANTE fix: check if the user was blocked
        // between createPaymentIntent and this webhook. Stripe already
        // charged the card — we can't retroactively refuse the funds —
        // but we FLAG the tx as blocked-at-charge so the admin can
        // decide (refund manually, keep, review). Without this, admin
        // blocks a suspected fraud user, they complete an open checkout,
        // and the tx lands in the tenant's revenue as if the block never
        // happened. Non-fatal: any Firestore read failure defaults to
        // "not blocked" so we never break the webhook.
        let flaggedBlocked = false;
        try {
          const blockCheckSnap = await db.collection("users").doc(uid).get();
          if (blockCheckSnap.exists && blockCheckSnap.data()?.isBlocked === true) {
            flaggedBlocked = true;
            console.warn("stripeWebhook: payment_intent.succeeded from BLOCKED user — flagging tx", {
              uid, paymentIntentId: docId, tenantId: txTenantId,
            });
          }
        } catch (blockErr) {
          console.warn("stripeWebhook: block check failed (non-fatal)", { uid, err: blockErr?.message });
        }

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
            status: flaggedBlocked ? 'flagged_blocked_user' : 'completed',
            ...(flaggedBlocked ? { flaggedBlocked: true } : {}),
            // donorMessage was sanitized in createPaymentIntent before being
            // stamped on the PI metadata; re-sanitize defensively here so a
            // forged event (theoretical — Stripe signature blocks this) can't
            // smuggle control chars into Firestore.
            ...(intent.metadata?.donorMessage
              ? { donorMessage: sanitizeDonorMessage(intent.metadata.donorMessage) }
              : {}),
            // Donation designation — copied from PI metadata to power admin
            // analytics ("which destination receives most donations?"). Cap
            // length defensively even though createPaymentIntent already did.
            ...(intent.metadata?.donationReason &&
              typeof intent.metadata.donationReason === "string" &&
              intent.metadata.donationReason.trim().length > 0
              ? { donationReason: String(intent.metadata.donationReason).trim().slice(0, 80) }
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

        // BUG #7 fix: guarded via applyRevenueDeltaOnce so a stuck-recovery
        // retry (event doc TTL > 5min or 'failed' status) doesn't double-count.
        if (txTenantId) await applyRevenueDeltaOnce(eventRef, txTenantId, txSnap.amountUSD, "increment");

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
      const uid = await resolveUidFromCharge(charge, stripe, acctReqOpts);
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
          //
          // Multi-partial refund fix: charge.amount_refunded is Stripe's
          // CUMULATIVE field, so refundedAmount grows on each partial
          // refund event ($30 then $80 for two $30/$50 refunds). Blindly
          // decrementing that would over-charge the tenant. We store
          // lastAppliedRefundAmount on the refund tx doc and only decrement
          // the delta since last event. Wrapped in a Firestore transaction
          // so concurrent duplicate deliveries can't double-decrement.
          //
          // Try both PI-keyed doc (regular donations) and inv-keyed doc
          // (subscription-generated charges) for tenant resolution.
          const originalTxRef = db
            .collection("users").doc(uid)
            .collection("transactions").doc(paymentIntentId);
          const invoiceId = typeof charge.invoice === "string"
            ? charge.invoice
            : (charge.invoice?.id || null);
          const invoiceTxRef = invoiceId
            ? db.collection("users").doc(uid)
                .collection("transactions").doc(`inv_${invoiceId}`)
            : null;
          const refundTxRef = db
            .collection("users").doc(uid)
            .collection("transactions").doc(`refund_${charge.id}`);
          const txRates = await getExchangeRates(null);

          await db.runTransaction(async (tx) => {
            const readTargets = [tx.get(originalTxRef), tx.get(refundTxRef)];
            if (invoiceTxRef) readTargets.push(tx.get(invoiceTxRef));
            const snaps = await Promise.all(readTargets);
            const originalTxSnap = snaps[0];
            const refundTxSnap = snaps[1];
            const invoiceTxSnap = invoiceTxRef ? snaps[2] : null;

            const originalMissing = !originalTxSnap.exists && !(invoiceTxSnap && invoiceTxSnap.exists);
            if (originalMissing) {
              console.warn("stripeWebhook: refund_before_original", {
                uid, paymentIntentId, chargeId: charge.id, invoiceId, eventId: event.id,
                note: "negating tx written with originalMissing flag — ops should reconcile",
              });
            }

            const lastApplied = Number(refundTxSnap.data()?.lastAppliedRefundAmount) || 0;
            const deltaAmount = refundedAmount - lastApplied;
            if (deltaAmount <= 0) {
              // Duplicate or out-of-order delivery — already accounted for.
              console.warn("stripeWebhook: refund_delta_nonpositive", {
                uid, chargeId: charge.id, refundedAmount, lastApplied, eventId: event.id,
              });
              return;
            }

            // The tx doc reflects the CUMULATIVE negative amount (audit-friendly),
            // while the decrement uses only the per-event DELTA.
            const cumulativeSnap = buildCurrencySnapshot(refundedAmount, currency, txRates);
            const deltaSnap = buildCurrencySnapshot(deltaAmount, currency, txRates);
            const negativeSnap = {};
            for (const [k, v] of Object.entries(cumulativeSnap)) {
              negativeSnap[k] = typeof v === "number" ? -v : v;
            }
            // Resolve tenantId from the original tx (refunds inherit it) BEFORE
            // writing the refund tx doc — so the doc gets stamped with
            // tenantId and shows up in tenant-scoped queries
            // (getRecentTransactions, LiveDonations widget). Without this
            // stamp, the CG rule that requires tenantId in resource.data
            // silently hides refunds from tenant admins — the donation still
            // appears as a positive in their history, but the offset is
            // invisible, making net-revenue reconciliation impossible.
            // Legacy positives that lack tenantId leave the refund null too
            // (super_admin-only visibility, same as the original).
            const refundTenantId = (originalTxSnap.exists
              ? originalTxSnap.data()?.tenantId
              : (invoiceTxSnap?.exists ? invoiceTxSnap.data()?.tenantId : null)) ?? null;
            tx.set(refundTxRef, {
              type: "refund",
              amount: -refundedAmount,
              currencyCode: currency,
              ...negativeSnap,
              ...(refundTenantId ? { tenantId: refundTenantId } : {}),
              description: "Reembolso Stripe",
              originalPaymentIntentId: paymentIntentId,
              originalInvoiceId: invoiceId || null,
              originalChargeId: charge.id,
              lastAppliedRefundAmount: refundedAmount,
              ...(originalMissing ? { originalMissing: true } : {}),
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });

            // BUG-024 fix: also decrement tenant revenue counter so admin
            // finance dashboards show net donations (gross minus refunds).
            //
            // Round-9 regression fix (LOW #1): stamp the decrement against
            // the ORIGINAL donation's month so historical buckets stay
            // net-accurate. Previously we stamped `now` — a January refund
            // of an October donation would silently make October look $X
            // larger than it actually was. Matches the dispute path which
            // uses applyRevenueDeltaOnce with originalDate.
            if (refundTenantId && deltaSnap.amountUSD > 0) {
              const originalTxData = originalTxSnap.exists
                ? originalTxSnap.data()
                : (invoiceTxSnap?.exists ? invoiceTxSnap.data() : null);
              const originalCreatedAt = originalTxData?.createdAt;
              const stampDate = originalCreatedAt?.toDate
                ? originalCreatedAt.toDate()
                : new Date();
              const stampMonthKey = `${stampDate.getUTCFullYear()}_${String(stampDate.getUTCMonth() + 1).padStart(2, "0")}`;
              tx.set(db.collection("tenants").doc(refundTenantId), {
                revenueStats: {
                  [stampMonthKey]: { revenue: admin.firestore.FieldValue.increment(-deltaSnap.amountUSD) },
                  allTime: { revenue: admin.firestore.FieldValue.increment(-deltaSnap.amountUSD) },
                },
              }, { merge: true });
            }
          });
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
        try { charge = await stripe.charges.retrieve(chargeId, acctReqOpts); } catch (_) { /* ignore */ }
      }
      const uid = charge ? await resolveUidFromCharge(charge, stripe, acctReqOpts) : null;
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
          // Resolve tenantId BEFORE writing the chargeback tx so the doc
          // itself carries `tenantId` — otherwise the tenant-scoped
          // history query (`where tenantId == X`) silently hides the loss
          // from the Rab, defeating the whole point of a negating row.
          // Try PI-keyed doc first (regular donations), then invoice-keyed
          // (subscription-generated charges).
          let refundTenantId = null;
          try {
            if (paymentIntentId) {
              const origSnap = await db.collection("users").doc(uid)
                .collection("transactions").doc(paymentIntentId).get();
              if (origSnap.exists) refundTenantId = origSnap.data()?.tenantId ?? null;
            }
            if (!refundTenantId) {
              const invoiceId = typeof charge?.invoice === "string"
                ? charge.invoice
                : charge?.invoice?.id;
              if (invoiceId) {
                const invSnap = await db.collection("users").doc(uid)
                  .collection("transactions").doc(`inv_${invoiceId}`).get();
                if (invSnap.exists) refundTenantId = invSnap.data()?.tenantId ?? null;
              }
            }
          } catch (tidErr) {
            console.warn("dispute.created: tenantId lookup failed (non-fatal)", {
              uid, chargeId, err: tidErr?.message,
            });
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
              ...(refundTenantId ? { tenantId: refundTenantId } : {}),
              description: "Contracargo (Stripe dispute)",
              disputeId: dispute.id,
              originalChargeId: chargeId,
              originalPaymentIntentId: paymentIntentId,
              disputeStatus: dispute.status || "needs_response",
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });

          // BUG #3 fix: guarded via applyRevenueDeltaOnce (stuck-recovery
          // retry safety) — was decrementing every retry, silently draining
          // the tenant revenue counter to negative on repeated deliveries.
          // Round 2 fix: no swallowing try/catch — if the tx fails, let it
          // propagate to the outer webhook catch so the event finalizes as
          // 'failed' and Stripe retries. Silently absorbing here would leave
          // the counter permanently out of sync.
          //
          // Refund crosses months? Recover the original donation date so the
          // nested bucket is decremented from the RIGHT month, not the refund
          // month (bug #6). Best-effort — falls back to "now" if unavailable.
          if (refundTenantId && txSnap.amountUSD > 0) {
            let originalDate = null;
            if (paymentIntentId) {
              try {
                const origSnap = await db.collection("users").doc(uid)
                  .collection("transactions").doc(paymentIntentId).get();
                const createdAt = origSnap.exists ? origSnap.data()?.createdAt : null;
                if (createdAt && typeof createdAt.toDate === "function") {
                  originalDate = createdAt.toDate();
                }
              } catch (_) { /* fall back to 'now' */ }
            }
            await applyRevenueDeltaOnce(eventRef, refundTenantId, txSnap.amountUSD, "decrement",
              originalDate ? { originalDate } : undefined);
          }
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

      // Alerta email crítica a super_admin (Ioel). Fire-and-forget para no
      // bloquear la escritura del webhook si SendGrid está caído. Los
      // disputes son time-sensitive (7-21 días para responder con evidence)
      // y perder uno = fee $15 + hit al risk score de Stripe.
      try {
        const disputeReason = dispute.reason || "sin razón especificada";
        const dashboardUrl = event.livemode
          ? `https://dashboard.stripe.com/disputes/${dispute.id}`
          : `https://dashboard.stripe.com/test/disputes/${dispute.id}`;
        sendEmail({
          to: SUPER_ADMIN_EMAIL,
          subject: `🚨 Chargeback recibido: ${currency} ${disputedAmount.toFixed(2)}`,
          html: `
            <h2 style="color:#dc2626;font-family:sans-serif">Chargeback recibido</h2>
            <p style="font-family:sans-serif;font-size:15px;line-height:1.5">
              Un donante inició un dispute en Stripe. Tenés <b>7 a 21 días</b> para responder con evidence o perdés el monto + $15 fee + hit al risk score de la cuenta.
            </p>
            <table style="font-family:sans-serif;font-size:14px;border-collapse:collapse;margin-top:16px">
              <tr><td style="padding:4px 12px;color:#64748b">Monto:</td><td style="padding:4px 12px"><b>${currency} ${disputedAmount.toFixed(2)}</b></td></tr>
              <tr><td style="padding:4px 12px;color:#64748b">Razón:</td><td style="padding:4px 12px">${disputeReason}</td></tr>
              <tr><td style="padding:4px 12px;color:#64748b">Dispute ID:</td><td style="padding:4px 12px;font-family:monospace">${dispute.id}</td></tr>
              <tr><td style="padding:4px 12px;color:#64748b">Charge ID:</td><td style="padding:4px 12px;font-family:monospace">${chargeId || "N/A"}</td></tr>
              <tr><td style="padding:4px 12px;color:#64748b">Ambiente:</td><td style="padding:4px 12px">${event.livemode ? "LIVE (dinero real)" : "TEST"}</td></tr>
            </table>
            <p style="margin-top:24px">
              <a href="${dashboardUrl}" style="display:inline-block;padding:12px 20px;background:#2563eb;color:#fff;text-decoration:none;border-radius:8px;font-family:sans-serif;font-weight:600">Ver en Stripe Dashboard →</a>
            </p>
            <p style="margin-top:24px;font-family:sans-serif;font-size:12px;color:#94a3b8">
              Alerta automática de Chabad Pushka backend.
            </p>
          `,
        }).catch(err => console.warn("dispute.created: alert email failed", { errorMessage: err?.message }));
      } catch (alertErr) {
        console.warn("dispute.created: alert email setup failed", { errorMessage: alertErr?.message });
      }
    } else if (event.type === "charge.dispute.closed") {
      // Dispute resolved. If we WON, reverse the negating chargeback tx.
      const dispute = event.data.object;
      const chargeId = typeof dispute.charge === "string" ? dispute.charge : dispute.charge?.id;
      let charge = null;
      if (chargeId) {
        try { charge = await stripe.charges.retrieve(chargeId, acctReqOpts); } catch (_) { /* ignore */ }
      }
      const uid = charge ? await resolveUidFromCharge(charge, stripe, acctReqOpts) : null;

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
          // Reverse the tenant-revenue decrement written by dispute.created.
          // Read the chargeback tx BEFORE deleting to recover the tenantId
          // and amount snapshot. Fire-and-forget so a failed increment
          // doesn't block the deletion.
          const disputeTxRef = db.collection("users").doc(uid)
            .collection("transactions").doc(`dispute_${dispute.id}`);
          try {
            const disputeTxSnap = await disputeTxRef.get();
            const disputeTx = disputeTxSnap.exists ? disputeTxSnap.data() : null;
            // Look up the original tx to recover tenantId (chargeback tx
            // itself doesn't store tenantId in the current schema).
            let refundTenantId = null;
            const origPiId = disputeTx?.originalPaymentIntentId || null;
            if (origPiId) {
              const origSnap = await db.collection("users").doc(uid)
                .collection("transactions").doc(origPiId).get();
              if (origSnap.exists) refundTenantId = origSnap.data()?.tenantId ?? null;
            }
            if (!refundTenantId) {
              const invId = typeof charge?.invoice === "string"
                ? charge.invoice
                : charge?.invoice?.id;
              if (invId) {
                const invSnap = await db.collection("users").doc(uid)
                  .collection("transactions").doc(`inv_${invId}`).get();
                if (invSnap.exists) refundTenantId = invSnap.data()?.tenantId ?? null;
              }
            }
            // amountUSD stored on chargeback is negative (we flipped signs) —
            // reinstate by adding back the absolute value.
            const negUsd = Number(disputeTx?.amountUSD || 0);
            const reinstateUsd = Math.abs(negUsd);
            if (refundTenantId && reinstateUsd > 0) {
              // BUG #9 + Round-2 bug #4 fix: applyRevenueDeltaOnce is now
              // fully atomic AND covers the flat KPI fields (the old inline
              // reinstate only touched the nested map, leaving the Rab's
              // real-time monthRevenueUSD dashboard permanently under-reported
              // after a won dispute). Stamp under the original donation month
              // so allTime + suma-de-meses stays net-consistent.
              let originalDate = null;
              if (origPiId) {
                try {
                  const origSnap = await db.collection("users").doc(uid)
                    .collection("transactions").doc(origPiId).get();
                  const createdAt = origSnap.exists ? origSnap.data()?.createdAt : null;
                  if (createdAt && typeof createdAt.toDate === "function") {
                    originalDate = createdAt.toDate();
                  }
                } catch (_) { /* fall back to 'now' */ }
              }
              await applyRevenueDeltaOnce(eventRef, refundTenantId, reinstateUsd, "increment",
                originalDate ? { originalDate } : undefined);
            }
          } catch (reinstateErr) {
            // Preserve legacy behavior for lookup/deletion failures — those
            // shouldn't block Stripe from acking the event since we already
            // reversed the tenant charge on the previous dispute.created.
            console.warn("dispute.closed(won): revenue reinstate failed (non-fatal)", {
              uid, disputeId: dispute.id, err: reinstateErr?.message,
            });
          }
          await disputeTxRef.delete().catch(() => { /* never written, ignore */ });
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
        try { charge = await stripe.charges.retrieve(chargeId, acctReqOpts); } catch (_) { /* ignore */ }
      }
      const uid = charge ? await resolveUidFromCharge(charge, stripe, acctReqOpts) : null;
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
        // BUG-023 fix: alert super_admin when Connect becomes restricted —
        // active charges will now fail (createPaymentIntent rejects), so the
        // tenant_admin needs to redo Stripe verification ASAP.
        if (newConnectStatus === "restricted" && prevConnectStatus === "active") {
          await writeActivityLog({
            type: "stripe_connect_restricted",
            tenantId: tenantsSnap.docs[0].id,
            tenantName: tenantDocData.name ?? tenantsSnap.docs[0].id,
            severity: "error",
            requiresAction: true,
            data: {
              accountId,
              chargesEnabled: chargesEnabled,
              payoutsEnabled: payoutsEnabled,
            },
          });
        }
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        accountId,
        outcome: "account_updated",
      });
    } else if (event.type === "account.application.deauthorized") {
      // A tenant admin revoked Pushka's access from their Stripe dashboard.
      // Without this handler, tenants/{id}.stripeConnectStatus would stay
      // "active" and subsequent donations would fail cryptically inside
      // createPaymentIntent when Stripe rejects the transfer_data
      // destination. Flip status to "disconnected" and alert.
      const account = event.data.object;
      const accountId = (event.account) || account.id || null;

      let disconnectedTenantId = null;
      let disconnectedTenantData = null;
      if (accountId) {
        const tenantsSnap = await db.collection("tenants")
          .where("stripeConnectAccountId", "==", accountId)
          .limit(1)
          .get();

        if (!tenantsSnap.empty) {
          const tenantRef = tenantsSnap.docs[0].ref;
          disconnectedTenantId = tenantsSnap.docs[0].id;
          disconnectedTenantData = tenantsSnap.docs[0].data() || {};

          await tenantRef.update({
            stripeConnectStatus: "disconnected",
            stripeConnectAccountId: admin.firestore.FieldValue.delete(),
            // Also drop any pending confirmation on the same tenant — the
            // rab revoked from Stripe, so the pending offer is dead too.
            pendingStripeConnect: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          await writeActivityLog({
            type: "stripe_connect_deauthorized",
            tenantId: disconnectedTenantId,
            tenantName: disconnectedTenantData.name ?? disconnectedTenantId,
            severity: "critical",
            requiresAction: true,
            data: { accountId },
          });

          // Fire-and-forget email to tenant admin + super_admin.
          try {
            // Round-6 audit fix: escape all tenant-controlled fields before
            // interpolating into HTML (tenant admin controls appName/name).
            const rawTenantName = disconnectedTenantData.name || disconnectedTenantData.appName || disconnectedTenantId;
            const tenantName = _escapeHtmlForEmail(rawTenantName);
            const adminEmail = disconnectedTenantData.adminEmail || null;
            const whenIso = new Date().toISOString();
            const subject = `[Pushka] Stripe Connect DESCONECTADO para ${rawTenantName}`;
            const html = `
              <p style="font-family:sans-serif;font-size:15px;line-height:1.5">
                Se revocó el acceso de Pushka a la cuenta de Stripe de <strong>${tenantName}</strong>. Las donaciones nuevas <b>van a fallar</b> hasta que se reconecte una cuenta.
              </p>
              <table style="font-family:sans-serif;font-size:14px;border-collapse:collapse;margin-top:12px">
                <tr><td style="padding:4px 12px;color:#64748b">Tenant:</td><td style="padding:4px 12px"><b>${tenantName}</b> (<code>${_escapeHtmlForEmail(disconnectedTenantId)}</code>)</td></tr>
                <tr><td style="padding:4px 12px;color:#64748b">Cuenta desconectada:</td><td style="padding:4px 12px;font-family:monospace">${_escapeHtmlForEmail(accountId)}</td></tr>
                <tr><td style="padding:4px 12px;color:#64748b">Fecha (UTC):</td><td style="padding:4px 12px">${whenIso}</td></tr>
              </table>
              <p style="margin-top:20px;padding:12px 16px;background:#fef2f2;border-left:4px solid #dc2626;color:#991b1b;font-family:sans-serif;font-size:14px;line-height:1.5">
                <strong>Acción requerida:</strong> ingresá al panel y volvé a conectar Stripe para reanudar los pagos.
              </p>
            `;
            const recipients = [];
            if (adminEmail) recipients.push(adminEmail);
            if (SUPER_ADMIN_EMAIL &&
                SUPER_ADMIN_EMAIL.toLowerCase() !== (adminEmail || "").toLowerCase()) {
              recipients.push(SUPER_ADMIN_EMAIL);
            }
            await Promise.all(recipients.map(to =>
              sendEmail({ to, subject, html }).catch(err =>
                console.warn("stripeWebhook: deauthorized alert email failed", {
                  tenantId: disconnectedTenantId, to: _redactEmail(to), error: err?.message,
                })
              )
            ));
          } catch (alertErr) {
            console.warn("stripeWebhook: deauthorized alert block failed", {
              tenantId: disconnectedTenantId, error: alertErr?.message,
            });
          }
        } else {
          console.warn("stripeWebhook: account.application.deauthorized — no tenant found", { accountId });
        }
      } else {
        console.warn("stripeWebhook: account.application.deauthorized without accountId", { eventId: event.id });
      }

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        accountId,
        tenantId: disconnectedTenantId,
        outcome: "account_deauthorized",
      });
    } else if (event.type === "application_fee.created") {
      // Our commission was collected — log for tracking.
      // BUG #10 fix: fee.charge on application_fee events is a STRING (charge id),
      // NOT an expanded object. `fee.charge?.metadata?.tenantId` was always null
      // (undefined property access on a string). Retrieve the charge via the
      // Stripe API when we need its metadata; skip if we can't get it.
      const fee = event.data.object;
      const chargeId = typeof fee.charge === "string" ? fee.charge : fee.charge?.id ?? null;
      let tenantId = null;
      if (chargeId) {
        try {
          const stripeClient = require("stripe")(stripeSecret.value());
          // Charge lives on the connected account for direct charges.
          const chargeAcctOpts = event.account ? { stripeAccount: event.account } : {};
          const chargeObj = await stripeClient.charges.retrieve(chargeId, chargeAcctOpts);
          tenantId = chargeObj?.metadata?.tenantId ?? null;
        } catch (chargeErr) {
          console.warn("stripeWebhook: application_fee.created charge retrieve failed", {
            feeId: fee.id, chargeId, err: chargeErr?.message,
          });
        }
      }
      const amountUsd = (fee.amount || 0) / currencyUnitDivisor(fee.currency || "usd");

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        tenantId,
        amountUsd,
        chargeId,
        outcome: "commission_collected",
      });
    } else if (event.type === "application_fee.refunded") {
      // Commission refunded back to platform from connected account — happens
      // automatically when the underlying charge is refunded.
      // BUG #10 fix: same string vs object issue as application_fee.created.
      const fee = event.data.object;
      const chargeId = typeof fee.charge === "string" ? fee.charge : fee.charge?.id ?? null;
      let tenantId = null;
      if (chargeId) {
        try {
          const stripeClient = require("stripe")(stripeSecret.value());
          const chargeAcctOpts = event.account ? { stripeAccount: event.account } : {};
          const chargeObj = await stripeClient.charges.retrieve(chargeId, chargeAcctOpts);
          tenantId = chargeObj?.metadata?.tenantId ?? null;
        } catch (chargeErr) {
          console.warn("stripeWebhook: application_fee.refunded charge retrieve failed", {
            feeId: fee.id, chargeId, err: chargeErr?.message,
          });
        }
      }
      const refundedAmount = (fee.amount_refunded || 0) /
        currencyUnitDivisor(fee.currency || "usd");

      await finalizeWebhookEvent(eventRef, {
        status: "processed",
        tenantId,
        amountUsd: refundedAmount,
        chargeId,
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
      const sub = event.data.object;
      // CRITICAL GUARD: donation_recurring subs (donor's monthly gifts) ALSO
      // carry metadata.tenantId (for attribution to the org). Without this
      // filter, cancelling a donation_recurring sub would set the tenant to
      // "suspended" and lock the entire org out of the app. This bug hit
      // prod 2026-08-03 after Ioel cancelled his $1/mo test sub — the
      // chabadmexico tenant was flagged suspended and every user saw
      // "Servicio no disponible". Cross-check: donation_recurring subs are
      // created with purpose='donation_recurring' in createDonationSubscription
      // (functions/index.js:~1895). SaaS-billing subs (tenant pays platform)
      // have a different metadata shape (purpose absent or set to a saas
      // sentinel), so this check safely divides the two flows.
      if (sub.metadata?.purpose === "donation_recurring") {
        await finalizeWebhookEvent(eventRef, {
          status: "processed",
          subscriptionId: sub.id,
          outcome: "donation_recurring_status_change_ignored",
        });
        // BUG #2 fix: send HTTP 200 so Stripe stops retrying. Previously
        // this branch fell through the outer function's `return` without
        // sending a response → Stripe timed out → retry storm for every
        // donation-recurring lifecycle event.
        res.json({ received: true, outcome: "donation_recurring_ignored" });
        return;
      }
      // Tenant Stripe Billing subscription state change. Mirror the status
      // onto tenants/{tid} so the suspension/grace-period logic
      // (router redirects, processPushkaAutoEmpty gate) reacts within seconds
      // instead of waiting for the next 60s tenant-config poll.
      const tenantId = sub.metadata?.tenantId ?? null;
      const status = sub.status; // active|past_due|canceled|unpaid|trialing|...

      if (tenantId) {
        const tenantStatus =
          status === "active" || status === "trialing" ? "active" :
          status === "past_due" || status === "unpaid" ? "grace_period" :
          status === "canceled" ? "suspended" :
          null; // ignore incomplete/incomplete_expired noise
        if (tenantStatus) {
          // Stripe API 2025-04+ removed sub.current_period_end from the
          // top-level subscription object — it now lives on the first item
          // (a sub can technically have multiple items on different cycles).
          // Fall back to the item's value so billingNextDue keeps working.
          // Mirrors the pattern used in listDonationSubscriptions.
          const cpe = sub.current_period_end
            ?? sub.items?.data?.[0]?.current_period_end
            ?? null;
          await db.collection("tenants").doc(tenantId).set({
            status: tenantStatus,
            paymentStatus: status,
            stripeSubscriptionId: sub.id,
            ...(cpe
              ? { billingNextDue: admin.firestore.Timestamp.fromMillis(cpe * 1000) }
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
        // Recurring-donation Connect drift detection (mirrors the PI drift
        // check in payment_intent.succeeded above). A subscription pins
        // transfer_data.destination at sub-creation time — if the tenant
        // later rotated their Connect account (Stripe verification
        // failed, they re-onboarded, etc.), every future invoice keeps
        // routing to the OLD account until someone updates the sub. Money
        // arrives at an account the tenant may not control anymore; the
        // Firestore tenant doc points at the new account. Alert loud so
        // Ioel can decide (refund + recreate sub, or push a sub update).
        // Do NOT auto-refund or auto-cancel — that's a business decision.
        if (tenantId) {
          try {
            const invoiceDest = invoice.transfer_data?.destination
              ?? invoice.parent?.subscription_details?.metadata?.connectAccountId
              ?? null;
            const invoiceDestId = typeof invoiceDest === "string"
              ? invoiceDest
              : invoiceDest?.id ?? null;
            if (invoiceDestId) {
              const tenantSnap = await db.collection("tenants").doc(tenantId).get();
              const currentConnect = tenantSnap.data()?.stripeConnectAccountId ?? null;
              if (currentConnect && currentConnect !== invoiceDestId) {
                console.error("stripeWebhook: recurring connectAccountId DRIFT", {
                  uid, tenantId, invoiceId: invoice.id, subId,
                  invoiceDestination: invoiceDestId,
                  currentConnect,
                });
                try {
                  await writeActivityLog({
                    type: "stripe_connect_drift_recurring",
                    tenantId,
                    tenantName: tenantSnap.data()?.name ?? tenantId,
                    severity: "critical",
                    requiresAction: true,
                    data: {
                      uid,
                      subscriptionId: subId,
                      invoiceId: invoice.id,
                      invoiceDestination: invoiceDestId,
                      currentConnect,
                      note: "Recurring invoice routed to old Connect account. Decide: refund + recreate sub (donor keeps giving to correct account) or ignore (money stays with old account).",
                    },
                  });
                } catch (logErr) {
                  console.warn("stripeWebhook: recurring drift activityLog failed", { err: logErr?.message });
                }
              }
            }
          } catch (driftErr) {
            console.warn("stripeWebhook: recurring drift check failed", {
              tenantId, subId, err: driftErr?.message,
            });
          }
        }
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
              // Donation designation inherited from the subscription. Powers
              // admin "donations by destination" reports.
              ...(subMeta?.donationReason &&
                typeof subMeta.donationReason === "string" &&
                subMeta.donationReason.trim().length > 0
                ? { donationReason: String(subMeta.donationReason).trim().slice(0, 80) }
                : {}),
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
          // BUG #8 fix: guarded via applyRevenueDeltaOnce (stuck-recovery dedup)
          if (tenantId) await applyRevenueDeltaOnce(eventRef, tenantId, txSnap.amountUSD, "increment");
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

    const fmtAbs = (n) => `${sym}${Math.abs(Number(n)).toFixed(2)}`;
    const messages = {
      es: {
        tzedaka:       `¡Gracias por tu donación! ${fmt(amount)}`,
        pushkaEmpty:   `Tu Pushka fue vaciada. Donación: ${fmt(amount)}`,
        refund:        `Reembolso procesado: ${fmtAbs(amount)}`,
        chargeback:    `Contracargo recibido: ${fmtAbs(amount)}. Tu banco está investigando un cargo.`,
        default:       "Nueva transacción registrada",
      },
      en: {
        tzedaka:       `Thank you for your donation! ${fmt(amount)}`,
        pushkaEmpty:   `Your Pushka was emptied. Donation: ${fmt(amount)}`,
        refund:        `Refund processed: ${fmtAbs(amount)}`,
        chargeback:    `Chargeback received: ${fmtAbs(amount)}. Your bank is investigating a charge.`,
        default:       "New transaction recorded",
      },
      fr: {
        tzedaka:       `Merci pour votre don ! ${fmt(amount)}`,
        pushkaEmpty:   `Votre Pushka a été vidée. Don : ${fmt(amount)}`,
        refund:        `Remboursement traité : ${fmtAbs(amount)}`,
        chargeback:    `Contestation reçue : ${fmtAbs(amount)}. Votre banque enquête sur un paiement.`,
        default:       "Nouvelle transaction enregistrée",
      },
      he: {
        tzedaka:       `תודה על תרומתך! ${fmt(amount)}`,
        pushkaEmpty:   `הפושקה שלך רוקנה. תרומה: ${fmt(amount)}`,
        refund:        `החזר עובד: ${fmtAbs(amount)}`,
        chargeback:    `התקבל ערעור על חיוב: ${fmtAbs(amount)}. הבנק שלך בודק את החיוב.`,
        default:       "עסקה חדשה נרשמה",
      },
    };

    const m = messages[lang];
    let body = m.default;
    if (type === "tzedaka") body = m.tzedaka;
    else if (type === "pushkaEmpty") body = m.pushkaEmpty;
    else if (type === "refund") body = m.refund;
    else if (type === "chargeback") body = m.chargeback;

    const tenantId = data.tenantId ?? "";

    // Title: prefer the tenant's appName so the notification matches the
    // branded UI the donor sees in-app. Falls back to "Pushka" for legacy
    // transactions without a tenantId or when the tenant doc is unreachable.
    //
    // Perf: cache appName per tenantId in a module-level Map with a 5 min
    // TTL. Without this every single donation triggered a fresh
    // tenants/{id} read; on a hot tenant that's one Firestore read per
    // donation on top of the trigger overhead. The cache lives inside the
    // warm instance — cold starts re-fetch, which is fine (appName rarely
    // changes and onTenantBrandingUpdated will invalidate the whole
    // container within a few minutes anyway).
    let title = "Pushka";
    if (tenantId) {
      try {
        const cached = _tenantAppNameCache.get(tenantId);
        if (cached && (Date.now() - cached.at) < TENANT_APPNAME_TTL_MS) {
          if (cached.appName) title = cached.appName;
        } else {
          const tSnap = await db.collection("tenants").doc(tenantId).get();
          const appName = String(tSnap.data()?.appName || "").trim();
          _tenantAppNameCache.set(tenantId, { appName, at: Date.now() });
          if (appName) title = appName;
        }
      } catch (_) { /* keep default */ }
    }

    await sendToUser(uid, {
      notification: { title, body },
      data: { type, amount: String(amount), tenantId, click_action: "/wallet" },
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

    // Round-11 audit MENOR + IMPORTANTE fix: denormalize `transactionCount`
    // and `lastDonationAt` onto `users/{uid}` so the admin CRM can show
    // them without an N+1 aggregation. Only count actual donations
    // (tzedaka + pushkaEmpty), NOT refunds or wallet fills — those would
    // inflate the count misleadingly. Best-effort; if this fails the
    // trigger still succeeded at delivering the notification.
    const countsAsDonation = type === "tzedaka" || type === "pushkaEmpty";
    if (countsAsDonation && uid) {
      try {
        await db.collection("users").doc(uid).set({
          transactionCount: admin.firestore.FieldValue.increment(1),
          lastDonationAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (err) {
        console.warn("onTransactionCreated: denorm failed (non-fatal)", String(err?.message || err));
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
    // Page through tenants instead of `.get()` on the whole collection —
    // safe at 100s of tenants today, but a single unbounded scan would
    // start hitting timeouts / memory ceilings around 10k+ tenants. Reads
    // are batched at 500 and writes at 400 (Firestore batch limit).
    const PAGE_SIZE = 500;
    const BATCH_SIZE = 400;
    let totalReset = 0;
    let lastDoc = null;
    while (true) {
      let q = db.collection("tenants").orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE_SIZE);
      if (lastDoc) q = q.startAfter(lastDoc);
      const tenantsSnap = await q.get();
      if (tenantsSnap.empty) break;
      let batch = db.batch();
      let count = 0;
      for (const doc of tenantsSnap.docs) {
        batch.update(doc.ref, { activeUsersThisMonth: 0 });
        if (++count % BATCH_SIZE === 0) { await batch.commit(); batch = db.batch(); }
      }
      if (count % BATCH_SIZE !== 0) await batch.commit();
      totalReset += tenantsSnap.size;
      lastDoc = tenantsSnap.docs[tenantsSnap.docs.length - 1];
      if (tenantsSnap.size < PAGE_SIZE) break;
    }

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
    console.info("resetMonthlyActiveUsers: complete", { tenantsReset: totalReset, monthlyActiveDeleted: deleted });
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

    const fieldMap = {
      name: "tenantName",
      appName: "tenantAppName",
      logoUrl: "tenantLogoUrl",
      primaryColor: "tenantPrimaryColor",
      // secondaryColor removed (Audit Round 4 — Bug C): no widget consumed
      // the secondary accent visually. The field is also gone from the
      // admin web editor + Flutter theme.
      contactPhone: "tenantContactPhone",
      // Round-11 audit MEDIO fix: previous mapping omitted these branded
      // fields. Any future UI that reads them from tenantState (support
      // screen, welcome copy, privacy link surfacing, address block) would
      // see stale data indefinitely because we never propagated the
      // updates. Mirror everything now so the deuda técnica desaparece
      // before anyone reads the stale field.
      welcomeText: "tenantWelcomeText",
      contactEmail: "tenantContactEmail",
      privacyPolicyUrl: "tenantPrivacyPolicyUrl",
      city: "tenantCity",
      country: "tenantCountry",
    };
    const changes = {};
    for (const [src, dest] of Object.entries(fieldMap)) {
      if (before[src] !== after[src]) {
        changes[dest] = after[src] ?? null;
      }
    }
    // donationReasons is an array — compare by JSON serialization.
    const beforeReasons = JSON.stringify(before.donationReasons ?? null);
    const afterReasons = JSON.stringify(after.donationReasons ?? null);
    if (beforeReasons !== afterReasons) {
      changes.tenantDonationReasons = after.donationReasons ?? null;
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


// --- Erev Rosh Chodesh computation (dynamic via @hebcal/core) ---
// Computes the next Erev Rosh Chodesh (day before the start of a Hebrew month)
// dynamically from the Hebrew calendar so the schedule never runs out. Skips
// Elul (its day 29 leads into Tishrei = Erev Rosh HaShana, handled separately
// as a holiday). Returns a UTC Date at 08:00.
//
// @hebcal/core is ESM-only — load via dynamic import + memoize.
let _hebcalCachePromise = null;
function _getHebcal() {
  if (!_hebcalCachePromise) {
    _hebcalCachePromise = import("@hebcal/core").then((mod) => ({
      HDate: mod.HDate,
      HMonths: mod.months,
    }));
  }
  return _hebcalCachePromise;
}

async function computeNextErevRoshChodesh(baseDate) {
  const { HDate, HMonths } = await _getHebcal();
  const now = new Date(baseDate);
  // Erev Rosh Chodesh = day 29 of any Hebrew month, EXCEPT Elul (whose day 29
  // leads into Tishrei = Erev Rosh HaShana, handled separately as a holiday).
  // Day 29 always exists regardless of whether the month has 29 or 30 days,
  // and is the colloquial "day before Rosh Chodesh begins".
  for (let dayOffset = 0; dayOffset < 400; dayOffset++) {
    const candidate = new Date(now);
    candidate.setUTCDate(candidate.getUTCDate() + dayOffset);
    candidate.setUTCHours(8, 0, 0, 0);
    if (candidate <= now) continue;

    const hd = new HDate(candidate);
    if (hd.getDate() === 29 && hd.getMonth() !== HMonths.ELUL) {
      return candidate;
    }
  }
  const fallback = new Date(now);
  fallback.setUTCDate(fallback.getUTCDate() + 30);
  return fallback;
}

// --- Pushka Auto Empty (scheduled) ---
// Reads from the `users/{uid}/tenantState/{tenantId}` subcollection so
// schedule + balance are per-organisation (a user belonging to two chabads
// gets two independent auto-empty cycles).
//
// BUG #16 fix: post-Direct-Charges migration, Stripe credentials (customer
// id + default PM) ALSO live on tenantState per-tenant, NOT on the flat
// user doc. Reads: tenantState.stripeConnectCustomerId +
// tenantState.stripeConnectDefaultPaymentMethodId (or autoEmptyPaymentMethodId
// override). Only cross-tenant settings (currencyCode, isBlocked) remain on
// users/{uid}. Requires a collection-group index on:
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

    // Paginated processing with soft deadline. Each iteration issues a Stripe
    // call (1-2s) + 2 Firestore txns. Page size 200 keeps memory bounded; we
    // keep paginating until either the query is drained or we approach the
    // function's 9-minute timeout. This scales past the previous 200/run cap.
    const PAGE_SIZE = 200;
    const SOFT_DEADLINE_MS = 7 * 60 * 1000; // 7 min — leaves 2 min buffer before 540s timeout
    const startedAt = Date.now();
    let processed = 0;
    let failed = 0;
    let skipped = 0;
    let cursor = null;
    let totalScanned = 0;
    const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });

    while (Date.now() - startedAt < SOFT_DEADLINE_MS) {
    let q = db
      .collectionGroup("tenantState")
      .where("autoEmptyNextRunAt", "<=", nowTs)
      .orderBy("autoEmptyNextRunAt", "asc")
      .limit(PAGE_SIZE);
    if (cursor) q = q.startAfter(cursor);
    const dueStates = await q.get();

    if (dueStates.empty) {
      if (totalScanned === 0) console.info("processPushkaAutoEmpty: no_due_states");
      break;
    }
    totalScanned += dueStates.size;
    cursor = dueStates.docs[dueStates.docs.length - 1];

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
            normalNextDate = await computeNextErevRoshChodesh(new Date());
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

          // Direct Charges: customers live per-connected-account. Read
          // stripeConnectCustomerId + stripeConnectDefaultPaymentMethodId
          // from tenantState (the per-tenant scope) instead of the flat
          // user doc fields (which were the platform customer, deprecated).
          const customerId = String(state.stripeConnectCustomerId || "").trim();
          const pmId = String(
            state.autoEmptyPaymentMethodId ||
            state.stripeConnectDefaultPaymentMethodId ||
            "",
          ).trim();
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

          // Round-4 audit CRITICAL fix: currency-drift guard. If the top-off
          // amount was persisted under a different currency than the user's
          // current one, refuse to charge — otherwise we'd interpret "500"
          // saved as ARS as USD 500 (~250× the intended donation). The
          // `changeUserCurrency` CF resets top-off atomically, but a legacy
          // record or a partial write from the old client-side flow can
          // leave a mismatch.
          const stampedTopOffCurrency = String(
            state.autoEmptyTopOffCurrency || ""
          ).toLowerCase().trim();
          if (topOffEnabled && topOffAmount > 0 && stampedTopOffCurrency && stampedTopOffCurrency !== rawCurrency) {
            console.warn("processPushkaAutoEmpty: skip_currency_drift", {
              uid, tenantId, userCurrency: rawCurrency, topOffCurrency: stampedTopOffCurrency,
            });
            tx.set(stateRef, {
              autoEmptyTopOffAmount: 0,
              autoEmptyTopOffEnabled: false,
              autoEmptyTopOffCurrency: admin.firestore.FieldValue.delete(),
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
                new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
              ),
              _lastAutoEmptySkipReason: "currency_drift",
              _lastAutoEmptySkipAt: admin.firestore.FieldValue.serverTimestamp(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
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
          } else if (!connectAccountId) {
            // Tenant never set up Connect. Previously we fell through to a
            // platform charge, which silently routed donor money to Pushka
            // instead of the tenant. Auto-empty is a BACKGROUND operation —
            // the donor didn't opt into this specific charge, so misrouting
            // it is worse than skipping. Defer 24h and log an activity so
            // the tenant_admin gets nudged.
            console.warn("processPushkaAutoEmpty: skip_no_connect", {
              uid, tenantId,
            });
            tx.set(stateRef, {
              autoEmptyNextRunAt: admin.firestore.Timestamp.fromDate(
                new Date(Date.now() + AUTO_EMPTY_RETRY_AFTER_FAILURE_HOURS * 3600 * 1000),
              ),
              _lastAutoEmptySkipReason: "tenant_connect_not_configured",
              _lastAutoEmptySkipAt: admin.firestore.FieldValue.serverTimestamp(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            // Fire-and-forget activity log outside the transaction — we
            // can't await inside runTransaction anyway. Best-effort.
            Promise.resolve().then(() => writeActivityLog({
              type: "auto_empty_skipped_no_connect",
              tenantId,
              tenantName: tenantData?.name ?? tenantId,
              severity: "warning",
              requiresAction: true,
              data: { uid },
            })).catch(() => {});
            return;
          }

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
        // Direct Charges: PI is created ON the connected account (via
        // Stripe-Account header below). No transfer_data / on_behalf_of —
        // those are for destination charges. application_fee_amount still
        // works if commissionRate > 0 (skims platform commission).
        if (plan.tenantConnectAccountId) {
          const appFee = computeApplicationFeeAmount(amountCents, plan.tenantCommissionRate);
          if (appFee) piParams.application_fee_amount = appFee.fee;
        }

        let paymentIntent;
        try {
          paymentIntent = await stripe.paymentIntents.create(piParams, {
            idempotencyKey,
            stripeAccount: plan.tenantConnectAccountId,
          });
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
            data: {
              type: "pushkaAutoEmptyFailed",
              tenantId: plan.tenantId,
              click_action: "/settings/saved-cards",
            },
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
            data: {
              type: "pushkaEmpty",
              amount: String(emptiedAmount),
              tenantId: plan.tenantId,
              click_action: "/wallet",
            },
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

    if (dueStates.size < PAGE_SIZE) break;
    }

    console.info("processPushkaAutoEmpty: completed", {
      processed, failed, skipped, totalScanned,
      hitSoftDeadline: Date.now() - startedAt >= SOFT_DEADLINE_MS,
    });
}

exports.processPushkaAutoEmpty = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Etc/UTC",
    secrets: [stripeSecret],
    maxInstances: 1,
    timeoutSeconds: 540,
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
  const rawRate = rates[code];
  // Round-4 audit HIGH fix: previous code silently defaulted unknown
  // currencies to rate=1 (i.e. treated 1 CLP as 1 USD → 1000× revenue
  // inflation on the tenant dashboard). Now we log LOUD when a rate is
  // missing so ops sees it, and mark the snapshot as unreliable
  // (`rateMissing: true`) so the aggregator (getSuperAdminDashboard)
  // can decide whether to skip it. amountUSD/MXN still get computed with
  // rate=1 as a best-effort fallback (rejecting the tx would lose donor
  // context on webhook writes), but the flag lets downstream reconcile.
  const rateMissing = !(rawRate > 0);
  if (rateMissing && code !== "USD") {
    console.warn("buildCurrencySnapshot: missing_rate_falling_back_to_1", {
      currencyCode: code, amount, availableRateKeys: Object.keys(rates || {}).length,
    });
  }
  const rate = rateMissing ? 1 : rawRate;
  const mxnRate = rates["MXN"] ?? 17.1;
  const amountUSD = code === "USD" ? amount : amount / rate;
  const amountMXN = amountUSD * mxnRate;
  const out = {
    amountUSD:         Math.round(amountUSD * 100) / 100,
    amountMXN:         Math.round(amountMXN * 100) / 100,
    exchangeRateToUSD: Math.round((1 / rate) * 1_000_000) / 1_000_000,
    exchangeRateToMXN: Math.round((mxnRate / rate) * 1_000_000) / 1_000_000,
  };
  if (rateMissing && code !== "USD") out.rateMissing = true;
  return out;
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

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// bootstrapSuperAdmin — first-time claim assignment for SUPER_ADMIN_EMAIL.
// ---------------------------------------------------------------------------
// Catch-22 problem: setAdminClaim requires the caller to already be super_admin
// (or tenant_admin). On a fresh project deploy nobody has the claim yet — so
// the SUPER_ADMIN_EMAIL account can sign up but the admin web shows them as a
// regular user. This endpoint solves it: the canonical super-admin email can
// promote ITSELF, exactly once, when no super_admin claim is present.
//
// Safety:
//   - Caller must be authenticated AND have request.auth.token.email match
//     SUPER_ADMIN_EMAIL exactly (constant in this file).
//   - We re-fetch the auth record to read the email server-side (token can lag
//     1h but the email matching is verified again against admin SDK truth).
//   - Refuse if the caller already has a super_admin claim — this endpoint is
//     ONLY for bootstrap, never for "refresh" or "fix" of an existing claim.
//   - Idempotent: a second call after the claim is set returns the existing
//     claim, doesn't error, doesn't overwrite.
// Rate limited so a compromised email cannot spam Auth.
exports.bootstrapSuperAdmin = onCall(
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    }
    await enforceRateLimit(request.auth.uid, "bootstrapSuperAdmin", 10, 3600);

    const callerRecord = await admin.auth().getUser(request.auth.uid);
    const callerEmail = callerRecord.email;
    if (callerEmail !== SUPER_ADMIN_EMAIL) {
      throw new HttpsError(
        "permission-denied",
        "Solo el super administrador canónico puede inicializar este claim."
      );
    }
    const existing = callerRecord.customClaims || {};
    if (existing.role === "super_admin") {
      // Idempotent — already done. Tell the caller so the UI can update.
      return { alreadySet: true, role: "super_admin" };
    }

    await admin.auth().setCustomUserClaims(request.auth.uid, {
      role: "super_admin",
      admin: true,
    });

    // Mirror to _superAdmins so listAdmins can serve fast.
    try {
      await db.collection("_superAdmins").doc(request.auth.uid).set({
        uid: request.auth.uid,
        email: callerEmail ?? null,
        displayName: callerRecord.displayName ?? null,
        grantedBy: "bootstrap",
        grantedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    } catch (mirrorErr) {
      console.warn("bootstrapSuperAdmin: mirror write failed (non-fatal)", { err: mirrorErr?.message });
    }

    console.info("bootstrapSuperAdmin: claim granted", {
      uid: request.auth.uid,
      email: callerEmail,
    });
    return { alreadySet: false, role: "super_admin" };
  },
);

// ---------------------------------------------------------------------------
// claimPendingTenantAdmin — apply a pre-authorized tenant_admin invitation.
// ---------------------------------------------------------------------------
// When super_admin assigns a tenant_admin role to an email that doesn't yet
// have an Auth account (the rab nunca abrió la app), setAdminClaim queues
// the invitation in `_pendingTenantAdmins/{lowercased-email}` instead of
// failing. The admin web calls THIS function during post-login to apply
// the claim retroactively the first time that email signs in.
//
// Safety:
//   - Caller must be authenticated.
//   - We use `request.auth.token.email` (verified by Firebase Auth) so a
//     malicious caller can't claim someone else's invitation by passing
//     a different email in the body.
//   - The pending doc is deleted on success so the invitation is single-use.
//   - Idempotent: a second call after the claim is set returns
//     `{ applied: false, reason: "no_pending" }`.
exports.claimPendingTenantAdmin = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    }
    await enforceRateLimit(callerUid, "claimPendingTenantAdmin", 20, 3600);

    // Re-fetch from admin SDK so we can't be tricked by a stale token email
    // (in practice Firebase Auth rotates the token on email change, but
    // belt + suspenders for a security-relevant lookup).
    const callerRecord = await admin.auth().getUser(callerUid);
    // Security: an unverified email lets an attacker sign up with somebody
    // else's address (Firebase Auth allows this) and steal a pending
    // tenant_admin invitation. Require ownership proof via a verified email
    // before granting any claim.
    if (!callerRecord.emailVerified) {
      throw new HttpsError(
        "failed-precondition",
        "Debes verificar tu correo electrónico antes de aceptar una invitación."
      );
    }
    const email = String(callerRecord.email || "").toLowerCase().trim();
    if (!email) {
      return { applied: false, reason: "no_email" };
    }

    const pendingRef = db.collection("_pendingTenantAdmins").doc(email);
    const pendingSnap = await pendingRef.get();
    if (!pendingSnap.exists) {
      return { applied: false, reason: "no_pending" };
    }
    const pending = pendingSnap.data() || {};
    const role = pending.role;
    const tenantId = pending.tenantId;
    // BUG-040 fix: respect TTL on stale invitations. A pending doc older than
    // its expiresAt is treated as if it didn't exist — the doc is also
    // deleted so it doesn't loop on every login.
    const expiresAt = pending.expiresAt?.toMillis?.() ?? null;
    if (expiresAt && Date.now() > expiresAt) {
      await pendingRef.delete().catch(() => {});
      console.info("claimPendingTenantAdmin: pending invitation expired", {
        uid: callerUid, email: _redactEmail(email),
      });
      return { applied: false, reason: "expired" };
    }
    if (role !== "tenant_admin" && role !== "tenant_collaborator") {
      // Unknown role — clean the pending doc so it doesn't loop forever.
      await pendingRef.delete().catch(() => {});
      return { applied: false, reason: "invalid_role" };
    }
    if (!tenantId) {
      await pendingRef.delete().catch(() => {});
      return { applied: false, reason: "no_tenant_id" };
    }

    // Verify the tenant still exists. If it was deleted between invitation
    // and first sign-in, drop the pending doc and return.
    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) {
      await pendingRef.delete().catch(() => {});
      return { applied: false, reason: "tenant_missing" };
    }

    // Apply the claim. setCustomUserClaims REPLACES the object, but a user
    // who's only ever been a pending invitation has no claims to preserve.
    await admin.auth().setCustomUserClaims(callerUid, { role, tenantId });

    // Mirror into tenant team subcollection so admin dashboards see them.
    try {
      await db.collection("tenants").doc(tenantId).collection("team").doc(callerUid).set({
        uid: callerUid,
        email: callerRecord.email,
        displayName: callerRecord.displayName ?? null,
        role,
        addedAt: admin.firestore.FieldValue.serverTimestamp(),
        addedBy: pending.invitedBy ?? null,
        claimedFromPending: true,
      });
    } catch (teamErr) {
      console.warn("claimPendingTenantAdmin: team subcollection update failed (non-fatal)", {
        uid: callerUid, tenantId, err: teamErr?.message,
      });
    }

    // Single-use: drop the pending doc.
    await pendingRef.delete().catch(() => {});

    console.info("claimPendingTenantAdmin: applied", {
      uid: callerUid, email, role, tenantId,
    });
    return { applied: true, role, tenantId };
  },
);

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

    // Resolve target. If the email has no Auth account yet (rab never opened
    // the app), we don't throw — we record the invitation in
    // `_pendingTenantAdmins/{lowercased-email}` and the claim is applied on
    // first sign-in (handled by claimPendingTenantAdmin CF below). Revoke
    // on a non-existent email also goes through the pending path so the
    // caller can cancel an invitation before the invitee signs in.
    const normalizedEmail = String(targetEmail).toLowerCase().trim();
    let targetRecord = null;
    let targetExistingClaims = {};
    try {
      targetRecord = await admin.auth().getUserByEmail(normalizedEmail);
      targetExistingClaims = targetRecord.customClaims || {};
    } catch (err) {
      if (err?.code !== "auth/user-not-found") throw err;
      // Pending invitation branch — handled after permission gates below so
      // a tenant_admin can't sneak around the same-tenant check.
    }

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
        // Normalize both sides — Firebase Auth stores emails case-preserving
        // and tenants.adminEmail was written from raw operator input, so a
        // direct === would let a legitimate first admin be blocked (or, in
        // the opposite direction, let the wrong person impersonate the
        // first admin) depending on how the two strings were cased at
        // creation vs sign-up time. Mirrors the sibling super_admin check.
        const tenantAdminEmail = (tenantDoc.exists && tenantDoc.data().adminEmail) || "";
        const callerEmail = callerRecord.email || "";
        const isFirstAdmin = tenantDoc.exists &&
          tenantAdminEmail.toLowerCase().trim() === callerEmail.toLowerCase().trim();
        if (!isFirstAdmin) {
          throw new HttpsError("permission-denied", "Solo el primer administrador puede revocar accesos.");
        }
      }
    }

    // Super admin email can never be revoked. Compare against the normalized
    // (lowercased) email — a case-mismatched targetEmail like
    // "IOELKATZ@GMAIL.COM" would otherwise bypass this gate and wipe the
    // super_admin's claims (BUG-035, Audit Round 4 Phase 5).
    if (revoke && normalizedEmail === SUPER_ADMIN_EMAIL.toLowerCase()) {
      throw new HttpsError("permission-denied", "No se pueden revocar los permisos del super administrador.");
    }

    // First tenant admin of an org can never be revoked.
    // Compare case-insensitively — same rationale as the sibling caller
    // check above and the SUPER_ADMIN_EMAIL guard: a case mismatch would
    // wrongly allow revocation of the org's first admin.
    if (revoke && targetExistingClaims.tenantId) {
      const tenantDoc = await db.collection("tenants").doc(targetExistingClaims.tenantId).get();
      const tenantAdminEmail = (tenantDoc.exists && tenantDoc.data().adminEmail) || "";
      if (tenantDoc.exists &&
          tenantAdminEmail.toLowerCase().trim() === String(targetEmail).toLowerCase().trim()) {
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
      // Round-6 audit MEDIUM fix: validate that tenantId actually exists
      // before writing an orphan claim. Previously a super_admin typo (or
      // a tenant deleted between UI select + submit) created a claim
      // pointing at a void, and the user got tenant_admin scope on
      // nothing — worse, if a NEW tenant with the same id ever appeared
      // (unlikely but possible via slug reuse), they'd inherit admin.
      const tSnap = await db.collection("tenants").doc(tenantId).get();
      if (!tSnap.exists) {
        throw new HttpsError("not-found", `Tenant ${tenantId} no existe. Verificá el id antes de asignar el rol.`);
      }
      newClaims = { role: "tenant_admin", tenantId };
    } else if (role === "tenant_collaborator") {
      if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido para tenant_collaborator.");
      const tSnap = await db.collection("tenants").doc(tenantId).get();
      if (!tSnap.exists) {
        throw new HttpsError("not-found", `Tenant ${tenantId} no existe.`);
      }
      newClaims = { role: "tenant_collaborator", tenantId };
    }

    // If the email doesn't have an Auth account yet, record the invitation
    // and exit successfully. claimPendingTenantAdmin (called from the admin
    // web auth flow) will apply the claim + team membership on first sign in.
    if (!targetRecord) {
      if (revoke) {
        // Revoking a pending invitation: just delete the pending doc.
        await db.collection("_pendingTenantAdmins").doc(normalizedEmail).delete().catch(() => {});
        return { pending: false, revoked: true, email: normalizedEmail };
      }
      // BUG-040 fix: 30-day TTL on pending invitations. Without an explicit
      // expiry, a forgotten invitation could reactivate months later when the
      // invitee finally creates an account. claimPendingTenantAdmin checks
      // `expiresAt` and ignores expired docs.
      const PENDING_TTL_DAYS = 30;
      const expiresAt = new Date(Date.now() + PENDING_TTL_DAYS * 24 * 60 * 60 * 1000);
      const pendingPayload = {
        email: normalizedEmail,
        role,
        ...(tenantId ? { tenantId } : {}),
        invitedBy: callerUid,
        invitedByEmail: callerRecord.email ?? null,
        invitedAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
      };
      await db.collection("_pendingTenantAdmins").doc(normalizedEmail).set(pendingPayload);
      console.info("setAdminClaim: invitation queued (no Auth account yet)", {
        email: normalizedEmail, role, tenantId,
      });
      return { pending: true, email: normalizedEmail, role, tenantId };
    }

    await admin.auth().setCustomUserClaims(targetRecord.uid, newClaims);

    // Mirror super_admin state to Firestore so listAdmins can query it in
    // O(1) instead of paginating the entire Auth directory. The mirror is
    // authoritative for listing UX; the custom claim remains authoritative
    // for authorization (never trust the mirror alone).
    try {
      const superRef = db.collection("_superAdmins").doc(targetRecord.uid);
      if (newClaims.role === "super_admin") {
        await superRef.set({
          uid: targetRecord.uid,
          email: targetRecord.email ?? null,
          displayName: targetRecord.displayName ?? null,
          grantedBy: callerUid,
          grantedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } else {
        // revoke or role change to something non-super — delete mirror.
        await superRef.delete().catch(() => {});
      }
    } catch (mirrorErr) {
      console.warn("setAdminClaim: superAdmin mirror update failed (non-fatal)", {
        uid: targetRecord.uid, err: mirrorErr?.message,
      });
    }

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
      callerEmail: _redactEmail(callerRecord.email),
      targetEmail: _redactEmail(targetEmail),
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

    // super_admin with no tenantId: return only super admins.
    // Preferred path: read the `_superAdmins` Firestore mirror maintained by
    // setAdminClaim. Fallback: paginate Firebase Auth (first-run bootstrap
    // before any grant has populated the mirror, and belt-and-suspenders if
    // the mirror is empty for any reason).
    try {
      const mirrorSnap = await db.collection("_superAdmins").limit(500).get();
      if (!mirrorSnap.empty) {
        const admins = mirrorSnap.docs.map((d) => {
          const m = d.data() || {};
          return {
            uid: m.uid || d.id,
            email: m.email || null,
            displayName: m.displayName || null,
            role: "super_admin",
            tenantId: null,
          };
        });
        return { admins };
      }
    } catch (mirrorErr) {
      console.warn("listAdmins: mirror read failed, falling back to Auth pagination", {
        err: mirrorErr?.message,
      });
    }

    // Fallback: paginate Auth users. This is the O(N) path we replaced;
    // kept for bootstrap and defense-in-depth. The pageSize is small (200)
    // and MAX_PAGES tight (5) — the fallback is only meant to seed the
    // mirror on first use, not to serve dashboards long-term.
    const allUsers = [];
    let pageToken;
    let pages = 0;
    const MAX_PAGES = 5;
    do {
      const listResult = await admin.auth().listUsers(200, pageToken);
      allUsers.push(...listResult.users);
      pageToken = listResult.pageToken;
      pages += 1;
      if (pages >= MAX_PAGES) {
        console.warn("listAdmins: hit fallback MAX_PAGES cap; results truncated", { pages, totalSoFar: allUsers.length });
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

    // Best-effort mirror backfill so subsequent calls take the fast path.
    if (admins.length > 0) {
      Promise.resolve().then(async () => {
        for (const a of admins) {
          try {
            await db.collection("_superAdmins").doc(a.uid).set({
              uid: a.uid,
              email: a.email ?? null,
              displayName: a.displayName ?? null,
              backfilledAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
          } catch (_) { /* non-fatal */ }
        }
      }).catch(() => {});
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

    // Fetch users — filtered by tenant if needed.
    // Hard cap the unscoped read at 1000 to prevent OOM once the project
    // grows past a few thousand users. The dashboard totals will show
    // "based on latest 1000 users" beyond that threshold — good enough
    // until we denormalize into tenantAggregates counters.
    // TODO(future): replace with pre-aggregated tenantAggregates read +
    // db.collection('users').count().get() aggregate for the total count.
    const USERS_HARD_CAP = 1000;
    const usersQuery = filterTenantId
      ? db.collection("users").where("tenantId", "==", filterTenantId).limit(USERS_HARD_CAP)
      : db.collection("users").limit(USERS_HARD_CAP);

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

    // Build displayName map only for the uids that actually appear in the
    // fetched txs (max FETCH_CAP unique donors). Previously we read the
    // ENTIRE users collection to build this map — an O(N) scan that scaled
    // with tenant size and blew the memory budget on large tenants. Batched
    // getAll in chunks of 30 (Firestore per-request limit).
    const uniqueUids = Array.from(new Set(
      txSnap.docs.map((d) => d.ref.parent.parent?.id).filter(Boolean)
    ));
    const userMap = {};
    const USER_BATCH = 30;
    for (let i = 0; i < uniqueUids.length; i += USER_BATCH) {
      const chunk = uniqueUids.slice(i, i + USER_BATCH);
      const refs = chunk.map((id) => db.collection("users").doc(id));
      let docs = [];
      try {
        docs = await db.getAll(...refs);
      } catch (err) {
        console.warn("getRecentTransactions: users.getAll chunk failed", { err: err?.message });
        continue;
      }
      docs.forEach((d) => {
        if (!d.exists) return;
        const u = d.data() ?? {};
        // Defense-in-depth: when a tenant filter is on, exclude users whose
        // current tenantId does not match (the tx tenantId stamp already
        // filters at query time; this catches drift).
        if (filterTenantId && u.tenantId !== filterTenantId) return;
        userMap[d.id] = {
          displayName: u.displayName || u.email || d.id,
          email: u.email || "",
        };
      });
    }

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
          // Round-11 audit IMPORTANTE fix: expose these fields so the admin
          // TransactionsPage can render the "Recurrente" badge, show donor
          // messages, and filter by designation. Previously they were
          // stripped from the response and the page had no way to
          // differentiate recurring vs one-off donations.
          paymentMethod: tx.paymentMethod ?? null,
          status: tx.status ?? null,
          subscriptionId: tx.subscriptionId ?? null,
          donorMessage: tx.donorMessage ?? null,
          donationReason: tx.donationReason ?? null,
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

    // Tenant admins can only block users in their own tenant.
    // Round-6 audit MEDIUM fix: check tenantIds[] (multi-tenant), not just
    // scalar tenantId. A donor whose current active tenant is elsewhere
    // but who is ALSO a member of this tenant used to slip past the guard
    // — a tenant_admin from tenant A couldn't block their multi-tenant
    // member if member.tenantId happened to point at tenant B.
    if (isTenantAdminRole) {
      const targetSnap = await db.collection("users").doc(uid).get();
      if (!targetSnap.exists) {
        throw new HttpsError("permission-denied", "Solo puedes gestionar usuarios de tu organización.");
      }
      const targetData = targetSnap.data() || {};
      const targetTenantIds = Array.isArray(targetData.tenantIds)
        ? targetData.tenantIds
        : (targetData.tenantId ? [targetData.tenantId] : []);
      if (!targetTenantIds.includes(callerClaims.tenantId)) {
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

    // Round-6 audit MEDIUM fix: activity log entry so audit trail exists.
    // Blocking a user cancels sessions + prevents access — security-relevant.
    // Best-effort: log failure never fails the block itself.
    try {
      const targetSnap = await db.collection("users").doc(uid).get();
      const targetData = targetSnap.exists ? (targetSnap.data() || {}) : {};
      const targetTenantId = targetData.tenantId || null;
      let targetTenantName = null;
      if (targetTenantId) {
        try {
          const tSnap = await db.collection("tenants").doc(targetTenantId).get();
          targetTenantName = tSnap.data()?.name || null;
        } catch (_) { /* leave null */ }
      }
      await writeActivityLog({
        type: isBlocked ? "user_blocked" : "user_unblocked",
        tenantId: targetTenantId,
        tenantName: targetTenantName,
        severity: "warning",
        requiresAction: false,
        data: {
          targetUid: uid,
          targetEmail: targetData.email || null,
          actorUid: callerUid,
          actorEmail: callerRecord.email || null,
          notes: notes ?? null,
        },
      });
    } catch (logErr) {
      console.warn("setUserBlocked: activityLog failed (non-fatal)", { uid, error: logErr?.message });
    }

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
  // Round-2 audit residual: default 60s can time out for users belonging to
  // many tenants (per-tenant Stripe cleanup runs sequentially: list subs,
  // cancel each, then delete connect customer). 300s covers ~30 tenants
  // comfortably with headroom for API retries. Memory bump lets the parallel
  // Firestore reads (transactions, tenantState) fit without swapping.
  { secrets: [stripeSecret], enforceAppCheck: false, timeoutSeconds: 300, memory: "512MiB" },
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
    // BUG-049 fix: capture tenant memberships BEFORE the sweep so we can
    // write an activity log entry per tenant after deletion. Tenant_admins
    // then see "donor X left" in their activity feed alongside their
    // recurring-donation drop in revenue.
    const tenantMemberships = Array.isArray(userData.tenantIds) && userData.tenantIds.length > 0
      ? [...userData.tenantIds]
      : (userData.tenantId ? [userData.tenantId] : []);

    // Round-11 audit fix (IMPORTANT): reject deletion when the caller is
    // the ONLY tenant_admin of any tenant. Silent orphaning would leave
    // recurring donation subscriptions billing OTHER donors forever with
    // no one able to cancel them, no branding updates, no invite codes,
    // and no admin visibility. The user must transfer the role first
    // (via account switcher > organization > invite another admin >
    // switch role) before deletion succeeds.
    //
    // We iterate memberships and check each tenant's team subcollection
    // for other active tenant_admins. If any tenant has none, we throw
    // failed-precondition with the offending tenant name so the client
    // can guide the user.
    const orphaningTenants = [];
    for (const tid of tenantMemberships) {
      try {
        const teamSnap = await db.collection("tenants").doc(tid).collection("team")
          .where("role", "==", "tenant_admin")
          .get();
        const otherAdmins = teamSnap.docs.filter((d) => {
          const data = d.data() || {};
          if (d.id === uid) return false;
          // Only count active admins; suspended/pending don't cover for us.
          const status = data.status || "active";
          return status === "active";
        });
        if (otherAdmins.length === 0) {
          // Check if THIS user is actually a tenant_admin (they might just
          // be a donor with no admin role — then orphaning doesn't apply).
          const selfTeamSnap = await db.collection("tenants").doc(tid)
            .collection("team").doc(uid).get();
          const selfIsAdmin = selfTeamSnap.exists && selfTeamSnap.data()?.role === "tenant_admin";
          if (selfIsAdmin) {
            const tenantName = (await db.collection("tenants").doc(tid).get())
              .data()?.name || tid;
            orphaningTenants.push(tenantName);
          }
        }
      } catch (probeErr) {
        // Firestore transient error — fail closed rather than let a silent
        // orphan slip through. User can retry.
        console.warn("deleteAccount: orphan probe failed", { uid, tid, error: probeErr?.message });
        throw new HttpsError("unavailable", "No pudimos verificar tus organizaciones. Reintentá en un momento.");
      }
    }
    if (orphaningTenants.length > 0) {
      throw new HttpsError(
        "failed-precondition",
        `Sos el único administrador de: ${orphaningTenants.join(", ")}. Transferí el rol a otra persona antes de eliminar tu cuenta.`,
      );
    }

    // ---- 1. Stripe cleanup (best-effort; don't block deletion on it) ----
    // BUG #1 fix: Direct Charges migration moved customers per-tenant. The
    // OLD flat `stripeCustomerId` is deprecated and NEVER populated for
    // post-migration donors, so the previous cleanup was a no-op — recurring
    // donation subscriptions kept billing the deleted donor forever, and
    // saved cards + PII remained in each connected account (GDPR violation).
    // Fix: iterate tenantState/{tid}, resolve connectAccountId from tenant
    // doc, cancel subs + delete customer PER-account with {stripeAccount}.
    // Legacy platform customer (if any) is still cleaned as a fallback.
    let stripeCleanup = {
      customerDeleted: false,
      subscriptionsCanceled: 0,
      connectAccountsCleaned: 0,
      connectAccountsFailed: 0,
    };
    if (stripeSecret.value()) {
      const stripe = require("stripe")(stripeSecret.value());

      // (a) Per-tenant cleanup (Direct Charges path).
      const cancelableStatuses = ["active", "trialing", "past_due", "unpaid", "paused"];
      const tenantStateSnaps = await userRef.collection("tenantState").get().catch(() => null);
      if (tenantStateSnaps) {
        for (const stateDoc of tenantStateSnaps.docs) {
          const tid = stateDoc.id;
          const connectCustomerId = stateDoc.data()?.stripeConnectCustomerId || null;
          if (!connectCustomerId) continue;
          try {
            const tenantSnap = await db.collection("tenants").doc(tid).get();
            const connectAcctId = tenantSnap.data()?.stripeConnectAccountId || null;
            if (!connectAcctId) continue;
            const acctOpts = { stripeAccount: connectAcctId };
            const seenSubIds = new Set();
            for (const status of cancelableStatuses) {
              let subs;
              try {
                subs = await stripe.subscriptions.list({
                  customer: connectCustomerId, status, limit: 100,
                }, acctOpts);
              } catch (listErr) {
                console.warn("deleteAccount: connect subscription list failed", {
                  uid, tid, connectAcctId, status, errorMessage: listErr?.message,
                });
                continue;
              }
              for (const sub of subs.data) {
                if (seenSubIds.has(sub.id)) continue;
                seenSubIds.add(sub.id);
                try {
                  await stripe.subscriptions.cancel(sub.id, {}, acctOpts);
                  stripeCleanup.subscriptionsCanceled += 1;
                } catch (subErr) {
                  console.warn("deleteAccount: connect subscription cancel failed", {
                    uid, tid, subscriptionId: sub.id, status, errorMessage: subErr?.message,
                  });
                }
              }
            }
            await stripe.customers.del(connectCustomerId, acctOpts);
            stripeCleanup.connectAccountsCleaned += 1;
          } catch (perTenantErr) {
            stripeCleanup.connectAccountsFailed += 1;
            console.error("deleteAccount: per-tenant cleanup failed", {
              uid, tid, errorMessage: perTenantErr?.message,
            });
          }
        }
      }

      // (b) Legacy platform customer cleanup (pre-migration donors only).
      if (stripeCustomerId) {
        try {
          const seenLegacySubIds = new Set();
          for (const status of cancelableStatuses) {
            let subs;
            try {
              subs = await stripe.subscriptions.list({
                customer: stripeCustomerId, status, limit: 100,
              });
            } catch (listErr) {
              console.warn("deleteAccount: legacy subscription list failed", {
                uid, status, errorMessage: listErr?.message,
              });
              continue;
            }
            for (const sub of subs.data) {
              if (seenLegacySubIds.has(sub.id)) continue;
              seenLegacySubIds.add(sub.id);
              try {
                await stripe.subscriptions.cancel(sub.id);
                stripeCleanup.subscriptionsCanceled += 1;
              } catch (subErr) {
                console.warn("deleteAccount: legacy subscription cancel failed", {
                  uid, subscriptionId: sub.id, status, errorMessage: subErr?.message,
                });
              }
            }
          }
          await stripe.customers.del(stripeCustomerId);
          stripeCleanup.customerDeleted = true;
        } catch (stripeErr) {
          console.error("deleteAccount: legacy Stripe cleanup failed", {
            uid, stripeCustomerId, errorMessage: stripeErr?.message,
          });
        }
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

    // ---- 4.1. Round-6 audit HIGH fix: cleanup PII in per-tenant team docs ----
    // tenants/{tid}/team/{uid} carries email + displayName + role. Not
    // touched by the tenantIds loop above. Iterates userData.tenantIds so
    // we hit every tenant the user was a member of.
    const userTenantIds = Array.isArray(userData?.tenantIds)
      ? userData.tenantIds.filter((t) => typeof t === "string" && t.length > 0)
      : (userData?.tenantId ? [userData.tenantId] : []);
    for (const tid of userTenantIds) {
      try {
        await db.collection("tenants").doc(tid)
          .collection("team").doc(uid).delete();
      } catch (teamErr) {
        console.warn("deleteAccount: team doc cleanup failed (non-fatal)", {
          uid, tenantId: tid, error: teamErr?.message,
        });
      }
    }

    // ---- 4.2. Round-6 audit HIGH fix: cleanup _pendingTenantAdmins by email ----
    // If the user was invited to become tenant_admin under an email that
    // matches theirs, the pending doc has the email. Delete so PII doesn't
    // outlive the account.
    const userEmailLower = String(userData?.email || "").toLowerCase().trim();
    if (userEmailLower) {
      try {
        await db.collection("_pendingTenantAdmins").doc(userEmailLower).delete();
      } catch (pendErr) {
        // Doc likely didn't exist — deleting a non-existent doc is a no-op
        // anyway; catch is only for defense.
        console.warn("deleteAccount: pendingTenantAdmins cleanup failed", {
          uid, email: userEmailLower, error: pendErr?.message,
        });
      }
    }

    // ---- 4.3. Round-6 audit MEDIUM fix: cleanup _monthlyActive entries ----
    // Best-effort scan of docs with prefix `{monthKey}_{tenantId}_{uid}` for
    // this user across the last 6 months (older buckets get cleaned by the
    // scheduled resetMonthlyActiveUsers CF over time).
    try {
      const now = new Date();
      const monthsToCheck = [];
      for (let i = 0; i < 6; i++) {
        const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1));
        monthsToCheck.push(`${d.getUTCFullYear()}_${String(d.getUTCMonth() + 1).padStart(2, "0")}`);
      }
      const monthlyBatch = db.batch();
      let monthlyOps = 0;
      for (const monthKey of monthsToCheck) {
        for (const tid of userTenantIds) {
          const docId = `${monthKey}_${tid}_${uid}`;
          monthlyBatch.delete(db.collection("_monthlyActive").doc(docId));
          monthlyOps += 1;
          if (monthlyOps >= 400) {
            await monthlyBatch.commit();
            monthlyOps = 0;
          }
        }
      }
      if (monthlyOps > 0) await monthlyBatch.commit();
    } catch (monErr) {
      console.warn("deleteAccount: _monthlyActive cleanup failed (non-fatal)", {
        uid, error: monErr?.message,
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

    // ---- 5b. Decrement tenants.totalUsers for each membership ----
    // Without this, deleted donors linger in per-tenant counts, inflating
    // seat metrics forever. Batched in groups of 400 for safety.
    if (tenantMemberships.length > 0) {
      const CHUNK = 400;
      for (let i = 0; i < tenantMemberships.length; i += CHUNK) {
        const slice = tenantMemberships.slice(i, i + CHUNK);
        const batch = db.batch();
        for (const tenantId of slice) {
          batch.set(db.collection("tenants").doc(tenantId), {
            totalUsers: admin.firestore.FieldValue.increment(-1),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
        }
        try {
          await batch.commit();
        } catch (decErr) {
          console.warn("deleteAccount: totalUsers decrement failed (non-fatal)", {
            uid, err: decErr?.message,
          });
        }
      }
    }

    // ---- 6. Delete the parent user doc itself ----
    await userRef.delete().catch(() => { /* idempotent */ });

    // ---- 6b. Per-tenant activity log entries (BUG-049 fix) ----
    // After the user is gone, write one entry per tenant they belonged to so
    // each tenant_admin sees the departure in their activity feed. Best-
    // effort: an audit-log write failure must not impact account deletion.
    for (const tenantId of tenantMemberships) {
      try {
        const tenantSnap = await db.collection("tenants").doc(tenantId).get();
        const tenantName = tenantSnap.exists ? (tenantSnap.data()?.name ?? tenantId) : tenantId;
        await writeActivityLog({
          type: "donor_deleted_account",
          tenantId,
          tenantName,
          severity: "info",
          requiresAction: false,
          data: {
            uid,
            stripeCleanup,
            // PII redacted to honor the GDPR delete we just executed.
            email: _redactEmail(email || ""),
          },
        });
      } catch (logErr) {
        console.warn("deleteAccount: per-tenant activity log failed", {
          uid, tenantId, error: logErr?.message,
        });
      }
    }

    // ---- 6b. Round-11 audit fix (IMPORTANT): scrub historical PII in
    // `_activityLog`. Every `writeActivityLog` call across the app stamps
    // `data.uid` (and often `data.donorName` / `data.donorEmail`) so the
    // tenant admins' feed can attribute activity. Those entries stay
    // forever unless we redact — a lingering donor email in the log
    // violates GDPR "right to be forgotten" after the user requests
    // deletion. Redact IN-PLACE with best-effort batches; don't block
    // the overall delete on a transient Firestore error here.
    try {
      const activityQuery = db.collection("_activityLog").where("data.uid", "==", uid);
      const activitySnap = await activityQuery.get();
      const REDACTED = "[deleted]";
      const CHUNK = 400; // Firestore batch limit is 500; leave headroom.
      let redactedCount = 0;
      for (let i = 0; i < activitySnap.docs.length; i += CHUNK) {
        const batch = db.batch();
        const slice = activitySnap.docs.slice(i, i + CHUNK);
        for (const doc of slice) {
          batch.update(doc.ref, {
            "data.email": REDACTED,
            "data.donorEmail": REDACTED,
            "data.donorName": REDACTED,
            "data.userEmail": REDACTED,
            "data.userName": REDACTED,
            "data.redactedAt": admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        redactedCount += slice.length;
      }
      if (redactedCount > 0) {
        console.info("deleteAccount: activity log PII redacted", { uid, redactedCount });
      }
    } catch (redactErr) {
      // Non-fatal — log for follow-up; ops can run a backfill later.
      console.warn("deleteAccount: activity log redact failed", { uid, error: redactErr?.message });
    }

    // ---- 7. Delete Firebase Auth user (irreversible) ----
    // Round-11 audit fix (IMPORTANT): idempotency guard. If a previous
    // attempt already deleted the Auth user but crashed BEFORE returning
    // success, the client retries and this call throws "auth/user-not-found".
    // Swallow that specific case — the tombstone marker below is the source
    // of truth. Any other Auth error still bubbles up so the client sees it.
    try {
      await admin.auth().deleteUser(uid);
    } catch (authErr) {
      if (authErr?.code === "auth/user-not-found") {
        console.info("deleteAccount: auth user already gone (idempotent retry)", { uid });
      } else {
        throw authErr;
      }
    }

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
  { enforceAppCheck: false },
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
      // BUG #15 fix: post-Direct-Charges migration, cards live PER-TENANT on
      // the connected account (not on the platform). The relevant identifiers
      // are in each `tenantState.stripeConnectCustomerId` + the parent
      // `tenants/{tid}.stripeConnectAccountId`. Point users at both.
      _meta: {
        format: "pushka-export-v1",
        notes:
          "Saved cards / payment methods live in Stripe on each tenant's " +
          "connected account. To request card data from Stripe support, " +
          "provide the tenantState.stripeConnectCustomerId (from `tenantStates`) " +
          "and the corresponding tenants/{tenantId}.stripeConnectAccountId. " +
          "Legacy platform customerId (users/{uid}.stripeCustomerId) is deprecated.",
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
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    // super_admin no se rate-limita: durante debugging/testing es normal
    // hacer >10 joins en una hora. Usuarios normales siguen topeados en
    // 30/h (subido de 10 — 10 pegaba a edge cases legítimos como retries
    // por red lenta + cambio entre 2-3 tenants).
    if (!callerIsSuperAdmin(request)) {
      await enforceRateLimit(request.auth.uid, "joinTenant", 30, 3600);
    }

    const uid = request.auth.uid;
    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    // Validate tenant exists and is active.
    // BUG-041 fix: exclude `grace_period`. A tenant whose payment is
    // failing is on the verge of suspension — letting new users join while
    // they're a few days from being kicked out creates churn confusion.
    // They can still rejoin after the rab regularizes payment.
    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) throw new HttpsError("not-found", "Organización no encontrada.");
    const tenantData = tenantSnap.data();
    if (!["active", "trial"].includes(tenantData.status)) {
      throw new HttpsError("failed-precondition", "Esta organización no está disponible.");
    }

    const userRef = db.collection("users").doc(uid);
    const stateRef = userRef.collection("tenantState").doc(tenantId);

    // Defensa en profundidad: si el doc del user no existe en Firestore (por
    // wipe, restore desde backup, race en signUp, o cualquier estado
    // inesperado), lo creamos acá con los mismos defaults que
    // createUserDocument del client. Sin esto el user queda atrapado en
    // /tenant-setup viendo "Código no encontrado" sin entender qué pasa.
    // El lookup a admin.auth() es solo si el doc no existe (path raro),
    // así que no agrega latencia al flujo normal.
    let preloadedAuthRecord = null;
    const preExistsSnap = await userRef.get();
    if (!preExistsSnap.exists) {
      try {
        preloadedAuthRecord = await admin.auth().getUser(uid);
      } catch (_) { /* fallback a token */ }
    }

    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      const stateSnap = await tx.get(stateRef);

      let userData;
      if (!userSnap.exists) {
        const authEmail = preloadedAuthRecord?.email
          || request.auth.token?.email || "";
        const authName = preloadedAuthRecord?.displayName
          || request.auth.token?.name || "";
        const seed = {
          uid,
          email: authEmail,
          displayName: authName,
          billingEmail: "",
          phoneNumber: "",
          mailingAddress: "",
          pushkaAmount: 0,
          pushkaGoal: 180, // USD default; tenant override applied below if isFirst
          presetAmount: 1.0,
          presetAmounts: [],
          soundEnabled: true,
          vibrationEnabled: true,
          partialPaymentsEnabled: false,
          biometricAuthenticationEnabled: false,
          currencyCountry: "Estados Unidos",
          currencyCode: "USD",
          autoEmptyFrequency: "manual",
          autoEmptyTopOffEnabled: false,
          streakCount: 0,
          lastStreakDate: null,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
          // language omitida: bloque "if (isFirst)" abajo la setea con
          // tenant.defaultLanguage.
        };
        tx.set(userRef, seed, { merge: true });
        userData = seed;
        console.log("joinTenant: created missing user doc", { uid, tenantId });
      } else {
        userData = userSnap.data();
      }
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
// ---------------------------------------------------------------------------
// changeUserCurrency — atomic, cross-doc currency change.
//
// Bug fixed (Round 4 audit CRITICAL): the previous client-side flow fired
// three independent, un-awaited Firestore writes (users.currencyCode +
// tenantState.pushkaAmount=0 + tenantState.autoEmptyTopOff cleared). If any
// one dropped (network, security-rule change, offline flush ordering), the
// cron `processPushkaAutoEmpty` could see currencyCode='usd' with a stale
// topOffAmount originally saved as ARS 500 and charge USD 500 (~250× the
// intended donation).
//
// Fix: run all writes inside a single `runTransaction`. Either everything
// commits or nothing does. The client only mirrors state after the CF
// returns success; on failure it reverts local UI and shows an error.
//
// Also stamps `autoEmptyTopOffCurrency` on every top-off write (empty
// string here since we're CLEARING it) so `processPushkaAutoEmpty`'s
// guard has an unambiguous "no top-off configured" marker.
// ---------------------------------------------------------------------------
exports.changeUserCurrency = onCall(
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    const uid = request.auth.uid;
    await enforceRateLimit(uid, "changeUserCurrency", 20, 3600);

    const newCurrency = validateCurrency(request.data?.currencyCode);
    const newCurrencyCountry = String(request.data?.currencyCountry || newCurrency).toUpperCase();
    const newGoalRaw = request.data?.pushkaGoal;
    const newGoal = Number.isFinite(newGoalRaw) && newGoalRaw > 0 ? Number(newGoalRaw) : null;
    const newPresetsRaw = Array.isArray(request.data?.presetAmounts) ? request.data.presetAmounts : null;
    const newPresets = newPresetsRaw
      ?.filter((v) => Number.isFinite(v) && v > 0)
      ?.slice(0, 3)
      ?.map((v) => Number(v));
    if (!newPresets || newPresets.length !== 3) {
      throw new HttpsError("invalid-argument", "presetAmounts debe ser un array de 3 números positivos.");
    }

    const userRef = db.collection("users").doc(uid);

    const result = await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) throw new HttpsError("not-found", "Usuario no encontrado.");
      const userData = userSnap.data() || {};
      const activeTenantId = String(userData.tenantId || "").trim();

      // Update user doc atomically with everything the client would have
      // updated: currency, country, pushka goal, and preset amounts.
      // All three fields belong to the SAME document — this write is
      // trivially atomic; the value here is combining it with the
      // tenantState reset below in the SAME transaction commit.
      tx.set(userRef, {
        currencyCode: newCurrency.toUpperCase(),
        currencyCountry: newCurrencyCountry,
        pushkaGoal: newGoal,
        presetAmounts: newPresets,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      // Reset tenant-scoped state for the ACTIVE tenant so the accumulated
      // pushka amount + top-off configuration don't get reinterpreted in
      // the new currency. This is the critical piece: without it, the cron
      // charges the user in the wrong currency. Other tenants the user
      // belongs to are left alone — the user will hit their own currency
      // mismatch guard next time they switch to those.
      //
      // Also mirrors pushkaGoal + presetAmounts to tenantState because that
      // is where pushka_screen actually reads presets/goal from (root user
      // doc holds the same fields but is NOT what the donate UI consumes).
      // Without this the picker keeps showing the old currency's presets
      // even though the setting was changed.
      if (activeTenantId) {
        const tenantStateRef = userRef.collection("tenantState").doc(activeTenantId);
        tx.set(tenantStateRef, {
          pushkaAmount: 0,
          pushkaGoal: newGoal,
          presetAmounts: newPresets,
          autoEmptyTopOffAmount: 0,
          autoEmptyTopOffEnabled: false,
          // Explicit marker so processPushkaAutoEmpty can distinguish
          // "no top-off configured" (blank) from "configured in currency X".
          autoEmptyTopOffCurrency: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      // Round-9 regression fix (refined in Round-10): reset presets/goal
      // + pushkaAmount on OTHER tenants the user belongs to. Currency is
      // user-global, so leaving other tenants' pushkaAmount in the old
      // currency's numeric scale would silently reinterpret it: an ARS
      // 500 balance would render as US$500 (~350x its real value) on the
      // next switch. We choose parity with the active-tenant behavior:
      // change of currency is a hard reset across ALL tenants. The user
      // sees the currency change as a global "start fresh" — matches the
      // in-app confirmation dialog copy which already warns about it.
      const otherTenantIds = (userData.tenantIds || [])
        .filter((t) => typeof t === "string" && t !== activeTenantId);
      for (const tid of otherTenantIds) {
        const otherStateRef = userRef.collection("tenantState").doc(tid);
        tx.set(otherStateRef, {
          pushkaAmount: 0,
          pushkaGoal: newGoal,
          presetAmounts: newPresets,
          autoEmptyTopOffAmount: 0,
          autoEmptyTopOffEnabled: false,
          autoEmptyTopOffCurrency: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      return { activeTenantId };
    });

    return { success: true, currencyCode: newCurrency.toUpperCase(), activeTenantId: result.activeTenantId };
  }
);

exports.switchTenant = onCall(
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    await enforceRateLimit(request.auth.uid, "switchTenant", 30, 3600);

    const uid = request.auth.uid;
    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    const userRef = db.collection("users").doc(uid);

    // Wrapped in a transaction so a concurrent leaveTenant() can't drop the
    // user's membership between our read and write, leaving them pointed at
    // a tenant they no longer belong to. The read+write happen atomically:
    // if leaveTenant races us, one of the two will retry against the fresh
    // snapshot.
    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) throw new HttpsError("not-found", "Usuario no encontrado.");

      const userData = userSnap.data();
      const tenantIds = userData.tenantIds || (userData.tenantId ? [userData.tenantId] : []);

      if (!tenantIds.includes(tenantId)) {
        throw new HttpsError("permission-denied", "No eres miembro de esa organización.");
      }

      tx.set(userRef, {
        tenantId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    return { success: true, tenantId };
  }
);

// ---------------------------------------------------------------------------
// leaveTenant — removes the caller from a tenant's membership list.
// If the tenant being left is the active one, falls back to the first
// remaining tenant (or clears tenantId if none remain).
// ---------------------------------------------------------------------------
exports.leaveTenant = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    await enforceRateLimit(request.auth.uid, "leaveTenant", 10, 3600);

    const uid = request.auth.uid;
    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    // Round-6 audit CRITICAL fix: cancel donor's active recurring
    // subscriptions in this tenant's Connect account BEFORE leaving. Without
    // this, Stripe keeps charging the donor monthly for a tenant they can
    // no longer see or cancel from the app (listDonationSubscriptions
    // filters by user's tenantIds). Best-effort: log failures but proceed
    // with leave so a Stripe outage doesn't block the user from leaving.
    try {
      const tenantSnap = await db.collection("tenants").doc(tenantId).get();
      const tenantData = tenantSnap.exists ? (tenantSnap.data() ?? {}) : {};
      const connectAccountId = tenantData.stripeConnectAccountId;
      if (connectAccountId && tenantData.stripeConnectStatus === "active" && stripeSecret.value()) {
        const stateSnap = await db.collection("users").doc(uid)
          .collection("tenantState").doc(tenantId).get();
        const customerId = String(stateSnap.data()?.stripeConnectCustomerId || "").trim();
        if (customerId) {
          const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });
          const opts = { stripeAccount: connectAccountId };
          const subs = await stripe.subscriptions.list({
            customer: customerId, status: "all", limit: 100,
          }, opts).catch((err) => {
            console.warn("leaveTenant: stripe.subscriptions.list failed", {
              uid, tenantId, error: String(err?.message || err),
            });
            return { data: [] };
          });
          const ACTIVE_STATUSES = new Set(["active", "trialing", "past_due", "incomplete"]);
          for (const sub of (subs.data || [])) {
            if (sub.metadata?.purpose !== "donation_recurring") continue;
            if (!ACTIVE_STATUSES.has(sub.status)) continue;
            try {
              await stripe.subscriptions.cancel(sub.id, {}, opts);
            } catch (cancelErr) {
              console.warn("leaveTenant: sub cancel failed", {
                uid, tenantId, subId: sub.id, error: String(cancelErr?.message || cancelErr),
              });
            }
          }
        }
      }
    } catch (subCleanupErr) {
      console.warn("leaveTenant: sub cleanup wrapper failed (non-fatal)", {
        uid, tenantId, error: String(subCleanupErr?.message || subCleanupErr),
      });
    }

    const userRef = db.collection("users").doc(uid);
    const stateRef = userRef.collection("tenantState").doc(tenantId);

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

      // Round-6 audit HIGH fix: delete the tenantState doc so it doesn't
      // appear as a ghost in the account switcher. Without this the user
      // sees the left tenant in listings but can't select it.
      tx.delete(stateRef);

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
  "primaryColor", "logoUrl",
  // secondaryColor + termsUrl + showPoweredBy removed: not consumed by the
  // Flutter client. Legacy tenant docs may still hold these fields, but we
  // no longer expose them to clients.
  "defaultLanguage", "defaultCurrency", "defaultCountry",
  "contactEmail", "contactPhone", "privacyPolicyUrl",
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
// Default destinations seeded on every new tenant. Tenant admins can edit
// (add/remove/rename) from the admin web → Configuración → Designaciones.
// Edits propagate live to the app via getTenantConfig polling +
// onTenantBrandingUpdated trigger that mirrors the array onto every member's
// tenantState.tenantDonationReasons cache.
const DEFAULT_CHABAD_DONATION_REASONS = [
  "Donde más se necesite",
  "Comida para familias",
  "Estudios de Torá",
  "Festividades",
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
    // Round-6 audit LOW fix: rate limit prevents accidental double-submit
    // (super_admin double-tap in admin panel) creating orphan tenants and
    // caps blast radius if the super_admin account is ever compromised.
    await enforceRateLimit(request.auth.uid, "createTenant", 20, 3600);

    const {
      name, slug, appName, welcomeText,
      primaryColor, logoUrl,
      defaultLanguage, defaultCurrency, defaultCountry,
      contactEmail, contactPhone, privacyPolicyUrl,
      city, country,
      adminEmail,
      commissionRate, planPrice,
      // secondaryColor + termsUrl deprecated (Audit Round 4 Bugs B & C) —
      // accepted from clients for backwards-compat but no longer stored.
      secondaryColor: _ignoredSecondaryColor,
      termsUrl: _ignoredTermsUrl,
    } = request.data ?? {};
    // Suppress unused-var lint warnings while keeping the destructure as docs.
    void _ignoredSecondaryColor;
    void _ignoredTermsUrl;

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
      primaryColor: /^#[0-9A-Fa-f]{6}$/.test(String(primaryColor || "")) ? String(primaryColor).trim().toLowerCase() : "#e8a87c",
      // secondaryColor + showPoweredBy removed: no widget consumed them.
      logoUrl: String(logoUrl || "").trim() || null,

      // Localization
      defaultLanguage: String(defaultLanguage || "es"),
      // Round-4 audit fix: validate against SUPPORTED_CURRENCIES so a typo
      // ('UYU', 'JPY', 'XYZ') doesn't silently break every subsequent
      // createPaymentIntent/createDonationSubscription for the tenant.
      defaultCurrency: validateCurrency(defaultCurrency || "USD").toUpperCase(),
      defaultCountry: String(defaultCountry || "").trim() || null,

      // Legal / Contact
      contactEmail: String(contactEmail || adminEmail).trim() || null,
      contactPhone: String(contactPhone || "").trim() || null,
      privacyPolicyUrl: String(privacyPolicyUrl || "").trim() || null,
      // termsUrl deprecated (Audit Round 4 Bug C) — no longer stored on tenant docs.
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

    // Welcome email — errors are logged, never thrown.
    //
    // Previously this generated a Stripe Connect OAuth link directly and
    // wrote the state token to tenants/{id}.stripeConnectOAuthState. That
    // was broken end-to-end: handleStripeConnectOAuth reads from
    // _stripeConnectOAuth/{state}, so every embedded welcome-email OAuth
    // link failed with "Estado inválido o expirado".
    //
    // Simpler + safer flow: the welcome email just points at the admin
    // panel. The tenant admin signs in there (using the password-setup
    // link above), and clicks the panel's "Conectar Stripe" button, which
    // calls createStripeConnectLink and gets a state token that IS in
    // sync with handleStripeConnectOAuth.
    const adminPanelUrl = "https://chabad-admin.web.app";

    // Round-8 audit HIGH fix: track welcome-email delivery outcome so the
    // response tells super_admin whether they need to send the setup link
    // manually. Previous silent behavior meant the tenant admin never
    // received the password link and got stuck out of their own panel.
    let welcomeEmailDelivered = false;
    let welcomeEmailError = null;
    try {
      await sendEmail({
        to: adminEmail.trim(),
        subject: `Bienvenido/a a ${tenantData.appName} — Tu panel está listo`,
        html: buildTenantWelcomeEmail({
          appName: tenantData.appName,
          adminEmail: adminEmail.trim(),
          adminPanelUrl,
          passwordSetupLink,
          stripeConnectUrl: null,
        }),
      });
      welcomeEmailDelivered = true;
    } catch (e) {
      console.error("createTenant: welcome email failed:", e.message);
      welcomeEmailError = String(e?.message || e).slice(0, 300);
      // Best-effort ops alert so someone notices even without checking logs.
      try {
        await writeActivityLog({
          type: "tenant_welcome_email_failed",
          tenantId: tenantRef.id,
          tenantName: tenantData.name,
          severity: "warning",
          requiresAction: true,
          data: {
            adminEmail: _redactEmail(adminEmail),
            passwordSetupLink: passwordSetupLink ? "generated" : "missing",
            error: welcomeEmailError,
          },
        });
      } catch (_) { /* activity log itself failed — swallow */ }
    }

    // BUG-026 fix: provision the Stripe Billing subscription automatically
    // when the tenant is created. Without this chain, super_admin would have
    // to call createTenantSubscription manually after creation — easy to
    // forget, and the tenant runs in "trial" indefinitely (= Pushka never
    // bills the rab).
    //
    // We swallow errors here so a Stripe API hiccup doesn't prevent tenant
    // creation. The super_admin can re-run createTenantSubscription manually
    // from TenantDetailPage if this initial provisioning fails.
    let subscriptionProvision = null;
    if (typeof planPrice === "number" && planPrice > 0) {
      try {
        const result = await _ensureTenantSubscription(tenantRef.id);
        subscriptionProvision = {
          subscriptionId: result.subscriptionId,
          hostedInvoiceUrl: result.hostedInvoiceUrl,
        };
        console.info("createTenant: subscription provisioned", {
          tenantId: tenantRef.id, subscriptionId: result.subscriptionId,
        });
      } catch (subErr) {
        console.warn("createTenant: subscription provisioning failed (non-fatal)", {
          tenantId: tenantRef.id, error: subErr?.message ?? String(subErr),
        });
      }
    }

    await writeActivityLog({
      type: "new_tenant",
      tenantId: tenantRef.id,
      tenantName: tenantData.name,
      severity: "info",
      requiresAction: false,
      data: { adminEmail: adminEmail.trim(), appName: tenantData.appName, slug: normalizedSlug },
    });

    return {
      success: true,
      tenantId: tenantRef.id,
      slug: normalizedSlug,
      // Round-8 audit HIGH fix: surface welcome email delivery outcome so
      // the super_admin UI can show "email failed — send this link
      // manually" instead of silently assuming delivery.
      welcomeEmailDelivered,
      welcomeEmailError,
      passwordSetupLink: passwordSetupLink ?? null,
      ...(subscriptionProvision ? { subscription: subscriptionProvision } : {}),
    };
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

    // Round-5 audit HIGH fix: normalizeSlug throws HttpsError for invalid
    // slugs (<3, >30, empty after normalization). Previously that abort the
    // WHOLE backfill on a single legacy tenant with a weird slug. Now catch
    // per-tenant and collect the failures so ops sees them without losing
    // the rest of the sweep.
    const invalidSlugs = [];
    for (const tenantDoc of tenantsSnap.docs) {
      scanned += 1;
      const tenantId = tenantDoc.id;
      const slugRaw = String(tenantDoc.data()?.slug || "").trim();
      if (!slugRaw) {
        skippedNoSlug.push(tenantId);
        continue;
      }
      let slug;
      try {
        slug = normalizeSlug(slugRaw);
      } catch (slugErr) {
        invalidSlugs.push({ tenantId, slugRaw, error: String(slugErr?.message || slugErr) });
        continue;
      }
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
      // Round-11 audit MEDIO fix: two super_admins running the backfill
      // concurrently used to race — the second attempt's `.create()` would
      // throw ALREADY_EXISTS on the first slug the first attempt just
      // created between our .get() (above) and this .create(). That
      // aborted the whole second sweep half-way. Catch the race and
      // re-classify as skippedAlreadyExists or conflicts depending on
      // whether the winning doc points at the same tenant.
      try {
        await slugRef.create({
          tenantId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          backfilled: true,
        });
        created += 1;
      } catch (raceErr) {
        if (raceErr?.code === 6 || /ALREADY_EXISTS/i.test(String(raceErr?.message))) {
          const raced = await slugRef.get();
          if (raced.exists && raced.data()?.tenantId === tenantId) {
            skipped += 1;
          } else {
            conflicts.push({ slug, tenantId, ownerTenantId: raced.data()?.tenantId, raceLost: true });
          }
        } else {
          throw raceErr;
        }
      }
    }

    const summary = {
      scanned,
      created,
      skippedAlreadyExists: skipped,
      skippedNoSlug,
      conflicts,
      invalidSlugs, // Round-5 fix: legacy tenants with malformed slugs
      previousRun, // null on first run; otherwise prior completedAt/created
    };
    console.info("backfillTenantSlugs: completed", summary);
    // Stamp sentinel — only if there were no conflicts AND no invalid slugs
    // (both mean the backfill is incomplete; keep the prior sentinel state
    // so ops know reconciliation is still pending).
    if (conflicts.length === 0 && invalidSlugs.length === 0) {
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
  { enforceAppCheck: false },
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
// backfillTransactionTenantId — one-shot super_admin operation: stamp
// `tenantId` on legacy transactions written before the multi-tenant cutover.
//
// Pre-multi-tenant transactions lack the `tenantId` field on the doc.
// Multi-tenant `where('tenantId', '==', X)` queries silently exclude them,
// so the tenant's admin dashboard loses historical donations from migrated
// donors. This backfill resolves `tenantId` from each user's current
// `tenants/{id}` membership (single-tenant assumption: at the time these
// txns were written, the donor had exactly one tenant — there were no
// multi-memberships yet).
//
// Idempotent: skips txns that already have tenantId. Bounded by 5000 docs
// per invocation to stay under the function timeout; rerun until
// `remaining` returns 0.
// BUG-048 fix (Audit Round 4 Phase 6).
// ---------------------------------------------------------------------------
exports.backfillTransactionTenantId = onCall(
  { enforceAppCheck: false },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo super_admin.");
    }
    await enforceRateLimit(request.auth.uid, "backfillTransactionTenantId", 5, 3600);

    const MAX_PER_RUN = 5000;
    let scanned = 0;
    let stamped = 0;
    let alreadyHadTenantId = 0;
    let skippedNoUserTenant = 0;
    let remaining = 0;

    // Collection-group query over all transactions, filtering at app level
    // to those missing tenantId. We can't `.where('tenantId', '==', null)`
    // because Firestore queries don't return docs that lack the field.
    const cg = await db.collectionGroup("transactions").limit(MAX_PER_RUN + 1).get();
    if (cg.size > MAX_PER_RUN) {
      remaining = cg.size - MAX_PER_RUN;
    }
    const docs = cg.docs.slice(0, MAX_PER_RUN);

    // Group by uid so we batch user lookups (each unique user only fetched once).
    const byUid = new Map(); // uid -> [DocumentSnapshot]
    for (const txDoc of docs) {
      scanned += 1;
      if (txDoc.data()?.tenantId) {
        alreadyHadTenantId += 1;
        continue;
      }
      const uid = txDoc.ref.parent.parent?.id;
      if (!uid) continue;
      if (!byUid.has(uid)) byUid.set(uid, []);
      byUid.get(uid).push(txDoc);
    }

    // For each uid, look up their tenantId (or first of tenantIds[]) and
    // stamp every matching tx with it. Chunked into batches of 400 to stay
    // under Firestore's 500-write batch ceiling.
    for (const [uid, txDocs] of byUid.entries()) {
      let userTenantId;
      try {
        const userSnap = await db.collection("users").doc(uid).get();
        const userData = userSnap.data() ?? {};
        userTenantId = userData.tenantId ?? (Array.isArray(userData.tenantIds) ? userData.tenantIds[0] : null);
      } catch (lookupErr) {
        console.warn("backfillTransactionTenantId: user lookup failed", {
          uid, error: lookupErr?.message,
        });
        continue;
      }
      if (!userTenantId) {
        skippedNoUserTenant += txDocs.length;
        continue;
      }
      const CHUNK = 400;
      for (let i = 0; i < txDocs.length; i += CHUNK) {
        const batch = db.batch();
        for (const txDoc of txDocs.slice(i, i + CHUNK)) {
          batch.set(txDoc.ref, { tenantId: userTenantId }, { merge: true });
          stamped += 1;
        }
        await batch.commit();
      }
    }

    const summary = { scanned, stamped, alreadyHadTenantId, skippedNoUserTenant, remaining };
    console.info("backfillTransactionTenantId: completed", summary);
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
    // Round-6 audit LOW fix: rate limit prevents infinite-polling from
    // tenant_admin dashboards. 120/hr is generous for legitimate use
    // (branding editor refresh) but caps a runaway polling bug.
    if (request.auth?.uid) {
      await enforceRateLimit(request.auth.uid, "getTenantBranding", 120, 3600);
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
      "primaryColor", "logoUrl",
      // secondaryColor + termsUrl + showPoweredBy removed.
      "defaultLanguage", "defaultCurrency", "defaultCountry",
      "contactEmail", "contactPhone", "privacyPolicyUrl",
      "city", "country", "donationReasons",
    ];
    const branding = { tenantId: snap.id };
    for (const f of fields) {
      if (data[f] !== undefined) branding[f] = data[f];
    }
    if (!Array.isArray(branding.donationReasons) || branding.donationReasons.length === 0) {
      branding.donationReasons = DEFAULT_CHABAD_DONATION_REASONS;
    }
    return branding;
  }
);

// ---------------------------------------------------------------------------
// updateTenant — super_admin (all fields) or tenant_admin (branding only)
// ---------------------------------------------------------------------------
exports.updateTenant = onCall(
  { enforceAppCheck: false, secrets: [stripeSecret] },
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
    // Round-6 audit LOW fix: rate limit — updateTenant triggers
    // onTenantBrandingUpdated which fans out to every member's tenantState.
    // A runaway rewrite loop (or compromised admin) could DoS Firestore.
    await enforceRateLimit(callerUid, "updateTenant", 60, 3600);

    const { tenantId, ...updates } = request.data ?? {};
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    // Tenant admin can only edit their own tenant
    if (isTenantAdmin && callerClaims.tenantId !== tenantId) {
      throw new HttpsError("permission-denied", "Solo podés editar tu propia organización.");
    }

    // BUG-028/015 fix: `subscriptionMonthlyAmount` was a phantom field that
    // never affected actual Stripe billing — only `planPrice` does. Treat
    // subscriptionMonthlyAmount as a deprecation alias that writes through
    // to planPrice (and we explicitly null out the phantom field below so
    // the data model converges to a single source of truth).
    if (
      isSuper &&
      "subscriptionMonthlyAmount" in updates &&
      !("planPrice" in updates)
    ) {
      updates.planPrice = updates.subscriptionMonthlyAmount;
    }

    const tenantRef = db.collection("tenants").doc(tenantId);
    const snap = await tenantRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Tenant no encontrado.");

    // Super admin: all fields. Tenant admin: branding only.
    const brandingFields = [
      "appName", "welcomeText",
      "primaryColor", "logoUrl",
      // secondaryColor + termsUrl + showPoweredBy removed. If a client
      // still sends them, they're silently dropped (not in allowed).
      "defaultLanguage", "defaultCurrency", "defaultCountry",
      "contactEmail", "contactPhone", "privacyPolicyUrl",
      "city", "country",
      "donationReasons",
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
      "privacyPolicyUrl", "defaultCountry", "city", "country",
    ]);

    // Hex color fields — must be exactly #rrggbb
    const hexColorFields = new Set(["primaryColor"]);
    const hexRe = /^#[0-9A-Fa-f]{6}$/;

    const patch = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };
    for (const key of allowed) {
      if (!(key in updates)) continue;
      let val = updates[key];
      // donationReasons is an array of strings — validate and clean each entry
      if (key === "donationReasons") {
        if (!Array.isArray(val)) continue;
        val = val
          .filter((r) => typeof r === "string" && r.trim().length > 0)
          .map((r) => r.trim())
          .slice(0, 30); // cap at 30 items
        patch[key] = val;
        continue;
      }
      if (typeof val === "string") {
        val = val.trim();
        if (nullableStringFields.has(key) && val === "") val = null;
        if (hexColorFields.has(key)) {
          if (!hexRe.test(val)) continue; // skip invalid hex
          val = val.toLowerCase(); // normalize to lowercase for consistent storage
        }
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
      // Round-4 audit fix: validate defaultCurrency against SUPPORTED_CURRENCIES
      // so a super_admin (or a tenant_admin via a bug) can't persist a value
      // the payments backend will reject on every subsequent donation.
      if (key === "defaultCurrency" && typeof val === "string" && val.length > 0) {
        val = validateCurrency(val).toUpperCase();
      }
      patch[key] = val;
    }

    // Auto-resolve adminUid when super_admin transfers adminEmail. The field
    // is in superOnlyFields so a tenant_admin can never reach this branch.
    // We resolve via Auth admin SDK so the client doesn't need to know the
    // uid — it just sends the new email. If the new email doesn't yet have
    // an Auth account, we null out adminUid so the field becomes accurate
    // (the next time that user signs up, they'll be the canonical admin).
    if (isSuper && "adminEmail" in updates && typeof patch.adminEmail === "string" && patch.adminEmail.length > 0) {
      const oldEmail = (snap.data()?.adminEmail ?? "").toLowerCase();
      const oldAdminUid = snap.data()?.adminUid || null;
      const newEmail = patch.adminEmail.toLowerCase();
      patch.adminEmail = newEmail; // normalize storage to lowercase
      if (newEmail !== oldEmail) {
        let newAdminUid = null;
        try {
          const targetRecord = await admin.auth().getUserByEmail(newEmail);
          newAdminUid = targetRecord.uid;
          patch.adminUid = newAdminUid;
        } catch (lookupErr) {
          // user-not-found → null out adminUid; the new admin can sign up
          // later and the team subcollection sweep will reconcile.
          patch.adminUid = null;
          console.info("updateTenant: adminEmail target has no auth account yet", {
            tenantId, newEmail,
          });
        }

        // Round-11 audit IMPORTANTE fix: the old code only rewrote
        // tenants/{tid}.adminEmail — it did NOT grant the tenant_admin
        // custom claim to the new admin nor revoke it from the outgoing
        // one. Result: the new admin literally could not log into the
        // panel ("no permisos"), and the outgoing admin kept full write
        // access to a tenant that was no longer theirs. UI had a hint
        // "recordá asignarle el rol" but nothing enforced it. Now we
        // atomically transfer the claim + team-subcollection record.
        //
        // Also update tenants/{tid}/team subcollection so the roster
        // reflects the swap immediately — otherwise the outgoing admin
        // still appears in the team list.
        if (newAdminUid) {
          try {
            const newUserRecord = await admin.auth().getUser(newAdminUid);
            const newClaims = { ...(newUserRecord.customClaims || {}) };
            newClaims.role = "tenant_admin";
            newClaims.tenantId = tenantId;
            await admin.auth().setCustomUserClaims(newAdminUid, newClaims);
            // Force refresh on next request so the new admin doesn't wait
            // for the ~1h token cache.
            await admin.auth().revokeRefreshTokens(newAdminUid);

            // Team subcollection: mark the new admin active with role
            // tenant_admin (idempotent — merge preserves other fields).
            await db.collection("tenants").doc(tenantId).collection("team")
              .doc(newAdminUid).set({
                uid: newAdminUid,
                email: newEmail,
                role: "tenant_admin",
                status: "active",
                addedAt: admin.firestore.FieldValue.serverTimestamp(),
                addedBy: request.auth?.uid || "updateTenant",
              }, { merge: true });
          } catch (claimErr) {
            console.warn("updateTenant: failed to grant tenant_admin claim to new admin", {
              tenantId, newAdminUid, error: claimErr?.message,
            });
          }
        }

        if (oldAdminUid && oldAdminUid !== newAdminUid) {
          try {
            const oldUserRecord = await admin.auth().getUser(oldAdminUid);
            const oldClaims = { ...(oldUserRecord.customClaims || {}) };
            // Only strip the tenant_admin claim if it was pointing at THIS
            // tenant — a super_admin retains super_admin, an admin who
            // manages a different tenant keeps that binding.
            if (oldClaims.role === "tenant_admin" && oldClaims.tenantId === tenantId) {
              delete oldClaims.role;
              delete oldClaims.tenantId;
              await admin.auth().setCustomUserClaims(oldAdminUid, oldClaims);
              await admin.auth().revokeRefreshTokens(oldAdminUid);
            }
            // Mark the outgoing admin as removed from the team roster.
            await db.collection("tenants").doc(tenantId).collection("team")
              .doc(oldAdminUid).set({
                status: "removed",
                removedAt: admin.firestore.FieldValue.serverTimestamp(),
                removedBy: request.auth?.uid || "updateTenant",
              }, { merge: true });
          } catch (revokeErr) {
            console.warn("updateTenant: failed to revoke tenant_admin claim from old admin", {
              tenantId, oldAdminUid, error: revokeErr?.message,
            });
          }
        }
      }
    }

    // BUG-028/015 follow-up: explicitly null out subscriptionMonthlyAmount on
    // any patch where planPrice is set, so legacy admin docs gradually
    // converge to a single source of truth (planPrice only).
    if ("planPrice" in patch) {
      patch.subscriptionMonthlyAmount = null;
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
            // Round-11 audit MEDIO fix: instead of hard-deleting the old
            // slug lock, convert it into a redirect. Users with the old
            // link saved (pushkapp.cc/j/oldslug in WhatsApp, email,
            // bookmarks) get seamlessly routed to the new tenant instead
            // of a "código no encontrado" screen. getTenantBySlug follows
            // the redirectTo field one hop.
            if (oldSlugRef) {
              tx.set(oldSlugRef, {
                redirectTo: normalizedSlug,
                tenantId, // keep for defense-in-depth reverse lookups
                redirectedAt: admin.firestore.FieldValue.serverTimestamp(),
              }, { merge: true });
            }
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

    // BUG-017/027 fix: propagate planPrice changes to Stripe.
    //
    // Two paths:
    //   1. There's already a Stripe subscription → swap the price in place
    //      (with proration). Used when admin raises $50 → $100.
    //   2. There's no subscription yet AND new planPrice > 0 → create one
    //      from scratch via _ensureTenantSubscription. Used when admin
    //      enables billing for a tenant that started on free tier
    //      (planPrice 0 → 50). Without this branch, Firestore said
    //      "$50/mo" but Stripe never billed.
    //   - If planPrice drops to 0, we leave the existing subscription
    //     alone (super_admin can cancel manually via cancelTenantSubscription).
    const beforeData = snap.data() ?? {};
    const prevPlanPrice = beforeData.planPrice ?? null;
    const newPlanPrice = "planPrice" in patch && typeof patch.planPrice === "number"
      ? patch.planPrice
      : null;
    const planPriceChanged =
      newPlanPrice !== null && newPlanPrice !== prevPlanPrice;
    const existingSubscriptionId = beforeData.stripeSubscriptionId ?? null;

    if (isSuper && planPriceChanged && newPlanPrice > 0 && existingSubscriptionId) {
      // Path 1: update existing subscription
      try {
        const stripe = require("stripe")(stripeSecret.value());
        const newPrice = await stripe.prices.create(
          {
            currency: "usd",
            unit_amount: Math.round(newPlanPrice * 100),
            recurring: { interval: "month" },
            product_data: { name: `Chabad Pushka SaaS — ${beforeData.name ?? tenantId}` },
          },
          { idempotencyKey: `tenant_price_${tenantId}_${Math.round(newPlanPrice * 100)}` },
        );
        const sub = await stripe.subscriptions.retrieve(existingSubscriptionId);
        const subItemId = sub.items?.data?.[0]?.id;
        if (subItemId) {
          await stripe.subscriptions.update(existingSubscriptionId, {
            items: [{ id: subItemId, price: newPrice.id }],
            proration_behavior: "create_prorations",
            metadata: { tenantId },
          });
          console.info("updateTenant: stripe subscription price updated", {
            tenantId, subscriptionId: existingSubscriptionId, newAmount: newPlanPrice,
          });
        } else {
          console.warn("updateTenant: subscription has no items.data[0]", {
            tenantId, subscriptionId: existingSubscriptionId,
          });
        }
      } catch (subErr) {
        console.warn("updateTenant: stripe sub update failed (non-fatal)", {
          tenantId, error: subErr?.message ?? String(subErr),
        });
      }
    } else if (isSuper && planPriceChanged && newPlanPrice > 0 && !existingSubscriptionId) {
      // Path 2: tenant was on free tier (planPrice 0) — provision a
      // subscription now that admin enabled paid billing. Non-fatal: if
      // Stripe is unreachable, the next updateTenant write or a manual
      // createTenantSubscription call will retry.
      try {
        await _ensureTenantSubscription(tenantId);
        console.info("updateTenant: stripe subscription provisioned on planPrice 0→>0", {
          tenantId, newAmount: newPlanPrice,
        });
      } catch (provErr) {
        console.warn("updateTenant: stripe sub provisioning failed (non-fatal)", {
          tenantId, error: provErr?.message ?? String(provErr),
        });
      }
    }

    // BUG-010 fix: when super_admin changes adminEmail, transfer
    // tenant_admin claims too. Without this, the tenant was orphaned: the
    // tenant doc pointed at the new email, but the new email had no
    // claim and the old email still had claim+tenantId pointing at this
    // tenant for up to 1h until token refresh.
    if (isSuper && "adminEmail" in updates) {
      const oldEmail = String(beforeData.adminEmail ?? "").toLowerCase();
      const newEmail = String(patch.adminEmail ?? "").toLowerCase();
      if (newEmail && newEmail !== oldEmail) {
        // 1. Revoke claims from old admin (if they have an Auth account AND
        //    their claim still points to this tenant). Skip if they're a
        //    super_admin — never revoke super_admin via this side channel.
        if (oldEmail) {
          try {
            const oldRec = await admin.auth().getUserByEmail(oldEmail);
            const oldClaims = oldRec.customClaims ?? {};
            const stillPointsHere =
              (oldClaims.role === "tenant_admin" || oldClaims.role === "tenant_collaborator") &&
              oldClaims.tenantId === tenantId;
            const isOldSuper = oldClaims.role === "super_admin";
            if (stillPointsHere && !isOldSuper) {
              const { role: _r, tenantId: _t, ...keep } = oldClaims;
              await admin.auth().setCustomUserClaims(oldRec.uid, keep);
              await admin.auth().revokeRefreshTokens(oldRec.uid);
              try {
                await tenantRef.collection("team").doc(oldRec.uid).delete();
              } catch (_) { /* tolerate missing team doc */ }
            }
          } catch (oldErr) {
            // user-not-found is benign (admin was a pending invitation).
            if (oldErr?.code !== "auth/user-not-found") {
              console.warn("updateTenant: old admin claim revoke failed (non-fatal)", {
                tenantId, oldEmail: _redactEmail(oldEmail), error: oldErr?.message,
              });
            }
          }
        }
        // 2. Apply tenant_admin claim to new email. If no Auth account yet,
        //    queue a pending invitation (same flow as setAdminClaim).
        try {
          let newRec;
          try {
            newRec = await admin.auth().getUserByEmail(newEmail);
          } catch (notFound) {
            if (notFound?.code === "auth/user-not-found") newRec = null;
            else throw notFound;
          }
          if (newRec) {
            const existingClaims = newRec.customClaims ?? {};
            const isAlreadySuper = existingClaims.role === "super_admin";
            // Preserve super_admin status; otherwise stamp tenant_admin claim.
            await admin.auth().setCustomUserClaims(newRec.uid, {
              ...existingClaims,
              ...(isAlreadySuper ? {} : { role: "tenant_admin", tenantId }),
            });
            await admin.auth().revokeRefreshTokens(newRec.uid);
            try {
              await tenantRef.collection("team").doc(newRec.uid).set({
                uid: newRec.uid,
                email: newRec.email,
                displayName: newRec.displayName ?? null,
                role: isAlreadySuper ? "super_admin" : "tenant_admin",
                addedAt: admin.firestore.FieldValue.serverTimestamp(),
                addedBy: callerUid,
                addedVia: "adminEmail_transfer",
              });
            } catch (teamErr) {
              console.warn("updateTenant: team subcoll write failed", { error: teamErr?.message });
            }
          } else {
            // No Auth account yet → queue pending invitation (30-day TTL).
            const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
            await db.collection("_pendingTenantAdmins").doc(newEmail).set({
              email: newEmail,
              role: "tenant_admin",
              tenantId,
              invitedBy: callerUid,
              invitedByEmail: callerRecord.email ?? null,
              invitedAt: admin.firestore.FieldValue.serverTimestamp(),
              expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
              addedVia: "adminEmail_transfer",
            });
          }
        } catch (newErr) {
          console.warn("updateTenant: new admin claim apply failed (non-fatal)", {
            tenantId, newEmail: _redactEmail(newEmail), error: newErr?.message,
          });
        }
      }
    }

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

    // Round-11 audit MEDIO fix: honor slug redirects. When a tenant renames
    // their slug via updateTenant, the old lock doc is rewritten with a
    // `redirectTo` field pointing to the new slug. Old links (WhatsApp,
    // email, bookmarks) transparently resolve to the new tenant instead of
    // showing "no encontrado". Single hop only to prevent loops.
    let effectiveSlug = slug;
    try {
      const oldLockSnap = await db.collection("_tenantSlugs").doc(slug).get();
      if (oldLockSnap.exists) {
        const lockData = oldLockSnap.data() || {};
        if (typeof lockData.redirectTo === "string" && lockData.redirectTo.length > 0 && lockData.redirectTo !== slug) {
          effectiveSlug = lockData.redirectTo.toLowerCase().replace(/[^a-z0-9]/g, "");
        }
      }
    } catch (_) { /* fall through to canonical query */ }

    const snap = await db.collection("tenants")
      .where("slug", "==", effectiveSlug)
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
  { enforceAppCheck: false },
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
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    // Cap to 200/h. The app legitimately polls this on boot + every ~60s
    // while in the foreground, so a normal session sees 60-80/h. 200 leaves
    // headroom for tab-switch refetches without letting a buggy client (or
    // attacker bypassing App Check) hammer the endpoint.
    await enforceRateLimit(request.auth.uid, "getTenantConfig", 200, 3600);

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
          // BUG-047 fix: also clear the rest of the legacy fields that were
          // copied into tenantState above. Leaving stale duplicates on the
          // user doc creates "which value is authoritative?" confusion and
          // risks the Flutter app writing to the wrong place (silent desync).
          // tenantState is now the source of truth for these per-tenant
          // values; the user doc only keeps cross-tenant settings (language,
          // currencyCode, biometricAuthenticationEnabled, etc.).
          batch.set(
            db.collection("users").doc(uid),
            {
              autoEmptyNextRunAt: null,
              pushkaAmount: admin.firestore.FieldValue.delete(),
              pushkaGoal: admin.firestore.FieldValue.delete(),
              presetAmount: admin.firestore.FieldValue.delete(),
              presetAmounts: admin.firestore.FieldValue.delete(),
              streakCount: admin.firestore.FieldValue.delete(),
              lastStreakDate: admin.firestore.FieldValue.delete(),
              autoEmptyFrequency: admin.firestore.FieldValue.delete(),
              autoEmptyWeekday: admin.firestore.FieldValue.delete(),
              autoEmptyDayOfMonth: admin.firestore.FieldValue.delete(),
              autoEmptyTopOffEnabled: admin.firestore.FieldValue.delete(),
              autoEmptyTopOffAmount: admin.firestore.FieldValue.delete(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
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

    // Cursor pagination — at 1k+ tenants the unbounded `.limit(1000).get()`
    // becomes slow + expensive on every dashboard open. Caller passes
    // `cursor` (createdAt ISO string) from the previous response to fetch
    // the next page. `limit` clamps to [1, 200].
    const requestedLimit = Number(request.data?.limit ?? 100);
    const limit = Math.min(200, Math.max(1, Number.isFinite(requestedLimit) ? requestedLimit : 100));
    const cursorRaw = request.data?.cursor;
    let q = db.collection("tenants").orderBy("createdAt", "desc");
    if (cursorRaw && typeof cursorRaw === "string") {
      const cursorDate = new Date(cursorRaw);
      if (!isNaN(cursorDate.getTime())) {
        q = q.startAfter(admin.firestore.Timestamp.fromDate(cursorDate));
      }
    }
    const snap = await q.limit(limit).get();

    function mapTenantDoc(d) {
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
    }

    const tenants = snap.docs.map(mapTenantDoc);

    // Catch tenants missing the `createdAt` field — Firestore's orderBy
    // silently excludes them, so the ordered query above never sees them.
    // Without this branch, an orphan tenant (e.g. a legacy doc created
    // before we started stamping createdAt) is invisible in the admin web
    // and can't be selected for deletion or repair. We only run this catch
    // on the FIRST page (no cursor) to avoid double-paginating; on
    // production scale, anyone with so many tenants would also be paying
    // for the audit log of orphan creation.
    if (!cursorRaw) {
      try {
        const orphanSnap = await db.collection("tenants").limit(500).get();
        const seen = new Set(snap.docs.map((d) => d.id));
        for (const od of orphanSnap.docs) {
          if (seen.has(od.id)) continue;
          tenants.push(mapTenantDoc(od));
        }
      } catch (orphanErr) {
        console.warn("listTenants: orphan sweep failed (non-fatal)", { err: orphanErr?.message });
      }
    }

    const nextCursor = snap.size === limit && tenants.length > 0
        ? tenants[tenants.length - 1].createdAt
        : null;

    return { tenants, nextCursor };
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

    // Bounded query: with unlimited .get() the dashboard scales O(tenant
    // count) and eventually OOMs. Cap at 200 most-recent tenants — plenty
    // for the near-term while a proper cursor-paginated dashboard is
    // designed. TODO(future): accept pageToken/startAfter for full paging.
    const DASHBOARD_TENANT_CAP = 200;
    const tenantsSnap = await db.collection("tenants")
      .orderBy("createdAt", "desc")
      .limit(DASHBOARD_TENANT_CAP)
      .get();

    // Helper: sum revenueStats monthly buckets over a range of months.
    // startOffset=0 → include current month, startOffset=1 → skip current
    // and start at last month. count is the number of buckets to sum.
    function sumMonthsRange(revenueStats, startOffset, count) {
      let total = 0;
      for (let i = 0; i < count; i++) {
        const monthOffset = startOffset + i;
        const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - monthOffset, 1));
        const key = `${d.getUTCFullYear()}_${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
        total += (revenueStats[key]?.revenue || 0);
      }
      return total;
    }
    // Backward-compat wrapper — legacy callsites treated monthsBack=N as
    // "current + prev N-1". Kept for the multi-month rollups; the current-
    // vs-previous-month distinction is now explicit via sumMonthsRange.
    function sumMonths(revenueStats, monthsBack) {
      return sumMonthsRange(revenueStats, 0, monthsBack);
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
          // Round-4 audit HIGH fix: `revenueLastMonth` used to be the
          // CURRENT month (misleading label). Split into two fields:
          //   - revenueThisMonth: current calendar month
          //   - revenueLastMonth: the previous calendar month (real "last")
          // Legacy consumers reading revenueLastMonth-as-current-month will
          // see zero for orgs with no activity yet in the calendar month;
          // update the admin panel to prefer revenueThisMonth.
          revenueThisMonth:          Math.round(sumMonthsRange(revenueStats, 0, 1) * 100) / 100,
          revenueLastMonth:          Math.round(sumMonthsRange(revenueStats, 1, 1) * 100) / 100,
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

    // Generate a state token for CSRF protection. Persisted in a
    // server-only collection (_stripeConnectOAuth/{stateToken}) rather
    // than on the tenant doc — any tenant member can read tenants/{id}
    // per firestore.rules (see `match /tenants/{tenantId} { allow read }`),
    // so storing the state there would let a tenant_collaborator steal it,
    // complete OAuth with their own Stripe account, and hijack donations.
    // The `_`-prefixed collection is covered by the existing deny-all
    // rule pattern in firestore.rules.
    //
    // COMPAT: any state tokens lingering on tenants/{id}
    // (stripeConnectOAuthState / ..CreatedAt) from before this fix are
    // stale — the new handleStripeConnectOAuth only looks in
    // _stripeConnectOAuth. There are no in-flight OAuth flows in prod
    // at deploy time, so the one-shot break is intentional and no
    // migration is required.
    const crypto = require("crypto");
    const state = crypto.randomBytes(20).toString("hex");
    const nowMs = Date.now();

    // Invalidate any prior state tokens for this tenant so a leaked or
    // screen-shared old link can't sit hot for 24h. Best-effort: failure
    // to delete leaves the natural TTL as a fallback bound.
    try {
      const priorSnap = await db.collection("_stripeConnectOAuth")
        .where("tenantId", "==", tenantId)
        .get();
      if (!priorSnap.empty) {
        const batch = db.batch();
        priorSnap.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
      }
    } catch (e) {
      console.warn("createStripeConnectLink: prior state cleanup failed (non-fatal)", {
        tenantId, error: e?.message,
      });
    }

    await db.collection("_stripeConnectOAuth").doc(state).set({
      tenantId,
      callerUid,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromMillis(nowMs + 86400000),
    });

    // Dynamically derive the project ID so prod and dev deployments each
    // round-trip to their own callback. Both URLs must be added to the
    // Stripe Connect dashboard's allowed redirect URIs.
    const projectId = process.env.GCLOUD_PROJECT ||
        process.env.GOOGLE_CLOUD_PROJECT ||
        "pushka-app-ioel";
    const redirectUri = `https://us-central1-${projectId}.cloudfunctions.net/handleStripeConnectOAuth`;
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
      // Round-6 audit LOW fix: delete the state doc so it doesn't sit
      // consuming Firestore quota for 24h TTL. Best-effort: if state
      // param is absent, skip (nothing to delete).
      if (state) {
        await db.collection("_stripeConnectOAuth").doc(state).delete().catch(() => {});
      }
      return res.redirect(`https://chabad-admin.web.app/tenants?connect=denied`);
    }

    if (!code || !state) {
      return res.status(400).send("Parámetros inválidos.");
    }

    // Look up the OAuth state token in the server-only collection
    // (_stripeConnectOAuth/{stateToken}) — see createStripeConnectLink
    // for why the state no longer lives on the tenant doc.
    //
    // COMPAT: pre-fix state tokens stored on tenants/{id} are ignored
    // here (there are no in-flight OAuth flows in prod at deploy time).
    const stateRef = db.collection("_stripeConnectOAuth").doc(state);
    const stateSnap = await stateRef.get();

    if (!stateSnap.exists) {
      console.error("No _stripeConnectOAuth entry for state:", state);
      return res.status(400).send("Estado inválido o expirado.");
    }

    const stateData = stateSnap.data() || {};
    const tenantId = stateData.tenantId;
    const initiatorUid = stateData.callerUid || null;

    if (!tenantId) {
      console.error("_stripeConnectOAuth entry missing tenantId:", state);
      await stateRef.delete().catch(() => {});
      return res.status(400).send("Estado inválido.");
    }

    // Validate state is not older than 24 hours (prefer explicit
    // expiresAt; fall back to createdAt + 24h if a doc predates the
    // expiresAt field for any reason).
    const nowMs = Date.now();
    const expiresAtMs = stateData.expiresAt?.toMillis?.() ??
      ((stateData.createdAt?.toMillis?.() ?? 0) + 86400000);
    if (!expiresAtMs || nowMs > expiresAtMs) {
      await stateRef.delete().catch(() => {});
      return res.status(400).send("Enlace expirado. Genera uno nuevo desde el panel.");
    }

    const tenantRef = db.collection("tenants").doc(tenantId);
    const tenantSnap = await tenantRef.get();
    if (!tenantSnap.exists) {
      console.error("Stripe Connect OAuth: tenant not found for state", { state, tenantId });
      await stateRef.delete().catch(() => {});
      return res.status(400).send("Tenant no encontrado.");
    }

    // Exchange code for access_token and stripe_user_id
    try {
      const stripe = require("stripe")(stripeSecret.value());
      const response = await stripe.oauth.token({
        grant_type: "authorization_code",
        code,
      });

      const stripeConnectAccountId = response.stripe_user_id;

      // SECURITY (2-step confirmation, "silent swap" fix):
      // We intentionally DO NOT write stripeConnectAccountId here. The person
      // whose browser completed OAuth may not be the person who owns the
      // tenant's Stripe (e.g. someone logged into the wrong Stripe account
      // in that tab, or a compromised tenant_admin trying to redirect
      // payouts). Instead we stash the details in tenants/{id}.pendingStripeConnect
      // and require an explicit confirmStripeConnectAccount call from a
      // super_admin or the tenant's tenant_admin — with the fetched details
      // visible — before donations start routing to this account.
      //
      // This is what prevents "wrong Stripe accidentally connected because
      // the person on the browser at OAuth time was logged into the wrong
      // Stripe" (which is how tenant chabadmexico briefly pointed at
      // AI Systems / Ioel's Stripe).
      let businessName = null;
      let acctCountry = null;
      let acctEmail = null;
      let chargesEnabled = false;
      let payoutsEnabled = false;
      try {
        const acct = await stripe.accounts.retrieve(stripeConnectAccountId);
        businessName = acct.business_profile?.name
          || acct.settings?.dashboard?.display_name
          || acct.company?.name
          || (acct.individual
                ? `${acct.individual.first_name || ""} ${acct.individual.last_name || ""}`.trim() || null
                : null)
          || acct.email
          || null;
        acctCountry = acct.country || null;
        acctEmail = acct.email || null;
        chargesEnabled = acct.charges_enabled === true;
        payoutsEnabled = acct.payouts_enabled === true;
      } catch (acctErr) {
        // Defensive: if retrieve fails we still store what we have — the
        // confirm step will re-fetch and refuse to activate an account
        // that isn't ready.
        console.warn("handleStripeConnectOAuth: account retrieve failed", {
          tenantId, stripeConnectAccountId, error: acctErr?.message,
        });
      }

      // Snapshot prior account id so the pending email can tell the reader
      // whether this would be a first-time connection or a swap.
      const priorTenantData = tenantSnap.data() || {};
      const priorStripeConnectAccountId = priorTenantData.stripeConnectAccountId || null;

      const pendingPayload = {
        accountId: stripeConnectAccountId,
        businessName: businessName || null,
        country: acctCountry || null,
        email: acctEmail || null,
        chargesEnabled,
        payoutsEnabled,
        initiatedByUid: initiatorUid || null,
        initiatedAt: admin.firestore.FieldValue.serverTimestamp(),
        // 7-day window to confirm — after that the confirm CF will refuse
        // and require a fresh OAuth cycle.
        expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 7 * 86400000),
      };

      await tenantRef.update({
        pendingStripeConnect: pendingPayload,
        // COMPAT: legacy fields from the old (insecure) state-on-tenant
        // scheme — clear them if present. FieldValue.delete() is a no-op
        // when the field doesn't exist, so this is safe on new tenants.
        stripeConnectOAuthState: admin.firestore.FieldValue.delete(),
        stripeConnectOAuthStateCreatedAt: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Retire the state token so it can't be replayed. Failure to
      // delete is logged but non-fatal — the 24h TTL still bounds abuse
      // and a nightly sweep can GC leftovers.
      await stateRef.delete().catch(err => {
        console.warn("handleStripeConnectOAuth: failed to delete _stripeConnectOAuth entry", {
          state, tenantId, error: err?.message,
        });
      });

      console.log(`Stripe Connect PENDING confirmation for tenant ${tenantId}: ${stripeConnectAccountId}`);

      // Notify tenant admin + super_admin of the PENDING account with the
      // details fetched from Stripe so the human can spot a wrong account
      // BEFORE it goes live. Fire-and-forget: SendGrid outages must not
      // fail the OAuth redirect.
      try {
        const tenantData = priorTenantData;
        const tenantName = tenantData.name || tenantData.appName || tenantId;
        const adminEmail = tenantData.adminEmail || null;
        const maskAcct = (id) => (id && typeof id === "string" && id.length > 12)
          ? `${id.slice(0, 8)}…${id.slice(-4)}`
          : (id || "(desconocido)");
        const maskedNewAcct = maskAcct(stripeConnectAccountId);
        const maskedPriorAcct = priorStripeConnectAccountId
          ? maskAcct(priorStripeConnectAccountId)
          : null;
        const isSwap = priorStripeConnectAccountId &&
          priorStripeConnectAccountId !== stripeConnectAccountId;
        const whenIso = new Date().toISOString();
        const subject = `[Pushka] Confirmá la cuenta de Stripe para ${tenantName}`;
        const priorRow = maskedPriorAcct
          ? `<tr><td style="padding:4px 12px;color:#64748b">Cuenta anterior:</td><td style="padding:4px 12px;font-family:monospace">${maskedPriorAcct}</td></tr>`
          : "";
        const confirmUrl = `https://chabad-admin.web.app/tenants/${tenantId}/confirm-stripe`;
        const html = `
          <p style="font-family:sans-serif;font-size:15px;line-height:1.5">
            Se autorizó una cuenta de Stripe Connect ${isSwap ? "para <b>reemplazar</b> la actual" : "para el tenant"} <strong>${tenantName}</strong>. <b>Todavía NO está activa</b> — revisá los datos y confirmá.
          </p>
          <table style="font-family:sans-serif;font-size:14px;border-collapse:collapse;margin-top:12px">
            <tr><td style="padding:4px 12px;color:#64748b">Tenant:</td><td style="padding:4px 12px"><b>${tenantName}</b> (<code>${tenantId}</code>)</td></tr>
            ${priorRow}
            <tr><td style="padding:4px 12px;color:#64748b">Cuenta nueva:</td><td style="padding:4px 12px;font-family:monospace">${maskedNewAcct}</td></tr>
            <tr><td style="padding:4px 12px;color:#64748b">Nombre comercial:</td><td style="padding:4px 12px"><b>${_escapeHtmlForEmail(businessName || "(no disponible)")}</b></td></tr>
            <tr><td style="padding:4px 12px;color:#64748b">País:</td><td style="padding:4px 12px">${_escapeHtmlForEmail(acctCountry || "(no disponible)")}</td></tr>
            <tr><td style="padding:4px 12px;color:#64748b">Email Stripe:</td><td style="padding:4px 12px">${_escapeHtmlForEmail(acctEmail || "(no disponible)")}</td></tr>
            <tr><td style="padding:4px 12px;color:#64748b">Estado KYC:</td><td style="padding:4px 12px">charges_enabled=${chargesEnabled}, payouts_enabled=${payoutsEnabled}</td></tr>
            <tr><td style="padding:4px 12px;color:#64748b">Iniciado por (UID):</td><td style="padding:4px 12px;font-family:monospace">${initiatorUid || "(desconocido)"}</td></tr>
            <tr><td style="padding:4px 12px;color:#64748b">Fecha (UTC):</td><td style="padding:4px 12px">${whenIso}</td></tr>
          </table>
          <p style="margin-top:20px">
            <a href="${confirmUrl}" style="display:inline-block;background:#10b981;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:600;font-family:sans-serif">Revisar y confirmar →</a>
          </p>
          <p style="margin-top:20px;padding:12px 16px;background:#fef2f2;border-left:4px solid #dc2626;color:#991b1b;font-family:sans-serif;font-size:14px;line-height:1.5">
            <strong>Si el nombre comercial NO coincide con tu organización, rechazá la conexión.</strong>
            Confirmar una cuenta equivocada redirige todas las donaciones futuras a esa cuenta.
          </p>
          <p style="margin-top:24px;font-family:sans-serif;font-size:12px;color:#94a3b8">
            Alerta automática de Chabad Pushka backend.
          </p>
        `;
        const recipients = [];
        if (adminEmail) recipients.push(adminEmail);
        if (SUPER_ADMIN_EMAIL &&
            SUPER_ADMIN_EMAIL.toLowerCase() !== (adminEmail || "").toLowerCase()) {
          recipients.push(SUPER_ADMIN_EMAIL);
        }
        await Promise.all(
          recipients.map(to =>
            sendEmail({ to, subject, html }).catch(err =>
              console.warn("handleStripeConnectOAuth: alert email failed", {
                tenantId, to: _redactEmail(to), error: err?.message,
              })
            )
          )
        );
      } catch (alertErr) {
        console.warn("handleStripeConnectOAuth: alert block failed", {
          tenantId, error: alertErr?.message,
        });
      }

      return res.redirect(`https://chabad-admin.web.app/tenants/${tenantId}/confirm-stripe`);
    } catch (err) {
      console.error("Stripe Connect OAuth exchange error:", err);
      return res.status(500).send("Error al conectar con Stripe. Intentá de nuevo.");
    }
  }
);

// ---------------------------------------------------------------------------
// confirmStripeConnectAccount — apply a pending Stripe Connect account
// ---------------------------------------------------------------------------
// Second step of the 2-phase Stripe Connect flow. handleStripeConnectOAuth
// only stashes the returned stripe_user_id + fetched account details into
// tenants/{id}.pendingStripeConnect. A human (super_admin OR the tenant's
// tenant_admin) must then eyeball those details and confirm — this is what
// prevents accidentally activating the wrong Stripe account when the browser
// was logged into someone else's Stripe at OAuth time.
exports.confirmStripeConnectAccount = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "confirmStripeConnectAccount", 20, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuperAdminCaller = await callerIsSuperAdminFresh(request);
    const isTenantAdminCaller = callerClaims.role === "tenant_admin";
    if (!isSuperAdminCaller && !isTenantAdminCaller) {
      throw new HttpsError("permission-denied", "Acceso denegado.");
    }

    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    if (!isSuperAdminCaller && callerClaims.tenantId !== tenantId) {
      throw new HttpsError("permission-denied", "Solo podés confirmar la cuenta de tu propia organización.");
    }

    const tenantRef = db.collection("tenants").doc(tenantId);
    const tenantSnap = await tenantRef.get();
    if (!tenantSnap.exists) throw new HttpsError("not-found", "Tenant no encontrado.");
    const tenantData = tenantSnap.data() || {};
    const pending = tenantData.pendingStripeConnect || null;
    if (!pending || !pending.accountId) {
      throw new HttpsError("failed-precondition", "No hay ninguna cuenta pendiente de confirmar.");
    }

    // Expiry check: reject stale pending records (force fresh OAuth).
    const expMs = pending.expiresAt?.toMillis?.() ?? null;
    if (expMs && Date.now() > expMs) {
      await tenantRef.update({
        pendingStripeConnect: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      throw new HttpsError("deadline-exceeded", "La solicitud pendiente venció. Iniciá una nueva conexión.");
    }

    // Re-verify status directly against Stripe. We refuse to activate an
    // account that isn't charges+payouts ready — donors would get generic
    // errors otherwise. If retrieve fails, we mark it "restricted" and let
    // the next account.updated webhook flip it to "active".
    const stripe = require("stripe")(stripeSecret.value());
    let initialStatus = "restricted";
    try {
      const acct = await stripe.accounts.retrieve(pending.accountId);
      initialStatus = (acct.charges_enabled === true && acct.payouts_enabled === true)
        ? "active"
        : "restricted";
    } catch (e) {
      console.warn("confirmStripeConnectAccount: account retrieve failed", {
        tenantId, accountId: pending.accountId, error: e?.message,
      });
    }

    const priorStripeConnectAccountId = tenantData.stripeConnectAccountId || null;

    await tenantRef.update({
      stripeConnectAccountId: pending.accountId,
      stripeConnectStatus: initialStatus,
      pendingStripeConnect: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    console.info("confirmStripeConnectAccount: applied", {
      tenantId, accountId: pending.accountId, callerUid, initialStatus,
    });

    // Existing "Stripe Connect account changed" alert — fires now that the
    // account is truly active. Mirrors the pre-refactor behavior.
    try {
      const tenantName = tenantData.name || tenantData.appName || tenantId;
      const adminEmail = tenantData.adminEmail || null;
      const maskAcct = (id) => (id && typeof id === "string" && id.length > 12)
        ? `${id.slice(0, 8)}…${id.slice(-4)}`
        : (id || "(desconocido)");
      const maskedNewAcct = maskAcct(pending.accountId);
      const maskedPriorAcct = priorStripeConnectAccountId ? maskAcct(priorStripeConnectAccountId) : null;
      const isSwap = priorStripeConnectAccountId && priorStripeConnectAccountId !== pending.accountId;
      const whenIso = new Date().toISOString();
      const subject = `[Pushka] Stripe Connect account CONFIRMED for ${tenantName}`;
      const priorRow = maskedPriorAcct
        ? `<tr><td style="padding:4px 12px;color:#64748b">Cuenta anterior:</td><td style="padding:4px 12px;font-family:monospace">${maskedPriorAcct}</td></tr>`
        : "";
      const html = `
        <p style="font-family:sans-serif;font-size:15px;line-height:1.5">
          Se ${isSwap ? "<b>reemplazó</b>" : "activó"} la cuenta de Stripe Connect para <strong>${tenantName}</strong>. Las donaciones futuras van a esta cuenta.
        </p>
        <table style="font-family:sans-serif;font-size:14px;border-collapse:collapse;margin-top:12px">
          <tr><td style="padding:4px 12px;color:#64748b">Tenant:</td><td style="padding:4px 12px"><b>${tenantName}</b> (<code>${tenantId}</code>)</td></tr>
          ${priorRow}
          <tr><td style="padding:4px 12px;color:#64748b">Cuenta activa:</td><td style="padding:4px 12px;font-family:monospace">${maskedNewAcct}</td></tr>
          <tr><td style="padding:4px 12px;color:#64748b">Nombre comercial:</td><td style="padding:4px 12px"><b>${_escapeHtmlForEmail(pending.businessName || "(no disponible)")}</b></td></tr>
          <tr><td style="padding:4px 12px;color:#64748b">Estado inicial:</td><td style="padding:4px 12px">${initialStatus}</td></tr>
          <tr><td style="padding:4px 12px;color:#64748b">Confirmado por (UID):</td><td style="padding:4px 12px;font-family:monospace">${callerUid}</td></tr>
          <tr><td style="padding:4px 12px;color:#64748b">Fecha (UTC):</td><td style="padding:4px 12px">${whenIso}</td></tr>
        </table>
        <p style="margin-top:20px;padding:12px 16px;background:#fef2f2;border-left:4px solid #dc2626;color:#991b1b;font-family:sans-serif;font-size:14px;line-height:1.5">
          <strong>Si vos no hiciste este cambio, contactanos inmediatamente.</strong>
        </p>
      `;
      const recipients = [];
      if (adminEmail) recipients.push(adminEmail);
      if (SUPER_ADMIN_EMAIL && SUPER_ADMIN_EMAIL.toLowerCase() !== (adminEmail || "").toLowerCase()) {
        recipients.push(SUPER_ADMIN_EMAIL);
      }
      await Promise.all(recipients.map(to =>
        sendEmail({ to, subject, html }).catch(err =>
          console.warn("confirmStripeConnectAccount: alert email failed", {
            tenantId, to: _redactEmail(to), error: err?.message,
          })
        )
      ));
    } catch (alertErr) {
      console.warn("confirmStripeConnectAccount: alert block failed", {
        tenantId, error: alertErr?.message,
      });
    }

    return {
      success: true,
      accountId: pending.accountId,
      stripeConnectStatus: initialStatus,
    };
  },
);

// ---------------------------------------------------------------------------
// rejectStripeConnectAccount — discard a pending Stripe Connect account
// ---------------------------------------------------------------------------
exports.rejectStripeConnectAccount = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "rejectStripeConnectAccount", 20, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuperAdminCaller = await callerIsSuperAdminFresh(request);
    const isTenantAdminCaller = callerClaims.role === "tenant_admin";
    if (!isSuperAdminCaller && !isTenantAdminCaller) {
      throw new HttpsError("permission-denied", "Acceso denegado.");
    }

    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    if (!isSuperAdminCaller && callerClaims.tenantId !== tenantId) {
      throw new HttpsError("permission-denied", "Solo podés rechazar la cuenta de tu propia organización.");
    }

    const tenantRef = db.collection("tenants").doc(tenantId);
    const tenantSnap = await tenantRef.get();
    if (!tenantSnap.exists) throw new HttpsError("not-found", "Tenant no encontrado.");
    const pending = tenantSnap.data()?.pendingStripeConnect || null;
    if (!pending) {
      // Idempotent — already clear.
      return { success: true, cleared: false };
    }

    await tenantRef.update({
      pendingStripeConnect: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    console.info("rejectStripeConnectAccount: cleared", {
      tenantId, accountId: pending.accountId, callerUid,
    });

    return { success: true, cleared: true, accountId: pending.accountId || null };
  },
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
            ¿Tenés dudas? Contactá a tu asesor de Chabad Pushka.<br>
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
  // Stricter than the previous /[^\s@]+@[^\s@]+\.[^\s@]+/: requires at
  // least one alphanumeric in the local + domain start, and a TLD of 2+
  // alpha chars. Catches "a@-b.com" / "a@b.c" which the loose form let
  // through. Firebase Auth is the canonical email gate; this is defense
  // in depth before we hit SendGrid (and waste an API call on garbage).
  const emailRegex = /^[A-Za-z0-9._%+\-]+@[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z]{2,}$/;
  if (!to || to.length > 254 || !emailRegex.test(to)) {
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
      from: { email: SENDGRID_FROM, name: "Chabad Pushka" },
      subject,
      content: [{ type: "text/html", value: html }],
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    console.error("sendEmail error:", res.status, body);
    // Round-8 audit HIGH fix: throw on non-OK so callers wrapping in
    // `.catch(...)` actually see the failure. Previous silent behavior
    // meant welcome-email failures (createTenant) and dunning notices
    // never surfaced — admin thought the email went out.
    throw new Error(`SendGrid ${res.status}: ${body.slice(0, 400)}`);
  }
}

// ---------------------------------------------------------------------------
// createTenantSubscription — super_admin creates Stripe Billing subscription
// ---------------------------------------------------------------------------
/**
 * Internal helper: creates Stripe customer + price + subscription for a tenant.
 * Used by both the public `createTenantSubscription` CF and by `createTenant`
 * (which chains this call automatically so every new tenant gets a billing
 * subscription wired up without manual intervention — BUG-026 fix).
 *
 * Idempotent: a second call for the same tenant reuses the existing customer
 * and the same Stripe price+sub objects (via deterministic idempotency keys).
 *
 * Returns:
 *   { subscriptionId, clientSecret, hostedInvoiceUrl, alreadyExisted? }
 */
async function _ensureTenantSubscription(tenantId) {
  if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

  const tenantRef = db.collection("tenants").doc(tenantId);
  const tenantSnap = await tenantRef.get();
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

  // Reuse existing subscription if already provisioned (idempotency).
  if (tenantData.stripeSubscriptionId) {
    try {
      const existing = await stripe.subscriptions.retrieve(tenantData.stripeSubscriptionId, {
        expand: ["latest_invoice.payment_intent"],
      });
      return {
        subscriptionId: existing.id,
        clientSecret: existing.latest_invoice?.payment_intent?.client_secret ?? null,
        hostedInvoiceUrl: existing.latest_invoice?.hosted_invoice_url ?? null,
        alreadyExisted: true,
      };
    } catch (retrieveErr) {
      // Existing ID is stale (deleted in Stripe?). Fall through to create a fresh sub.
      console.warn("_ensureTenantSubscription: existing sub retrieve failed, will create new", {
        tenantId, subscriptionId: tenantData.stripeSubscriptionId, error: retrieveErr?.message,
      });
    }
  }

  // Create or reuse Stripe customer. Idempotency key tied to tenantId so a
  // retry within 24h reuses the same Stripe customer instead of creating a
  // duplicate. Stripe API rejects ANY parameter mismatch under the same
  // key — keep the create body deterministic (no timestamps, etc.).
  let stripeCustomerId = tenantData.stripeCustomerId;
  if (!stripeCustomerId) {
    const customer = await stripe.customers.create(
      {
        email: adminEmail,
        name: tenantData.name,
        metadata: { tenantId },
      },
      { idempotencyKey: `tenant_customer_${tenantId}` },
    );
    stripeCustomerId = customer.id;
  }

  // Per-tenant price object. The idempotency key includes planPrice so a
  // legitimate plan change (admin bumps the price) creates a NEW price
  // instead of reusing the old amount; same plan + same tenant always
  // reuses the same price object.
  const price = await stripe.prices.create(
    {
      currency: "usd",
      unit_amount: Math.round(planPrice * 100),
      recurring: { interval: "month" },
      product_data: { name: `Pushka SaaS — ${tenantData.name}` },
    },
    { idempotencyKey: `tenant_price_${tenantId}_${Math.round(planPrice * 100)}` },
  );

  // Subscription. Same key → Stripe returns the existing subscription on
  // retry instead of creating a second one (= double-billing to tenant).
  const subscription = await stripe.subscriptions.create(
    {
      customer: stripeCustomerId,
      items: [{ price: price.id }],
      payment_behavior: "default_incomplete",
      payment_settings: { save_default_payment_method: "on_subscription" },
      expand: ["latest_invoice.payment_intent"],
      metadata: { tenantId },
    },
    { idempotencyKey: `tenant_sub_${tenantId}_${Math.round(planPrice * 100)}` },
  );

  const now = new Date();
  const nextDue = new Date(now);
  nextDue.setMonth(nextDue.getMonth() + 1);

  // Use "pending_payment" — subscription is incomplete until customer
  // adds a payment method and the first invoice is confirmed via webhook.
  await tenantRef.update({
    stripeCustomerId,
    stripeSubscriptionId: subscription.id,
    paymentStatus: "pending_payment",
    billingCycleStart: admin.firestore.Timestamp.fromDate(now),
    billingNextDue: admin.firestore.Timestamp.fromDate(nextDue),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return {
    subscriptionId: subscription.id,
    clientSecret: subscription.latest_invoice?.payment_intent?.client_secret ?? null,
    hostedInvoiceUrl: subscription.latest_invoice?.hosted_invoice_url ?? null,
    alreadyExisted: false,
  };
}

exports.createTenantSubscription = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo el super administrador.");
    }
    // Cap retries: a double-click without idempotency keys would have created
    // duplicate Stripe customers + prices + subscriptions (= double-charge to
    // the tenant). Idempotency keys below close that primary hole; the rate
    // limit is the second line of defense against rapid retries from the
    // admin web panel.
    await enforceRateLimit(request.auth.uid, "createTenantSubscription", 5, 3600);

    const { tenantId } = request.data ?? {};
    return await _ensureTenantSubscription(tenantId);
  }
);

// ---------------------------------------------------------------------------
// createBillingPortalSession — Stripe Customer Portal for tenant self-service.
// Lets the tenant_admin update their payment method, view invoices, download
// receipts without super_admin intervention (BUG-034 fix, Audit Round 4).
// ---------------------------------------------------------------------------
exports.createBillingPortalSession = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "createBillingPortalSession", 10, 3600);

    const callerRecord = await admin.auth().getUser(callerUid);
    const callerClaims = callerRecord.customClaims || {};
    const isSuper = callerClaims.role === "super_admin" ||
      (callerClaims.admin === true && callerRecord.email === SUPER_ADMIN_EMAIL);
    const isTenantAdmin = callerClaims.role === "tenant_admin";
    if (!isSuper && !isTenantAdmin) {
      throw new HttpsError("permission-denied", "Acceso denegado.");
    }

    // super_admin can request any tenant; tenant_admin only their own
    const tenantId = isSuper
      ? request.data?.tenantId
      : callerClaims.tenantId;
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");
    if (isTenantAdmin && callerClaims.tenantId !== tenantId) {
      throw new HttpsError("permission-denied", "Solo podés gestionar tu propia organización.");
    }

    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) throw new HttpsError("not-found", "Tenant no encontrado.");
    const tenantData = tenantSnap.data();
    const customerId = tenantData.stripeCustomerId;
    if (!customerId) {
      throw new HttpsError(
        "failed-precondition",
        "Tu organización todavía no tiene una suscripción configurada.",
      );
    }

    const stripe = require("stripe")(stripeSecret.value());
    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: "https://chabad-admin.web.app/my-org",
    });

    return { url: session.url };
  }
);

// ---------------------------------------------------------------------------
// cancelTenantSubscription — super_admin cancels Stripe Billing subscription
// ---------------------------------------------------------------------------
exports.cancelTenantSubscription = onCall(
  { secrets: [stripeSecret, sendgridApiKey], enforceAppCheck: false },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo el super administrador.");
    }
    // Round-6 audit LOW fix: symmetry with deleteTenant which already
    // rate-limits (20/hr). Prevents accidental double-cancel + caps blast
    // radius if super_admin credentials leak.
    await enforceRateLimit(request.auth.uid, "cancelTenantSubscription", 20, 3600);

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

    // BUG-029 fix: notify the tenant_admin via email so the rab gets a
    // paper trail of the cancellation. Also log to the activity feed for
    // super_admin operations history.
    const adminEmail = tenantData.adminEmail;
    const tenantName = tenantData.name ?? tenantId;
    if (adminEmail) {
      try {
        await sendEmail({
          to: adminEmail,
          subject: `Tu suscripción a Chabad Pushka fue cancelada — ${tenantName}`,
          html: `
            <p>Hola,</p>
            <p>Te informamos que tu suscripción de <strong>${tenantName}</strong> a Chabad Pushka ha sido cancelada.</p>
            <p>Tu servicio sigue activo hasta el fin del período de facturación actual.</p>
            <p>Si esto fue un error o querés reactivar la suscripción, contactá a soporte.</p>
            <p>— Equipo Chabad Pushka</p>
          `,
        });
      } catch (e) {
        console.warn("cancelTenantSubscription: tenant email failed", { tenantId, error: e?.message });
      }
    }
    try {
      await writeActivityLog({
        type: "tenant_subscription_canceled",
        tenantId,
        tenantName,
        severity: "warning",
        requiresAction: false,
        data: {
          actor: request.auth.uid,
          subscriptionId,
          adminEmail: adminEmail ?? null,
        },
      });
    } catch (logErr) {
      console.warn("cancelTenantSubscription: activityLog failed", { error: logErr?.message });
    }

    return { success: true };
  }
);

// ---------------------------------------------------------------------------
// deleteTenant — super_admin only. Hard-delete a tenant + cleanup orphans.
// ---------------------------------------------------------------------------
// What it does, in order:
//   1. Cancel any active Stripe Billing subscription (best-effort).
//   2. Cancel any active Stripe Connect link (just clears our reference; the
//      Connect account itself stays in Stripe — only Stripe support can purge).
//   3. Delete the `_tenantSlugs/{slug}` lock so the slug becomes available.
//   4. For every user in `tenantIds`: remove this tenant from their array,
//      clear the `tenantId` field if it pointed here (so they aren't stuck
//      pointing at a void), delete their `tenantState/{tenantId}` doc.
//   5. Delete the tenant doc itself.
//   6. Write an activity log entry for audit.
//
// Tradeoffs:
//   - We do NOT delete user accounts even if this was their only tenant.
//     They keep history + Stripe customer; on next app open
//     `getTenantConfig` returns "tenant_missing" and the orphan-healing path
//     redirects to /tenant-setup.
//   - We do NOT delete the user's transactions/payment events that point at
//     this tenant. Those have legal retention requirements and the tenant id
//     stays as metadata for ops reconciliation.
//   - This is a HARD delete — no undo. Soft-delete (status: 'deleted') was
//     considered but adds complexity and the slug-reuse + Stripe-cleanup
//     concerns push toward hard-delete for prelaunch test data.
//
// Safety: requires super_admin claim AND idempotency on Stripe operations
// (so a retry doesn't error out partway through).
exports.deleteTenant = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "Solo el super administrador.");
    }
    await enforceRateLimit(request.auth.uid, "deleteTenant", 20, 3600);

    const tenantId = String(request.data?.tenantId || "").trim();
    if (!tenantId) throw new HttpsError("invalid-argument", "tenantId requerido.");

    const tenantRef = db.collection("tenants").doc(tenantId);
    const tenantSnap = await tenantRef.get();
    if (!tenantSnap.exists) {
      throw new HttpsError("not-found", "Tenant no encontrado.");
    }
    const tenantData = tenantSnap.data() || {};
    const tenantName = tenantData.name || tenantId;
    const slug = tenantData.slug || null;
    const stripeSubscriptionId = tenantData.stripeSubscriptionId || null;
    const stripeCustomerId = tenantData.stripeCustomerId || null;

    const result = {
      tenantId,
      tenantName,
      stripeSubCanceled: false,
      stripeCustomerDeleted: false,
      slugLockDeleted: false,
      usersUpdated: 0,
      tenantStatesDeleted: 0,
      tenantDocDeleted: false,
      warnings: [],
    };

    // 1. Cancel Stripe Billing subscription (best-effort — we still proceed
    // with delete even if Stripe call fails, e.g. sub already canceled).
    if (stripeSubscriptionId && stripeSecret.value()) {
      try {
        const stripe = require("stripe")(stripeSecret.value());
        await stripe.subscriptions.cancel(stripeSubscriptionId, { invoice_now: false, prorate: false });
        result.stripeSubCanceled = true;
      } catch (err) {
        result.warnings.push(`stripe sub cancel failed: ${err?.message ?? err}`);
      }
    }

    // 2. Delete Stripe customer (also detaches all saved cards on it). Skip if
    // shared with anything else — but tenant SaaS customers are dedicated.
    if (stripeCustomerId && stripeSecret.value()) {
      try {
        const stripe = require("stripe")(stripeSecret.value());
        await stripe.customers.del(stripeCustomerId);
        result.stripeCustomerDeleted = true;
      } catch (err) {
        result.warnings.push(`stripe customer delete failed: ${err?.message ?? err}`);
      }
    }

    // 2.5. Round-6 audit CRITICAL fix: cancel ALL donor recurring
    // subscriptions on the tenant's Connect account BEFORE dropping
    // memberships. Without this, donors keep getting charged monthly for a
    // tenant that no longer exists in the app — they have no UI path to
    // cancel (listDonationSubscriptions filters by user's tenantIds, which
    // won't include this one post-delete).
    const stripeConnectAccountId = tenantData.stripeConnectAccountId || null;
    if (stripeConnectAccountId && tenantData.stripeConnectStatus === "active" && stripeSecret.value()) {
      try {
        const stripe = require("stripe")(stripeSecret.value(), { timeout: 30000 });
        const opts = { stripeAccount: stripeConnectAccountId };
        const ACTIVE_STATUSES = new Set(["active", "trialing", "past_due", "incomplete"]);
        // Paginated list — a large tenant could have thousands of active subs.
        let startingAfter = null;
        let donorSubsCanceled = 0;
        let donorSubCancelFailures = 0;
        while (true) {
          const listArgs = { status: "all", limit: 100 };
          if (startingAfter) listArgs.starting_after = startingAfter;
          const subs = await stripe.subscriptions.list(listArgs, opts);
          if (!subs.data || subs.data.length === 0) break;
          for (const sub of subs.data) {
            if (sub.metadata?.purpose !== "donation_recurring") continue;
            if (!ACTIVE_STATUSES.has(sub.status)) continue;
            try {
              await stripe.subscriptions.cancel(sub.id, {}, opts);
              donorSubsCanceled += 1;
            } catch (cancelErr) {
              donorSubCancelFailures += 1;
              console.warn("deleteTenant: donor sub cancel failed", {
                tenantId, subId: sub.id, error: String(cancelErr?.message || cancelErr),
              });
            }
          }
          if (!subs.has_more) break;
          startingAfter = subs.data[subs.data.length - 1].id;
        }
        result.donorSubsCanceled = donorSubsCanceled;
        if (donorSubCancelFailures > 0) {
          result.warnings.push(`donor sub cancels failed: ${donorSubCancelFailures}`);
        }
      } catch (err) {
        result.warnings.push(`donor subs cleanup failed: ${err?.message ?? err}`);
      }
    }

    // 3. Delete slug lock so the slug is reusable.
    if (slug) {
      try {
        await db.collection("_tenantSlugs").doc(slug).delete();
        result.slugLockDeleted = true;
      } catch (err) {
        result.warnings.push(`slug lock delete failed: ${err?.message ?? err}`);
      }
    }

    // 4. Update affected users — paginated to handle tenants with many members
    // without blowing up the function timeout. 500 per page covers >99% of
    // tenants in our scale; for the rare giant tenant we recurse via while.
    const PAGE = 500;
    let lastDoc = null;
    while (true) {
      let q = db.collection("users")
        .where("tenantIds", "array-contains", tenantId)
        .limit(PAGE);
      if (lastDoc) q = q.startAfter(lastDoc);
      const usersSnap = await q.get();
      if (usersSnap.empty) break;

      // Batch reused across the page. IMPORTANT: after batch.commit(), the
      // WriteBatch object is closed — any further batch.set/delete on it
      // will not be re-applied. We MUST reassign `batch = db.batch()` after
      // every mid-loop commit. Cap at 400 ops (safe margin under 500 limit).
      let batch = db.batch();
      let batchOps = 0;
      // BUG-030 fix: collect uids whose claims point at this tenant so we
      // can revoke them after the batch commits. We do the claim revocation
      // OUTSIDE the Firestore batch because setCustomUserClaims is an Auth
      // operation, not Firestore — they can't share a transaction.
      const claimRevokes = [];
      for (const userDoc of usersSnap.docs) {
        const userData = userDoc.data();
        const newTenantIds = (userData.tenantIds || []).filter((id) => id !== tenantId);

        // If this was their active tenant, blank it (orphan-healing path will
        // pick another one or send them through tenant-setup on next open).
        // If they have other memberships, switch active to the first remaining.
        const isActive = userData.tenantId === tenantId;
        const newActiveTenantId = isActive
          ? (newTenantIds[0] ?? null)
          : userData.tenantId;

        const userPatch = {
          tenantIds: newTenantIds,
          tenantId: newActiveTenantId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        batch.set(userDoc.ref, userPatch, { merge: true });
        batchOps += 1;

        // Delete their tenantState/{tenantId} doc if it exists.
        const stateRef = userDoc.ref.collection("tenantState").doc(tenantId);
        batch.delete(stateRef);
        batchOps += 1;

        result.usersUpdated += 1;
        result.tenantStatesDeleted += 1;

        // Queue claim revocation for users whose Auth custom claims point at
        // this deleted tenant. We skip super_admin (their claims aren't
        // tenant-scoped) and users whose role+tenantId combo doesn't match
        // this tenant (they're scoped elsewhere). Without this, the user
        // would carry a stale `role=tenant_admin, tenantId=<deleted>` claim
        // for up to 1h after delete (orphan-healing in getTenantConfig
        // eventually fixes it on next call — this just makes it instant).
        claimRevokes.push(userDoc.id);

        // Firestore batch limit is 500. Flush mid-loop if we'd cross it.
        // Each user adds 2 ops, so 400 is the safe threshold (200 users).
        if (batchOps >= 400) {
          await batch.commit();
          batch = db.batch();
          batchOps = 0;
        }
      }
      if (batchOps > 0) await batch.commit();

      // Process Auth claim revocations sequentially after the batch commits.
      // Each is wrapped in try/catch so a single Auth failure doesn't break
      // the sweep — orphan-healing will pick up stragglers on next login.
      for (const uid of claimRevokes) {
        try {
          const authRec = await admin.auth().getUser(uid);
          const claims = authRec.customClaims ?? {};
          const pointsHere =
            (claims.role === "tenant_admin" || claims.role === "tenant_collaborator") &&
            claims.tenantId === tenantId;
          if (pointsHere) {
            const { role: _r, tenantId: _t, ...keep } = claims;
            await admin.auth().setCustomUserClaims(uid, keep);
            await admin.auth().revokeRefreshTokens(uid);
          }
        } catch (revokeErr) {
          // user-not-found is fine (account deleted in parallel); log others.
          if (revokeErr?.code !== "auth/user-not-found") {
            console.warn("deleteTenant: claim revoke failed (non-fatal)", {
              uid, tenantId, error: revokeErr?.message,
            });
          }
        }
      }

      if (usersSnap.size < PAGE) break;
      lastDoc = usersSnap.docs[usersSnap.docs.length - 1];
    }

    // Also catch users still using the legacy single-tenantId field with no
    // tenantIds array (shouldn't happen post-multitenant migration but guard).
    // Paginated: an unbounded .get() on a giant users collection would blow
    // the function's memory budget and the 500-op batch limit at once.
    try {
      const LEGACY_PAGE = 400;
      let legacyLastDoc = null;
      while (true) {
        let legacyQ = db.collection("users")
          .where("tenantId", "==", tenantId)
          .orderBy("__name__")
          .limit(LEGACY_PAGE);
        if (legacyLastDoc) legacyQ = legacyQ.startAfter(legacyLastDoc);
        const legacySnap = await legacyQ.get();
        if (legacySnap.empty) break;
        const legacyBatch = db.batch();
        let ops = 0;
        for (const u of legacySnap.docs) {
          // Skip if already handled above (tenantIds array path).
          if ((u.data().tenantIds ?? []).includes(tenantId)) continue;
          legacyBatch.set(u.ref, {
            tenantId: null,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
          result.usersUpdated += 1;
          ops += 1;
        }
        if (ops > 0) await legacyBatch.commit();
        if (legacySnap.size < LEGACY_PAGE) break;
        legacyLastDoc = legacySnap.docs[legacySnap.docs.length - 1];
      }
    } catch (err) {
      result.warnings.push(`legacy users sweep failed: ${err?.message ?? err}`);
    }

    // 4b. Cascade-delete tenant subcollections. Firestore does NOT auto-delete
    // subcollections when the parent doc is deleted — leaving `team` and
    // `_backfillRuns` docs orphaned in the tree (queryable, wasting quota,
    // and leaking previous membership emails). Paginated + batched at 400.
    const tenantSubcollections = ["team", "_backfillRuns"];
    for (const subName of tenantSubcollections) {
      try {
        let subLastDoc = null;
        while (true) {
          let subQ = tenantRef.collection(subName).orderBy("__name__").limit(400);
          if (subLastDoc) subQ = subQ.startAfter(subLastDoc);
          const subSnap = await subQ.get();
          if (subSnap.empty) break;
          const subBatch = db.batch();
          subSnap.docs.forEach((d) => subBatch.delete(d.ref));
          await subBatch.commit();
          if (subSnap.size < 400) break;
          subLastDoc = subSnap.docs[subSnap.docs.length - 1];
        }
      } catch (subErr) {
        result.warnings.push(`subcollection ${subName} cleanup failed: ${subErr?.message ?? subErr}`);
      }
    }

    // 5. Delete the tenant doc itself.
    try {
      await tenantRef.delete();
      result.tenantDocDeleted = true;
    } catch (err) {
      throw new HttpsError("internal", `Tenant delete failed: ${err?.message ?? err}`);
    }

    // 6. Audit log.
    try {
      await writeActivityLog({
        type: "tenant_deleted",
        tenantId,
        tenantName,
        severity: "warning",
        requiresAction: false,
        data: {
          actor: request.auth.uid,
          slug,
          stripeSubscriptionId,
          stripeCustomerId,
          ...result,
        },
      });
    } catch (err) {
      // Audit-log failure is non-fatal — tenant is already deleted.
      console.warn("deleteTenant: audit log failed", err?.message ?? err);
    }

    console.info("deleteTenant: completed", { tenantId, ...result });
    return result;
  },
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

    // Purpose guard: this endpoint is dedicated to SaaS billing (tenant
    // paying Pushka). If a donor's recurring-donation invoice is misrouted
    // here, running the tenant-billing state machine on it would corrupt
    // billing status (e.g. mark tenant as `grace_period` because a donor's
    // card was declined). Only proceed for saas_billing subs or legacy subs
    // without a purpose tag; skip anything explicitly marked donation.
    try {
      const obj = event?.data?.object;
      let purpose = obj?.subscription_details?.metadata?.purpose
        ?? obj?.metadata?.purpose
        ?? null;
      if (!purpose && obj && (obj.object === "invoice" || obj.subscription)) {
        // Fetch subscription to inspect its metadata.purpose.
        const subId = typeof obj.subscription === "string"
          ? obj.subscription
          : obj.subscription?.id;
        if (subId) {
          try {
            const sub = await stripe.subscriptions.retrieve(subId);
            purpose = sub?.metadata?.purpose || null;
          } catch (_) { /* ignore */ }
        }
      }
      if (purpose === "donation_recurring") {
        console.info("stripeBillingWebhook: donation_recurring event skipped (wrong endpoint)", {
          eventId: event.id, type: event.type,
        });
        await finalizeWebhookEvent(eventRef, {
          status: "skipped",
          reason: "donation_recurring_wrong_endpoint",
        });
        return res.json({ received: true, skipped: "donation_recurring" });
      }
    } catch (purposeErr) {
      console.warn("stripeBillingWebhook: purpose check failed (non-fatal)", {
        eventId: event.id, err: purposeErr?.message,
      });
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
          subject: "Problema con tu pago — Chabad Pushka",
          html: `
            <p>Hola,</p>
            <p>Hubo un problema al procesar el pago de tu suscripción a Chabad Pushka.</p>
            <p>Tenés <strong>30 días</strong> para regularizar el pago antes de que el servicio sea suspendido.</p>
            <p>Por favor contactá a tu administrador o actualizá tu método de pago.</p>
            <p>— Equipo Chabad Pushka</p>
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
            <p><a href="https://chabad-admin.web.app/tenants/${tenantId}">Ver en el panel</a></p>
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
  // BUG-032 fix: every 12h instead of 24h. With a 24h cadence the worst
  // case for a tenant whose grace ended at midnight is ~24h of overrun
  // before suspension. 12h cuts that in half at negligible cost (job
  // reads a handful of docs).
  { schedule: "every 12 hours", secrets: [sendgridApiKey] },
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
            subject: "Tu servicio Chabad Pushka fue suspendido",
            html: `
              <p>Hola,</p>
              <p>Tu servicio Chabad Pushka ha sido suspendido por falta de pago.</p>
              <p>Para reactivarlo, contactá a soporte.</p>
              <p>— Equipo Chabad Pushka</p>
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
          subject: `Recordatorio: tu suscripción a Chabad Pushka vence en ${daysLeft} días`,
          html: `
            <p>Hola,</p>
            <p>Tu suscripción de <strong>${tenantName}</strong> a Chabad Pushka vence en <strong>${daysLeft} días</strong>.</p>
            <p>Por favor actualizá tu método de pago para evitar la suspensión del servicio.</p>
            <p>— Equipo Chabad Pushka</p>
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
  // GET-only. The endpoint serves a public Android App Links manifest;
  // anything else is a misuse — fail fast so we don't waste CF time.
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.set("Allow", "GET, HEAD");
    return res.status(405).send("Method Not Allowed");
  }
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
  // Manifest is stable for the keystore lifetime (years). Cache 1h at
  // edges/clients to cut bandwidth + CF invocations from verifier polls.
  res.set("Cache-Control", "public, max-age=3600, s-maxage=3600");
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
    // Round-6 audit LOW fix: rate limit — spam of writes from a compromised
    // super_admin could burn Firestore quota.
    await enforceRateLimit(request.auth.uid, "resolveActivityItem", 200, 3600);

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

// ---------------------------------------------------------------------------
// getDonationReasonStats — admin analytics: which donation destinations
// (designaciones) get the most love in a given period. Sums in USD using
// the same frozen-snapshot / fallback chain as getAdminStats so results
// are FX-stable across multi-currency tenants. Tenant members are scoped
// to their own tenant; super_admin can pass tenantId or read aggregate.
// ---------------------------------------------------------------------------
exports.getDonationReasonStats = onCall(
  { enforceAppCheck: false },
  async (request) => {
    const callerUid = request.auth?.uid;
    if (!callerUid) throw new HttpsError("unauthenticated", "Debes estar autenticado.");
    await enforceRateLimit(callerUid, "getDonationReasonStats", 60, 3600);

    const callerClaims = request.auth?.token ?? {};
    const isSuper = callerIsSuperAdmin(request);
    const isTenantMember = callerClaims.role === "tenant_admin" ||
      callerClaims.role === "tenant_collaborator";
    if (!isSuper && !isTenantMember) {
      throw new HttpsError("permission-denied", "Solo administradores.");
    }

    // Tenant member always scoped to their own tenant; super_admin may pass
    // tenantId or null (null = aggregate across all tenants).
    const filterTenantId = isTenantMember
      ? callerClaims.tenantId
      : (request.data?.tenantId ?? null);

    const period = String(request.data?.period ?? "1m");
    const now = new Date();
    let since = null;
    switch (period) {
      case "1m":
        since = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, now.getUTCDate()));
        break;
      case "3m":
        since = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 3, now.getUTCDate()));
        break;
      case "6m":
        since = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 6, now.getUTCDate()));
        break;
      case "1y":
        since = new Date(Date.UTC(now.getUTCFullYear() - 1, now.getUTCMonth(), now.getUTCDate()));
        break;
      case "all":
        since = null;
        break;
      default:
        throw new HttpsError("invalid-argument",
            "period debe ser uno de: 1m, 3m, 6m, 1y, all.");
    }

    const rates = await getExchangeRates(null);
    const mxnRate = rates["MXN"] ?? 17.1;

    // Same composite-index pattern as getAdminStats: (tenantId + createdAt)
    // when scoped, plain createdAt otherwise.
    let txQuery = db.collectionGroup("transactions");
    if (since) {
      txQuery = txQuery.where("createdAt", ">=",
          admin.firestore.Timestamp.fromDate(since));
    }
    if (filterTenantId) {
      txQuery = txQuery.where("tenantId", "==", filterTenantId);
    }
    const TX_HARD_CAP = 50000;
    const txSnap = await txQuery.limit(TX_HARD_CAP).get();
    if (txSnap.size >= TX_HARD_CAP) {
      console.warn(`getDonationReasonStats: hit TX_HARD_CAP=${TX_HARD_CAP} ` +
        `for tenant=${filterTenantId ?? "all"} period=${period} — ` +
        `totals truncated; migrate to pre-aggregated counters.`);
    }

    // For tenant scope, also gate by user docs that belong to the tenant —
    // catches grandfathered transactions written before the tenantId field
    // was stamped (BUG-014 legacy data). Without this they'd be excluded
    // from the where("tenantId", "==") query above; with the user-side
    // gate we recover them via the uid path.
    // Bounded read: cap at 500 users. A giant tenant would previously OOM
    // the function here. If we ever hit the cap the aggregation may miss
    // some legacy uids — warn so ops can migrate to backfilling tenantId.
    // TODO(future): drop this whole gate once BUG-014 backfill runs in prod.
    let tenantUserIds = null;
    if (filterTenantId) {
      const REASON_USER_CAP = 500;
      const usersSnap = await db.collection("users")
        .where("tenantId", "==", filterTenantId)
        .limit(REASON_USER_CAP)
        .get();
      tenantUserIds = new Set(usersSnap.docs.map((d) => d.id));
      if (usersSnap.size >= REASON_USER_CAP) {
        console.warn(
          `getDonationReasonStats: hit REASON_USER_CAP=${REASON_USER_CAP} ` +
          `for tenant=${filterTenantId} — legacy-uid gate may miss users; ` +
          `backfill tenantId on legacy transactions to drop this fallback.`
        );
      }
    }

    const byReason = {};
    let grandTotal = 0;
    let grandCount = 0;

    for (const txDoc of txSnap.docs) {
      const tx = txDoc.data();
      const uid = txDoc.ref.parent.parent?.id;
      if (!uid) continue;
      // Only count actual donations (tzedaka + pushkaEmpty are both donor
      // money). Skip 'manual' (admin adjustments), 'refund', etc.
      if (tx.type && tx.type !== "tzedaka" && tx.type !== "pushkaEmpty") continue;
      // Skip in-flight / failed transactions — only completed should count.
      if (tx.status && tx.status !== "completed") continue;
      if (tenantUserIds && !tenantUserIds.has(uid)) continue;

      const txCurrency = String(tx.currencyCode || "USD").toUpperCase();
      let amountUSD;
      if (tx.amountUSD != null) {
        amountUSD = tx.amountUSD;
      } else if (tx.amountMXN != null) {
        amountUSD = tx.amountMXN / mxnRate;
      } else {
        const txRate = rates[txCurrency] ?? 1;
        amountUSD = (tx.amount ?? 0) / txRate;
      }

      const reason = (tx.donationReason &&
          String(tx.donationReason).trim().length > 0)
        ? String(tx.donationReason).trim()
        : "Sin designación";

      if (!byReason[reason]) {
        byReason[reason] = { reason, totalUSD: 0, count: 0 };
      }
      byReason[reason].totalUSD += amountUSD;
      byReason[reason].count += 1;

      grandTotal += amountUSD;
      grandCount += 1;
    }

    const reasons = Object.values(byReason)
      .map((r) => ({
        reason: r.reason,
        totalUSD: Math.round(r.totalUSD * 100) / 100,
        count: r.count,
        percentage: grandTotal > 0
          ? Math.round((r.totalUSD / grandTotal) * 1000) / 10
          : 0,
      }))
      .sort((a, b) => b.totalUSD - a.totalUSD);

    return {
      reasons,
      grandTotalUSD: Math.round(grandTotal * 100) / 100,
      grandCount,
      period,
      truncated: txSnap.size >= TX_HARD_CAP,
    };
  }
);

// ---------------------------------------------------------------------------
// createCheckoutSession — Stripe Checkout redirect flow para PWA / web.
// Reemplaza el Payment Sheet nativo (flutter_stripe) que no soporta web.
// Devuelve una URL de Stripe Checkout que el cliente carga con
// window.location = url. Stripe maneja Apple Pay web, 3DS/SCA, y toda la
// PSD2 compliance automáticamente. Callback: success_url + cancel_url
// vuelven al app.pushkapp.cc / app.pushkapp.cc/cancel.
// ---------------------------------------------------------------------------
exports.createCheckoutSession = onCall(
  { secrets: [stripeSecret], enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
    }
    await enforceRateLimit(request.auth.uid, "createCheckoutSession", 10, 600);
    if (!stripeSecret.value()) {
      throw new HttpsError("failed-precondition", "Stripe no configurado.");
    }

    // Purpose: accept both 'donation' (Donate button) AND 'pushka_empty'
    // (Empty Pushka button on the classic flow). On mobile PaymentSheet
    // pushka_empty uses a Firestore lock to prevent double-empty races
    // between manual + scheduled auto-empty; on web Checkout the whole
    // page navigates away so there's no equivalent race — the Stripe
    // Checkout Session itself is idempotent. Stamp the purpose in the
    // PI metadata so the webhook applies pushka reset logic when needed.
    const purpose = String(request.data?.purpose || "donation").toLowerCase();
    if (purpose !== "donation" && purpose !== "pushka_empty") {
      throw new HttpsError("invalid-argument", "Propósito de pago inválido.");
    }

    // Auth + blocked + tenant lookup (mismo patrón que createPaymentIntent).
    const [adminDataSnap, userSnap] = await Promise.all([
      db.collection("adminData").doc(request.auth.uid).get(),
      db.collection("users").doc(request.auth.uid).get(),
    ]);
    if (adminDataSnap.exists && adminDataSnap.data()?.isBlocked === true) {
      throw new HttpsError("permission-denied", "Tu cuenta está temporalmente suspendida.");
    }
    const userData = userSnap.exists ? (userSnap.data() ?? {}) : {};
    const tenantId = userData.tenantId ?? null;
    if (!tenantId) {
      throw new HttpsError("failed-precondition", "Para donar necesitás unirte a una organización primero.");
    }

    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) {
      throw new HttpsError("failed-precondition", "Esta organización no existe o no está disponible.");
    }
    const tenantData = tenantSnap.data() ?? {};
    if (tenantData.status !== "active" && tenantData.status !== "trial") {
      throw new HttpsError("failed-precondition", "Esta organización no está aceptando donaciones.");
    }
    const tenantConnectAccountId = tenantData.stripeConnectAccountId || null;
    if (!tenantConnectAccountId || tenantData.stripeConnectStatus !== "active") {
      throw new HttpsError("failed-precondition", "La organización no tiene pagos configurados.");
    }
    const tenantCommissionRate = safeTenantCommissionRate(tenantData.commissionRate, tenantId);

    // Amount + currency validation con los mismos caps que createPaymentIntent.
    const amount = Number(request.data?.amount || 0);
    const currency = validateCurrency(request.data?.currency || "usd");
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new HttpsError("invalid-argument", "Monto inválido.");
    }
    const minForCurrency = minAmountForCurrency(currency);
    if (amount < minForCurrency) {
      throw new HttpsError("invalid-argument", `Monto mínimo: ${minForCurrency} (unidad menor de ${currency.toUpperCase()}).`);
    }
    const maxForCurrency = maxAmountForCurrency(currency);
    if (amount > maxForCurrency) {
      console.warn("createCheckoutSession: amount exceeds per-currency cap", {
        uid: request.auth.uid, tenantId, currency, amount, maxForCurrency,
      });
      throw new HttpsError("invalid-argument", `El monto excede el máximo permitido por transacción (${currency.toUpperCase()}).`);
    }

    // Optional metadata — donor message + designation.
    const donorMessage = sanitizeDonorMessage(request.data?.donorMessage);
    const donationReasonRaw = request.data?.donationReason;
    const donationReason = (typeof donationReasonRaw === "string" &&
        donationReasonRaw.trim().length > 0)
      // eslint-disable-next-line no-control-regex
      ? donationReasonRaw.replace(/[\x00-\x1F\x7F-\x9F]/g, " ").trim().slice(0, 80)
      : null;

    // Correlation ID para tracing end-to-end (client → CF → Stripe → webhook).
    const rawCid = request.data?.correlationId;
    const cidRegex = /^[a-f0-9]{16}$/i;
    const correlationId = (typeof rawCid === "string" && cidRegex.test(rawCid))
      ? rawCid.toLowerCase()
      : require("crypto").randomBytes(8).toString("hex");

    // Success / cancel URLs — el cliente PWA los provee; caemos a defaults
    // seguros si vienen malformed o vacíos. Solo aceptamos HTTPS Y un origin
    // en la lista blanca (previene open redirect a hosts arbitrarios que
    // podrían capturar el session_id via referer + phishing UI).
    //
    // Sin este chequeo, un atacante que engañe al cliente para pasar
    // successUrl=https://evil.com/steal?sid={CHECKOUT_SESSION_ID} podría
    // interceptar el ID de la sesión (aunque no el cargo — Stripe ya
    // capturó los fondos). Igual: mejor cerrar el vector.
    const ALLOWED_REDIRECT_ORIGINS = new Set([
      "https://pushka-pwa.web.app",
      "https://pushka-app-ioel.web.app",
      "https://pushka-app-ioel-test.web.app",
      "https://pushkapp.cc",
      "https://www.pushkapp.cc",
      "https://app.pushkapp.cc",
    ]);
    function _isAllowedRedirect(u) {
      if (typeof u !== "string" || !u.startsWith("https://")) return false;
      try {
        const parsed = new URL(u);
        return ALLOWED_REDIRECT_ORIGINS.has(`${parsed.protocol}//${parsed.host}`);
      } catch (_) {
        return false;
      }
    }
    const rawSuccessUrl = String(request.data?.successUrl || "").trim();
    const rawCancelUrl = String(request.data?.cancelUrl || "").trim();
    const defaultSuccessUrl = "https://pushka-pwa.web.app/donation-success?session_id={CHECKOUT_SESSION_ID}";
    const defaultCancelUrl = "https://pushka-pwa.web.app/donation-cancel";
    const successUrl = _isAllowedRedirect(rawSuccessUrl) ? rawSuccessUrl : defaultSuccessUrl;
    const cancelUrl = _isAllowedRedirect(rawCancelUrl) ? rawCancelUrl : defaultCancelUrl;

    const stripe = require("stripe")(stripeSecret.value(), { timeout: 15000 });
    const customerEmail = request.auth.token?.email
      ? String(request.auth.token.email).slice(0, 254)
      : null;
    const stripeReqOpts = { stripeAccount: tenantConnectAccountId };

    // Direct Charges: customer lives per connected account. Get-or-create
    // on the tenantState scope, calling Stripe with the connected header.
    const tenantStateRef = db.collection("users").doc(request.auth.uid)
      .collection("tenantState").doc(tenantId);
    const tenantStateSnap = await tenantStateRef.get();
    let customerId = String(tenantStateSnap.data()?.stripeConnectCustomerId || "").trim() || null;
    if (!customerId && customerEmail) {
      try {
        const customer = await stripe.customers.create({
          email: customerEmail,
          metadata: { uid: request.auth.uid, tenantId },
        }, {
          idempotencyKey: `customer_create_${request.auth.uid}_${tenantId}`,
          stripeAccount: tenantConnectAccountId,
        });
        customerId = customer.id;
        await tenantStateRef.set({
          stripeConnectCustomerId: customerId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (err) {
        console.warn("createCheckoutSession: connect customer.create failed", {
          uid: request.auth.uid, tenantId, cid: correlationId, errorMessage: err?.message,
        });
      }
    }

    // Direct Charges: no transfer_data / on_behalf_of. Charge is on the
    // connected account (via Stripe-Account header on sessions.create).
    // application_fee_amount still valid — skims platform commission.
    const paymentIntentData = {
      metadata: {
        uid: request.auth.uid,
        tenantId,
        // connectAccountId lets the webhook detect Connect drift (donation
        // routed to an account that was disconnected between session
        // creation and confirmation). Mirrors what createPaymentIntent
        // stamps — without it the webhook's drift-detection check silently
        // no-ops for Checkout-originated donations.
        connectAccountId: tenantConnectAccountId,
        purpose,
        correlationId,
        ...(donationReason ? { donationReason } : {}),
        ...(donorMessage ? { donorMessage } : {}),
      },
    };
    {
      const appFee = computeApplicationFeeAmount(amount, tenantCommissionRate);
      if (appFee) {
        if (appFee.clamped) {
          console.warn("createCheckoutSession: clamped_app_fee", {
            uid: request.auth.uid, tenantId, amount, tenantCommissionRate,
            rawFee: appFee.rawFee, safeFee: appFee.fee,
          });
        }
        paymentIntentData.application_fee_amount = appFee.fee;
      }
    }

    const idempotencyKey = `cs_${request.auth.uid}_${correlationId}`;
    const productName = purpose === "donation"
      ? `Donación a ${tenantData.appName || tenantData.name || "Colel Chabad"}`
      : "Pago";

    try {
      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        line_items: [
          {
            price_data: {
              currency,
              unit_amount: amount,
              product_data: {
                name: productName,
                ...(donationReason ? { description: `Designación: ${donationReason}` } : {}),
              },
            },
            quantity: 1,
          },
        ],
        payment_intent_data: paymentIntentData,
        success_url: successUrl,
        cancel_url: cancelUrl,
        ...(customerId ? { customer: customerId } : { customer_email: customerEmail || undefined }),
        metadata: {
          uid: request.auth.uid,
          tenantId,
          purpose,
          correlationId,
        },
        locale: "es",
      }, { idempotencyKey, stripeAccount: tenantConnectAccountId });

      console.info("createCheckoutSession: created", {
        uid: request.auth.uid, tenantId, cid: correlationId,
        amount, currency, sessionId: session.id,
      });

      return {
        url: session.url,
        sessionId: session.id,
        correlationId,
      };
    } catch (err) {
      console.error("createCheckoutSession: stripe.checkout.sessions.create failed", {
        uid: request.auth.uid, tenantId, cid: correlationId,
        errorMessage: err?.message, errorType: err?.type,
      });
      throw new HttpsError("internal", "No se pudo crear la sesión de pago. Intentá de nuevo.");
    }
  }
);

// ---------------------------------------------------------------------------
// sendWeeklySummary — scheduled Monday 08:00 ART "heartbeat" email to
// super_admin covering the last 7 days across every tenant. The point is
// not deep analytics (getAdminStats already does that on demand) — it's
// PROACTIVE anomaly detection: if this email stops arriving, or the
// numbers look wrong, Ioel knows within 7 days that something is broken
// (SendGrid dead, donations not landing, chargebacks piling up). Without
// this, weeks could go by silently before launch monitoring kicks in.
//
// Delivery success is itself the healthcheck — SendGrid working, Firestore
// readable, function runtime healthy. Every aggregation query is wrapped
// in .catch() so a single broken query (e.g. missing composite index)
// zeros out that section instead of nuking the whole email. Fire-and-forget
// on the sendEmail failure path: we swallow + log so the scheduler doesn't
// retry and flood the inbox on a transient SendGrid blip.
// ---------------------------------------------------------------------------
exports.sendWeeklySummary = onSchedule(
  {
    schedule: "every monday 08:00",
    timeZone: "America/Argentina/Buenos_Aires",
    region: "us-central1",
    secrets: [sendgridApiKey],
    timeoutSeconds: 300,
  },
  async () => {
    const now = new Date();
    const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
    const sinceTs = admin.firestore.Timestamp.fromDate(sevenDaysAgo);

    const fmtDay = (d) => d.toISOString().slice(0, 10);
    const startDate = fmtDay(sevenDaysAgo);
    const endDate = fmtDay(now);

    // Live FX rates for USD conversion of any legacy tx docs missing the
    // frozen amountUSD snapshot. If the rate provider itself is down we
    // just fall back to an empty map — non-USD legacy rows silently
    // contribute 0 USD in that (rare) case, which is preferable to
    // failing the whole email.
    const rates = await getExchangeRates(null).catch((err) => {
      console.warn("sendWeeklySummary: getExchangeRates failed, using empty map", {
        err: err?.message,
      });
      return {};
    });

    // --- Donations (transactions in the last 7d) ------------------------
    // collectionGroup scan same as getAdminStats. 20k cap is generous for a
    // pre-launch app; if we ever cross it we'd want per-tenant aggregation
    // via pre-computed counters instead of a live scan.
    const TX_HARD_CAP = 20000;
    const txSnap = await db.collectionGroup("transactions")
      .where("createdAt", ">=", sinceTs)
      .limit(TX_HARD_CAP)
      .get()
      .catch((err) => {
        console.error("sendWeeklySummary: transactions query failed", {
          err: err?.message,
        });
        return { docs: [], size: 0 };
      });
    if (txSnap.size >= TX_HARD_CAP) {
      console.warn("sendWeeklySummary: hit TX_HARD_CAP — totals truncated", {
        cap: TX_HARD_CAP,
      });
    }

    let donationCount = 0;
    let donationUSD = 0;
    const perCurrencyOriginal = {};
    const tenantRevenue = {}; // tenantId -> { usd, count, name }

    for (const txDoc of (txSnap.docs || [])) {
      const tx = txDoc.data() || {};
      // Only completed donation-type txs — mirrors getDonationReasonStats.
      if (tx.type && tx.type !== "tzedaka" && tx.type !== "pushkaEmpty") continue;
      if (tx.status && tx.status !== "completed") continue;

      const currency = String(tx.currencyCode || "USD").toUpperCase();
      let amountUSD;
      if (tx.amountUSD != null) {
        amountUSD = Number(tx.amountUSD);
      } else {
        const rate = rates[currency];
        amountUSD = (rate && rate > 0) ? (Number(tx.amount) || 0) / rate : 0;
      }
      if (!Number.isFinite(amountUSD)) amountUSD = 0;

      donationCount += 1;
      donationUSD += amountUSD;

      const origAmount = Number(tx.amount) || 0;
      perCurrencyOriginal[currency] = (perCurrencyOriginal[currency] || 0) + origAmount;

      const tenantId = tx.tenantId || null;
      if (tenantId) {
        if (!tenantRevenue[tenantId]) tenantRevenue[tenantId] = { usd: 0, count: 0, name: null };
        tenantRevenue[tenantId].usd += amountUSD;
        tenantRevenue[tenantId].count += 1;
      }
    }

    // --- New users (last 7d) --------------------------------------------
    // Requires a users.createdAt ASC index. If missing, we log + zero out.
    const newUsersSnap = await db.collection("users")
      .where("createdAt", ">=", sinceTs)
      .limit(5000)
      .get()
      .catch((err) => {
        console.warn("sendWeeklySummary: new users query failed (missing index?)", {
          err: err?.message,
        });
        return { size: 0 };
      });
    const newUsersCount = newUsersSnap.size || 0;

    // --- Failed payment intents (last 7d) -------------------------------
    // Needs composite index (type ASC, createdAt ASC) on _stripeWebhookEvents.
    const failedSnap = await db.collection("_stripeWebhookEvents")
      .where("type", "==", "payment_intent.payment_failed")
      .where("createdAt", ">=", sinceTs)
      .limit(5000)
      .get()
      .catch((err) => {
        console.warn("sendWeeklySummary: failed PIs query failed (missing index?)", {
          err: err?.message,
        });
        return { size: 0 };
      });
    const failedCount = failedSnap.size || 0;

    // --- Chargebacks (last 7d) ------------------------------------------
    const chargebackSnap = await db.collection("_stripeWebhookEvents")
      .where("type", "==", "charge.dispute.created")
      .where("createdAt", ">=", sinceTs)
      .limit(1000)
      .get()
      .catch((err) => {
        console.warn("sendWeeklySummary: chargebacks query failed (missing index?)", {
          err: err?.message,
        });
        return { size: 0 };
      });
    const chargebackCount = chargebackSnap.size || 0;

    // --- Active tenants + name lookup for top-3 -------------------------
    const activeTenantsSnap = await db.collection("tenants")
      .where("status", "==", "active")
      .get()
      .catch((err) => {
        console.warn("sendWeeklySummary: active tenants query failed", {
          err: err?.message,
        });
        return { docs: [] };
      });
    const activeTenantsDocs = activeTenantsSnap.docs || [];
    const activeTenantsCount = activeTenantsDocs.length;
    const tenantNameById = {};
    for (const d of activeTenantsDocs) {
      const data = d.data() || {};
      tenantNameById[d.id] = data.name || data.appName || d.id;
    }
    // Backfill names for tenants that got donations but aren't in the active
    // set (suspended / trial / recently canceled). Cheap: bounded by top-N
    // candidates; we cap the lookup to keep runtime predictable.
    const missingNameTenantIds = Object.keys(tenantRevenue)
      .filter((tid) => !tenantNameById[tid])
      .slice(0, 20);
    for (const tid of missingNameTenantIds) {
      const s = await db.collection("tenants").doc(tid).get().catch(() => null);
      const data = s?.data?.() || {};
      tenantNameById[tid] = data.name || data.appName || tid;
    }

    // --- Unresolved activity items requiring action ---------------------
    // Needs composite index (requiresAction ASC, resolved ASC) on _activityLog.
    const activitySnap = await db.collection("_activityLog")
      .where("requiresAction", "==", true)
      .where("resolved", "==", false)
      .limit(500)
      .get()
      .catch((err) => {
        console.warn("sendWeeklySummary: activityLog query failed (missing index?)", {
          err: err?.message,
        });
        return { size: 0 };
      });
    const unresolvedActivityCount = activitySnap.size || 0;

    // --- Top 3 tenants by weekly revenue --------------------------------
    const topTenants = Object.entries(tenantRevenue)
      .map(([tid, v]) => ({
        tenantId: tid,
        name: tenantNameById[tid] || tid,
        usd: v.usd,
        count: v.count,
      }))
      .sort((a, b) => b.usd - a.usd)
      .slice(0, 3);

    // --- Red flags ------------------------------------------------------
    // "Attempted" = completed donations + failed PIs. Not perfectly precise
    // (a single PI can fail then succeed and be double-counted) but the
    // signal is directional: sharp jumps are what we care about.
    const attemptedPayments = donationCount + failedCount;
    const failRate = attemptedPayments > 0 ? failedCount / attemptedPayments : 0;
    const redFlags = [];
    if (failRate > 0.05) {
      redFlags.push(`Tasa de fallo de pagos ${(failRate * 100).toFixed(1)}% (umbral 5%).`);
    }
    if (chargebackCount > 0) {
      redFlags.push(`${chargebackCount} chargeback${chargebackCount === 1 ? "" : "s"} en la semana — revisar disputas en Stripe.`);
    }
    if (unresolvedActivityCount > 5) {
      redFlags.push(`${unresolvedActivityCount} alertas del activityLog sin resolver (umbral 5).`);
    }
    const alertCount = redFlags.length;

    // --- HTML build -----------------------------------------------------
    const fmtUSD = (n) => `$${(Number(n) || 0).toLocaleString("en-US", {
      minimumFractionDigits: 2, maximumFractionDigits: 2,
    })}`;
    const fmtInt = (n) => (Number(n) || 0).toLocaleString("en-US");

    const ACCENT = "#2563EB";
    const S = {
      wrap: "font-family: -apple-system, Segoe UI, Roboto, sans-serif; color: #111; max-width: 640px; margin: 0 auto; padding: 24px;",
      h1: `color: ${ACCENT}; font-size: 22px; margin: 0 0 4px 0;`,
      sub: "color: #666; font-size: 13px; margin: 0 0 24px 0;",
      section: `margin: 20px 0; padding: 16px; background: #F8FAFC; border-left: 4px solid ${ACCENT}; border-radius: 4px;`,
      h2: "font-size: 14px; text-transform: uppercase; letter-spacing: 0.5px; color: #334155; margin: 0 0 12px 0;",
      row: "display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #E2E8F0; font-size: 14px;",
      num: "font-family: SF Mono, Menlo, Consolas, monospace; font-weight: 600;",
      red: "margin: 20px 0; padding: 16px; background: #FEF2F2; border-left: 4px solid #DC2626; border-radius: 4px; color: #7F1D1D;",
      redH2: "font-size: 14px; text-transform: uppercase; letter-spacing: 0.5px; color: #991B1B; margin: 0 0 12px 0;",
      footer: "margin-top: 32px; padding-top: 16px; border-top: 1px solid #E2E8F0; color: #94A3B8; font-size: 12px; line-height: 1.5;",
    };

    const perCurrencyRows = Object.entries(perCurrencyOriginal)
      .sort((a, b) => b[1] - a[1])
      .map(([cur, amt]) =>
        `<div style="${S.row}"><span>${_escapeHtmlForEmail(cur)}</span><span style="${S.num}">${fmtInt(Math.round(amt))}</span></div>`
      ).join("") || `<div style="${S.row}"><span>(sin donaciones)</span><span style="${S.num}">0</span></div>`;

    const topTenantsRows = topTenants.length > 0
      ? topTenants.map((t, i) =>
          `<div style="${S.row}"><span>${i + 1}. ${_escapeHtmlForEmail(t.name)} <span style="color:#94A3B8">(${fmtInt(t.count)} donaciones)</span></span><span style="${S.num}">${fmtUSD(t.usd)}</span></div>`
        ).join("")
      : `<div style="${S.row}"><span>(sin actividad)</span><span style="${S.num}">—</span></div>`;

    const redFlagBlock = redFlags.length > 0
      ? `<div style="${S.red}">
           <div style="${S.redH2}">Se&ntilde;ales de alarma (${redFlags.length})</div>
           <ul style="margin:0; padding-left: 20px;">
             ${redFlags.map((f) => `<li style="margin:4px 0;">${_escapeHtmlForEmail(f)}</li>`).join("")}
           </ul>
         </div>`
      : "";

    const html = `
      <div style="${S.wrap}">
        <h1 style="${S.h1}">Pushka &mdash; Resumen Semanal</h1>
        <p style="${S.sub}">Del ${startDate} al ${endDate}</p>

        ${redFlagBlock}

        <div style="${S.section}">
          <div style="${S.h2}">Donaciones</div>
          <div style="${S.row}"><span>Total (USD equivalente)</span><span style="${S.num}">${fmtUSD(donationUSD)}</span></div>
          <div style="${S.row}"><span>Cantidad</span><span style="${S.num}">${fmtInt(donationCount)}</span></div>
          <div style="${S.row}"><span>Promedio por donaci&oacute;n</span><span style="${S.num}">${fmtUSD(donationCount > 0 ? donationUSD / donationCount : 0)}</span></div>
        </div>

        <div style="${S.section}">
          <div style="${S.h2}">Por moneda (importe original)</div>
          ${perCurrencyRows}
        </div>

        <div style="${S.section}">
          <div style="${S.h2}">Top 3 organizaciones (semana)</div>
          ${topTenantsRows}
        </div>

        <div style="${S.section}">
          <div style="${S.h2}">Plataforma</div>
          <div style="${S.row}"><span>Nuevos usuarios</span><span style="${S.num}">${fmtInt(newUsersCount)}</span></div>
          <div style="${S.row}"><span>Organizaciones activas</span><span style="${S.num}">${fmtInt(activeTenantsCount)}</span></div>
          <div style="${S.row}"><span>Pagos fallidos (payment_intent.payment_failed)</span><span style="${S.num}">${fmtInt(failedCount)}</span></div>
          <div style="${S.row}"><span>Tasa de fallo</span><span style="${S.num}">${(failRate * 100).toFixed(2)}%</span></div>
          <div style="${S.row}"><span>Chargebacks</span><span style="${S.num}">${fmtInt(chargebackCount)}</span></div>
          <div style="${S.row}"><span>Alertas sin resolver (activityLog)</span><span style="${S.num}">${fmtInt(unresolvedActivityCount)}</span></div>
        </div>

        <div style="${S.footer}">
          Este resumen se env&iacute;a todos los lunes 08:00 ART autom&aacute;ticamente.<br>
          Si dej&aacute;s de recibirlo, algo puede estar roto (SendGrid, esta CF, o el scheduler de Cloud Functions).
        </div>
      </div>
    `;

    const subject = `[Pushka Weekly] ${startDate} - ${endDate}: ${fmtInt(donationCount)} donaciones, ${alertCount} alertas`;

    try {
      await sendEmail({ to: SUPER_ADMIN_EMAIL, subject, html });
      console.info("sendWeeklySummary: sent", {
        to: _redactEmail(SUPER_ADMIN_EMAIL),
        donationCount,
        donationUSD: Math.round(donationUSD * 100) / 100,
        newUsersCount, failedCount, chargebackCount, activeTenantsCount,
        unresolvedActivityCount, alertCount,
        failRate: Number(failRate.toFixed(4)),
        redFlags,
      });
    } catch (err) {
      // Fire-and-forget: log but don't throw so the scheduler doesn't retry
      // and flood the inbox on a transient SendGrid glitch.
      console.error("sendWeeklySummary: sendEmail threw (non-fatal)", {
        err: err?.message,
      });
    }
  }
);

// Local HTML escaper for the weekly summary email — tenant names, activity
// descriptions, and currency codes can contain user-controlled text and this
// email is rendered as HTML in the super_admin inbox. Kept private to this
// section (prefix `_`) so it doesn't collide with any escaper added
// elsewhere later. Function declaration = hoisted, so the caller above is fine.
function _escapeHtmlForEmail(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ---------------------------------------------------------------------------
// health — public liveness probe for external uptime monitors.
// ---------------------------------------------------------------------------
// Read by UptimeRobot / GCP Monitoring uptime check every 5 min. No auth
// so the monitor can hit it without credentials.
//
// DoS-hardened (round 6 audit):
//  - maxInstances=3 caps concurrent CF invocations
//  - Stripe probe result cached 60s in module memory — a burst of requests
//    only hits Stripe once per minute per warm instance. Attacker/crawler
//    can no longer exhaust the platform's 100 req/s Stripe limit.
//  - Firestore probe is cheap ($0.06 per 100k reads) and self-scoped
//    to a single doc; no cache needed but still bounded by maxInstances.
//
// TODO(ops): create _health/probe doc in Firestore once — missing doc is
// still a valid read (returns empty snapshot), so this is optional; the
// doc lets you attach ops metadata (last verified, etc.).
let _stripeHealthCache = null; // { status, message, at }
const STRIPE_HEALTH_TTL_MS = 60_000;

exports.health = onRequest(
  {
    secrets: [stripeSecret],
    region: "us-central1",
    cors: false,
    memory: "256MiB",
    timeoutSeconds: 15,
    maxInstances: 3,
    concurrency: 40,
  },
  async (req, res) => {
    if (req.method !== "GET") {
      res.status(405).json({ error: "GET only" });
      return;
    }

    const started = Date.now();
    const result = {
      status: "ok",
      timestamp: new Date().toISOString(),
      firestore: "unknown",
      stripe: "unknown",
      stripeCached: false,
      latencyMs: 0,
    };

    // Firestore probe (cheap, direct).
    try {
      await db.collection("_health").doc("probe").get();
      result.firestore = "ok";
    } catch (e) {
      result.firestore = "error";
      result.status = "degraded";
      console.error("health: firestore probe failed", { message: e?.message });
    }

    // Stripe probe: cached 60s to prevent DoS on the Stripe API quota.
    const now = Date.now();
    if (_stripeHealthCache && now - _stripeHealthCache.at < STRIPE_HEALTH_TTL_MS) {
      result.stripe = _stripeHealthCache.status;
      result.stripeCached = true;
      if (_stripeHealthCache.status !== "ok") {
        result.status = "degraded";
      }
    } else {
      try {
        const stripe = require("stripe")(stripeSecret.value(), { timeout: 5000 });
        await stripe.balance.retrieve();
        result.stripe = "ok";
        _stripeHealthCache = { status: "ok", message: null, at: now };
      } catch (e) {
        result.stripe = "error";
        result.status = "degraded";
        _stripeHealthCache = { status: "error", message: e?.message || null, at: now };
        console.error("health: stripe probe failed", { message: e?.message });
      }
    }

    result.latencyMs = Date.now() - started;
    res.status(result.status === "ok" ? 200 : 503).json(result);
  }
);

// ---------------------------------------------------------------------------
// cleanupLegacyOAuthFields — one-shot sweep of stale tenant-doc OAuth state.
// ---------------------------------------------------------------------------
// Legacy tenants may still have stripeConnectOAuthState and
// stripeConnectOAuthStateCreatedAt fields on their tenant doc. These were
// moved to _stripeConnectOAuth/{token} in the OAuth harden pass, so the
// tenant-doc fields are inert (nothing reads them) but represent residual
// state. This function sweeps and removes them.
//
// Super_admin only. Idempotent. Safe to re-run.
exports.cleanupLegacyOAuthFields = onCall(
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Auth required.");
    if (!(await callerIsSuperAdminFresh(request))) {
      throw new HttpsError("permission-denied", "super_admin only.");
    }

    let scanned = 0;
    let cleaned = 0;
    const BATCH = 100;
    let lastDoc = null;
    while (true) {
      let q = db.collection("tenants").orderBy("__name__").limit(BATCH);
      if (lastDoc) q = q.startAfter(lastDoc);
      const snap = await q.get();
      if (snap.empty) break;
      const batch = db.batch();
      let batchWrites = 0;
      for (const doc of snap.docs) {
        scanned += 1;
        const data = doc.data();
        if ("stripeConnectOAuthState" in data || "stripeConnectOAuthStateCreatedAt" in data) {
          batch.update(doc.ref, {
            stripeConnectOAuthState: admin.firestore.FieldValue.delete(),
            stripeConnectOAuthStateCreatedAt: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          batchWrites += 1;
          cleaned += 1;
        }
      }
      if (batchWrites > 0) await batch.commit();
      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.size < BATCH) break;
    }

    return { scanned, cleaned };
  }
);

// ---------------------------------------------------------------------------
// onUserDocCreated — auto-apply pending tenant admin invitations
// ---------------------------------------------------------------------------
// Before this trigger existed, an invited tenant_admin who opened the
// Flutter mobile app FIRST (before the admin web) never had their
// invitation applied: the app doesn't call claimPendingTenantAdmin, and
// setAdminClaim only queued a `_pendingTenantAdmins/{email}` doc that
// waited for a web sign-in. Same problem for tenant_collaborators.
//
// This trigger fires when any users/{uid} doc is created (Flutter and
// admin web both create these on first sign-in), looks up the caller's
// email in `_pendingTenantAdmins`, and applies the claim + team membership
// automatically — regardless of which client the invitee hits first.
//
// Safety mirrors claimPendingTenantAdmin:
//   - Refuses to apply if the email isn't verified (a password-provider
//     signup with someone else's email would otherwise steal the invitation).
//   - Checks pending doc TTL; deletes expired docs.
//   - Refuses if the tenant no longer exists.
//   - Preserves any pre-existing customClaims via spread — never wipes them.
//   - Idempotent: no pending doc → no-op.
exports.onUserDocCreated = onDocumentCreated(
  "users/{uid}",
  async (event) => {
    const uid = event.params.uid;
    if (!uid) return;

    let userRecord;
    try {
      userRecord = await admin.auth().getUser(uid);
    } catch (e) {
      console.warn("onUserDocCreated: getUser failed", { uid, error: e?.message });
      return;
    }

    if (!userRecord?.emailVerified) {
      // Skip silently — user will call claimPendingTenantAdmin explicitly
      // after verifying their email, or the trigger will effectively be
      // superseded by that call.
      return;
    }

    const email = String(userRecord.email || "").toLowerCase().trim();
    if (!email) return;

    const pendingRef = db.collection("_pendingTenantAdmins").doc(email);
    const pendingSnap = await pendingRef.get();
    if (!pendingSnap.exists) return;

    const pending = pendingSnap.data() || {};
    const role = pending.role;
    const tenantId = pending.tenantId;

    const expiresAtMs = pending.expiresAt?.toMillis?.() ?? null;
    if (expiresAtMs && Date.now() > expiresAtMs) {
      await pendingRef.delete().catch(() => {});
      console.info("onUserDocCreated: pending invitation expired", { uid, email: _redactEmail(email) });
      return;
    }

    if (role !== "tenant_admin" && role !== "tenant_collaborator") {
      await pendingRef.delete().catch(() => {});
      return;
    }
    if (!tenantId) {
      await pendingRef.delete().catch(() => {});
      return;
    }

    const tenantSnap = await db.collection("tenants").doc(tenantId).get();
    if (!tenantSnap.exists) {
      await pendingRef.delete().catch(() => {});
      return;
    }

    // Preserve any pre-existing claims (very unlikely for a fresh user
    // doc, but belt-and-suspenders — matches setAdminClaim's discipline).
    const existingClaims = userRecord.customClaims || {};
    try {
      await admin.auth().setCustomUserClaims(uid, {
        ...existingClaims,
        role,
        tenantId,
      });
    } catch (e) {
      console.error("onUserDocCreated: setCustomUserClaims failed", {
        uid, tenantId, role, error: e?.message,
      });
      return;
    }

    // Mirror into tenant team subcollection so admin dashboards see them.
    try {
      await db.collection("tenants").doc(tenantId).collection("team").doc(uid).set({
        uid,
        email: userRecord.email,
        displayName: userRecord.displayName ?? null,
        role,
        addedAt: admin.firestore.FieldValue.serverTimestamp(),
        addedBy: pending.invitedBy ?? null,
        claimedFromPending: true,
        claimedVia: "onUserDocCreated",
      });
    } catch (e) {
      console.warn("onUserDocCreated: team subcollection update failed (non-fatal)", {
        uid, tenantId, error: e?.message,
      });
    }

    // Force the user's next ID token to include the new claims — otherwise
    // the client would keep its no-claim token until 1h expiry.
    try {
      await admin.auth().revokeRefreshTokens(uid);
    } catch (e) {
      console.warn("onUserDocCreated: revokeRefreshTokens failed (non-fatal)", {
        uid, error: e?.message,
      });
    }

    // Single-use: retire the pending doc.
    await pendingRef.delete().catch(() => {});

    console.info("onUserDocCreated: pending invitation applied", {
      uid, email: _redactEmail(email), role, tenantId,
    });
  },
);

// ============================================================================
// SERVER-SIDE REMINDERS (Stage 3)
// ============================================================================
// Replaces the mobile-only flutter_local_notifications scheduling with a
// Cloud Scheduler → Cloud Function → FCM push pipeline. Works for BOTH
// native (Android/iOS) and PWA (web/Safari) users — reminders fire even
// when the app is closed, no local OS scheduling needed.
//
// FLOW:
//   1. User creates/edits a reminder → client writes to Firestore.
//   2. onReminderWrite (below) computes nextTriggerAt from the client fields
//      + the user's timezone, writes it back to the same doc.
//   3. onUserTimezoneChanged (below) recomputes nextTriggerAt for all
//      recurring (non-one-shot) reminders when the user's tz changes.
//   4. processDueReminders (below) runs every minute via Cloud Scheduler,
//      collectionGroup queries for isEnabled + nextTriggerAt <= now,
//      transactionally advances nextTriggerAt BEFORE sending (at-most-once),
//      then sendToUser().
//   5. backfillRemindersNextTriggerAt (super_admin onCall) populates
//      nextTriggerAt on existing reminders after this feature deploys.
//
// KEY INVARIANTS:
//   - Client toMap() never emits nextTriggerAt/lastTriggeredAt/timezone —
//     firestore.rules reject writes that include them.
//   - onReminderWrite is idempotent: uses onlyClientFieldsChanged() to
//     avoid re-triggering on server-side writes (loop guard).
//   - processDueReminders uses a transaction to compareAndSwap
//     nextTriggerAt BEFORE the FCM send. If the send fails, the reminder
//     still advances (at-most-once) — losing a push is preferable to
//     double-notifying the user (per adversarial review R-1).
//   - one-shot reminders (oneShotDate != null): fire once, then
//     nextTriggerAt=null + isEnabled=false. Frozen against tz changes.

/**
 * Fields written by the CLIENT (via Reminder.toMap()). Any change in these
 * between doc versions should recompute nextTriggerAt. Fields NOT here are
 * server-owned (nextTriggerAt/lastTriggeredAt/timezone) and their diff must
 * NOT trigger a recompute (loop guard — see onReminderWrite).
 */
const REMINDER_CLIENT_FIELDS = [
  "timeHour", "timeMinute", "days", "isHoliday",
  "secondTimeHour", "secondTimeMinute", "secondDays", "secondIsHoliday",
  "isEnabled", "oneShotDate",
];

function _reminderClientFieldsChanged(before, after) {
  if (!before && after) return true; // create
  if (before && !after) return false; // delete (no recompute needed)
  for (const key of REMINDER_CLIENT_FIELDS) {
    const b = before[key];
    const a = after[key];
    // Firestore Timestamps compare by reference — normalize to millis.
    const bn = (b && typeof b.toMillis === "function") ? b.toMillis() : b;
    const an = (a && typeof a.toMillis === "function") ? a.toMillis() : a;
    if (JSON.stringify(bn) !== JSON.stringify(an)) return true;
  }
  return false;
}

/**
 * Given a reminder doc + the user's IANA timezone, compute the next UTC
 * instant at which the reminder should fire. Returns null if the reminder
 * is disabled or has no configured slots.
 *
 * Semantics:
 * - If `oneShotDate` is set (chooseDate): return that date at (timeHour,
 *   timeMinute) in the given timezone, converted to UTC. If already past,
 *   return null (one-shot expired — cleanup in processDueReminders).
 * - Otherwise (recurring): find the earliest next occurrence of any
 *   configured (weekday, hour, minute) slot in the timezone. Combines
 *   days×time and secondDays×secondTime into a single MIN — one nextTriggerAt
 *   field for the entire reminder (per adversarial review R-3 — linearize).
 */
function computeNextTrigger(reminder, timezone) {
  if (!reminder || reminder.isEnabled === false) return null;
  const tz = timezone || "UTC";

  const now = DateTime.now().setZone(tz);
  const hour = Number.isFinite(reminder.timeHour) ? reminder.timeHour : 12;
  const minute = Number.isFinite(reminder.timeMinute) ? reminder.timeMinute : 0;

  // One-shot: absolute date at the reminder's time in user's timezone.
  const oneShot = reminder.oneShotDate;
  if (oneShot) {
    const asDate = (typeof oneShot.toDate === "function") ? oneShot.toDate() : new Date(oneShot);
    const dt = DateTime.fromJSDate(asDate, { zone: tz })
        .set({ hour, minute, second: 0, millisecond: 0 });
    if (dt <= now) return null;
    return dt.toUTC().toJSDate();
  }

  // Recurring: enumerate all configured slots and pick the earliest future one.
  const days = Array.isArray(reminder.days) ? reminder.days.map(Number).filter((d) => d >= 1 && d <= 7) : [];
  const secondDays = Array.isArray(reminder.secondDays) ? reminder.secondDays.map(Number).filter((d) => d >= 1 && d <= 7) : [];
  const secondHour = Number.isFinite(reminder.secondTimeHour) ? reminder.secondTimeHour : null;
  const secondMinute = Number.isFinite(reminder.secondTimeMinute) ? reminder.secondTimeMinute : null;
  const hasSecond = secondHour !== null && secondMinute !== null;

  const candidates = [];
  const pushSlot = (weekdays, h, m) => {
    for (const w of weekdays) {
      // Luxon weekday: 1 = Monday .. 7 = Sunday — matches Dart's DateTime.monday etc.
      let cand = now.set({ weekday: w, hour: h, minute: m, second: 0, millisecond: 0 });
      // If that weekday+time is earlier today (or already past today), roll to next week.
      if (cand <= now) cand = cand.plus({ weeks: 1 });
      candidates.push(cand);
    }
  };
  pushSlot(days, hour, minute);
  if (hasSecond) pushSlot(secondDays, secondHour, secondMinute);

  if (candidates.length === 0) return null;
  const winner = candidates.reduce((a, b) => (a < b ? a : b));
  return winner.toUTC().toJSDate();
}

/** Read the user's IANA timezone from users/{uid}. Fallback to UTC. */
async function _getUserTimezone(uid) {
  try {
    const snap = await db.collection("users").doc(uid).get();
    const tz = snap.exists ? snap.get("timezone") : null;
    return (typeof tz === "string" && tz.length > 0 && tz.length <= 60) ? tz : "UTC";
  } catch (_) {
    return "UTC";
  }
}

/**
 * onReminderWrite — computes nextTriggerAt whenever a reminder's CLIENT
 * fields change. Loop-guarded: no-op if the change was purely server-side
 * (e.g., processDueReminders advancing nextTriggerAt+lastTriggeredAt).
 */
exports.onReminderWrite = onDocumentWritten(
  {
    document: "users/{uid}/reminders/{reminderId}",
    region: "us-central1",
  },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();

    // Delete: no compute needed. The doc is gone.
    if (!after) return;

    // Loop-guard: if only server-owned fields changed, don't recompute.
    if (before && !_reminderClientFieldsChanged(before, after)) return;

    const { uid, reminderId } = event.params;
    const timezone = await _getUserTimezone(uid);
    const nextTriggerAt = computeNextTrigger(after, timezone);

    const patch = {
      timezone,
      nextTriggerAt: nextTriggerAt ? admin.firestore.Timestamp.fromDate(nextTriggerAt) : null,
    };
    // Skip write if the computed values match what's already there — avoids
    // an infinite loop if _reminderClientFieldsChanged has a bug.
    const currentTz = after.timezone;
    const currentNext = after.nextTriggerAt;
    const nextMs = nextTriggerAt ? nextTriggerAt.getTime() : null;
    const currentMs = (currentNext && typeof currentNext.toMillis === "function")
        ? currentNext.toMillis() : null;
    if (currentTz === timezone && currentMs === nextMs) return;

    await event.data.after.ref.set(patch, { merge: true });
    console.info("onReminderWrite: computed nextTriggerAt", {
      uid, reminderId, timezone, nextTriggerAt: nextTriggerAt?.toISOString() || null,
    });
  },
);

/**
 * onUserTimezoneChanged — recompute nextTriggerAt for all recurring
 * reminders when the user's timezone changes. One-shot reminders are
 * FROZEN (adversarial R-6): the oneShotDate is a commitment to an absolute
 * moment ("my grandfather's yahrzeit is Tuesday 9am"), it shouldn't shift.
 */
exports.onUserTimezoneChanged = onDocumentUpdated(
  {
    document: "users/{uid}",
    region: "us-central1",
  },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;
    if (before.timezone === after.timezone) return;
    const newTz = after.timezone;
    if (typeof newTz !== "string" || newTz.length === 0) return;

    // Round-6 audit LOW fix: validate IANA-shape before running through
    // Luxon. Arbitrary strings ("hola", "utc-3", etc) make Luxon return
    // Invalid DateTime → Timestamp.fromDate(NaN) crashes the batch commit.
    // Use DateTime.now().setZone(x).isValid as the ground-truth check.
    try {
      const { DateTime } = require("luxon");
      if (!DateTime.now().setZone(newTz).isValid) {
        console.warn("onUserTimezoneChanged: invalid IANA tz — skipping", { uid: event.params.uid, newTz });
        return;
      }
    } catch (_) { /* if luxon load fails, fall through and trust newTz */ }

    const { uid } = event.params;
    const remindersRef = db.collection("users").doc(uid).collection("reminders");
    const snap = await remindersRef.get();
    if (snap.empty) return;

    // Round-6 audit LOW fix: paginate the batch — a user with >500 reminders
    // used to blow the single-batch limit and the tz stayed desynced across
    // all of them. Chunk to 400 for margin.
    let batch = db.batch();
    let batchOps = 0;
    let recomputed = 0;
    for (const doc of snap.docs) {
      const data = doc.data();
      // Skip one-shot: absolute date, tz-frozen (see R-6).
      if (data.oneShotDate) continue;
      const nextTriggerAt = computeNextTrigger(data, newTz);
      batch.set(doc.ref, {
        timezone: newTz,
        nextTriggerAt: nextTriggerAt ? admin.firestore.Timestamp.fromDate(nextTriggerAt) : null,
      }, { merge: true });
      batchOps += 1;
      recomputed += 1;
      if (batchOps >= 400) {
        await batch.commit();
        batch = db.batch();
        batchOps = 0;
      }
    }
    if (batchOps > 0) await batch.commit();
    console.info("onUserTimezoneChanged: recomputed reminders", { uid, newTz, recomputed });
  },
);

/**
 * processDueReminders — Cloud Scheduler tick every 1 minute. Queries the
 * collectionGroup 'reminders' for isEnabled + nextTriggerAt <= now, fires
 * FCM push (via sendToUser, which already handles per-platform payload),
 * and advances nextTriggerAt to the next occurrence.
 *
 * At-MOST-once semantics: the transaction advances nextTriggerAt BEFORE
 * the send. If the send fails, that firing is lost — but the reminder
 * NEVER fires twice for the same slot. Per adversarial R-1: losing an
 * occasional weekly reminder is less bad than duplicate notifications.
 */
exports.processDueReminders = onSchedule(
  {
    schedule: "every 1 minutes",
    timeZone: "UTC",
    region: "us-central1",
    retryCount: 0, // no retry — the next tick catches misses
    memory: "256MiB",
  },
  async () => {
    const now = admin.firestore.Timestamp.now();
    const snap = await db.collectionGroup("reminders")
        .where("isEnabled", "==", true)
        .where("nextTriggerAt", "<=", now)
        .limit(500) // one tick's budget; misses get picked up the next minute
        .get();

    if (snap.empty) return;

    // Round-5 audit HIGH fix: staleness cap. If nextTriggerAt is more than
    // STALENESS_CAP_MIN in the past, skip the fire — sending a "recuérdame"
    // notification hours late is worse than missing it. Common trigger:
    // Cloud Scheduler outage, quota exhaustion, or hitting the 500-doc
    // cap for many ticks. The reminder still advances to its next slot
    // in the tx below.
    const STALENESS_CAP_MIN = 30;
    const staleThresholdMs = now.toMillis() - (STALENESS_CAP_MIN * 60 * 1000);

    // Group docs by parent uid so we do ONE getUserTokens per uid (cheap Firestore read).
    const byUid = new Map();
    for (const doc of snap.docs) {
      // doc.ref.path: users/{uid}/reminders/{id}
      const parts = doc.ref.path.split("/");
      const uid = parts[1];
      if (!byUid.has(uid)) byUid.set(uid, []);
      byUid.get(uid).push(doc);
    }

    // Round-5 audit fix: batch-load user profiles for each uid ONCE so we
    // don't do N Firestore reads for language + tenant appName inside the
    // inner loop. Skipped uids from block-check via getUserTokens still
    // avoid a second read since we cache here first.
    const userProfileCache = new Map();
    async function _getCachedUserProfile(uid) {
      if (userProfileCache.has(uid)) return userProfileCache.get(uid);
      let data = {};
      try {
        const s = await db.collection("users").doc(uid).get();
        data = s.exists ? (s.data() || {}) : {};
      } catch (_) { /* fall back to empty */ }
      userProfileCache.set(uid, data);
      return data;
    }

    // Round-7 regression fix: cache tenant docs by tid so many reminders
    // firing for the same tenant in one tick don't re-read the tenant
    // doc for each (was N reads for N reminders — now 1 per unique
    // tenantId per tick).
    const tenantCache = new Map();
    async function _getCachedTenant(tid) {
      if (tenantCache.has(tid)) return tenantCache.get(tid);
      let data = {};
      try {
        const s = await db.collection("tenants").doc(tid).get();
        data = s.exists ? (s.data() || {}) : {};
      } catch (_) { /* fall back to empty */ }
      tenantCache.set(tid, data);
      return data;
    }

    let fired = 0;
    let skipped = 0;
    const tasks = [];

    // Round-9 regression fix (LOW #7): pre-check isBlocked once per uid
    // instead of paying that read inside every getUserTokens call. A user
    // with M reminders firing this tick used to cost M redundant user-doc
    // reads (getUserTokens re-checks isBlocked internally). Now we skip
    // the entire uid batch upfront when blocked.
    const blockedUids = new Set();
    const blockedProbes = await Promise.allSettled(
      Array.from(byUid.keys()).map((u) =>
        db.collection("users").doc(u).get().then((s) => ({ u, blocked: s.exists && s.data()?.isBlocked === true }))
      )
    );
    for (const p of blockedProbes) {
      if (p.status === "fulfilled" && p.value.blocked) blockedUids.add(p.value.u);
    }

    for (const [uid, docs] of byUid.entries()) {
      if (blockedUids.has(uid)) {
        skipped += docs.length;
        continue;
      }
      for (const doc of docs) {
        const data = doc.data();
        const tz = data.timezone || "UTC";
        // AT-MOST-ONCE: advance nextTriggerAt in a transaction FIRST.
        // If another tick already advanced it, our compareAndSwap fails
        // → we skip (no duplicate). If our advance succeeds but the send
        // below throws, we lose that firing — acceptable per R-1.
        const isOneShot = !!data.oneShotDate;
        let advanced = false;
        try {
          await db.runTransaction(async (tx) => {
            const fresh = await tx.get(doc.ref);
            if (!fresh.exists) return;
            const freshData = fresh.data();
            if (!freshData.isEnabled) return;
            const freshNext = freshData.nextTriggerAt;
            // Somebody else already advanced past our target — skip.
            if (!freshNext || freshNext.toMillis() > now.toMillis()) return;

            const newNext = isOneShot ? null : computeNextTrigger(freshData, tz);
            const patch = {
              lastTriggeredAt: now,
              nextTriggerAt: newNext ? admin.firestore.Timestamp.fromDate(newNext) : null,
            };
            // One-shot: also disable so it doesn't show as "enabled" in the
            // UI post-fire (and skips future queries for good).
            if (isOneShot) patch.isEnabled = false;
            tx.set(doc.ref, patch, { merge: true });
            advanced = true;
          });
        } catch (e) {
          console.warn("processDueReminders: tx failed", { path: doc.ref.path, error: e?.message });
          skipped += 1;
          continue;
        }
        if (!advanced) {
          skipped += 1;
          continue;
        }

        // Round-5 audit HIGH fix: skip retroactive fires. If we're advancing
        // past a trigger point that was already >30 min in the past, don't
        // send the push — the "recuerdame antes" moment is gone. We STILL
        // advance nextTriggerAt (transaction above) so the next slot fires
        // normally; we just skip the actual FCM send this tick.
        const wasStale = data.nextTriggerAt &&
          typeof data.nextTriggerAt.toMillis === "function" &&
          data.nextTriggerAt.toMillis() < staleThresholdMs;
        if (wasStale) {
          console.warn("processDueReminders: skip_stale", {
            uid, reminderId: doc.id,
            ageMinutes: Math.round((now.toMillis() - data.nextTriggerAt.toMillis()) / 60000),
          });
          skipped += 1;
          continue;
        }

        // Now fire the push (best-effort; if it fails we don't retry).
        // Round-5 audit HIGH fix: title fallback should be the tenant's
        // appName (branding), not the hardcoded "Pushka". User-set title
        // still wins when present (data.title). We use the user's ACTIVE
        // tenant per tenantId in the user doc; multi-tenant users get the
        // brand they last looked at.
        const userProfile = await _getCachedUserProfile(uid);
        let tenantAppName = "Pushka";
        const activeTenantId = String(userProfile.tenantId || "").trim();
        if (activeTenantId) {
          // Round-7 regression fix: use tenant cache so N reminders for
          // the same tenant in one tick only cost 1 tenant doc read.
          const td = await _getCachedTenant(activeTenantId);
          tenantAppName = String(td.appName || td.name || "Pushka");
        }
        // Round-6 audit MEDIUM fix: String.slice cuts UTF-16 code units,
        // not code points — a surrogate pair (emoji) at char 100 would
        // split in half and render mojibake. Split on Array.from() which
        // iterates code points then rejoin.
        const rawTitle = String(data.title || tenantAppName);
        const titleCodepoints = Array.from(rawTitle);
        const title = titleCodepoints.length > 100
            ? titleCodepoints.slice(0, 100).join("")
            : rawTitle;
        // Body: localized default in the user's language. Falls back to
        // Spanish if the profile has no language set.
        const raw = String(userProfile.language || "").trim().toLowerCase();
        const userLang = ["es", "en", "fr", "he"].includes(raw) ? raw : "es";
        const bodyByLang = {
          es: "Es momento de dar tzedaka 🕎",
          en: "It's time to give tzedaka 🕎",
          fr: "Il est temps de donner tzedaka 🕎",
          he: "🕎 הגיע הזמן לתת צדקה",
        };
        const body = bodyByLang[userLang];
        tasks.push(
          // Round-10 audit fix (MEDIUM #3): skip the internal isBlocked
          // re-check — we already prefetched it once for this tick above.
          sendToUser(uid, {
            notification: { title, body },
            data: {
              type: "reminder",
              reminderId: doc.id,
              click_action: "/reminders",
            },
          }, { skipBlockedCheck: true }).catch((err) => {
            console.warn("processDueReminders: send failed", { uid, reminderId: doc.id, error: err?.message });
          }),
        );
        fired += 1;
      }
    }

    // Fire sends in parallel (bounded implicitly by Node's HTTP pool).
    await Promise.all(tasks);
    console.info("processDueReminders: tick complete", { fired, skipped });
  },
);

/**
 * backfillRemindersNextTriggerAt — one-shot super_admin migration to
 * populate nextTriggerAt on reminders created BEFORE this feature deployed.
 * Idempotent; safe to re-run. Returns a summary; if timeoutHint is true
 * the caller should invoke again to continue (limit prevents 9min timeout).
 */
exports.backfillRemindersNextTriggerAt = onCall(
  { region: "us-central1", enforceAppCheck: false },
  async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "sign in required");
    const callerSnap = await db.collection("users").doc(request.auth.uid).get();
    const role = callerSnap.get("role");
    if (role !== "super_admin") {
      throw new HttpsError("permission-denied", "super_admin only");
    }

    const startAfterId = request.data?.startAfter || null;
    const pageSize = Math.min(Math.max(Number(request.data?.pageSize) || 400, 50), 500);

    let query = db.collectionGroup("reminders").orderBy(admin.firestore.FieldPath.documentId()).limit(pageSize);
    if (startAfterId) query = query.startAfter(startAfterId);
    const snap = await query.get();

    if (snap.empty) {
      return { scanned: 0, updated: 0, skipped: 0, done: true };
    }

    // Group by uid to dedupe user timezone lookups.
    const uidToDocs = new Map();
    for (const doc of snap.docs) {
      const parts = doc.ref.path.split("/");
      const uid = parts[1];
      if (!uidToDocs.has(uid)) uidToDocs.set(uid, []);
      uidToDocs.get(uid).push(doc);
    }
    const uids = [...uidToDocs.keys()];
    const userRefs = uids.map((uid) => db.collection("users").doc(uid));
    const userSnaps = userRefs.length ? await db.getAll(...userRefs) : [];
    const uidToTz = new Map();
    userSnaps.forEach((s, i) => {
      const tz = s.get("timezone");
      uidToTz.set(uids[i], (typeof tz === "string" && tz.length > 0) ? tz : "UTC");
    });

    let updated = 0;
    let skipped = 0;
    const batch = db.batch();
    for (const [uid, docs] of uidToDocs.entries()) {
      const tz = uidToTz.get(uid) || "UTC";
      for (const doc of docs) {
        const data = doc.data();
        // Skip if already populated — idempotency.
        if (data.nextTriggerAt || data.timezone) { skipped += 1; continue; }
        const nextTriggerAt = computeNextTrigger(data, tz);
        batch.set(doc.ref, {
          timezone: tz,
          nextTriggerAt: nextTriggerAt ? admin.firestore.Timestamp.fromDate(nextTriggerAt) : null,
        }, { merge: true });
        updated += 1;
      }
    }
    if (updated > 0) await batch.commit();

    const lastDoc = snap.docs[snap.docs.length - 1];
    const nextStartAfter = lastDoc ? lastDoc.id : null;
    const done = snap.size < pageSize;
    return {
      scanned: snap.size,
      updated,
      skipped,
      done,
      nextStartAfter: done ? null : nextStartAfter,
    };
  },
);
