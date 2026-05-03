import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
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

  // App Tracking Transparency (iOS only). Apple rejects apps that ship with
  // any IDFA-equivalent SDK (Firebase Analytics counts) without prompting
  // the user via requestTrackingAuthorization first. The package is a
  // no-op on Android — wrapping in Platform.isIOS keeps the call site
  // explicit. We disable Firebase Analytics + Crashlytics auto-collection
  // when the user declines, since both can attribute behavior to a device
  // identifier behind the scenes.
  //
  // Run AFTER FirebaseAppCheck.activate so App Check tokens still mint
  // (App Check uses DeviceCheck/Play Integrity, NOT IDFA — independent of
  // ATT). Run AFTER first frame (a 600ms breath) so the system prompt
  // doesn't race the splash teardown.
  if (!kIsWeb && Platform.isIOS) {
    try {
      // Block-style: prompt → await user's choice → propagate.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final status = await AppTrackingTransparency.requestTrackingAuthorization();
      final granted = status == TrackingStatus.authorized;
      // Disable both analytics + crashlytics auto-collection when not
      // granted. Crash REPORTING still works (manual recordError calls)
      // but won't auto-attach device identifiers across sessions.
      try {
        await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(granted);
        await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(granted);
      } catch (e) {
        debugPrint('appDeferredInit: ATT analytics gate apply failed: $e');
      }
    } catch (e) {
      // Older iOS (< 14) doesn't support ATT; the package returns
      // TrackingStatus.notSupported but throws on edge devices. Treat
      // failure as "user did not opt in" — keep analytics off until next
      // launch when we can prompt again.
      debugPrint('appDeferredInit: ATT request failed: $e');
    }
  }

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
