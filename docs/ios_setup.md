# iOS setup — TestFlight via Codemagic (no Mac needed locally)

This is the runbook for getting Pushka onto your iPhone via TestFlight when
you don't have a Mac. **The build itself runs on a Codemagic-hosted Mac;
you only touch the Apple Developer Portal, Firebase Console, and the
Codemagic web UI.**

The `codemagic.yaml` at the repo root already encodes both workflows:

- `ios-testflight-dev` — Stripe test keys + Firebase test project. Runs on
  every push to `dev`. Uses bundle id `com.pushka.app`.
- `ios-testflight-prod` — Stripe live keys + Firebase prod project. Manual
  trigger only.

This doc is the human side: what to click, in what order, before the first
CI build will succeed. Total wall-clock: ~2-3 hours of focused work,
spread across whichever services are still verifying you.

---

## 0. Prerequisites

- [ ] Apple Developer Program account (paid, $99 USD/year). Sign up at
      https://developer.apple.com. Verification can take a few days the
      first time — start this BEFORE the rest.
- [ ] An iPhone running iOS 13.0 or later (Stripe SDK requires it).
- [ ] The TestFlight app installed on that iPhone.
- [ ] Owner access on the GitHub repo (`ioelkatz/pushka-app`).

---

## 1. Apple Developer Portal — create the App ID + merchant ID

> https://developer.apple.com/account → Certificates, Identifiers & Profiles

### 1a. Register the App ID

1. **Identifiers → +** → "App IDs" → "App"
2. **Description**: `Pushka`
3. **Bundle ID** (Explicit): `com.pushka.app`
4. **Capabilities**: tick
   - Apple Pay Payment Processing
   - Associated Domains
   - Push Notifications
   - Sign In with Apple
   - App Attest (under "DeviceCheck")
5. Save.

### 1b. Register the Apple Pay merchant ID

1. **Identifiers → +** → "Merchant IDs"
2. **Description**: `Pushka donations`
3. **Identifier**: `merchant.com.pushka.app`
4. Save.

> The same string is hard-coded in `ios/Runner/Runner.entitlements` and
> passed to Stripe via `--dart-define=STRIPE_MERCHANT_ID=merchant.com.pushka.app`
> at build time (Codemagic env var).

### 1c. Bind the merchant ID to the App ID

1. Open the App ID created in 1a → "Edit"
2. Apple Pay Payment Processing → "Configure" → tick `merchant.com.pushka.app`
3. Save.

### 1d. Generate the Apple Pay Payment Processing certificate

1. Stripe Dashboard → Settings → Payment methods → Apple Pay → "Add new
   merchant ID" → enter `merchant.com.pushka.app` → download the CSR
   Stripe gives you.
2. Apple Developer Portal → the merchant ID → "Create Certificate" →
   upload the CSR from Stripe.
3. Download the resulting `.cer` and upload it back to Stripe.

> Without this round-trip, the Apple Pay sheet shows but the charge fails.

### 1e. Generate the App Store Connect API key

1. https://appstoreconnect.apple.com → Users and Access → Keys → "+"
2. Name: `Codemagic CI`. Access: **App Manager**.
3. Download the `.p8` file (you can only download it once).
4. Note the **Key ID** and **Issuer ID** shown on the screen.

> These three values let Codemagic upload to TestFlight without a session
> token. Treat the `.p8` like a password.

---

## 2. Firebase Console — register the iOS app in BOTH projects

You need to register `com.pushka.app` as an iOS app in both
`pushka-app-ioel-test` (dev workflow) and `pushka-app-ioel` (prod workflow).

For each project:

1. Firebase Console → the project → ⚙️ Project Settings → "Your apps" →
   "Add app" → iOS icon.
2. **Apple bundle ID**: `com.pushka.app`
3. **App nickname**: `Pushka iOS` (or whatever).
4. Skip the SDK-add steps (FlutterFire handles them).
5. Download the `GoogleService-Info.plist`. Save with a descriptive name
   (e.g. `GoogleService-Info-test.plist` and `-prod.plist`).
6. App Check → register the iOS app → enable **App Attest** as primary
   provider, **DeviceCheck** as fallback.
