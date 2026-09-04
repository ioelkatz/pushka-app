import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/shell/presentation/app_shell.dart';
import '../features/shell/presentation/app_drawer.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/register_screen.dart';
import '../features/auth/presentation/verify_email_screen.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/splash/presentation/splash_screen.dart';
import '../features/tenant/presentation/tenant_code_screen.dart';
import '../features/tenant/presentation/tenant_suspended_screen.dart';
import '../features/tenant/presentation/join_via_link_screen.dart';
import '../core/deep_link_handler.dart';
import '../core/hostname_tenant_map.dart';

import '../features/pushka/presentation/pushka_screen.dart';
import '../features/wallet/presentation/wallet_screen.dart';
import '../features/reminders/presentation/reminders_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/settings/presentation/saved_cards_screen.dart';
import '../features/payments/presentation/donation_subscriptions_screen.dart';
import '../features/prayers/presentation/prayers_screen.dart';
import '../features/support/presentation/support_screen.dart';
import '../features/about/presentation/about_screen.dart';
import '../features/notifications/notification_service.dart';
import '../features/deep_links/deep_link_service.dart';
import '../core/l10n/s.dart';

final _auth = FirebaseAuth.instance;
final _firestore = FirebaseFirestore.instance;
final navigatorKey = GlobalKey<NavigatorState>();
// ShellRoute's nested navigator — used by the shell AppBar to pop screens
// pushed locally (e.g. the wallet info detail page) before falling back
// to a top-level go_router navigation.
final shellNavigatorKey = GlobalKey<NavigatorState>();

// Cache tenantId per uid to avoid a Firestore read on every navigation event.
String? _cachedTenantCheckUid;
bool? _cachedHasTenant;

/// Call this after the user joins a tenant so the next redirect re-reads Firestore.
void invalidateTenantCache() {
  _cachedTenantCheckUid = null;
  _cachedHasTenant = null;
}

/// Cuentas creadas a partir de este instante deben confirmar el correo antes
/// de poder usar la app. TIENE que coincidir con EMAIL_VERIFICATION_CUTOFF_MS
/// en functions/index.js.
///
/// El corte existe porque la app mandaba el mail de verificacion al
/// registrarse pero nunca lo exigio: casi ningun donante actual lo clickeo.
/// Exigirlo hacia atras los dejaria afuera de un dia para el otro.
final _emailVerificationCutoff = DateTime.utc(2026, 9, 4);

