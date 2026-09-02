# Pushka App — Workflow

This file is read by Claude (and by humans) on both dev machines. Conventions live here so both Claudes behave the same.

## Devs

- **Alan** (GitHub: `alankatz37931`) — works on branch `alan/dev` off `dev`
- **Ioel** (GitHub: `ioelkatz`, repo + Firebase + Stripe owner) — works on branch `ioel/dev` off `dev`

## Environments

Two Firebase projects, two Stripe modes, two Android applicationIds — switched at build time via Flutter flavor + dart-define:

| Env | Flutter flavor | applicationId | Firebase project | Stripe mode |
|---|---|---|---|---|
| `prod` | `prod` (default) | `com.pushka.app` | `pushka-app-ioel` | live |
| `dev` | `dev` | `com.pushka.app.test` | `pushka-app-ioel-test` | test |

Both APKs install side-by-side on the same device (different applicationId). Dev shows as **"Pushka Test"** in the launcher; prod as **"Pushka"**.

## Build & run

### Dev (recommended for daily work — no real money, test cards work)
```
flutter run --flavor dev \
  --dart-define=ENV=dev \
  --dart-define=STRIPE_PUBLISHABLE_KEY=pk_test_...
```
Use Stripe test cards (e.g. `4242 4242 4242 4242`, any future expiry, any CVC).

### Prod (for verifying real payment flow — uses real money)
```
flutter run --flavor prod \
  --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_...
```

### Release builds
```
# Test/staging (signed with debug key by default — change if needed)
flutter build apk --flavor dev --dart-define=ENV=dev --dart-define=STRIPE_PUBLISHABLE_KEY=pk_test_...

# Production — PLAY STORE (.aab). NO lleva APP_CHECK_PROVIDER: el default es
# Play Integrity, que es la atestación real que exige una app publicada.
flutter build appbundle --flavor prod --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_...

# Production — SIDELOAD (APK que se baja de pushka-landing.web.app/instalar).
# APP_CHECK_PROVIDER=debug es OBLIGATORIO: Play Integrity no puede attestar una
# app que no vino de Play Store, así que sin este flag falla en TODOS los
# usuarios. Ver la nota de _appCheckProvider en lib/app/app_initializer.dart.
flutter build apk --flavor prod --split-per-abi \
  --dart-define=APP_CHECK_PROVIDER=debug \
  --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_... \
  --dart-define=RECAPTCHA_SITE_KEY=...
```

> ⚠️ **El default del proveedor de App Check es el estricto a propósito.** De
> los dos errores posibles, el caro es publicar en la tienda con el proveedor
> de debug: queda una app pública sin atestación real y sin ninguna señal
> visible. Olvidar el flag en un build de sideload se nota enseguida y no
> expone nada.

## Git workflow

- `dev` is the integration branch. **Never commit directly to `dev`** — protected, requires PR + 1 approval.
- Each dev works on `alan/dev` or `ioel/dev` (or feature branches off them).
- Open a PR to `dev` to share work. Auto-merge enabled — squash-merge only, branches auto-delete after merge.
- Always `git pull --rebase origin dev` before opening a PR to keep history clean.

## Local environment (per dev)

These files are gitignored — each dev generates them locally and never commits them:

| File | Path | How to get it |
|---|---|---|
| Prod Firebase config | `android/app/src/prod/google-services.json` | from secrets bundle (ask Ioel) |
| Dev Firebase config | `android/app/src/dev/google-services.json` | run `firebase apps:sdkconfig ANDROID <DEV_APP_ID> --project pushka-app-ioel-test > android/app/src/dev/google-services.json` |
| Release keystore | `android/app/pushka-release-key.jks` | from secrets bundle |
| Keystore properties | `android/key.properties` | from secrets bundle |
| Env file (prod) | `production.env` | from secrets bundle (`STRIPE_PUBLISHABLE_KEY=pk_live_...`) |
| Env file (dev) | `dev.env` | ask Ioel for the Stripe test publishable key (`STRIPE_PUBLISHABLE_KEY=pk_test_...`) |
| Prod Firebase opts | `lib/firebase_options_prod.dart` | run `flutterfire configure --project=pushka-app-ioel --platforms=android --out=lib/firebase_options_prod.dart` and rename `DefaultFirebaseOptions` → `ProdFirebaseOptions` |
| Dev Firebase opts | `lib/firebase_options_dev.dart` | run `flutterfire configure --project=pushka-app-ioel-test --platforms=android --out=lib/firebase_options_dev.dart` and rename → `DevFirebaseOptions` |

## SHA-1 fingerprints (Google Sign-In + App Check)

