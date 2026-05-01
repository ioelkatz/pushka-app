import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/shell/presentation/app_shell.dart';
import '../features/shell/presentation/app_drawer.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/register_screen.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/splash/presentation/splash_screen.dart';
import '../features/tenant/presentation/tenant_code_screen.dart';
import '../features/tenant/presentation/tenant_suspended_screen.dart';
import '../features/tenant/data/tenant_repository.dart';

import '../features/pushka/presentation/pushka_screen.dart';
import '../features/reminders/presentation/reminders_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/settings/presentation/saved_cards_screen.dart';
import '../features/prayers/presentation/prayers_screen.dart';
import '../features/support/presentation/support_screen.dart';
import '../features/about/presentation/about_screen.dart';
import '../features/notifications/notification_service.dart';
import '../core/l10n/s.dart';

final _auth = FirebaseAuth.instance;
final _firestore = FirebaseFirestore.instance;
final navigatorKey = GlobalKey<NavigatorState>();

// Cache tenantId per uid to avoid a Firestore read on every navigation event.
String? _cachedTenantCheckUid;
bool? _cachedHasTenant;

/// Call this after the user joins a tenant so the next redirect re-reads Firestore.
void invalidateTenantCache() {
  _cachedTenantCheckUid = null;
  _cachedHasTenant = null;
}

final router = GoRouter(
  navigatorKey: navigatorKey,
  initialLocation: '/splash',
  refreshListenable: GoRouterRefreshStream(_auth.authStateChanges()),
  observers: [
    FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance),
  ],
  redirect: (context, state) async {
    final loggedIn = _auth.currentUser != null;
    final loc = state.matchedLocation;
    // Always let the splash run — it handles its own navigation when done
    if (loc == '/splash') return null;
    final goingToAuth = loc == '/login' || loc == '/register';
    if (!loggedIn && !goingToAuth) return '/login';
    if (loggedIn && goingToAuth) {
      // Capture uid before async gap — currentUser can become null if the user
      // signs out between the loggedIn check above and this Firestore read.
      final uid = _auth.currentUser?.uid;
      if (uid == null) return '/login';
      final snap = await _firestore.collection('users').doc(uid).get();
      // Re-check: user may have signed out during the Firestore read.
      if (_auth.currentUser?.uid != uid) return '/login';
      final done = snap.data()?['onboardingCompleted'] as bool? ?? false;
      return done ? '/' : '/onboarding';
    }
    // If the user is logged in but has no tenantId, send them to tenant setup.
    // Skip this check when already heading there or to auth/onboarding screens.
    if (loggedIn && loc != '/tenant-setup' && loc != '/suspended' && !goingToAuth && loc != '/onboarding') {
      final uid = _auth.currentUser?.uid;
      if (uid != null) {
        // Use cache to avoid a Firestore read on every navigation event.
        // Cache is invalidated when uid changes (login/logout).
        if (_cachedTenantCheckUid != uid) {
          final snap = await _firestore.collection('users').doc(uid).get();
          if (_auth.currentUser?.uid != uid) return '/login';
          final tenantId = snap.data()?['tenantId'] as String?;
          _cachedTenantCheckUid = uid;
          _cachedHasTenant = tenantId != null && tenantId.isNotEmpty;
        }
        if (_cachedHasTenant == false) return '/tenant-setup';
      }
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/splash',
      pageBuilder: (context, state) => _fadePage(state, const SplashScreen()),
    ),
    GoRoute(
      path: '/login',
      pageBuilder: (context, state) => _fadePage(state, const LoginScreen()),
    ),
    GoRoute(
      path: '/register',
      pageBuilder: (context, state) => _slidePage(state, const RegisterScreen()),
    ),
    GoRoute(
      path: '/onboarding',
      pageBuilder: (context, state) => _fadePage(state, const OnboardingScreen()),
    ),
    GoRoute(
      path: '/tenant-setup',
      pageBuilder: (context, state) => _fadePage(state, const TenantCodeScreen()),
    ),
    GoRoute(
      path: '/suspended',
      pageBuilder: (context, state) => _fadePage(state, const TenantSuspendedScreen()),
    ),
    ShellRoute(
      pageBuilder: (context, state, child) {
        final loc = state.uri.toString();
        final current = _drawerItemFromLocation(loc);
        final appBar = _buildAppBar(context, loc);
        return _fadePage(
          state,
          AppShell(
            drawer: AppDrawer(current: current),
            appBar: appBar,
            child: child,
          ),
        );
      },
      routes: [
        GoRoute(path: '/', pageBuilder: (context, state) => _fadePage(state, const PushkaScreen())),
        GoRoute(path: '/reminders', pageBuilder: (context, state) => _slidePage(state, const RemindersScreen())),
        GoRoute(path: '/history', pageBuilder: (context, state) => _slidePage(state, const HistoryScreen())),
        GoRoute(
          path: '/settings',
          pageBuilder: (context, state) => _slidePage(state, const SettingsScreen()),
          routes: [
            GoRoute(
              path: 'saved-cards',
              pageBuilder: (context, state) => _slidePage(state, const SavedCardsScreen()),
            ),
          ],
        ),
        GoRoute(path: '/prayers', pageBuilder: (context, state) => _slidePage(state, const PrayersScreen())),
        GoRoute(path: '/support', pageBuilder: (context, state) => _slidePage(state, const SupportScreen())),
        GoRoute(path: '/about', pageBuilder: (context, state) => _slidePage(state, const AboutScreen())),
      ],
    ),
  ],
);