7. Cloud Messaging → upload your **APNs Authentication Key**:
   - Apple Developer Portal → Keys → "+" → "Apple Push Notifications
     service (APNs)" → all environments → download `.p8` once.
   - Firebase Console → Cloud Messaging → APNs Authentication Key →
     upload the `.p8` + Key ID + Team ID.

---

## 3. Generate `firebase_options_{dev,prod}.dart` locally (Windows OK)

`flutterfire configure` runs on any platform and writes the Dart options
file. Run it twice — once per project — and rename the class each time.

```bash
dart pub global activate flutterfire_cli
# (you may need to add ~/.pub-cache/bin or %LocalAppData%\Pub\Cache\bin to PATH)

flutterfire configure --project=pushka-app-ioel-test \
  --platforms=ios,android \
  --ios-bundle-id=com.pushka.app \
  --out=lib/firebase_options_dev.dart --yes

# Open lib/firebase_options_dev.dart and rename:
#   class DefaultFirebaseOptions  →  class DevFirebaseOptions

flutterfire configure --project=pushka-app-ioel \
  --platforms=ios,android \
  --ios-bundle-id=com.pushka.app \
  --out=lib/firebase_options_prod.dart --yes

# Same rename:
#   class DefaultFirebaseOptions  →  class ProdFirebaseOptions
```

> These two files are gitignored — they live only on your machine. Both
> get base64-encoded and uploaded to Codemagic in step 5.

---

## 4. Generate APNs auth key (alternative to certs — preferred)

Already covered in 2.7 above. The `.p8` lives only on Firebase Console
side; Codemagic doesn't need it directly because FCM init goes through
Firebase, not Apple, at runtime.

---

## 5. Codemagic — connect repo + integrations + env vars

### 5a. Add the app

1. https://codemagic.io → Sign in with GitHub.
2. **Add application** → pick `ioelkatz/pushka-app` → "Flutter App".
3. Codemagic auto-detects `codemagic.yaml`. Both workflows appear in the
   sidebar.

### 5b. Connect the App Store Connect API key

1. Codemagic → **Teams → Integrations → Apple Developer Portal**.
2. Click **Connect** → upload the `.p8` from step 1e + paste Key ID +
   Issuer ID.
3. Codemagic verifies. The integration name `codemagic` (referenced in
   `codemagic.yaml`) needs to match — it does by default.

### 5c. Create environment variable groups

Codemagic → **App settings → Environment variables**.

> Tip: when uploading the base64 of a file that may contain trailing
> newlines, encode with `-w 0` to keep it on one line. On Windows
> PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("path"))`.

#### Group `pushka_dev_secrets`

| Variable | Value | Secure? |
|---|---|---|
| `STRIPE_PUBLISHABLE_KEY` | `pk_test_…` (from your Stripe test dashboard) | yes |
| `STRIPE_MERCHANT_ID` | `merchant.com.pushka.app` | yes |
| `GOOGLE_SERVICE_INFO_PLIST_B64` | base64 of `GoogleService-Info-test.plist` | yes |
| `FIREBASE_OPTIONS_DEV_DART_B64` | base64 of `lib/firebase_options_dev.dart` | yes |
| `FIREBASE_OPTIONS_PROD_DART_B64` | base64 of `lib/firebase_options_prod.dart` | yes |

#### Group `pushka_prod_secrets`

| Variable | Value | Secure? |
|---|---|---|
| `STRIPE_PUBLISHABLE_KEY` | `pk_live_…` | yes |
| `STRIPE_MERCHANT_ID` | `merchant.com.pushka.app` | yes |
| `GOOGLE_SERVICE_INFO_PLIST_B64` | base64 of `GoogleService-Info-prod.plist` | yes |
| `FIREBASE_OPTIONS_DEV_DART_B64` | base64 of `lib/firebase_options_dev.dart` | yes |
| `FIREBASE_OPTIONS_PROD_DART_B64` | base64 of `lib/firebase_options_prod.dart` | yes |

> Both groups need both `_DART_B64` vars because the source tree imports
> both files unconditionally. The runtime `--dart-define=ENV=…` decides
> which one is used.

### 5d. App Store Connect TestFlight beta group

Codemagic publishes to a beta group named **Internal Testers**.

- App Store Connect → My Apps → Pushka → TestFlight → Internal Testing →
  "+" → name it exactly **`Internal Testers`** → add yourself by Apple ID.
- This is where TestFlight builds appear after a successful CI run.

---

## 6. First build

Easiest path:

1. Push any commit to `dev` (the audit Lows or hosting PR landings count).
2. Codemagic detects, runs `ios-testflight-dev`. ~12-15 minutes.
3. Watch the build in Codemagic → Builds. Dump full logs if anything fails
   — most first-build failures are missing env vars or the merchant ID
   not being bound to the App ID (step 1c).
4. On success, App Store Connect → TestFlight → Internal Testing shows
   the build. iPhone TestFlight app receives a push within 2-5 minutes.

---

## 7. Smoke test on iPhone (the actual MVP test)

Once the TestFlight build is on the phone, run through:

- [ ] **Auth**: Sign in with Google + Apple. Both should show their
      native sheets (Apple Sign-In is required by App Store review when
      Google Sign-In is offered).
- [ ] **Tenant join**: enter a test tenant code from `pushka-app-ioel-test`.
- [ ] **One-shot donation**: Apple Pay sheet should open with the
      `merchant.com.pushka.app` identity. Use a test card.
- [ ] **Recurring donation**: Mensual + Apple Pay. Verify sub appears in
      "Mis donaciones recurrentes".
- [ ] **Cancel sub**: chevron tap → confirm → list refreshes.
- [ ] **Auto-empty**: enable monthly, change pinned card. Verify
      Firestore tenantState updates.
- [ ] **Notifications**: receive a push (e.g. donation succeeded webhook
      stamps a notification). May need to grant notification permission
      first.
- [ ] **Universal Link**: tap a `https://pushka-app-ioel.web.app/...`
      link from an email/note — should open the app, not Safari.
      Currently `apple-app-site-association` is hosted only at the
      `.web.app` domain; once `pushkaapp.com` DNS is mapped the
      `applinks:www.pushkaapp.com` entitlement also activates.
