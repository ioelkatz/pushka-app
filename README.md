# Pushka

App de donaciones y tzedaka digital. Permite a los usuarios realizar donaciones, gestionar su billetera digital, y llevar un historial de sus contribuciones.

## Requisitos

- Flutter 3.x+
- Dart 3.x+
- Firebase CLI
- Node.js 18+ (para Cloud Functions)

## Setup

1. Clona el repositorio
2. Configura Firebase:
   `ash
   flutterfire configure --project=pushka-app-ioel
   `
3. Coloca `google-services.json` en `android/app/`
4. Corre la app:
   `ash
   flutter run --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_TU_CLAVE
   `

## Build de Release

### Android (APK)
`ash
flutter build apk --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_TU_CLAVE
`

### Android (App Bundle para Play Store)
`ash
flutter build appbundle --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_TU_CLAVE
`

### iOS
`ash
flutter build ios --dart-define=STRIPE_PUBLISHABLE_KEY=pk_live_TU_CLAVE
`

## Tests

`ash
flutter test
`

## Arquitectura

- `lib/features/` - Pantallas y logica por feature (pushka, wallet, auth, settings, etc.)
- `lib/config/` - Configuracion (Stripe, etc.)
- `functions/` - Firebase Cloud Functions (pagos, transferencias, webhooks)
- `firestore.rules` - Reglas de seguridad de Firestore
- `test/` - Tests unitarios y de integracion

## Tecnologias

- Flutter / Dart
- Firebase (Auth, Firestore, Cloud Functions, Crashlytics, Analytics)
- Stripe (pagos con tarjeta)
- Riverpod (state management)
