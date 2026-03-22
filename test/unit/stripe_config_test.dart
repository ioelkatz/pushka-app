import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/config/stripe_config.dart';

void main() {
  group('StripeConfig', () {
    test('publishable key is not empty', () {
      expect(StripeConfig.publishableKey.isNotEmpty, true,
          reason: 'Stripe publishable key must be configured');
    });

    test('publishable key starts with pk_', () {
      expect(StripeConfig.publishableKey.startsWith('pk_'), true,
          reason: 'Stripe key should start with pk_test_ or pk_live_');
    });

    test('publishable key is not a secret key', () {
      expect(StripeConfig.publishableKey.startsWith('sk_'), false,
          reason: 'Never embed a Stripe secret key in the app');
    });

    test('merchant identifier is a string', () {
      expect(StripeConfig.merchantIdentifier, isA<String>());
    });
  });
}