/// Solo aplica al alta con correo y contrasena. Las cuentas de Google llegan
/// con el correo ya verificado por Google, asi que nunca ven la pantalla.
bool needsEmailVerification(User? user) {
  if (user == null) return false;
  if (user.emailVerified) return false;
  if ((user.email ?? '').isEmpty) return false;
  final isPassword =
      user.providerData.any((p) => p.providerId == 'password');
  if (!isPassword) return false;
  final created = user.metadata.creationTime;
  if (created == null) return false;
  return created.isAfter(_emailVerificationCutoff);
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
    // Correo sin confirmar: no se llega a ninguna otra pantalla hasta
    // resolverlo. Ver needsEmailVerification para por que esto solo
    // alcanza a las cuentas de correo y contrasena creadas despues del
    // corte — las de Google llegan con el correo ya verificado.
    if (loggedIn && loc != '/verify-email' && !goingToAuth &&
        needsEmailVerification(_auth.currentUser)) {
      return '/verify-email';
    }
    // Ya verifico y quedo parado en la pantalla: lo sacamos.
    if (loc == '/verify-email' &&
        (!loggedIn || !needsEmailVerification(_auth.currentUser))) {
      return loggedIn ? '/' : '/login';
    }
    if (loggedIn && goingToAuth) {
      // Capture uid before async gap — currentUser can become null if the user
      // signs out between the loggedIn check above and this Firestore read.
      final uid = _auth.currentUser?.uid;
      if (uid == null) return '/login';
      // Este es el primer read despues de iniciar sesion, o sea el momento
      // exacto en que alguien con mala senal se lo come. Firestore tira
      // `unavailable` y, sin este try, la excepcion escapa del redirect de
      // go_router y tumba la app: llegaba a Crashlytics como fatal en
      // FirebaseFirestoreHostApi.documentReferenceGet.
      //
      // Regla: ante un read fallido NUNCA decidimos un destino a partir de
      // datos que no tenemos. Mandamos a '/' --que tiene cache Hive y sus
      // propios estados de carga-- y la siguiente pasada del redirect
      // resuelve bien cuando vuelva la red.
      final DocumentSnapshot<Map<String, dynamic>> snap;
      try {
        snap = await _firestore.collection('users').doc(uid).get();
      } catch (_) {
        return '/';
      }
      // Re-check: user may have signed out during the Firestore read.
      if (_auth.currentUser?.uid != uid) return '/login';
      final done = snap.data()?['onboardingCompleted'] as bool? ?? false;
      return done ? '/' : '/onboarding';
    }
    // Cold-start deep link: user tapped pushka.app/join/{slug} while logged in.
    // Consume the pending slug and redirect to the join screen.
    //
    // Round-5 audit HIGH fix: new user joining via deep link used to bypass
    // /onboarding entirely — they never got to pick language/currency/presets
    // and landed inside a tenant with app defaults (Spanish / USD / [1,5,10]).
    // Now we prioritize onboarding: if onboardingCompleted != true, keep the
    // pendingJoinSlug for AFTER onboarding and send the user through the
    // welcome flow first. The slug is consumed on the next pass once
    // onboarding is done.
    if (loggedIn && pendingJoinSlug != null && !loc.startsWith('/join/')) {
      final uid = _auth.currentUser?.uid;
      if (uid != null) {
        try {
          final snap = await _firestore.collection('users').doc(uid).get();
          if (_auth.currentUser?.uid != uid) return '/login';
          final onboardingDone = snap.data()?['onboardingCompleted'] as bool? ?? false;
          if (!onboardingDone && loc != '/onboarding') {
            // Keep the slug pending — /onboarding completion re-enters this
            // redirect and the branch below will consume it.
            return '/onboarding';
          }
        } catch (_) { /* fall through to consume slug */ }
      }
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
          // Mismo riesgo que el read de arriba, pero acá la degradación
          // correcta es la contraria: NO redirigir. Si mandaramos a
          // /tenant-setup porque el read fallo, un miembro real se quedaria
          // mirando la pantalla del codigo de invitacion sin ningun motivo.
          // Devolvemos null (se queda donde esta) y, sobre todo, NO tocamos
          // _cachedTenantCheckUid: envenenar el cache con un fallo
          // transitorio dejaria la decision congelada hasta el proximo
          // login.
          final DocumentSnapshot<Map<String, dynamic>> snap;
          try {
            snap = await _firestore.collection('users').doc(uid).get();
          } catch (_) {
            return null;
          }
          if (_auth.currentUser?.uid != uid) return '/login';
          // Defensa en profundidad: invariante "Auth user vivo => doc en
          // users/{uid}". Se rompe si vaciamos prod, hay race en signUp,
          // o el doc se borró por bug. Sin esto, el user queda atrapado
          // viendo "Código no encontrado" en /tenant-setup eternamente
          // porque joinTenant no encuentra su doc. La CF joinTenant
          // también auto-crea el doc como segunda red de seguridad.
          if (!snap.exists) {
            try {
              final currentUser = _auth.currentUser;
              if (currentUser != null) {
                await _firestore.collection('users').doc(uid).set({
                  'uid': uid,
                  'email': currentUser.email,
                  'displayName': currentUser.displayName ?? '',
                  'createdAt': FieldValue.serverTimestamp(),
                  'lastLoginAt': FieldValue.serverTimestamp(),
                  'billingEmail': '',
                  'phoneNumber': '',
                  'mailingAddress': '',
                  'pushkaAmount': 0.0,
                  'pushkaGoal': 180.0,
                  'presetAmount': 1.00,
                  'presetAmounts': <double>[],
                  'soundEnabled': true,
                  'vibrationEnabled': true,
                  'partialPaymentsEnabled': false,
                  'biometricAuthenticationEnabled': false,
                  'currencyCountry': 'Estados Unidos',
                  'currencyCode': 'USD',
                  'autoEmptyFrequency': 'manual',
                  'autoEmptyTopOffEnabled': false,
                  'streakCount': 0,
                  'lastStreakDate': null,
                }, SetOptions(merge: true));
              }
            } catch (_) { /* CF backfill will catch it */ }
          }
          final tenantId = snap.data()?['tenantId'] as String?;
          _cachedTenantCheckUid = uid;
          _cachedHasTenant = tenantId != null && tenantId.isNotEmpty;
        }
        if (_cachedHasTenant == false) {
          // If the user landed on a hostname that's mapped to a specific
          // tenant (e.g. app.jabadencampus.com → jabadencampus), skip the
          // code-entry screen and drop them straight into the join flow.
          // Zero friction for donors who arrive via a tenant-branded URL.
          // Falls back to /tenant-setup when no mapping matches (mobile
          // installs, generic hosts, unmapped tenants).
          final hostSlug = tenantSlugFromHostname();
          if (hostSlug != null && !loc.startsWith('/join/')) {
            return '/join/$hostSlug';
          }
          return '/tenant-setup';
        }
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
      path: '/verify-email',
      pageBuilder: (context, state) => _fadePage(state, const VerifyEmailScreen()),
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
      navigatorKey: shellNavigatorKey,
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
              path: 'saved-cards',
              pageBuilder: (context, state) => _slidePage(state, const SavedCardsScreen()),
            ),
            // Same screen as /settings/donation-subs but rooted under /wallet
            // so the back button returns to Billetera (where the user came
            // from) instead of bouncing them out to Configuración.
            GoRoute(
              path: 'donation-subs',
              pageBuilder: (context, state) =>
                  _slidePage(state, const DonationSubscriptionsScreen()),
            ),
          ],
        ),
        GoRoute(
          path: '/reminders',
          pageBuilder: (context, state) => _slidePage(state, const RemindersScreen()),
        ),
        GoRoute(path: '/history', pageBuilder: (context, state) => _slidePage(state, const HistoryScreen())),
        GoRoute(
          path: '/settings',
          pageBuilder: (context, state) => _slidePage(state, const SettingsScreen()),
          routes: [
            GoRoute(
              path: 'saved-cards',
              pageBuilder: (context, state) => _slidePage(state, const SavedCardsScreen()),
            ),
            GoRoute(
              path: 'donation-subs',
              pageBuilder: (context, state) =>
                  _slidePage(state, const DonationSubscriptionsScreen()),
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

/// AppBar for the home screen — fixed "Mi Pushka" title.
/// Used to show the tenant's appName/logo + a multi-tenant switcher
/// chevron, but the user wanted the tenant identity out of the home
/// AppBar (it's still in the drawer header). The switcher now lives in
/// the Settings screen via showAccountSwitcher().
class _TenantMainAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const _TenantMainAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final onSettingsTap = ref.watch(pushkaSettingsTapProvider);
    return AppBar(
      title: Text(tr.myPushka, style: const TextStyle(fontWeight: FontWeight.w600)),
      centerTitle: true,
      actions: [
        IconButton(
          // Round-5 audit fix: TalkBack/VoiceOver need tooltip on
          // icon-only buttons — was announced as just "Botón".
          tooltip: tr.settings,
          icon: const Icon(Icons.settings),
          onPressed: onSettingsTap,
        ),
      ],
    );
  }
}

PreferredSizeWidget? _buildAppBar(BuildContext context, String location) {
  final tr = S.of(context);
  if (location == '/') {
    return const _TenantMainAppBar();
  } else if (location == '/wallet') {
    return AppBar(title: Text(tr.wallet), centerTitle: true);
  } else if (location == '/wallet/saved-cards') {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return AppBar(
      title: Text(tr.savedCards),
      centerTitle: true,
      leading: IconButton(
        // Round-5 audit fix: back arrow needs tooltip for a11y.
        tooltip: tr.back,
        icon: Icon(isRtl ? Icons.arrow_forward : Icons.arrow_back),
        onPressed: () {
          final shellNav = shellNavigatorKey.currentState;
          if (shellNav != null && shellNav.canPop()) {
            shellNav.pop();
          } else {
            context.go('/wallet');
          }
        },
      ),
    );
  } else if (location == '/reminders') {
    return AppBar(title: Text(tr.navReminders), centerTitle: true);
  } else if (location == '/history') {
    return AppBar(title: Text(tr.navHistory), centerTitle: true);
  } else if (location == '/settings') {
    return AppBar(title: Text(tr.navSettings), centerTitle: true);
  } else if (location == '/settings/donation-subs' ||
      location == '/wallet/donation-subs') {
    // Same screen mounted under both /settings and /wallet — user reported
    // navbar disappearing when navigating from Wallet because this branch
    // only matched /settings/... The back button target depends on the
    // parent so the user returns to whichever screen they came from.
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final backTarget =
        location.startsWith('/wallet') ? '/wallet' : '/settings';
    return AppBar(
      title: Text(tr.mySubscriptions),
      centerTitle: true,
      leading: IconButton(
        // Round-5 audit fix: back arrow needs tooltip for a11y.
        tooltip: tr.back,
        icon: Icon(isRtl ? Icons.arrow_forward : Icons.arrow_back),
        onPressed: () {
          final shellNav = shellNavigatorKey.currentState;
          if (shellNav != null && shellNav.canPop()) {
            shellNav.pop();
          } else {
            context.go(backTarget);
          }
        },
      ),
    );
  } else if (location == '/settings/saved-cards') {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return AppBar(
      title: Text(tr.savedCards),
      centerTitle: true,
      leading: IconButton(
        // Round-5 audit fix: back arrow needs tooltip for a11y.
        tooltip: tr.back,
        icon: Icon(isRtl ? Icons.arrow_forward : Icons.arrow_back),
        onPressed: () {
          // If a nested screen is pushed on top of Métodos de pago (e.g.
          // the wallet info detail page for Google/Apple Pay), pop the
          // shell navigator first so the back arrow returns to the cards
          // list. Only fall back to Settings when the cards list itself
          // is on top of the shell.
          final shellNav = shellNavigatorKey.currentState;
          if (shellNav != null && shellNav.canPop()) {
            shellNav.pop();
          } else {
            context.go('/settings');
          }
        },
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

// Same durations as the original — what changes is that the OUTGOING page
// also fades out via `secondaryAnimation`. Previously only the incoming
// page faded in while the outgoing page stayed at 100% opacity underneath,
// so during the partial-opacity window the old layout showed through and
// looked like the previous content "lingered" longer than it should.
// Now it's a true crossfade: as the new page reaches X% opacity, the old
// page is at (100-X)%.
CustomTransitionPage<void> _fadePage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: FadeTransition(
          opacity: ReverseAnimation(
            CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeIn),
          ),
          child: child,
        ),
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
        child: FadeTransition(
          opacity: ReverseAnimation(
            CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeIn),
          ),
          child: SlideTransition(position: slide, child: child),
        ),
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