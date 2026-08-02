// Web-only WebStripe re-initialization with the connected account.
//
// Called from app.dart the first time we resolve the user's active
// tenantConnectAccountId — BEFORE the PaymentElement widget mounts. This
// avoids the flutter_stripe_web 7.6.0 gotcha where re-initializing after
// Elements are already cached leaves the widget bound to the stale Stripe.js
// instance (the one without stripeAccount), causing PaymentElement to look
// up the PaymentIntent on the platform account (where direct-charges PIs do
// not exist) and hang forever without firing onCardChanged.
//
// Idempotent: bails cheaply on repeat calls with the same accountId.

import 'package:flutter/foundation.dart';
import 'package:flutter_stripe_web/flutter_stripe_web.dart';

import '../../config/stripe_config.dart';

String? _lastAccountId;
Future<void>? _pending;

Future<void> initWebStripeForTenant(String? connectAccountId) async {
  final acct = (connectAccountId ?? '').trim();
  if (acct.isEmpty) return;
  if (StripeConfig.publishableKey.isEmpty) return;
  if (_lastAccountId == acct) return;

  // Coalesce concurrent calls (auth listener + tenantConfig listener fire in
  // quick succession) so we only re-init once per changed accountId.
  if (_pending != null) {
    await _pending;
    if (_lastAccountId == acct) return;
  }

  final completer = _pending = _doInit(acct);
  try {
    await completer;
    _lastAccountId = acct;
    if (kDebugMode) {
      debugPrint('WebStripe: re-initialized with stripeAccount=$acct');
    }
  } finally {
    _pending = null;
  }
}

Future<void> _doInit(String acct) async {
  await WebStripe.instance.initialise(
    publishableKey: StripeConfig.publishableKey,
    stripeAccountId: acct,
  );
}
