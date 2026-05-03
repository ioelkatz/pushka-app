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
import '../features/tenant/presentation/join_via_link_screen.dart';
import '../features/tenant/data/tenant_repository.dart';
import '../core/deep_link_handler.dart';

import '../features/pushka/presentation/pushka_screen.dart';
import '../features/reminders/presentation/reminders_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/settings/presentation/saved_cards_screen.dart';
import '../features/prayers/presentation/prayers_screen.dart';
import '../features/support/presentation/support_screen.dart';
import '../features/about/presentation/about_screen.dart';
import '../features/notifications/notification_service.dart';
import '../features/deep_links/deep_link_service.dart';
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
    // Cold-start deep link: user tapped pushka.app/join/{slug} while logged in.
    // Consume the pending slug and redirect to the join screen.
    if (loggedIn && pendingJoinSlug != null && !loc.startsWith('/join/')) {
      final slug = pendingJoinSlug!;
      pendingJoinSlug = null;
      return '/join/$slug';
    }

    // If the user is logged in but has no tenantId, send them to tenant setup.
    // Skip this check when already heading there or to auth/onboarding screens.
    if (loggedIn && loc != '/tenant-setup' && loc != '/suspended' && !goingToAuth && loc != '/onboarding' && !loc.startsWith('/join/')) {
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
    GoRoute(
      path: '/join/:slug',
      pageBuilder: (context, state) {
        final slug = state.pathParameters['slug']!;
        return _fadePage(state, JoinViaLinkScreen(slug: slug));
      },
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
  // Same handler for `pushka://...` deep links — both flows funnel through
  // the same allowed-route whitelist on their respective services, so a
  // single navigation sink is fine.
  DeepLinkService.instance.onNavigate = (route) {
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
    final summaries = ref.watch(userTenantSummariesProvider).valueOrNull ?? [];
    final hasMultiple = summaries.length > 1;

    final appName = (tenantConfig?.appName.isNotEmpty == true)
        ? tenantConfig!.appName
        : tr.navPushka;
    final logoUrl = tenantConfig?.logoUrl;

    Widget nameWidget = (logoUrl != null && logoUrl.isNotEmpty)
        ? Image.network(
            logoUrl,
            height: 32,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                Text(appName, style: const TextStyle(fontWeight: FontWeight.w600)),
          )
        : Text(appName, style: const TextStyle(fontWeight: FontWeight.w600));

    final Widget titleWidget = hasMultiple
        ? GestureDetector(
            onTap: () => _showSwitcherSheet(context, ref, summaries),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                nameWidget,
                const SizedBox(width: 4),
                const Icon(Icons.expand_more_rounded, size: 20),
              ],
            ),
          )
        : nameWidget;

    return AppBar(
      title: titleWidget,
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.share),
          onPressed: () async {
            try {
              await SharePlus.instance.share(
                ShareParams(text: tr.appShareText, subject: appName),
              );
            } catch (e) {
              debugPrint('[router] share failed: $e');
            }
          },
        ),
      ],
    );
  }

  void _showSwitcherSheet(BuildContext context, WidgetRef ref, List summaries) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _AccountSwitcherSheet(ref: ref),
    );
  }
}

class _AccountSwitcherSheet extends ConsumerWidget {
  const _AccountSwitcherSheet({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context, WidgetRef wRef) {
    final tr = S.of(context);
    final summaries = wRef.watch(userTenantSummariesProvider).valueOrNull ?? [];
    final tenantConfig = wRef.watch(tenantConfigProvider).valueOrNull;
    final activeTenantId = tenantConfig?.tenantId;
    final tt = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr.myOrganizations,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ...summaries.map((s) {
              final isActive = s.tenantId == activeTenantId;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _OrgAvatar(name: s.name, logoUrl: s.logoUrl),
                title: Text(
                  s.appName.isNotEmpty ? s.appName : s.name,
                  style: tt.bodyMedium?.copyWith(
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                trailing: isActive
                    ? Icon(Icons.check_rounded,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: isActive
                    ? null
                    : () async {
                        Navigator.of(context).pop();
                        await wRef
                            .read(tenantRepositoryProvider)
                            .switchTenant(s.tenantId);
                        wRef.invalidate(tenantConfigProvider);
                        wRef.invalidate(tenantStateProvider);
                        invalidateTenantCache();
                      },
              );
            }),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                radius: 20,
                child: Icon(Icons.add_rounded),
              ),
              title: Text(tr.addOrganization),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/tenant-setup');
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _OrgAvatar extends StatelessWidget {
  const _OrgAvatar({required this.name, this.logoUrl});

  final String name;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.primaryContainer;
    return CircleAvatar(
      radius: 20,
      backgroundColor: bg,
      child: logoUrl != null && logoUrl!.isNotEmpty
          ? ClipOval(
              child: Image.network(
                logoUrl!,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _initial(context),
              ),
            )
          : _initial(context),
    );
  }

  Widget _initial(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return Text(
      initial,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onPrimaryContainer,
        fontWeight: FontWeight.w700,
      ),
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

// Drawer-triggered navigation runs in parallel with the drawer's own
// close animation (~246ms in Material). Keeping our page transitions
// short so the combined perceived latency stays snappy. Previously
// 220-260ms felt like ~500ms once the drawer animation overlapped.
CustomTransitionPage<void> _fadePage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 150),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        child: child,
      );
    },
  );
}

CustomTransitionPage<void> _slidePage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 170),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final slide = Tween<Offset>(
        begin: const Offset(0.04, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
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