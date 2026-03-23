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

import '../features/pushka/presentation/pushka_screen.dart';
import '../features/wallet/presentation/wallet_screen.dart';
import '../features/wallet/presentation/wallet_send_request_screen.dart';
import '../features/wallet/presentation/wallet_auto_refill_screen.dart';
import '../features/reminders/presentation/reminders_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/prayers/presentation/prayers_screen.dart';
import '../features/support/presentation/support_screen.dart';
import '../features/about/presentation/about_screen.dart';
import '../features/users/data/user_repository.dart';
import 'theme/app_tokens.dart';

final _auth = FirebaseAuth.instance;
final _firestore = FirebaseFirestore.instance;
const _appShareText = '''
He estado usando esta increíble nueva app Pushka de Tzedaká. ¡Funciona igual que una pushka real! Con solo un toque puedes "poner una moneda", incluso el monto más pequeño, y cuando estés listo, puedes "vaciarla" para hacer una donación.

Toda la Tzedaká va directamente a Colel Chabad, que hace una labor increíble ayudando a los pobres en Israel.

Mírala aquí: https://pushkapp.cc/share
''';

String _walletShareMessage(String walletId) {
  return 'Mi código de billetera Pushka es: $walletId\n'
      'Escanéalo o ingrésalo manualmente para enviar o solicitar tzedaká.\n'
      'Descargar app: https://pushkapp.cc/share';
}

Future<String?> _resolveWalletId() async {
  final uid = _auth.currentUser?.uid;
  if (uid == null || uid.isEmpty) return null;
  final snap = await _firestore.collection('users').doc(uid).get();
  final data = snap.data();
  final fromProfile = (data?['walletId'] as String?)?.trim();
  if (fromProfile != null && fromProfile.isNotEmpty) return fromProfile;
  return UserRepository.walletIdFromUid(uid);
}

Future<void> _openWalletQrDialog(BuildContext context) async {
  final walletId = await _resolveWalletId();
  if (walletId == null) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Inicia sesión para ver tu código QR')),
    );
    return;
  }
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close_rounded, size: 22),
                  color: AppTokens.textPrimary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Cerrar',
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Tu billetera',
                style: TextStyle(
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
                'Tu código de 6 dígitos',
                style: TextStyle(
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
                    final message = _walletShareMessage(walletId);
                    await Clipboard.setData(ClipboardData(text: message));
                    await SharePlus.instance.share(
                      ShareParams(
                        text: message,
                        subject: 'Mi código de billetera Pushka',
                      ),
                    );
                    if (!dialogContext.mounted) return;
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(content: Text('Código copiado y listo para compartir')),
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
  initialLocation: '/login',
  refreshListenable: GoRouterRefreshStream(_auth.authStateChanges()),
  observers: [
    FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance),
  ],
  redirect: (context, state) {
    final loggedIn = _auth.currentUser != null;
    final goingToAuth =
        state.matchedLocation == '/login' || state.matchedLocation == '/register';

    if (!loggedIn && !goingToAuth) return '/login';
    if (loggedIn && goingToAuth) return '/';
    return null;
  },
  routes: [
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/register',
      builder: (context, state) => const RegisterScreen(),
    ),
    ShellRoute(
      builder: (context, state, child) {
        final loc = state.uri.toString();
        final current = _drawerItemFromLocation(loc);
        final appBar = _buildAppBar(context, loc);
        return AppShell(
          drawer: AppDrawer(current: current),
          appBar: appBar,
          child: child,
        );
      },
      routes: [
        GoRoute(path: '/', builder: (context, state) => const PushkaScreen()),
        GoRoute(
          path: '/wallet',
          builder: (context, state) => const WalletScreen(),
          routes: [
            GoRoute(
              path: 'send-request',
              builder: (context, state) => const WalletSendRequestScreen(),
            ),
            GoRoute(
              path: 'auto-refill',
              builder: (context, state) => const WalletAutoRefillScreen(),
            ),
          ],
        ),
        GoRoute(
          path: '/wallet-auto-refill',
          builder: (context, state) => const WalletAutoRefillScreen(),
        ),
        GoRoute(path: '/reminders', builder: (context, state) => const RemindersScreen()),
        GoRoute(path: '/history', builder: (context, state) => const HistoryScreen()),
        GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
        GoRoute(path: '/prayers', builder: (context, state) => const PrayersScreen()),
        GoRoute(path: '/support', builder: (context, state) => const SupportScreen()),
        GoRoute(path: '/about', builder: (context, state) => const AboutScreen()),
      ],
    ),
  ],
);

PreferredSizeWidget? _buildAppBar(BuildContext context, String location) {
  if (location == '/') {
    return AppBar(
      elevation: 0,
      backgroundColor: Colors.white,
      foregroundColor: AppTokens.textPrimary,
      title: const Text(
        'Mi Pushka',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.share),
          onPressed: () async {
            await SharePlus.instance.share(
              ShareParams(
                text: _appShareText,
                subject: 'Pushka App',
              ),
            );
          },
        ),
      ],
    );
  } else if (location == '/wallet') {
    return AppBar(
      title: const Text('Billetera'),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.qr_code_scanner_rounded),
          onPressed: () => _openWalletQrDialog(context),
          tooltip: 'Mostrar mi QR',
        ),
      ],
    );
  } else if (location == '/wallet/send-request') {
    return AppBar(
      title: const Text('Enviar/Solicitar'),
      centerTitle: true,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => context.go('/wallet'),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.qr_code_scanner_rounded),
          onPressed: () => _openWalletQrDialog(context),
        ),
      ],
    );
  } else if (location == '/wallet/auto-refill' || location == '/wallet-auto-refill') {
    return AppBar(
      title: const Text('RECARGA AUTOMÁTICA'),
      centerTitle: true,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => context.go('/wallet'),
      ),
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
      title: const Text('Segulot y Rezos'),
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