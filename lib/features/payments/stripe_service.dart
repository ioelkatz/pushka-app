import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

class StripeServiceException implements Exception {
  final String code;
  const StripeServiceException(this.code);
}

class StripeService {
  StripeService._();

  static final StripeService instance = StripeService._();

  Future<String> pay({
    required int amountCents,
    required String currency,
    String? customerEmail,
    String purpose = 'donation',
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'createPaymentIntent',
    );
    HttpsCallableResult result;
    try {
      result = await callable.call({
        'amount': amountCents,
        'currency': currency.toLowerCase(),
        'customerEmail': customerEmail,
        'purpose': purpose,
      });
    } on FirebaseFunctionsException {
      rethrow;
    }

    final clientSecret = result.data['clientSecret'] as String?;
    if (clientSecret == null || clientSecret.isEmpty) {
      throw const StripeServiceException('no-client-secret');
    }

    await Stripe.instance.initPaymentSheet(
      paymentSheetParameters: SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: 'Pushka',
        allowsDelayedPaymentMethods: false,
      ),
    );

    await Stripe.instance.presentPaymentSheet();

    const separator = '_secret_';
    final index = clientSecret.indexOf(separator);
    if (index <= 0) {
      throw const StripeServiceException('no-payment-id');
    }
    return clientSecret.substring(0, index);
  }
}
