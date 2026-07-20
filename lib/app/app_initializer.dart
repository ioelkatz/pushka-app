import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../features/notifications/notification_service.dart';
import '../features/reminders/data/reminder_repository.dart';
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

/// Activates App Check synchronously. **Must be awaited from main() before
/// runApp()**, so the very first Firestore/Functions call after Firebase init
/// presents a valid token instead of falling back to the framework default
/// (Play Integrity on Android), which fails on debug builds and burns the
/// per-app retry budget — causing the user-visible "verificación de seguridad
/// fallida" error and a "Too many attempts" rate-limit that takes several
/// minutes to clear.
///
/// Audit Round 4 follow-up — previously this lived inside
/// `_performDeferredInit` which ran AFTER runApp, leaving a race window where
/// the auto-default Play Integrity provider would attestation-fail on debug.
Future<void> activateAppCheck() async {
  if (kIsWeb) {
    // Web: si NO tenemos reCAPTCHA v3 site key configurado (via
    // --dart-define=RECAPTCHA_SITE_KEY=...), skip App Check activation
    // completo. Activar ReCaptchaV3Provider con siteKey vacío hace que
    // el provider tire error interno cada vez que el SDK pide token,
    // y Firebase Auth Web SDK propaga eso como 'auth/network-request-failed'
    // en cualquier operación (signup, signIn, etc.) — el user ve "Error
    // de red" al intentar crear cuenta aunque la red esté perfecta.
    //
    // Sin App Check en web, las CFs con enforceAppCheck: true rechazan
    // requests de web. Ese es un trade-off que aceptamos hasta configurar
    // reCAPTCHA v3 site key en Firebase Console → App Check → Web app →
    // Manage. Firebase Auth (signup/login) funciona sin App Check porque
    // Identity Toolkit no está enforced en este proyecto.
    const siteKey = String.fromEnvironment('RECAPTCHA_SITE_KEY', defaultValue: '');
    if (siteKey.isNotEmpty) {
      await FirebaseAppCheck.instance.activate(
        providerWeb: ReCaptchaV3Provider(siteKey),
      );
    }
    // else: no activar — evita el bug del provider con siteKey vacío.
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
}

Future<void> _performDeferredInit() async {
  if (!kIsWeb) {
    await NotificationService.instance.initialize();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await NotificationService.instance.syncFcmToken(user.uid);
      NotificationService.instance.listenForTokenRefresh(user.uid);
      // Re-arm OS-level alarms for any reminder saved in Firestore. The
      // plugin persists its own AlarmManager schedule across reboots, but
      // an uninstall (or clear-data) wipes those — leaving Firestore
      // reminders orphaned (visible in the UI but never firing). This
      // resync is idempotent: scheduleReminder calls cancelReminder first.
      try {
        final repo = ReminderRepository(FirebaseFirestore.instance);
        final reminders = await repo.fetchAll(user.uid);
        // Fan out per-reminder scheduling — each scheduleReminder is itself
        // a parallelized batch of cancel + zonedSchedule calls. Across many
        // reminders the outer for-await previously serialized everything
        // and pushed ~hundreds of milliseconds onto cold start.
        await Future.wait(
          reminders.map(NotificationService.instance.scheduleReminder),
        );
      } catch (e) {
        debugPrint('appDeferredInit: reminder resync failed: $e');
      }
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
