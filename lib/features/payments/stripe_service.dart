import 'package:cloud_functions/cloud_functions.dart';
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
      final message = switch (error.code) {
        'unauthenticated' =>
          'Tu sesión no es válida o falta App Check. Cierra sesión e inicia de nuevo.',
        'failed-precondition' =>
          'App Check no está configurado en este proyecto. Actívalo en Firebase Console.',
        'permission-denied' =>
          'Acceso denegado por seguridad. Verifica App Check y vuelve a intentar.',
        _ => error.message ?? 'No se pudo iniciar el pago',
      };
      throw Exception(message);
    }

    final clientSecret = result.data['clientSecret'] as String?;
    if (clientSecret == null || clientSecret.isEmpty) {
      throw Exception('No se pudo iniciar el pago');
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
      throw Exception('No se pudo identificar el pago');
    }
    return clientSecret.substring(0, index);
  }
}
