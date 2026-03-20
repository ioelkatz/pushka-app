class StripeConfig {
  const StripeConfig._();
  static const String publishableKey = String.fromEnvironment('STRIPE_PUBLISHABLE_KEY', defaultValue: '');
  static const String merchantIdentifier = String.fromEnvironment('STRIPE_MERCHANT_ID', defaultValue: '');
}
