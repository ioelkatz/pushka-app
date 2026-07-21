import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/l10n/s.dart';
import '../core/l10n/locale_provider.dart';
import '../core/theme_provider.dart';
import '../features/users/presentation/user_profile_provider.dart';
import '../features/feedback/feedback_service.dart';
import '../features/tenant/presentation/tenant_theme_provider.dart';
import '../features/tenant/data/tenant_repository.dart';
import '../features/auth/providers/auth_controller.dart';
import '../features/auth/providers/auth_state_provider.dart';
import '../features/users/data/user_repository.dart';
import 'router.dart';

class PushkaApp extends ConsumerStatefulWidget {
  const PushkaApp({super.key});

  @override
  ConsumerState<PushkaApp> createState() => _PushkaAppState();
}

class _PushkaAppState extends ConsumerState<PushkaApp> with WidgetsBindingObserver {
  Timer? _tenantStatusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Poll tenant status every 60s while the app is in the foreground. The
    // existing `ref.listen(tenantConfigProvider)` already redirects to
    // /suspended when the loadConfig() throws TenantSuspendedException — but
    // the FutureProvider only re-fires when invalidated. Without this poll an
    // active user keeps using the app after their tenant is suspended until
    // they restart. 60s is the latency vs. cost trade-off: each tick is one
    // Cloud Function call.
    _tenantStatusTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      // Only refresh if the user is signed in — otherwise we'd hit auth-required
      // errors with no useful effect.
      if (ref.read(firebaseAuthProvider).currentUser == null) return;
      ref.invalidate(tenantConfigProvider);
    });
  }

  @override
  void dispose() {
    _tenantStatusTimer?.cancel();
    _tenantStatusTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _applyProfilePreferences();
      // Restart ambient if it was active before the app went to background.
      // We call startAmbient() directly rather than re-reading the profile
      // because ambientEnabled already reflects the user's saved preference.
      if (FeedbackService.instance.ambientEnabled) {
        FeedbackService.instance.startAmbient();
      }
      // Re-check tenant status on resume — covers the case where the tenant
      // was suspended while the app was backgrounded for hours.
      if (ref.read(firebaseAuthProvider).currentUser != null) {
        ref.invalidate(tenantConfigProvider);
      }
    }
  }

  void _applyProfilePreferences() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    if (profile == null) return;

    // Audit Round 4 — Bug A (wire-up defaultLanguage): if the user has no
    // explicit `language` saved, fall back to the tenant's defaultLanguage.
    // syncFromRemote itself respects a Hive-saved manual preference, so users
    // who already chose a language won't be overridden.
    final userLang = profile['language'] as String?;
    final tenantLang = ref.read(tenantConfigProvider).valueOrNull?.defaultLanguage;
    final effectiveLang = (userLang != null && userLang.isNotEmpty) ? userLang : tenantLang;
    if (effectiveLang != null && effectiveLang.isNotEmpty) {
      ref.read(localeProvider.notifier).syncFromRemote(effectiveLang);
    }

    // ambient is intentionally excluded here: it must only start once the
    // main pushka screen is visible (never during the splash). PushkaScreen
    // calls updatePreferences(ambient: ...) in its _loadedRemote block.
    FeedbackService.instance.updatePreferences(
      sound: (profile['soundEnabled'] as bool?) ?? true,
      vibration: (profile['vibrationEnabled'] as bool?) ?? true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeProvider);
    final themeMode = ref.watch(themeModeProvider);

    // Sync language + non-ambient FeedbackService preferences whenever
    // the Firestore profile changes. Ambient is owned by PushkaScreen.
    ref.listen(userProfileProvider, (_, next) {
      final profile = next.valueOrNull;
      if (profile == null) return;

      // If an admin blocked this user while they were active, sign them out immediately.
      // Use AuthController.signOut so FCM tokens are revoked too — otherwise the
      // blocked user keeps receiving push notifications on this device.
      if (profile['isBlocked'] == true) {
        ref.read(authControllerProvider).signOut();
        return;
      }

      // Same tenant fallback as _applyProfilePreferences above.
      final userLang = profile['language'] as String?;
      final tenantLang = ref.read(tenantConfigProvider).valueOrNull?.defaultLanguage;
      final effectiveLang = (userLang != null && userLang.isNotEmpty) ? userLang : tenantLang;
      if (effectiveLang != null && effectiveLang.isNotEmpty) {
        ref.read(localeProvider.notifier).syncFromRemote(effectiveLang);
      }

      FeedbackService.instance.updatePreferences(
        sound: (profile['soundEnabled'] as bool?) ?? true,
        vibration: (profile['vibrationEnabled'] as bool?) ?? true,
      );
    });

    // Ensure a users/{uid} Firestore doc exists whenever the auth state
    // flips to a signed-in user. Covers auth paths that bypass
    // AuthController.signInWith* — most importantly Google via
    // signInWithRedirect on iOS PWA (Firebase auto-detects the redirect
    // credential on page load and fires authStateChanges without going
    // through our signInWithGoogle method). ensureUserDocument is
    // idempotent (checks existence + set-with-merge), so calling on every
    // auth transition is safe — just wastes one Firestore read per login.
    ref.listen(authStateChangesProvider, (prev, next) {
      final user = next.valueOrNull;
      if (user == null) return;
      // Fire and forget — this runs during app boot / router refresh and
      // shouldn't block anything. UserRepository catches its own errors.
      UserRepository(FirebaseFirestore.instance).ensureUserDocument(
        user: user,
        displayName: user.displayName,
      );
    });

    // Navigate to /suspended if the tenant gets suspended while the app is open
    ref.listen(tenantConfigProvider, (prev, next) {
      if (next.error is TenantSuspendedException) {
        router.go('/suspended');
        return;
      }
      // If the tenant was deleted out from under us, the backend heals the
      // user doc by clearing tenantId — the next emission has hasValue==true
      // with valueOrNull==null. The router caches "user has tenant" per uid
      // so we must invalidate it before the redirect, otherwise the cache
      // bounces the user right back to `/`.
      final prevHadTenant = prev?.valueOrNull != null;
      if (prevHadTenant && next.hasValue && next.valueOrNull == null) {
        invalidateTenantCache();
        router.go('/tenant-setup');
      }
    });

    final tenantTheme = ref.watch(tenantThemeProvider);

    return MaterialApp.router(
      title: 'Pushka',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: tenantTheme.light,
      darkTheme: tenantTheme.dark,
      themeMode: themeMode,
      locale: locale,
      supportedLocales: S.supportedLocales,
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
