import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import '../../config/stripe_config.dart';
import '../../firebase_options.dart';

/// 16-char hex correlation ID — generated client-side at the start of a
/// payment flow and threaded through createPaymentIntent → Stripe metadata
/// → webhook → Firestore tx doc. Lets ops trace a single donation across
/// every layer in Cloud Logging by grepping `[cid:abcd1234ef567890]`.
String _newCorrelationId() {
  final r = Random.secure();
  final bytes = List<int>.generate(8, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

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
    /// For purpose=='pushka_empty' only — the value the donor's pushka
    /// should be set to AFTER the charge confirms. The webhook (not the
    /// client) writes this to Firestore atomically with the transaction
    /// record. Defaults to 0 (full empty); pass a non-zero number for
    /// partial payments where the leftover stays in the pushka.
    double? pushkaAmountAfter,
  }) async {
    final sw = Stopwatch()..start();
    final cid = _newCorrelationId();
    final callable = FirebaseFunctions.instance.httpsCallable(
      'createPaymentIntent',
    );
    Future<HttpsCallableResult> callOnce() => callable.call({
          'amount': amountCents,
          'currency': currency.toLowerCase(),
          'customerEmail': customerEmail,
          'purpose': purpose,
          'correlationId': cid,
          if (donorMessage != null && donorMessage.isNotEmpty)
            'donorMessage': donorMessage,
          if (purpose == 'pushka_empty')
            'pushkaAmountAfter': pushkaAmountAfter ?? 0,
        });

    HttpsCallableResult result;
    try {
      result = await callOnce();
    } on FirebaseFunctionsException catch (e) {
      // Self-heal a stuck "manual" auto-empty lock: a prior attempt that
      // the donor cancelled (or that crashed mid-PaymentSheet) leaves
      // _autoEmptyChargeLockAt set on tenantState for up to 10 min. Without
      // this retry, the next 10 min of payment attempts all bounce with
      // "Tu Pushka se está vaciando automáticamente". Release the lock
      // server-side and try once more.
      if (e.code == 'aborted') {
        await _releaseManualPushkaEmptyLock();
        try {
          result = await callOnce();
        } on FirebaseFunctionsException {
          rethrow;
        } catch (_) {
          throw const StripeServiceException('network-error');
        }
      } else {
        rethrow;
      }
    } catch (_) {
      throw const StripeServiceException('network-error');
    }
    debugPrint('StripeService.pay[cid:$cid]: createPaymentIntent CF returned in ${sw.elapsedMilliseconds}ms');
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

    // flutter_stripe v12 requires that if customerId is set, at least one auth
    // mechanism (customerSessionClientSecret OR customerEphemeralKeySecret)
    // must also be non-null. If both auth tokens fail server-side, drop the
    // customerId entirely so the sheet still opens (just without saved cards).
    final hasSessionAuth = customerSessionClientSecret != null && customerSessionClientSecret.isNotEmpty;
    final hasEphemeralAuth = ephemeralKeySecret != null && ephemeralKeySecret.isNotEmpty;
    final hasCustomerContext = customerId != null && customerId.isNotEmpty && (hasSessionAuth || hasEphemeralAuth);

    try {
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: merchantDisplayName,
          allowsDelayedPaymentMethods: false,
          customerId: hasCustomerContext ? customerId : null,
          customerSessionClientSecret: hasCustomerContext && hasSessionAuth ? customerSessionClientSecret : null,
          customerEphemeralKeySecret: hasCustomerContext && !hasSessionAuth ? ephemeralKeySecret : null,
          applePay: _applePayConfig,
          googlePay: _googlePayConfigFor(currency),
        ),
      );
      debugPrint('StripeService.pay: initPaymentSheet returned in ${sw.elapsedMilliseconds}ms');
      sw.reset();

      await Stripe.instance.presentPaymentSheet();
      debugPrint('StripeService.pay: presentPaymentSheet returned (user closed/paid) in ${sw.elapsedMilliseconds}ms');
    } on StripeException catch (e) {
      // PaymentSheet failed or user dismissed. For purpose=='pushka_empty'
      // the CF claimed _autoEmptyChargeLockAt before returning the
      // clientSecret — we MUST proactively release it so the lock doesn't
      // persist for its full 10-min TTL, blocking every retry with
      // "Tu Pushka se está vaciando automáticamente". Best-effort: a
      // failure here just means the user waits the TTL.
      if (purpose == 'pushka_empty') {
        await _releaseManualPushkaEmptyLock();
      }
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        throw const StripeServiceException('canceled');
      }
      throw StripeServiceException(code.name);
    } catch (_) {
      // Same lock-release for unexpected non-Stripe errors.
      if (purpose == 'pushka_empty') {
        await _releaseManualPushkaEmptyLock();
      }
      rethrow;
    }

    return _extractIdFromSecret(clientSecret, 'pi_');
  }

  Future<void> _releaseManualPushkaEmptyLock() async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('releaseManualPushkaEmptyLock')
          .call({});
    } catch (e) {
      debugPrint('StripeService.pay: lock release failed (non-fatal): $e');
    }
  }

  /// Creates a Stripe Subscription for a recurring donation and confirms
  /// the first invoice via PaymentSheet. Subsequent charges run off-session
  /// against the saved default payment method (the Stripe webhook
  /// `invoice.payment_succeeded` writes each transaction record).
  ///
  /// Returns the subscription ID. Throws [StripeServiceException]('canceled')
  /// when the user dismisses the sheet.
  Future<String> subscribe({
    required int amountCents,
    required String currency,
    String interval = 'month',
    String? donorMessage,
    String merchantDisplayName = 'Pushka',
  }) async {
    debugPrint('StripeService.subscribe: calling CF amount=$amountCents currency=$currency interval=$interval');
    final callable = FirebaseFunctions.instance
        .httpsCallable('createDonationSubscription');
    HttpsCallableResult result;
    try {
      result = await callable.call({
        'amount': amountCents,
        'currency': currency.toLowerCase(),
        'interval': interval,
        if (donorMessage != null && donorMessage.isNotEmpty)
          'donorMessage': donorMessage,
      });
    } on FirebaseFunctionsException catch (e) {
      debugPrint('StripeService.subscribe: CF error code=${e.code} message=${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('StripeService.subscribe: network error $e');
      throw const StripeServiceException('network-error');
    }
    debugPrint('StripeService.subscribe: CF returned, initing PaymentSheet');

    final clientSecret = result.data['clientSecret'] as String?;
    final customerId = result.data['customerId'] as String?;
    final ephemeralKeySecret = result.data['ephemeralKeySecret'] as String?;
    final customerSessionClientSecret = result.data['customerSessionClientSecret'] as String?;
    final subscriptionId = result.data['subscriptionId'] as String?;
    if (clientSecret == null || clientSecret.isEmpty) {
      throw const StripeServiceException('no-client-secret');
    }

    // flutter_stripe v12 requires that if customerId is set, at least one auth
    // mechanism (customerSessionClientSecret OR customerEphemeralKeySecret) must
    // also be non-null. Prefer CustomerSession (modern) over ephemeral key.
    final hasSessionAuth = customerSessionClientSecret != null && customerSessionClientSecret.isNotEmpty;
    final hasEphemeralAuth = ephemeralKeySecret != null && ephemeralKeySecret.isNotEmpty;
    final hasCustomerContext = customerId != null && customerId.isNotEmpty && (hasSessionAuth || hasEphemeralAuth);

    await Stripe.instance.initPaymentSheet(
      paymentSheetParameters: SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: merchantDisplayName,
        allowsDelayedPaymentMethods: false,
        customerId: hasCustomerContext ? customerId : null,
        customerSessionClientSecret: hasCustomerContext && hasSessionAuth ? customerSessionClientSecret : null,
        customerEphemeralKeySecret: hasCustomerContext && !hasSessionAuth ? ephemeralKeySecret : null,
        applePay: _applePayConfig,
        googlePay: _googlePayConfigFor(currency),
      ),
    );

    try {
      debugPrint('StripeService.subscribe: presenting PaymentSheet');
      await Stripe.instance.presentPaymentSheet();
      debugPrint('StripeService.subscribe: PaymentSheet completed');
    } on StripeException catch (e) {
      debugPrint('StripeService.subscribe: PaymentSheet error code=${e.error.code} message=${e.error.message} localized=${e.error.localizedMessage}');
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        throw const StripeServiceException('canceled');
      }
      throw StripeServiceException(code.name);
    }

    return subscriptionId ?? '';
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
