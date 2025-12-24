import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/shell/presentation/app_shell.dart';
import '../features/shell/presentation/app_drawer.dart';

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
      builder: (context, state, child) {
        final loc = state.uri.toString();
        final current = _drawerItemFromLocation(loc);
        final appBar = _buildAppBar(context, loc);
        return AppShell(
          drawer: AppDrawer(current: current, userName: 'Ioel'),
          appBar: appBar,
          child: child,
        );
      },
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

PreferredSizeWidget? _buildAppBar(BuildContext context, String location) {
  if (location == '/') {
    return AppBar(
      elevation: 0,
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      title: const Text(
        'Mi Pushka',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.share),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Compartir')),
            );
          },
        ),
      ],
    );
  } else if (location == '/wallet') {
    return AppBar(
      title: const Text('Billetera'),
      centerTitle: true,
    );
  } else if (location == '/reminders') {
    return AppBar(
      title: const Text('Recordatorios'),
      centerTitle: true,
    );
  } else if (location == '/history') {
    return AppBar(
      title: const Text('Historial'),
      centerTitle: true,
    );
  } else if (location == '/settings') {
    return AppBar(
      title: const Text('Configuración'),
      centerTitle: true,
    );
  } else if (location == '/prayers') {
    return AppBar(
      title: const Text('Segulot y Rezós'),
      centerTitle: true,
    );
  } else if (location == '/support') {
    return AppBar(
      title: const Text('Soporte'),
      centerTitle: true,
    );
  } else if (location == '/about') {
    return AppBar(
      title: const Text('Acerca de'),
      centerTitle: true,
    );
  }
  return null;
}

DrawerItem _drawerItemFromLocation(String loc) {
  if (loc.startsWith('/wallet')) return DrawerItem.wallet;
  if (loc.startsWith('/reminders')) return DrawerItem.reminders;
  if (loc.startsWith('/history')) return DrawerItem.history;
  if (loc.startsWith('/settings')) return DrawerItem.settings;
  if (loc.startsWith('/prayers')) return DrawerItem.prayers;
  if (loc.startsWith('/support')) return DrawerItem.support;
  if (loc.startsWith('/about')) return DrawerItem.about;
  return DrawerItem.pushka;
}