Each dev's debug keystore has a unique SHA-1 that must be registered in BOTH Firebase projects:

```
keytool -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android -list -v | grep SHA1
```

Then for each project:
```
firebase apps:android:sha:create <APP_ID> <YOUR_SHA1> --project pushka-app-ioel
firebase apps:android:sha:create <APP_ID_TEST> <YOUR_SHA1> --project pushka-app-ioel-test
```

## App Check debug tokens

Backend enforces App Check. Debug builds use `AndroidProvider.debug` which prints a token to logcat on first launch. Register it in BOTH projects:

1. Run the app, look for: `D/com.google.firebase.appcheck.debug.internal.DebugAppCheckProvider: Enter this debug secret into the allow list ... <UUID>`
2. Register via API:
   ```
   curl -X POST "https://firebaseappcheck.googleapis.com/v1/projects/<PROJECT_NUMBER>/apps/<APP_ID>/debugTokens" \
     -H "Authorization: Bearer $(firebase auth:print-access-token)" \
     -H "X-Goog-User-Project: <PROJECT_ID>" \
     -H "Content-Type: application/json" \
     -d '{"displayName":"<your-machine> debug","token":"<UUID>"}'
   ```
   Or via Firebase Console → App Check → Apps → ⋮ → Manage debug tokens.

## Functions deployment

Each Firebase project has its own functions deployment. To deploy:
```
firebase deploy --only functions --project pushka-app-ioel-test     # to dev
firebase deploy --only functions --project pushka-app-ioel          # to prod
```

Secrets are scoped per project (`firebase functions:secrets:set <NAME> --project <PROJECT_ID>`). Currently set in dev: `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` (real test values), `STRIPE_BILLING_WEBHOOK_SECRET`, `STRIPE_CONNECT_CLIENT_ID`, `SENDGRID_API_KEY` (placeholders — set real test values when testing those flows).

### ⚠️ Always pipe secrets with `printf`, never `echo`

`echo "value" | firebase functions:secrets:set NAME --data-file -` appends a `\n`
to the secret value. The Stripe Node SDK (and any HTTP client that constructs
strict headers) rejects the `Authorization: Bearer <secret>\n` header with
`ERR_INVALID_CHAR`, surfacing as `StripeConnectionError: An error occurred with
our connection to Stripe`. Use `printf 'value' | ...` instead — it does NOT
add a trailing newline. This bit us hard once; don't repeat the mistake.

## Tooling versions

- Flutter 3.41.9 (stable) / Dart 3.11.5
- JDK 17 (Microsoft OpenJDK)
- Android SDK Platform 35/36 + NDK 28.2.13676358 + CMake 3.22.1
- Firebase CLI 15.16.0 / flutterfire_cli 1.3.2

## Known limitations

- **Stripe Payment Sheet language follows the device locale.** `flutter_stripe`
  v12 has no `locale` parameter on `SetupPaymentSheetParameters` or
  `Stripe.instance`. To see the sheet in Spanish, the device's system language
  must be Spanish. Most LATAM/IL users will already have this; not a blocker.

## Operational tasks

### Pre-launch blocker: `backfillTenantSlugs` in prod

**Why it's a blocker**: the `_tenantSlugs/{slug}` lock collection was
introduced after some tenants already existed in `pushka-app-ioel`, so those
legacy tenants don't have lock entries. Until the backfill runs, a malicious
`createTenant` call could duplicate one of those slugs (no lock = no
rejection). Idempotent + super_admin-only.

**Step-by-step (run BEFORE inviting users to prod)**:

1. **Deploy current functions to prod**:
   ```
   firebase deploy --only functions --project pushka-app-ioel
   ```

2. **Verify the function is deployed**:
   ```
   firebase functions:list --project pushka-app-ioel | grep backfillTenantSlugs
   ```
   Should show `backfillTenantSlugs` in the list.

3. **Sign in as super_admin** in the Flutter app (use the prod build —
   `flutter run --flavor prod`) — must be the SUPER_ADMIN_EMAIL configured
   in functions/index.js.

4. **Run via app dev console** (preferred — App Check tokens just work):
   - Open the app while logged in as super_admin
   - Open the Flutter DevTools console (or add a temporary one-off button)
   - Execute:
     ```dart
     final result = await FirebaseFunctions.instance
         .httpsCallable('backfillTenantSlugs').call();
     print(result.data);
     ```

   **OR via Cloud Functions REST** (alternative — bypass App Check via gcloud):
   ```bash
   gcloud auth print-identity-token \
     --audiences=https://us-central1-pushka-app-ioel.cloudfunctions.net/backfillTenantSlugs \
     | xargs -I {} curl -X POST \
       https://us-central1-pushka-app-ioel.cloudfunctions.net/backfillTenantSlugs \
       -H "Authorization: Bearer {}" \
       -H "Content-Type: application/json" \
       -d '{"data":{}}'
   ```

