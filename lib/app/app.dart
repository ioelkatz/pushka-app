import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/l10n/s.dart';
import '../core/l10n/locale_provider.dart';
import '../core/theme_provider.dart';
import '../features/users/presentation/user_profile_provider.dart';
import '../features/feedback/feedback_service.dart';
import 'router.dart';
import 'theme/app_theme.dart';

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
    }
  }

  void _applyProfilePreferences() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    if (profile == null) return;

    final lang = profile['language'] as String?;
    if (lang != null && lang.isNotEmpty) {
      ref.read(localeProvider.notifier).syncFromRemote(lang);
    }

    FeedbackService.instance.updatePreferences(
      sound: (profile['soundEnabled'] as bool?) ?? true,
      coinJingle: (profile['coinJingleEnabled'] as bool?) ?? true,
      vibration: (profile['vibrationEnabled'] as bool?) ?? true,
      ambient: (profile['ambientEnabled'] as bool?) ?? false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeProvider);
    final themeMode = ref.watch(themeModeProvider);

    // Sync language + FeedbackService preferences whenever Firestore profile changes.
    ref.listen(userProfileProvider, (_, next) {
      final profile = next.valueOrNull;
      if (profile == null) return;

      final lang = profile['language'] as String?;
      if (lang != null && lang.isNotEmpty) {
        ref.read(localeProvider.notifier).syncFromRemote(lang);
      }

      FeedbackService.instance.updatePreferences(
        sound: (profile['soundEnabled'] as bool?) ?? true,
        coinJingle: (profile['coinJingleEnabled'] as bool?) ?? true,
        vibration: (profile['vibrationEnabled'] as bool?) ?? true,
        ambient: (profile['ambientEnabled'] as bool?) ?? false,
      );
    });

    return MaterialApp.router(
      title: 'Pushka',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
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
