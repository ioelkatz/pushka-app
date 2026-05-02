import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import '../features/notifications/notification_service.dart';
import '../features/deep_links/deep_link_service.dart';
import '../config/stripe_config.dart';
import '../features/feedback/feedback_service.dart';
import 'router.dart' show initNotificationNavigation;

/// Deferred initialization future — started in main(), awaited in splash.
late final Future<void> appDeferredInit;

void scheduleDeferredInit() {
  appDeferredInit = _performDeferredInit();
}

Future<void> _performDeferredInit() async {
  if (kIsWeb) {
    await FirebaseAppCheck.instance.activate(
      webProvider: ReCaptchaV3Provider(
        const String.fromEnvironment('RECAPTCHA_SITE_KEY', defaultValue: ''),
      ),
    );
  } else if (kReleaseMode) {
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.playIntegrity,
      appleProvider: AppleProvider.deviceCheck,
    );
  } else {
    // Debug builds: backend enforces App Check, so we need the debug provider
    // here too. The token is printed to logcat on first launch — register it
    // at Firebase Console → App Check → <app> → Manage debug tokens.
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.debug,
      appleProvider: AppleProvider.debug,
    );
  }

  if (!kIsWeb) {
    await NotificationService.instance.initialize();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await NotificationService.instance.syncFcmToken(user.uid);
      NotificationService.instance.listenForTokenRefresh(user.uid);
    }
  }

  if (!kIsWeb && StripeConfig.publishableKey.isNotEmpty) {
    Stripe.publishableKey = StripeConfig.publishableKey;
    if (StripeConfig.merchantIdentifier.isNotEmpty) {
      Stripe.merchantIdentifier = StripeConfig.merchantIdentifier;
    }
    await Stripe.instance.applySettings();
  }

  await FeedbackService.instance.init();

  // Deep links: must initialize BEFORE initNotificationNavigation so that the
  // setter wiring (which assigns onNavigate to GoRouter) flushes any pending
  // route the cold-start handler may have already buffered.
  if (!kIsWeb) {
    try {
      await DeepLinkService.instance.initialize();
    } catch (e) {
      debugPrint('appDeferredInit: DeepLinkService.initialize failed: $e');
    }
  }

  if (!kIsWeb) initNotificationNavigation();
}
