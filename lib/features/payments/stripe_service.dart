import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// Records a non-fatal payment error to Crashlytics with rich context. The
/// flutter_stripe SDK and Cloud Functions throw exceptions that today only hit
/// `debugPrint` (logcat), so the first time a real donor's payment fails we'd
/// have no signal in Crashlytics. This routes every payment failure through
/// recordError with a tagged reason + structured information so post-launch
/// triage can grep by `payment:<op>` and pull the cid + amount + currency.
void _recordPaymentError(
  String op,
  Object error,
  StackTrace? stack, {
  required String cid,
  String? purpose,
  int? amountCents,
  String? currency,
  String? interval,
  String? extraCode,
}) {
  try {
    FirebaseCrashlytics.instance.recordError(
      error,
      stack,
      reason: 'payment:$op',
      information: [
        'cid=$cid',
        if (purpose != null) 'purpose=$purpose',
        if (interval != null) 'interval=$interval',
        if (amountCents != null) 'amountCents=$amountCents',
        if (currency != null) 'currency=$currency',
        if (extraCode != null) 'code=$extraCode',
      ],
      fatal: false,
    );
  } catch (_) {
    // Crashlytics itself failing must never tank the user-facing flow.
  }
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
    /// Optional tenant scope. When set, the pushka-empty lock release
    /// hits the same tenant that the createPaymentIntent CF locked —
    /// otherwise the CF falls back to the caller's active tenant, which
    /// may not be the right one for multi-tenant donors.
    String? tenantId,
    // Web: Payment Sheet nativo NO existe en flutter_stripe web (experimental).
    // Cuando llamen pay() desde PWA se debe redirigir a Stripe Checkout via
    // createCheckoutSession CF. Ese flow se implementa en el próximo commit.
    // Hasta entonces, tirar excepción clara en vez de crashear en runtime.
    // NOTA: guard is at top of method body below, no aquí en params.
    /// Optional designation/destination chosen by the donor (e.g. "Familias
    /// necesitadas", "Estudio de Torá"). Stamped onto the Stripe PaymentIntent
    /// metadata and persisted on the transaction so admin dashboards can
    /// break down donations by destination.
    String? donationReason,
    /// For purpose=='pushka_empty' only — the value the donor's pushka
    /// should be set to AFTER the charge confirms. The webhook (not the
    /// client) writes this to Firestore atomically with the transaction
    /// record. Defaults to 0 (full empty); pass a non-zero number for
    /// partial payments where the leftover stays in the pushka.
    double? pushkaAmountAfter,
  }) async {
    // Web (PWA): flutter_stripe web no tiene Payment Sheet, así que
    // delegamos a Stripe Checkout via createCheckoutSession CF. Después de
    // que Stripe procese el pago el user vuelve a success_url (o cancel_url
    // si abandona). Retorna el session ID como si fuese payment intent id
    // para mantener la signature del método.
    if (kIsWeb) {
      return _payWithCheckoutRedirect(
        amountCents: amountCents,
        currency: currency,
        purpose: purpose,
        donorMessage: donorMessage,
        donationReason: donationReason,
      );
    }
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
          if (donationReason != null && donationReason.isNotEmpty)
            'donationReason': donationReason,
          if (purpose == 'pushka_empty')
            'pushkaAmountAfter': pushkaAmountAfter ?? 0,
        });

    HttpsCallableResult result;
    try {
      result = await callOnce();
    } on FirebaseFunctionsException catch (e, st) {
      // Self-heal a stuck "manual" auto-empty lock: a prior attempt that
      // the donor cancelled (or that crashed mid-PaymentSheet) leaves
      // _autoEmptyChargeLockAt set on tenantState for up to 10 min. Without
      // this retry, the next 10 min of payment attempts all bounce with
      // "Tu Pushka se está vaciando automáticamente". Release the lock
      // server-side and try once more.
      if (e.code == 'aborted') {
        // Only release the pushka-empty lock when THIS attempt actually
        // took one (purpose='pushka_empty'). For 'donation' the CF never
        // set the lock, so releasing on the caller's active tenant is a
        // no-op at best and a stray write at worst.
        if (purpose == 'pushka_empty') {
          await _releaseManualPushkaEmptyLock(tenantId: tenantId);
        }
        try {
          result = await callOnce();
        } on FirebaseFunctionsException catch (e2, st2) {
          _recordPaymentError('pay/createPaymentIntent_retry', e2, st2,
              cid: cid, purpose: purpose, amountCents: amountCents,
              currency: currency, extraCode: e2.code);
          rethrow;
        } catch (e2, st2) {
          _recordPaymentError('pay/createPaymentIntent_retry_unknown', e2, st2,
              cid: cid, purpose: purpose, amountCents: amountCents, currency: currency);
          throw const StripeServiceException('network-error');
        }
      } else {
        _recordPaymentError('pay/createPaymentIntent', e, st,
            cid: cid, purpose: purpose, amountCents: amountCents,
            currency: currency, extraCode: e.code);
        rethrow;
      }
    } catch (e, st) {
      _recordPaymentError('pay/createPaymentIntent_unknown', e, st,
          cid: cid, purpose: purpose, amountCents: amountCents, currency: currency);
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
    } on StripeException catch (e, st) {
      // PaymentSheet failed or user dismissed. For purpose=='pushka_empty'
      // the CF claimed _autoEmptyChargeLockAt before returning the
      // clientSecret — we MUST proactively release it so the lock doesn't
      // persist for its full 10-min TTL, blocking every retry with
      // "Tu Pushka se está vaciando automáticamente". Best-effort: a
      // failure here just means the user waits the TTL.
      if (purpose == 'pushka_empty') {
        await _releaseManualPushkaEmptyLock(tenantId: tenantId);
      }
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        // User-initiated cancel — not an error worth Crashlytics noise.
        throw const StripeServiceException('canceled');
      }
      _recordPaymentError('pay/PaymentSheet', e, st,
          cid: cid, purpose: purpose, amountCents: amountCents,
          currency: currency, extraCode: code.name);
      throw StripeServiceException(code.name);
    } catch (e, st) {
      // Same lock-release for unexpected non-Stripe errors.
      if (purpose == 'pushka_empty') {
        await _releaseManualPushkaEmptyLock(tenantId: tenantId);
      }
      _recordPaymentError('pay/PaymentSheet_unknown', e, st,
          cid: cid, purpose: purpose, amountCents: amountCents, currency: currency);
      rethrow;
    }

    return _extractIdFromSecret(clientSecret, 'pi_');
  }

  /// Best-effort call to the server-side lock-release CF. `tenantId` is
  /// passed through so the CF can scope the lock clear to the right tenant
  /// (a donor who belongs to multiple tenants would otherwise release the
  /// wrong lock or a no-op lock on the caller's default tenant). Callers
  /// SHOULD pass the tenantId of the pushka they were charging; if omitted
  /// the CF falls back to the caller's active tenant.
  Future<void> _releaseManualPushkaEmptyLock({String? tenantId}) async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('releaseManualPushkaEmptyLock')
          .call({
        if (tenantId != null && tenantId.isNotEmpty) 'tenantId': tenantId,
      });
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
    /// See `pay()` — same role here for recurring donations. Stamped on the
    /// subscription metadata so every generated invoice's transaction inherits
    /// it in the webhook handler.
    String? donationReason,
    String merchantDisplayName = 'Pushka',
  }) async {
    // TODO(web): Monthly recurring donations require a native Payment
    // Sheet today. The caller (pushka_screen _FrequencyChip Monthly) MUST
    // hide the Monthly option on kIsWeb to avoid reaching this throw —
    // otherwise the donor picks Monthly and sees a scary error. Long-term:
    // implement recurring via Stripe Checkout Session (mode='subscription').
    if (kIsWeb) {
      throw const StripeServiceException('web_recurring_not_available');
    }
    final cid = _newCorrelationId();
    debugPrint('StripeService.subscribe[cid:$cid]: calling CF amount=$amountCents currency=$currency interval=$interval');
    final callable = FirebaseFunctions.instance
        .httpsCallable('createDonationSubscription');
    HttpsCallableResult result;
    try {
      result = await callable.call({
        'amount': amountCents,
        'currency': currency.toLowerCase(),
        'interval': interval,
        'correlationId': cid,
        if (donationReason != null && donationReason.isNotEmpty)
          'donationReason': donationReason,
        if (donorMessage != null && donorMessage.isNotEmpty)
          'donorMessage': donorMessage,
      });
    } on FirebaseFunctionsException catch (e, st) {
      debugPrint('StripeService.subscribe: CF error code=${e.code} message=${e.message}');
      _recordPaymentError('subscribe/createDonationSubscription', e, st,
          cid: cid, amountCents: amountCents, currency: currency,
          interval: interval, extraCode: e.code);
      rethrow;
    } catch (e, st) {
      debugPrint('StripeService.subscribe: network error $e');
      _recordPaymentError('subscribe/createDonationSubscription_unknown', e, st,
          cid: cid, amountCents: amountCents, currency: currency, interval: interval);
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
    } on StripeException catch (e, st) {
      // Translate StripeException → StripeServiceException so the caller's
      // 'canceled' short-circuit works uniformly (initPaymentSheet can
      // itself throw Canceled if the user dismisses an intermediate
      // wallet prompt before the sheet mounts).
      debugPrint('StripeService.subscribe: initPaymentSheet error code=${e.error.code} message=${e.error.message}');
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        throw const StripeServiceException('canceled');
      }
      _recordPaymentError('subscribe/initPaymentSheet', e, st,
          cid: cid, amountCents: amountCents, currency: currency,
          interval: interval, extraCode: code.name);
      throw StripeServiceException(code.name);
    }

    try {
      debugPrint('StripeService.subscribe: presenting PaymentSheet');
      await Stripe.instance.presentPaymentSheet();
      debugPrint('StripeService.subscribe: PaymentSheet completed');
    } on StripeException catch (e, st) {
      debugPrint('StripeService.subscribe: PaymentSheet error code=${e.error.code} message=${e.error.message} localized=${e.error.localizedMessage}');
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        throw const StripeServiceException('canceled');
      }
      _recordPaymentError('subscribe/PaymentSheet', e, st,
          cid: cid, amountCents: amountCents, currency: currency,
          interval: interval, extraCode: code.name);
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
    if (kIsWeb) {
      // Web: flutter_stripe's Payment Sheet is native-only. A proper fix
      // is a Stripe Checkout Session in setup mode (mode='setup') via a
      // new CF `createCheckoutSetupSession` — TODO. For now we surface a
      // friendlier code so the caller (SavedCardsScreen) can show the
      // exact workaround instead of a generic error.
      throw const StripeServiceException('web_add_card_not_available');
    }
    final cid = _newCorrelationId();
    final callable = FirebaseFunctions.instance.httpsCallable('createSetupIntent');
    HttpsCallableResult result;
    try {
      result = await callable.call({'correlationId': cid});
    } on FirebaseFunctionsException catch (e, st) {
      _recordPaymentError('setupCard/createSetupIntent', e, st,
          cid: cid, extraCode: e.code);
      rethrow;
    } catch (e, st) {
      _recordPaymentError('setupCard/createSetupIntent_unknown', e, st, cid: cid);
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
    } on StripeException catch (e, st) {
      final code = e.error.code;
      if (code == FailureCode.Canceled) {
        throw const StripeServiceException('canceled');
      }
      _recordPaymentError('setupCard/PaymentSheet', e, st,
          cid: cid, extraCode: code.name);
      throw StripeServiceException(code.name);
    }

    // Extract SetupIntent ID from client_secret (format: seti_xxx_secret_yyy)
    return _extractIdFromSecret(clientSecret, 'seti_');
  }

  /// Web-only: crea una Stripe Checkout Session server-side y redirige el
  /// browser a la URL de Stripe. El user completa el pago allí (Apple Pay web,
  /// card entry, 3DS, todo built-in) y Stripe redirige de vuelta a
  /// success_url (o cancel_url). Retorna el session ID.
  ///
  /// NO usar directamente — la llama pay() automáticamente cuando kIsWeb.
  Future<String> _payWithCheckoutRedirect({
    required int amountCents,
    required String currency,
    required String purpose,
    String? donorMessage,
    String? donationReason,
  }) async {
    final cid = _newCorrelationId();
    debugPrint('StripeService._payWithCheckoutRedirect[cid:$cid]: creating session '
        'amount=$amountCents currency=$currency purpose=$purpose');
    final callable = FirebaseFunctions.instance.httpsCallable(
      'createCheckoutSession',
    );
    // Anchor Stripe's success/cancel redirects to the ORIGIN the PWA is
    // being served from (pushkapp.cc, pushka-pwa.web.app, pushka-app-ioel[-test].web.app).
    // Without this the CF falls back to a hardcoded default that may not match
    // the origin the donor is using, breaking the return trip. The CF still
    // validates the origin against a whitelist server-side.
    final origin = kIsWeb ? Uri.base.origin : null;
    HttpsCallableResult result;
    try {
      result = await callable.call({
        'amount': amountCents,
        'currency': currency.toLowerCase(),
        'purpose': purpose,
        'correlationId': cid,
        if (donationReason != null && donationReason.isNotEmpty)
          'donationReason': donationReason,
        if (donorMessage != null && donorMessage.isNotEmpty)
          'donorMessage': donorMessage,
        if (origin != null) 'successUrl': '$origin/donation-success?session_id={CHECKOUT_SESSION_ID}',
        if (origin != null) 'cancelUrl': '$origin/donation-cancel',
      });
    } catch (e, st) {
      _recordPaymentError('createCheckoutSession', e, st,
          cid: cid, purpose: purpose, amountCents: amountCents, currency: currency);
      throw const StripeServiceException('checkout_session_failed');
    }
    final data = Map<String, dynamic>.from(result.data as Map);
    final url = (data['url'] as String? ?? '');
    final sessionId = data['sessionId'] as String? ?? '';
    if (url.isEmpty || sessionId.isEmpty) {
      throw const StripeServiceException('checkout_session_invalid_response');
    }
    debugPrint('StripeService._payWithCheckoutRedirect[cid:$cid]: redirecting to '
        '$sessionId');
    // launchUrl con webOnlyWindowName '_self' → same-tab redirect en web,
    // que es lo que Stripe Checkout espera (para poder navegar back a
    // success/cancel URLs sin abrir tabs nuevas).
    final launched = await launchUrl(
      Uri.parse(url),
      webOnlyWindowName: '_self',
    );
    if (!launched) {
      throw const StripeServiceException('checkout_redirect_failed');
    }
    // Esta línea probablemente nunca se alcanza — el browser ya navegó a
    // Stripe Checkout. Pero por si el redirect falla silently, retornamos
    // el sessionId para que el caller no se cuelgue esperando un future
    // que nunca resuelve.
    return sessionId;
  }
}
