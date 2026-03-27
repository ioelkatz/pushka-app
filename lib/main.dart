import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import 'firebase_options.dart';
import 'app/app.dart';
import 'features/notifications/notification_service.dart';
import 'config/stripe_config.dart';
import 'features/feedback/feedback_service.dart';
import 'core/hive_cache.dart';
import 'app/router.dart' show initNotificationNavigation;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {
    // Already initialized by native google-services plugin
  }

  if (kIsWeb) {
    await FirebaseAppCheck.instance.activate(
      webProvider: ReCaptchaV3Provider('6LcXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'),
    );
  } else {
    await FirebaseAppCheck.instance.activate(
      androidProvider:
          kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
      appleProvider: kReleaseMode ? AppleProvider.deviceCheck : AppleProvider.debug,
    );
  }

  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  if (!kIsWeb) {
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
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
  await HiveCache.instance.init();
  if (!kIsWeb) initNotificationNavigation();

  runApp(
    const ProviderScope(
      child: PushkaApp(),
    ),
  );
}


