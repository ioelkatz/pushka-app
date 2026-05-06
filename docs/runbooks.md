# Pushka — Operational Runbooks

Concise playbooks for the most likely on-call incidents. Each section
lists the symptom (what you'll see), the diagnosis (where to look), and
the response (what to do, in order).

These assume `firebase` CLI auth + project access (`pushka-app-ioel` for
prod, `pushka-app-ioel-test` for staging). Set `--project <id>` on every
command so you can't fat-finger prod.

## 1. Stripe outage

**Symptom**: bursts of `rate_limit_hit` warnings in Cloud Logging,
`StripeConnectionError` / `network_error` from `createPaymentIntent`,
multiple `payment_intent.payment_failed` events with reason
`processing_error` arriving in clusters.

**Diagnosis**:
1. Check [Stripe status](https://status.stripe.com) — confirms whether
   it's their problem.
2. Cloud Logging filter:
   ```
   resource.type="cloud_function"
   jsonPayload.message=~"stripe_charge_failed|StripeConnectionError"
   ```
   In the last 15 min, count by `code`. A spike with `code: undefined`
   plus mixed types is usually transient connectivity; a spike of
   identical `code: rate_limit` is throttling on our account.

**Response**:
- **If Stripe is down**: do nothing. Donations queue as failed PIs;
  retried PIs use idempotency keys so no double-charge risk. Monitor
  status page; once Stripe recovers, the auto-empty cron's 24-hour
  retry-on-failure path will sweep up most missed cycles.
- **If we're being rate-limited**: pause the auto-empty cron (`gcloud
  scheduler jobs pause processPushkaAutoEmpty --location us-central1`)
  to drop background load, investigate which CF is hottest in logs,
  scale that CF's `maxInstances` down to throttle ourselves before
  Stripe does it harder.
- **Communicate**: post in #ops channel. Donors who saw failures get
  a generic "intentá de nuevo" SnackBar — no proactive comms unless
  the outage exceeds 30 min.

## 2. Webhook backlog

**Symptom**: Stripe Dashboard → Developers → Webhooks shows attempts
piling up (red 4xx/5xx counts climbing). Donor history doesn't show
recent transactions even though the charge succeeded in Stripe.

**Diagnosis**:
1. Cloud Logging:
   ```
   resource.labels.function_name="stripeWebhook" severity>=ERROR
   ```
2. Look at `_stripeWebhookEvents` collection in Firestore. Filter
   `status == "processing"` AND `lastAttemptAt > 5 min ago` — any docs
   stuck in that state past `WEBHOOK_PROCESSING_TTL_MS` are recoverable
   (next webhook delivery picks them up via the recoveredFromStuck
   path), but shouldn't accumulate.
3. Check function timeout / cold-start metrics. If processing time
   creeps over 60s, Stripe will time out and retry → backlog.

**Response**:
- **If Firestore writes are failing**: check IAM, check Firestore
  health, check our quotas. Webhook returns 5xx, Stripe retries with
  exponential backoff up to 3 days. Don't manually replay — let the
  retry chain do its job.
- **If we deployed broken code**: roll back functions immediately
  (`firebase functions:list` → identify last good deploy, redeploy
  from that git tag). Stripe will retry stuck events.
- **Stuck `processing` docs**: after fixing the root cause, run
  `cleanupOldStripeWebhookEvents` (already scheduled daily at 04:20
  UTC) — manual run via console if needed.

## 3. Tenant suspension

**Symptom**: tenant admin reports their org's donations stopped; or
super_admin marks a tenant `status: "suspended"`.

**Diagnosis**: read `tenants/{tenantId}` doc — `status`,
`paymentStatus`, `gracePeriodEndsAt`, `stripeConnectStatus`.

**Response**:
- **Admin flagged abuse**: set `status: "suspended"` via super_admin
  dashboard. The CF `tenantSuspendedGuard` (in createPaymentIntent)
  blocks new charges. Existing recurring subscriptions need manual
  cancellation in Stripe (search by `metadata.tenantId`). Auto-empty
  cron skips suspended tenants automatically.
- **Tenant didn't pay their SaaS bill**: `paymentStatus: "past_due"`
  + `gracePeriodEndsAt` window starts. After grace period elapses
  the cron pauses auto-empty for that tenant (24h retry path).
  Notify admin by email; restoring requires reconciling the
  Stripe billing subscription.
- **Restoring**: change `status: "active"`, clear
  `_lastAutoEmptySkipReason` on member tenantStates, the next cron
  tick resumes normal cycle.

## 4. Auto-empty cron incident

**Symptom**: many users report "auto-empty didn't fire" or "got
charged but pushka not reset"; spike in `processPushkaAutoEmpty:
stripe_charge_failed` logs.

**Diagnosis**:
1. Cloud Logging filter on `processPushkaAutoEmpty` last 24h.
2. Group by `code` — common buckets:
   - `resource_missing` / `pm_unusable_offsession` / `pm_unactivated`
     → user's PM detached/tainted. Cron now self-heals (clears
     `autoEmptyPaymentMethodId` so user's default takes over next
     cycle). User receives a notification telling them to re-save
     the card.
   - `card_declined` → expected per-user failure. 24h retry path.
   - `tenant_connect_not_active` → tenant disconnected Stripe.
     `_lastAutoEmptySkipReason` stamped on tenantState; client banner.
3. Check `_stripeWebhookEvents` for stuck `payment_intent.succeeded`
   events that didn't reach the pushkaAmount-reset path.

**Response**:
- **Spike in pm_unusable_offsession**: usually a rollout where some
  cohort of cards entered the system without proper Customer
  attachment. Audit the SetupIntent flow for that cohort; fix the
  attach path going forward. Existing affected users self-recover
  next cycle.
- **One-off charge succeeded but pushka not reset**: webhook didn't
  fire or didn't process. Manually update tenantState's
  `pushkaAmount` for the affected user (Firestore console). Verify
  the tx doc exists in `users/{uid}/transactions` — if not, write
  one matching the Stripe charge.

## 5. Stripe Connect account changes mid-flight

**Symptom**: `stripeWebhook: connectAccountId DRIFT` errors in logs.
Donations made before a tenant re-linked Connect were attributed
to the old destination.

**Response**: each drift event is logged with `stampedConnect` (where
the money actually went) and `currentConnect` (where it would go now).
For each affected tx:
1. Verify the charge succeeded under the OLD Connect account in
   Stripe Dashboard.
2. Reconcile manually: either issue a refund + new charge to the
   correct destination, or — if the old account was closed — work
   with Stripe support to recover funds.
3. The tx doc was still written; stamp `connectDrift: true` on it
   for the audit trail.

## 6. Pre-launch checklist (super_admin must verify)

- [ ] `backfillTenantSlugs` ran in prod with 0 conflicts (verify
      `_backfillRuns/tenantSlugs` sentinel doc exists)
- [ ] Firestore TTL policy enabled on `_stripeWebhookEvents.expiresAt`
      (Firebase Console → Firestore → TTL)
- [ ] All tenants have a non-null `commissionRate` in [0, 0.10]
- [ ] Stripe Dashboard webhook endpoint subscribed to all events
      listed in CLAUDE.md
- [ ] App Check enforcement enabled on every callable + webhook

## Useful greps

```
# Trace a single donation across all CFs
[cid:abcd1234ef567890]

# All rate-limit hits in last hour
jsonPayload.message="rate_limit_hit"

# Auto-empty failures grouped by reason
resource.labels.function_name="processPushkaAutoEmpty"
jsonPayload.message="stripe_charge_failed"
| stats count by jsonPayload.code
```
