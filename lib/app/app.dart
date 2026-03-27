import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/l10n/s.dart';
import '../core/l10n/locale_provider.dart';
import '../features/users/presentation/user_profile_provider.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class PushkaApp extends ConsumerWidget {
  const PushkaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);

    // Sync language from Firestore profile whenever it changes
    ref.listen(userProfileProvider, (_, next) {
      final lang = next.valueOrNull?['language'] as String?;
      if (lang != null && lang.isNotEmpty) {
        ref.read(localeProvider.notifier).setLanguageCode(lang);
      }
    });

    return MaterialApp.router(
      title: 'Pushka',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: AppTheme.light(),
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