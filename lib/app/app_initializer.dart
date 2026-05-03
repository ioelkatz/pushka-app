import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import '../features/notifications/notification_service.dart';
import '../features/deep_links/deep_link_service.dart';
import '../config/stripe_config.dart';
import '../features/feedback/feedback_service.dart';
import '../core/deep_link_handler.dart';
import 'router.dart' show initNotificationNavigation, router;

/// Deferred initialization future — started in main(), awaited in splash.
late final Future<void> appDeferredInit;

void scheduleDeferredInit() {
  appDeferredInit = _performDeferredInit();
}

Future<void> _performDeferredInit() async {
  if (kIsWeb) {
    await FirebaseAppCheck.instance.activate(
      providerWeb: ReCaptchaV3Provider(
        const String.fromEnvironment('RECAPTCHA_SITE_KEY', defaultValue: ''),
      ),
    );
  } else if (kReleaseMode) {
    await FirebaseAppCheck.instance.activate(
      providerAndroid: AndroidPlayIntegrityProvider(),
      providerApple: AppleDeviceCheckProvider(),
    );
  } else {
    // Debug builds: backend enforces App Check, so we need the debug provider
    // here too. The token is printed to logcat on first launch — register it
    // at Firebase Console → App Check → <app> → Manage debug tokens.
    await FirebaseAppCheck.instance.activate(
      providerAndroid: AndroidDebugProvider(),
      providerApple: AppleDebugProvider(),
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

  // Two parallel deep-link surfaces (different concerns, same `app_links` package):
  //  - DeepLinkService (mine): static `pushka://<route>` whitelist for
  //    /history, /reminders, /settings, /prayers, /support, /about. Buffer +
  //    flush, so a cold-start link delivered before GoRouter is mounted is
  //    replayed once initNotificationNavigation sets the onNavigate sink.
  //  - startDeepLinkListener (Ioel): `/join/<slug>` for tenant join links,
  //    incl. https://pushka-app-ioel.web.app/join/<slug>. Slug-only callback
  //    pushed straight to GoRouter.
  // Both subscribe to the same uriLinkStream — each handler ignores URIs the
  // other handles, so no double-navigation. DeepLinkService.initialize() must
  // run BEFORE initNotificationNavigation so the buffer flushes correctly.
  if (!kIsWeb) {
    try {
      await DeepLinkService.instance.initialize();
    } catch (e) {
      debugPrint('appDeferredInit: DeepLinkService.initialize failed: $e');
    }
    initNotificationNavigation();
    startDeepLinkListener((slug) {
      router.go('/join/$slug');
    });
  }
}
