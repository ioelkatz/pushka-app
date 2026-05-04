import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'firebase_options.dart';
import 'app/app.dart';
import 'app/app_initializer.dart';
import 'core/hive_cache.dart';
import 'core/deep_link_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hide the Android system navigation bar entirely (back/home/recents
  // strip at the bottom). User can still reveal it temporarily by
  // swiping up from the bottom edge — that's the "sticky" behavior.
  // Status bar stays visible so the user keeps the clock/battery/wifi
  // info plus our transparent overlay style on top of the app content.
  if (!kIsWeb) {
    // Lock to portrait — the layout isn't designed for landscape.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [SystemUiOverlay.top],
    );
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
  }

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {
    // Already initialized by native google-services plugin
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

  // Hive must be ready before runApp so providers can read saved prefs on init
  await HiveCache.instance.init();

  // Capture cold-start deep link before runApp so the router can act on it
  await initDeepLinks();

  // Start heavy init in background — splash screen awaits before navigating
  scheduleDeferredInit();

  runApp(
    const ProviderScope(
      child: PushkaApp(),
    ),
  );
}
