import 'package:go_router/go_router.dart';

import '../features/shell/presentation/app_shell.dart';
import '../features/pushka/presentation/pushka_screen.dart';
import '../features/wallet/presentation/wallet_screen.dart';
import '../features/reminders/presentation/reminders_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/prayers/presentation/prayers_screen.dart';
import '../features/support/presentation/support_screen.dart';
import '../features/about/presentation/about_screen.dart';

final router = GoRouter(
  initialLocation: '/',
  routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(path: '/', builder: (_, __) => const PushkaScreen()),
        GoRoute(path: '/wallet', builder: (_, __) => const WalletScreen()),
        GoRoute(path: '/reminders', builder: (_, __) => const RemindersScreen()),
        GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
        GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
        GoRoute(path: '/prayers', builder: (_, __) => const PrayersScreen()),
        GoRoute(path: '/support', builder: (_, __) => const SupportScreen()),
        GoRoute(path: '/about', builder: (_, __) => const AboutScreen()),
      ],
    ),
  ],
);
