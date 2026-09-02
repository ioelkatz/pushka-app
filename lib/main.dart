import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'config/stripe_config.dart';
import 'firebase_options.dart';
import 'app/app.dart';
import 'app/app_initializer.dart';
import 'core/hive_cache.dart';
import 'core/deep_link_handler.dart';
import 'features/tenant/data/tenant_repository.dart' show TenantSuspendedException;

/// Returns true for exceptions that represent expected business flows —
/// the app handles them via UX (redirect, snackbar) but they'd otherwise
/// bubble up to the Crashlytics zone catcher as if they were crashes.
/// Whitelist ONLY expected exceptions; anything else must still be logged.
bool _isExpectedBusinessException(Object error) {
  return error is TenantSuspendedException;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Use clean URLs on web (pushkapp.cc/join/slug instead of pushkapp.cc/#/join/slug).
  // Required for App Links / Universal Links to match the go_router path. On
  // non-web platforms this call is a no-op (safe to call unconditionally).
  usePathUrlStrategy();

  // Stripe publishableKey — set SYNCHRONOUSLY before runApp so the web
  // PaymentElement mount never races the async `_initStripe()` chain.
  // Previously this lived inside `_performDeferredInit` which awaited
  // `applySettings()` in parallel with the first frame; on fast cold-start
  // a user could reach the pushka screen and tap Donar before the key was
  // set → PaymentElement mounted with null key → button stayed disabled
  // forever (MF5 in the Stage 4-6 adversarial review). The applySettings()
  // call is native-only and still runs deferred inside _initStripe.
  if (StripeConfig.publishableKey.isNotEmpty) {
    Stripe.publishableKey = StripeConfig.publishableKey;
    if (StripeConfig.merchantIdentifier.isNotEmpty) {
      Stripe.merchantIdentifier = StripeConfig.merchantIdentifier;
    }
  }

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

  // App Check MUST be activated before any Firestore/Functions traffic so
  // those calls present a valid token. Previously this ran inside
  // `_performDeferredInit()` AFTER runApp, leaving a race window where the
  // default Play Integrity provider (which fails on debug builds) burned the
  // per-app retry budget and surfaced as "verificación de seguridad fallida"
  // + "Too many attempts" rate-limit. Activating here closes the gap.
  try {
    await activateAppCheck();
  } catch (e) {
    debugPrint('activateAppCheck failed (non-fatal): $e');
  }

  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  if (!kIsWeb) {
    FlutterError.onError = (details) {
      // Expected business-flow exceptions surface as Flutter framework errors
      // when they're thrown inside a widget build / stream — they're already
      // handled by ref.listen(tenantConfigProvider) which redirects the user
      // to /suspended. Reporting them to Crashlytics as fatal noise inflates
      // the crash-free-user metric AND generates alert emails for what is
      // actually a normal state transition.
      if (_isExpectedBusinessException(details.exception)) {
        debugPrint('Suppressing expected exception from Crashlytics: ${details.exception}');
        return;
      }
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      // Same policy for async uncaught errors. TenantSuspendedException from
      // the tenantConfigProvider snapshot stream escapes to the zone through
      // Riverpod's error propagation; the ref.listen handles the UX but the
      // exception still reaches this hook.
      if (_isExpectedBusinessException(error)) {
        debugPrint('Suppressing expected async exception from Crashlytics: $error');
        return true;
      }
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