5. **Inspect the response**:
   ```json
   {
     "scanned": 12,                  // total tenants seen
     "created": 8,                   // new lock entries written
     "skippedAlreadyExists": 4,     // lock already correct
     "skippedNoSlug": 0,             // tenants without a slug field (review manually)
     "conflicts": []                 // ⚠️ slugs whose lock points elsewhere
   }
   ```
   - `conflicts` MUST be empty. If non-empty: each entry shows
     `{ slug, expectedTenantId, currentLockTenantId }` — a slug that resolved
     to two different tenants. Manual review required: pick the canonical
     tenant, delete the wrong `_tenantSlugs/{slug}` lock doc, re-run.
   - If `skippedNoSlug > 0`: those tenant docs lack a `slug` field entirely.
     Inspect each manually and decide whether to add a slug or mark inactive.

6. **Verify in Firestore Console**:
   `pushka-app-ioel` → Firestore → `_tenantSlugs/` → confirm one doc per
   active tenant slug.

Already deployed + verified in `pushka-app-ioel-test`. **Do NOT skip this
step in prod** — every day without the backfill is a day a malicious user
could squat a legacy tenant's slug.

### Other one-off backfills (lower priority)

- **`tenantId` on legacy transactions**: Transactions created before the
  multi-tenant cutover lack `tenantId`. The new strict Firestore rule
  requires it on creates (existing docs grandfathered). Multi-tenant history
  queries silently exclude these rows. To backfill: write a one-off CF that
  reads each user's `tenantId` and stamps it on their pre-cutover txns.

- **`tenantState` denormalized fields** (`tenantName`, `tenantAppName`,
  `tenantLogoUrl`, `tenantPrimaryColor`): The `onTenantBrandingUpdated`
  trigger keeps these fresh going forward, but legacy `tenantState` docs
  written before the trigger existed may have stale or absent values. Run
  a one-off scan: for each tenantState, read parent tenant doc, write
  current values via batch.

### iOS launch checklist (need Mac)

- [ ] Apple Developer account ($99/yr) + create Apple Pay merchant ID
- [ ] Add merchant ID to Xcode → Signing & Capabilities → Apple Pay
- [ ] Set `MERCHANT_IDENTIFIER` dart-define so `StripeConfig.merchantIdentifier` is non-empty
- [ ] Configure `apple-app-site-association` JSON on `pushkapp.cc/.well-known/`
- [ ] Add Associated Domains entitlement in Xcode (`applinks:pushkapp.cc`)
- [ ] Configure Apple Push Notifications certificates (Firebase Console → Cloud Messaging → APNs)
- [ ] Configure App Check DeviceCheck/AppAttest in Firebase Console
- [ ] Test ATT prompt fires on first launch (already wired in `app_initializer.dart`)
- [ ] Submit to App Store Review

### Stripe Dashboard checklist before going live

- [ ] Switch project from `pk_test_*` to `pk_live_*` keys (functions secrets + dart-defines)
- [ ] Configure `STRIPE_WEBHOOK_SECRET` for prod webhook endpoint
- [ ] Enable Google Pay + Apple Pay in Dashboard → Settings → Payment methods → Wallets
- [ ] Verify webhook endpoint URL on Stripe Dashboard matches `https://us-central1-pushka-app-ioel.cloudfunctions.net/stripeWebhook`
- [ ] Subscribe to ALL relevant events (the webhook handles: payment_intent.succeeded, .payment_failed, .canceled, charge.refunded, charge.dispute.created, .closed, .funds_withdrawn, .funds_reinstated, account.updated, application_fee.created, .refunded, customer.subscription.deleted, .updated, invoice.payment_succeeded, .payment_failed)

## For Claude (both Alans)

- Don't auto-resolve merge conflicts blindly — show them and let the dev decide.
- Don't `git push --force` to shared branches without explicit confirmation.
- Don't commit gitignored files even if asked vaguely; check the `.gitignore` first.
- Default to `--flavor dev` when running locally — never test against prod backend with real card data unless explicitly asked.
- For payment flow tests: always use `pk_test_...` + Stripe test cards (`4242...`).
- If both devs are working in parallel: prefer narrow, focused commits so PRs are easier to review and conflict-free.
- **Always set Cloud Functions secrets with `printf`, never `echo`** (see Functions deployment section above).
