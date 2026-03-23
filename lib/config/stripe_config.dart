class StripeConfig {
  const StripeConfig._();
  static const String publishableKey = 'pk_live_51SXSpGKA0soz9iBR0AFEM9LtvNQHu44wyvztkcQzJHKCRlozAnJmQJMPeUEuD2AAOb160pNwYZO3CFJMJaWTIBM000EbTNZ64C';
  static const String merchantIdentifier = String.fromEnvironment('STRIPE_MERCHANT_ID', defaultValue: '');
}