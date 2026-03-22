import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

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
    } on FirebaseFunctionsException catch (error) {
      debugPrint('[StripeService] Firebase function error: ${error.code} - ${error.message}');
      rethrow;
    }

    final clientSecret = result.data['clientSecret'] as String?;
    if (clientSecret == null || clientSecret.isEmpty) {
      throw Exception('No se pudo iniciar el pago');
    }

    debugPrint('[StripeService] PaymentIntent created, initializing sheet...');

    await Stripe.instance.initPaymentSheet(
      paymentSheetParameters: SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: 'Pushka',
        allowsDelayedPaymentMethods: false,
      ),
    );

    debugPrint('[StripeService] Sheet initialized, presenting...');

    await Stripe.instance.presentPaymentSheet();

    debugPrint('[StripeService] Payment completed successfully');

    const separator = '_secret_';
    final index = clientSecret.indexOf(separator);
    if (index <= 0) {
      throw Exception('No se pudo identificar el pago');
    }
    return clientSecret.substring(0, index);
  }
}
