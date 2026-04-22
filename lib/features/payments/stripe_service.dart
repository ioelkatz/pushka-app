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
    } catch (_) {
      throw const StripeServiceException('network-error');
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

    try {
      await Stripe.instance.presentPaymentSheet();
    } on StripeException catch (e) {
      // Convert StripeException to a typed exception so callers can distinguish
      // a user-initiated cancel from a genuine payment failure.
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        throw const StripeServiceException('canceled');
      }
      throw StripeServiceException(code.name);
    }

    return _extractIdFromSecret(clientSecret, 'pi_');
  }

  static String _extractIdFromSecret(String clientSecret, String expectedPrefix) {
    const separator = '_secret_';
    final index = clientSecret.indexOf(separator);
    if (index <= 0) throw const StripeServiceException('no-id');
    final id = clientSecret.substring(0, index);
    if (!id.startsWith(expectedPrefix)) throw const StripeServiceException('invalid-id');
    return id;
  }

  /// Opens the Stripe SetupIntent sheet so the user can save a card for
  /// future off-session charges. Returns the SetupIntent ID on success.
  Future<String> setupCard() async {
    final callable = FirebaseFunctions.instance.httpsCallable('createSetupIntent');
    HttpsCallableResult result;
    try {
      result = await callable.call({});
    } on FirebaseFunctionsException {
      rethrow;
    } catch (_) {
      throw const StripeServiceException('network-error');
    }

    final clientSecret = result.data['clientSecret'] as String?;
    if (clientSecret == null || clientSecret.isEmpty) {
      throw const StripeServiceException('no-client-secret');
    }

    await Stripe.instance.initPaymentSheet(
      paymentSheetParameters: SetupPaymentSheetParameters(
        setupIntentClientSecret: clientSecret,
        merchantDisplayName: 'Pushka',
        allowsDelayedPaymentMethods: false,
      ),
    );

    try {
      await Stripe.instance.presentPaymentSheet();
    } on StripeException catch (e) {
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        throw const StripeServiceException('canceled');
      }
      throw StripeServiceException(code.name);
    }

    // Extract SetupIntent ID from client_secret (format: seti_xxx_secret_yyy)
    return _extractIdFromSecret(clientSecret, 'seti_');
  }
}
