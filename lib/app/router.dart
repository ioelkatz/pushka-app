import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../features/shell/presentation/app_shell.dart';
import '../features/shell/presentation/app_drawer.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/register_screen.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/splash/presentation/splash_screen.dart';

import '../features/pushka/presentation/pushka_screen.dart';
import '../features/wallet/presentation/wallet_screen.dart';
import '../features/wallet/presentation/wallet_send_request_screen.dart';
import '../features/wallet/presentation/wallet_auto_refill_screen.dart';
import '../features/wallet/presentation/wallet_requests_screen.dart';
import '../features/reminders/presentation/reminders_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/settings/presentation/saved_cards_screen.dart';
import '../features/prayers/presentation/prayers_screen.dart';
import '../features/support/presentation/support_screen.dart';
import '../features/about/presentation/about_screen.dart';
import '../features/users/data/user_repository.dart';
import '../features/notifications/notification_service.dart';
import '../core/l10n/s.dart';
import 'theme/app_tokens.dart';

final _auth = FirebaseAuth.instance;
final _firestore = FirebaseFirestore.instance;
final navigatorKey = GlobalKey<NavigatorState>();

Future<String?> _resolveWalletId() async {
  final uid = _auth.currentUser?.uid;
  if (uid == null || uid.isEmpty) return null;
  try {
    final snap = await _firestore.collection('users').doc(uid).get();
    final data = snap.data();
    final fromProfile = (data?['walletId'] as String?)?.trim();
    if (fromProfile != null && fromProfile.isNotEmpty) return fromProfile;
  } catch (_) {
    // fall through to derive from uid
  }
  return UserRepository.walletIdFromUid(uid);
}

Future<void> _openWalletQrDialog(BuildContext context) async {
  final walletId = await _resolveWalletId();
  // Use the global navigator context so the dialog always opens even if the
  // original build context became stale after the async Firestore read.
  final ctx = navigatorKey.currentContext ?? context;
  if (!ctx.mounted) return;

  if (walletId == null) {
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text(S.of(ctx).signInToSeeQr)),
    );
    return;
  }

  await showDialog<void>(
    context: ctx,
    useRootNavigator: true,
    barrierDismissible: true,
    builder: (dialogContext) {
      final tr = S.of(dialogContext);
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: IconButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close_rounded, size: 22),
                  color: AppTokens.textPrimary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: tr.closeTooltip,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                tr.yourWalletDialog,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppTokens.textPrimary,
                ),
              ),
              const SizedBox(height: 14),
              QrImageView(
                data: walletId,
                version: QrVersions.auto,
                size: 180,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                tr.yourSixDigitCode,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTokens.mutedText,
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: AppTokens.cardSilver,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () async {
                    final message = tr.walletShareMessage(walletId);
                    await Clipboard.setData(ClipboardData(text: message));
                    if (!dialogContext.mounted) return;
                    await SharePlus.instance.share(
                      ShareParams(
                        text: message,
                        subject: tr.walletShareSubject,
                      ),
                    );
                    if (!dialogContext.mounted) return;
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text(tr.walletCodeCopied)),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          walletId,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                            color: AppTokens.textPrimary,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.share_rounded, size: 20, color: AppTokens.mutedText),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
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
        GoRoute(
          path: '/wallet',
          pageBuilder: (context, state) => _slidePage(state, const WalletScreen()),
          routes: [
            GoRoute(
              path: 'send-request',
              pageBuilder: (context, state) => _slidePage(state, const WalletSendRequestScreen()),
            ),
            GoRoute(
              path: 'auto-refill',
              pageBuilder: (context, state) => _slidePage(state, const WalletAutoRefillScreen()),
            ),
            GoRoute(
              path: 'requests',
              pageBuilder: (context, state) => _slidePage(state, const WalletRequestsScreen()),
            ),
          ],
        ),
        GoRoute(
          path: '/wallet-auto-refill',
          pageBuilder: (context, state) => _slidePage(state, const WalletAutoRefillScreen()),
        ),
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

PreferredSizeWidget? _buildAppBar(BuildContext context, String location) {
  final tr = S.of(context);
  if (location == '/') {
    return AppBar(
      title: Text(
        tr.navPushka,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.share),
          onPressed: () async {
            try {
              await SharePlus.instance.share(
                ShareParams(
                  text: tr.appShareText,
                  subject: 'Pushka App',
                ),
              );
            } catch (e) {
              debugPrint('[router] share failed: $e');
            }
          },
        ),
      ],
    );
  } else if (location == '/wallet') {
    return AppBar(
      title: Text(tr.navWallet),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.qr_code_scanner_rounded),
          onPressed: () => _openWalletQrDialog(context),
          tooltip: tr.showMyQr,
        ),
      ],
    );
  } else if (location == '/wallet/requests') {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return AppBar(
      title: Text(tr.walletRequests),
      centerTitle: true,
      leading: IconButton(
        icon: Icon(isRtl ? Icons.arrow_forward : Icons.arrow_back),
        onPressed: () => context.go('/wallet'),
      ),
    );
  } else if (location == '/wallet/send-request') {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return AppBar(
      title: Text(tr.navSendRequest),
      centerTitle: true,
      leading: IconButton(
        icon: Icon(isRtl ? Icons.arrow_forward : Icons.arrow_back),
        onPressed: () => context.go('/wallet'),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.qr_code_scanner_rounded),
          onPressed: () => _openWalletQrDialog(context),
          tooltip: tr.showMyQr,
        ),
      ],
    );
  } else if (location == '/wallet/auto-refill' || location == '/wallet-auto-refill') {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return AppBar(
      title: Text(tr.navAutoRefill),
      centerTitle: true,
      leading: IconButton(
        icon: Icon(isRtl ? Icons.arrow_forward : Icons.arrow_back),
        onPressed: () => context.go('/wallet'),
      ),
    );
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
  if (loc.startsWith('/wallet')) return DrawerItem.wallet;
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