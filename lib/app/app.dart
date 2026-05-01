import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/l10n/s.dart';
import '../core/l10n/locale_provider.dart';
import '../core/theme_provider.dart';
import '../features/users/presentation/user_profile_provider.dart';
import '../features/feedback/feedback_service.dart';
import '../features/tenant/presentation/tenant_theme_provider.dart';
import 'router.dart';

class PushkaApp extends ConsumerStatefulWidget {
  const PushkaApp({super.key});

  @override
  ConsumerState<PushkaApp> createState() => _PushkaAppState();
}

class _PushkaAppState extends ConsumerState<PushkaApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
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
    }
  }

  void _applyProfilePreferences() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    if (profile == null) return;

    final lang = profile['language'] as String?;
    if (lang != null && lang.isNotEmpty) {
      ref.read(localeProvider.notifier).syncFromRemote(lang);
    }

    // ambient is intentionally excluded here: it must only start once the
    // main pushka screen is visible (never during the splash). PushkaScreen
    // calls updatePreferences(ambient: ...) in its _loadedRemote block.
    FeedbackService.instance.updatePreferences(
      sound: (profile['soundEnabled'] as bool?) ?? true,
      coinJingle: (profile['coinJingleEnabled'] as bool?) ?? true,
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
      if (profile['isBlocked'] == true) {
        FirebaseAuth.instance.signOut();
        return;
      }

      final lang = profile['language'] as String?;
      if (lang != null && lang.isNotEmpty) {
        ref.read(localeProvider.notifier).syncFromRemote(lang);
      }

      FeedbackService.instance.updatePreferences(
        sound: (profile['soundEnabled'] as bool?) ?? true,
        coinJingle: (profile['coinJingleEnabled'] as bool?) ?? true,
        vibration: (profile['vibrationEnabled'] as bool?) ?? true,
      );
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