/// Wire notification taps → GoRouter navigation. Call once after Flutter init.
void initNotificationNavigation() {
  NotificationService.instance.onNavigate = (route) {
    router.go(route);
  };
}

/// AppBar for the main pushka screen — reads tenant appName from provider.
class _TenantMainAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const _TenantMainAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final tenantConfig = ref.watch(tenantConfigProvider).valueOrNull;
    final title = (tenantConfig?.appName.isNotEmpty == true)
        ? tenantConfig!.appName
        : tr.navPushka;

    return AppBar(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.share),
          onPressed: () async {
            try {
              await SharePlus.instance.share(
                ShareParams(text: tr.appShareText, subject: title),
              );
            } catch (e) {
              debugPrint('[router] share failed: $e');
            }
          },
        ),
      ],
    );
  }
}

PreferredSizeWidget? _buildAppBar(BuildContext context, String location) {
  final tr = S.of(context);
  if (location == '/') {
    return const _TenantMainAppBar();
  } else if (location == '/reminders') {
    return AppBar(title: Text(tr.navReminders), centerTitle: true);
  } else if (location == '/history') {
    return AppBar(title: Text(tr.navHistory), centerTitle: true);
  } else if (location == '/settings') {
    return AppBar(title: Text(tr.navSettings), centerTitle: true);
  } else if (location == '/settings/saved-cards') {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return AppBar(
      title: Text(tr.savedCards),
      centerTitle: true,
      leading: IconButton(
        icon: Icon(isRtl ? Icons.arrow_forward : Icons.arrow_back),
        onPressed: () => context.go('/settings'),
      ),
    );
  } else if (location == '/prayers') {
    return AppBar(title: Text(tr.navPrayers), centerTitle: true);
  } else if (location == '/support') {
    return AppBar(title: Text(tr.navSupport), centerTitle: true);
  } else if (location == '/about') {
    return AppBar(title: Text(tr.aboutTitle), centerTitle: true);
  }
  return null;
}

DrawerItem _drawerItemFromLocation(String loc) {
  if (loc.startsWith('/reminders')) return DrawerItem.reminders;
  if (loc.startsWith('/history')) return DrawerItem.history;
  if (loc.startsWith('/settings')) return DrawerItem.settings;
  if (loc.startsWith('/prayers')) return DrawerItem.prayers;
  if (loc.startsWith('/support')) return DrawerItem.support;
  if (loc.startsWith('/about')) return DrawerItem.about;
  return DrawerItem.pushka;
}

// --- Page transition helpers ---

CustomTransitionPage<void> _fadePage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

CustomTransitionPage<void> _slidePage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final slide = Tween<Offset>(
        begin: const Offset(0.06, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}

class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}