- [ ] **App Check**: backend logs (Cloud Functions) should NOT report
      App Check failures. App Attest needs the device to be production
      (i.e. App Store / TestFlight build, not a sideload), so this is
      where the TestFlight path differs from a Mac-side `flutter run`.
- [ ] **ATT prompt**: first launch, confirm the system tracking-prompt
      fires once. If user denies, Firebase Analytics should self-disable
      (we wired this in `app_initializer.dart`).

---

## 8. Promotion to App Store

When TestFlight QA is green:

1. Codemagic UI → workflows → `ios-testflight-prod` → **Start build**
   manually (no auto-trigger).
2. Build → upload to TestFlight under the prod Firebase project + live
   Stripe keys. **Same bundle id, but App Store Connect tracks by build
   number.**
3. App Store Connect → My Apps → Pushka → "+ Version" → fill listing,
   screenshots, data safety, content rating → submit for review.
4. App Review queue: typically 24-48 hours for a first submission, can
   take longer for finance / payment apps.

---

## Things I (the agent) already did from Windows

- `ios/Runner/Info.plist` — added `UIBackgroundModes` (remote-notification,
  fetch) and `FirebaseAppDelegateProxyEnabled`.
- `ios/Runner/Runner.entitlements` — added Apple Pay, Push, App Attest,
  Sign in with Apple, plus universal link domains for `web.app` AND
  `www.pushkaapp.com`.
- `ios/Runner.xcodeproj/project.pbxproj` — wired `CODE_SIGN_ENTITLEMENTS`
  to point at `Runner/Runner.entitlements` for all 3 build configs
  (Debug, Release, Profile). Without this the entitlements above are
  ignored at sign time.
- `codemagic.yaml` — both workflows ready, with placeholder env-var
  bindings matching the groups defined in step 5c.
- `public/.well-known/apple-app-site-association` — already deployed
  (Firebase Hosting live), so universal link verification will pass for
  TestFlight builds.
- `lib/app/app_initializer.dart` — already had ATT prompt + iOS-aware
  App Check + Stripe merchant ID wiring. No code change needed.
- `lib/features/payments/stripe_service.dart` — already gates Apple Pay
  on `merchantIdentifier` being non-empty. No code change needed.

---

## Things still on you

Anything in steps 1-5 above. None of them require a Mac.

If you hit a snag, paste the Codemagic build log and I'll diagnose.
