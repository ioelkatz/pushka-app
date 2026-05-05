import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import '../../config/stripe_config.dart';
import '../../firebase_options.dart';

class StripeServiceException implements Exception {
  final String code;
  const StripeServiceException(this.code);
}

class StripeService {
  StripeService._();

  static final StripeService instance = StripeService._();

  // Wallet config builders (Apple Pay + Google Pay).
  //
  // merchantCountryCode is the country of the PLATFORM Stripe account that
  // creates the PaymentIntent (we use Stripe Connect destination_charge —
  // the platform is the merchant of record for the wallet handshake, not the
  // tenant). Hardcoded to 'US' since this app's platform Stripe account is
  // US-incorporated; revisit if the platform ever moves jurisdictions.
  //
  // Apple Pay: needs the merchantIdentifier configured in iOS via
  // Stripe.merchantIdentifier (see main.dart) AND the Apple Pay capability
  // enabled in the iOS project. Without those, Stripe silently does not
  // surface the Apple Pay button — passing this config is harmless.
  //
  // Google Pay: testEnv must be true on dev builds to hit Google's test PSP
  // sandbox; false on production. Stripe rejects mixing prod testEnv with
  // a pk_test_ key (and vice versa).
  static const _platformCountryCode = 'US';

  // Apple Pay config is gated on having a non-empty Stripe merchantIdentifier
  // configured (passed via dart-define + applied to Stripe.merchantIdentifier
  // in app_initializer). The Stripe SDK throws an assertion if applePay is
  // present without merchantIdentifier set — passing null skips the wallet
  // entirely on platforms / builds where it's not configured.
  static PaymentSheetApplePay? get _applePayConfig =>
      StripeConfig.merchantIdentifier.isEmpty
          ? null
          : const PaymentSheetApplePay(merchantCountryCode: _platformCountryCode);

  static PaymentSheetGooglePay _googlePayConfigFor(String currency) =>
      PaymentSheetGooglePay(
        merchantCountryCode: _platformCountryCode,
        currencyCode: currency.toUpperCase(),
        testEnv: DefaultFirebaseOptions.isDev,
      );

  Future<String> pay({
    required int amountCents,
    required String currency,
    String? customerEmail,
    String purpose = 'donation',
    String merchantDisplayName = 'Pushka',
    String? donorMessage,
  }) async {
    final sw = Stopwatch()..start();
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
        if (donorMessage != null && donorMessage.isNotEmpty)
          'donorMessage': donorMessage,
      });
    } on FirebaseFunctionsException {
      rethrow;
    } catch (_) {
      throw const StripeServiceException('network-error');
    }
    debugPrint('StripeService.pay: createPaymentIntent CF returned in ${sw.elapsedMilliseconds}ms');
    sw.reset();

    final clientSecret = result.data['clientSecret'] as String?;
    if (clientSecret == null || clientSecret.isEmpty) {
      throw const StripeServiceException('no-client-secret');
    }

    // customerId + (customerSessionClientSecret OR ephemeralKeySecret)
    // unlock the saved-card list inside PaymentSheet. Prefer Customer
    // Sessions (the new Stripe API) when present — the legacy ephemeralKey
    // path was observed to silently filter out some saved cards (a user
    // with Visa default + MC only saw MC in the picker). Sessions declare
    // explicit feature flags (save/remove/redisplay) so the SDK shows
    // every PaymentMethod the customer has attached. EphemeralKey is kept
    // as fallback for transient session-creation failures.
    final customerId = result.data['customerId'] as String?;
    final customerSessionClientSecret =
        result.data['customerSessionClientSecret'] as String?;
    final ephemeralKeySecret = result.data['ephemeralKeySecret'] as String?;
    final hasCustomerContext = customerId != null && customerId.isNotEmpty;

    await Stripe.instance.initPaymentSheet(
      paymentSheetParameters: SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: merchantDisplayName,
        allowsDelayedPaymentMethods: false,
        customerId: hasCustomerContext ? customerId : null,
        customerSessionClientSecret: hasCustomerContext
            ? customerSessionClientSecret
            : null,
        customerEphemeralKeySecret: hasCustomerContext &&
                (customerSessionClientSecret == null ||
                    customerSessionClientSecret.isEmpty)
            ? ephemeralKeySecret
            : null,
        applePay: _applePayConfig,
        googlePay: _googlePayConfigFor(currency),
      ),
    );
    debugPrint('StripeService.pay: initPaymentSheet returned in ${sw.elapsedMilliseconds}ms');
    sw.reset();

    try {
      await Stripe.instance.presentPaymentSheet();
      debugPrint('StripeService.pay: presentPaymentSheet returned (user closed/paid) in ${sw.elapsedMilliseconds}ms');
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
  Future<String> setupCard({String merchantDisplayName = 'Pushka'}) async {
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
        merchantDisplayName: merchantDisplayName,
        allowsDelayedPaymentMethods: false,
        // Suppress wallets entirely on the SAVE-CARD flow:
        //   - applePay/googlePay configs omitted (no wallet auth save here)
        //   - Link disabled via linkDisplay: never (otherwise Stripe surfaces
        //     a "Pay with Link" CTA at the Account level even when the
        //     SetupIntent declares payment_method_types: ['card'] —
        //     paymentMethodOrder is just ordering, not an allowlist)
        // Result: the sheet shows only the card form when the user taps
        // "Agregar tarjeta", matching the user's intent (save, not pay).
        linkDisplayParams: const LinkDisplayParams(
          linkDisplay: LinkDisplay.never,
        ),
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
