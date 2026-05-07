# iOS sideload via AltStore — UI-only smoke test (no Apple Developer Program)

This runbook gets a debug build of Pushka onto your iPhone via AltStore +
your free Apple ID. **No $99/yr Apple Developer Program, no Mac.** It's
limited to UI / navigation / non-payment flows because Apple's free signing
tier strips entitlements that paid features depend on (Apple Pay, Push
Notifications, paid-tier Google Sign-In OAuth).

If you later upgrade to the paid program, switch to the TestFlight path in
[`ios_setup.md`](./ios_setup.md) — same source tree, different Codemagic
workflow.

---

## What works / doesn't on this path

| Feature | Works on AltStore? | Why |
|---|---|---|
| UI, navigation, settings | ✅ | No entitlements needed |
| Auth — email/password | ✅ | Firebase Auth, no native plugin |
| Auth — **Apple Sign-In** | ✅ | Free Apple ID supports it |
| Auth — **Google Sign-In** | ❌ | OAuth callback URL scheme stripped at re-sign |
| Firestore reads / writes | ✅ | Pure HTTP |
| Cloud Functions calls | ✅ if App Check debug token registered | Debug provider works |
| Donations via credit-card form | ✅ | Stripe SDK, no entitlement needed |
| Donations via **Apple Pay** | ❌ | Needs merchant ID (paid program only) |
| Push notifications | ❌ | Needs APNs cert (paid program only) |
| App Attest (production) | ❌ → falls back to debug provider | Free Apple ID can't attest |
| Universal Links | ⚠️ partial | Domain check works, but provisioning profile may strip |

> The **debug build** also enables verbose logs + slower performance vs
> a release build. That's intentional — debug build = debug App Check
> provider (the only App Check path that works without paid program).

---

## Prerequisites (all $0)

- [ ] An Apple ID (the same one you use on the iPhone). Free.
- [ ] iPhone running iOS 13+, with the **TestFlight** app NOT needed (we use AltStore instead).
- [ ] Windows 10/11 PC with USB cable to the iPhone.
- [ ] iTunes (Microsoft Store version) + iCloud for Windows. AltServer
      depends on iTunes' Apple Mobile Device Service to talk to the phone.
- [ ] A Codemagic account (free tier, signs up with GitHub).

---

## 1. Generate `firebase_options_{dev,prod}.dart` locally

Same as in the TestFlight runbook — `flutterfire configure` runs on
Windows. You only need the **dev** project for AltStore testing, but
both files must exist because the source tree imports both:

```bash
dart pub global activate flutterfire_cli

flutterfire configure --project=pushka-app-ioel-test \
  --platforms=ios,android \
  --ios-bundle-id=com.pushka.app \
  --out=lib/firebase_options_dev.dart --yes
# Open the file and rename: class DefaultFirebaseOptions → class DevFirebaseOptions

flutterfire configure --project=pushka-app-ioel \
  --platforms=ios,android \
  --ios-bundle-id=com.pushka.app \
  --out=lib/firebase_options_prod.dart --yes
# Same rename: class DefaultFirebaseOptions → class ProdFirebaseOptions
```

> Even though we only target the dev project for AltStore, the prod file
> must exist because `lib/firebase_options.dart` imports it
> unconditionally. Generating it from the prod project is a one-line
> command — just do it.

---

## 2. Register the iOS app in Firebase (dev project only)

For AltStore testing, only the **test** project matters. Register the iOS
app there so `flutterfire configure` can pick it up + so App Check can
accept debug tokens for it.

1. Firebase Console → `pushka-app-ioel-test` → ⚙️ → Your apps → Add app → iOS
2. Bundle ID: `com.pushka.app`
3. Skip the SDK steps (FlutterFire handles them)
4. Download `GoogleService-Info.plist` (this is a different file than the
   Android one)
