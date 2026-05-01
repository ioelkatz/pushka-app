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

# Production
flutter build appbundle --flavor prod --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_...
```

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
| Env file | `production.env` | from secrets bundle (Stripe live key reference) |
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

Secrets are scoped per project (`firebase functions:secrets:set <NAME> --project <PROJECT_ID>`). Currently set in dev: `STRIPE_SECRET_KEY` (real test key), `STRIPE_WEBHOOK_SECRET`, `STRIPE_BILLING_WEBHOOK_SECRET`, `STRIPE_CONNECT_CLIENT_ID`, `SENDGRID_API_KEY` (placeholders — set real test values when testing those flows).

## Tooling versions

- Flutter 3.41.9 (stable) / Dart 3.11.5
- JDK 17 (Microsoft OpenJDK)
- Android SDK Platform 35/36 + NDK 28.2.13676358 + CMake 3.22.1
- Firebase CLI 15.16.0 / flutterfire_cli 1.3.2

## For Claude (both Alans)

- Don't auto-resolve merge conflicts blindly — show them and let the dev decide.
- Don't `git push --force` to shared branches without explicit confirmation.
- Don't commit gitignored files even if asked vaguely; check the `.gitignore` first.
- Default to `--flavor dev` when running locally — never test against prod backend with real card data unless explicitly asked.
- For payment flow tests: always use `pk_test_...` + Stripe test cards (`4242...`).
- If both devs are working in parallel: prefer narrow, focused commits so PRs are easier to review and conflict-free.
