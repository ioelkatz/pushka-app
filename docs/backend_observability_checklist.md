## Backend Observability Checklist (Pushka)

Use this checklist after each release and once a week.

### 1) Deploy Status

- Confirm latest functions are deployed:
  - `createPaymentIntent`
  - `stripeWebhook`
  - `cleanupStaleFcmTokens`
  - `cleanupOldStripeWebhookEvents`
  - `monitorStripeWebhookHealth`
  - `monitorStripeWebhookStuckEvents`
- Confirm Scheduler jobs are enabled in Google Cloud Scheduler.

### 2) Logs to Watch

In Google Cloud Logs Explorer, create saved queries for:

- `resource.type="cloud_function" AND textPayload:"stripeWebhook: Processing failed"`
- `resource.type="cloud_function" AND textPayload:"monitorStripeWebhookHealth: degraded"`
- `resource.type="cloud_function" AND textPayload:"monitorStripeWebhookStuckEvents: found_stuck_events"`

### 3) Alerts to Configure

Create alerting policies from logs (recommended):

- **Critical:** `stripeWebhook: Processing failed`
- **High:** `monitorStripeWebhookHealth: degraded`
- **High:** `monitorStripeWebhookStuckEvents: found_stuck_events`

Recommended channels:

- Email (engineering owner)
- WhatsApp/Slack bridge (optional)

### 4) Weekly Data Health Checks

- Verify `_stripeWebhookEvents` is being cleaned daily.
- Verify old `fcmTokens` are being cleaned daily.
- Review `users/{uid}/paymentEvents` for failed/refunded events trend.

### 5) Incident Quick Response

If a payment is charged but not shown in app:

1. Check Stripe event delivery for `payment_intent.succeeded`.
2. Check function logs for `stripeWebhook`.
3. Check Firestore:
   - `users/{uid}/transactions/{paymentIntentId}`
   - `_stripeWebhookEvents/{eventId}`
4. If missing, replay event from Stripe Dashboard.

