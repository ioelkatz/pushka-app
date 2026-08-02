// Non-web stub. Native (Android/iOS) builds pick this file up via the
// conditional import in stripe_web_bootstrap.dart. flutter_stripe handles
// stripeAccountId via Stripe.stripeAccountId setter in-flow (see
// stripe_service.dart pay()); no bootstrap needed on native.

Future<void> initWebStripeForTenant(String? connectAccountId) async {
  // No-op on native.
}