5. App Check section → register the iOS app, set DeviceCheck/App Attest
   as the providers (we won't use them but Firebase requires them set).

---

## 3. Codemagic — connect repo + env vars

### 3a. Add the app

1. https://codemagic.io → Sign in with GitHub.
2. **Add application** → pick `ioelkatz/pushka-app`.
3. Codemagic auto-detects `codemagic.yaml`. Three workflows show up;
   we'll use `ios-altstore-debug` only.

### 3b. Skip the App Store Connect integration

The TestFlight workflows need it; AltStore does not. Just don't touch
**Teams → Integrations → Apple Developer Portal** for now.

### 3c. Set env-var group `pushka_dev_secrets`

App settings → Environment variables → group **`pushka_dev_secrets`**:

| Variable | Value | Secure |
|---|---|---|
| `STRIPE_PUBLISHABLE_KEY` | `pk_test_…` from your Stripe test dashboard | yes |
| `GOOGLE_SERVICE_INFO_PLIST_B64` | base64 of the test project's `GoogleService-Info.plist` | yes |
| `FIREBASE_OPTIONS_DEV_DART_B64` | base64 of `lib/firebase_options_dev.dart` | yes |
| `FIREBASE_OPTIONS_PROD_DART_B64` | base64 of `lib/firebase_options_prod.dart` | yes |

To base64 a file on Windows:
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("lib\firebase_options_dev.dart")) | Out-File -Encoding ASCII -NoNewline dev_b64.txt
```

> `STRIPE_MERCHANT_ID` is intentionally NOT set on this path — without
> it, Apple Pay self-disables and the Stripe sheet falls back to credit
> card only.

---

## 4. Build the unsigned IPA

1. Codemagic → workflows → **`ios-altstore-debug`** → **Start build**.
2. ~12-15 minutes. Watch the log.
3. On success: build page → **Artifacts** → download the `.ipa`.

---

## 5. AltStore on Windows — install AltServer

1. Download AltServer for Windows: https://altstore.io
2. Install iTunes (Microsoft Store version) and iCloud for Windows if
   you don't already have them. **Do not** use the older "iTunes from
   Apple's website" version — AltServer doesn't recognize it.
3. Run AltServer. It lives in your system tray.
4. Connect your iPhone via USB. Tap "Trust This Computer" on the phone.

---

## 6. Install AltStore on the iPhone (one time)

1. AltServer tray icon → "Install AltStore" → pick your iPhone.
2. Sign in with your **Apple ID** (the same one you use on the phone).
   AltServer issues a free 7-day provisioning profile bound to it.
3. iPhone → Settings → General → VPN & Device Management → trust the
   developer certificate Apple just issued in your name.
4. AltStore is now an app on your iPhone.

> **Free Apple ID limit**: 3 different bundle IDs per 7 days. Pushka uses
> 1 (`com.pushka.app`), so you have 2 left for other sideloaded apps.

---

## 7. Sideload Pushka

1. With iPhone still connected via USB, drag the `.ipa` from step 4
   onto the **AltStore** icon in your Mac's…
   …wait, you're on Windows — drag it onto the AltServer tray icon, OR
   open AltStore on the iPhone and tap "+", browse to the IPA on your
   network share, and pick it.
2. Enter your Apple ID password again. AltStore re-signs the IPA with
   your free provisioning profile.
3. Pushka shows up on the home screen.

---

## 8. Register the App Check debug token

The debug build prints an App Check debug token to the console once on
first launch. Without registering it, every Cloud Functions call gets
rejected with `failed-precondition: App Check token invalid`.

1. Open the app on the iPhone (debug build → token printed to OS log).
2. Capture the token by either:
   - Using a Mac to read iOS device logs via Xcode Console (not
     available on Windows), OR
   - **Easier**: in Firebase Console → `pushka-app-ioel-test` → App
     Check → the iOS app → ⋮ → "Manage debug tokens" → "Add debug
     token" → name it "alan-iphone" → leave token field blank → Save
     → it generates a token → copy it → put it in the iOS app's first
     run by re-signing with that env var…
   - Easiest in practice: use the **same** debug token that's already
     registered for your Android device. Override the auto-generated
     token via `iOS UserDefaults` — but that's harder than just adding
     a fresh one above. The Firebase Console "Add debug token" path is
     the canonical way.

> If App Check isn't a blocker for the flows you want to test (eg.
> raw Firestore reads via the SDK), the app will still work — just not
> the Cloud Functions calls.

---

## 9. Smoke test (what to actually try)

Re-do the Android test cycle, MINUS payment flows:

- [ ] **Sign in** via email/password (or Apple Sign-In if Auth is configured for it).
- [ ] **Tenant join** with a test slug from `pushka-app-ioel-test`.
- [ ] **Settings → Mis donaciones recurrentes** — list loads (calls CF, requires App Check token).
- [ ] **Donate** — open the sheet, complete with the credit-card form. **Skip Apple Pay (won't work).**
- [ ] **Settings → Vaciar Pushka** flow.
- [ ] **Auto-empty config** — change frequency, change pinned card, see Firestore stream update.
- [ ] **History** — list loads.
- [ ] **Profile** — upload a photo, change settings.

---

## 10. Re-sign every 7 days

The free provisioning profile expires after 7 days. AltServer can
auto-refresh:

- AltServer tray → preferences → enable "Refresh apps in the background"
- Keep AltServer running on Windows + iPhone on the same Wi-Fi network
- Refresh happens automatically; if it doesn't, manually open AltStore
  on the phone → My Apps → tap refresh next to Pushka.

> If iTunes shuts down or reboots happen, re-trust + re-pair via USB.

---

## When this stops being enough

If you need to test:
- Apple Pay → upgrade to TestFlight ($99/yr Apple Developer)
- Push notifications → ditto
- Distribution to other people → ditto

The Codemagic workflow `ios-testflight-dev` is already set up for that
path; see [`ios_setup.md`](./ios_setup.md) once you're ready to upgrade.
