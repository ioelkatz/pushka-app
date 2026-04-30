# Pushka App — Workflow

This file is read by Claude (and by humans) on both dev machines. Conventions live here so both Claudes behave the same.

## Devs

- **Alan** (GitHub: `alankatz37931`) — works on branch `alan/dev`
- **Ioel** (GitHub: `ioelkatz`, repo owner) — works on branch `ioel/dev`

## Git workflow

- `dev` is the integration branch. **Never commit directly to `dev`** — protected, requires PR + 1 approval.
- Each dev works on their personal branch (`alan/dev`, `ioel/dev`) or on feature branches off it (`alan/feature-x`).
- Open a PR to `dev` when you want to share work. Auto-merge is enabled — once the other dev approves, GitHub merges automatically.
- Squash-merge only (cleaner history). Branches auto-delete after merge.
- Always `git pull --rebase origin dev` into your branch before opening a PR to avoid messy merge commits.

## Local environment (per dev)

These files are **gitignored** — each dev generates them locally and never commits them:

| File | How to get it |
|---|---|
| `lib/firebase_options.dart` | `flutterfire configure --project=pushka-app-ioel --platforms=android` |
| `android/app/google-services.json` | from the secrets bundle (ask Alan/Ioel) |
| `android/app/pushka-release-key.jks` | from the secrets bundle |
| `android/key.properties` | from the secrets bundle |
| `production.env` | from the secrets bundle |

## Build & run

Debug on a connected Android device:
```
flutter run -d <device-id> --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_...
```

The Stripe key is read at compile time via `String.fromEnvironment('STRIPE_PUBLISHABLE_KEY')` — without `--dart-define`, the app shows "Stripe no configurado".

## Tooling versions used

- Flutter 3.41.9 (stable)
- Dart 3.11.5
- JDK 17 (Microsoft OpenJDK)
- Android SDK Platform 35/36 + NDK 28.2.13676358 + CMake 3.22.1
- Firebase CLI 15.16.0 + flutterfire_cli 1.3.2

## For Claude (both Alans)

- Don't auto-resolve merge conflicts blindly — show them and let the dev decide.
- Don't `git push --force` to shared branches without explicit confirmation.
- Don't commit gitignored files even if asked vaguely; check the `.gitignore` first.
- If both devs are working in parallel: prefer narrow, focused commits so PRs are easier to review and conflict-free.
