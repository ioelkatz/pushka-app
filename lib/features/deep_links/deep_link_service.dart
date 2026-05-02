import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Handles `pushka://...` URIs that wake the app from cold or warm start.
///
/// Both AndroidManifest.xml and ios/Runner/Info.plist already declare the
/// `pushka://` scheme — without this service the OS hands the URI to the app
/// and nothing happens. Mirrors NotificationService's wiring: route whitelist
/// to prevent navigation to internal screens, and a pending-route buffer for
/// the cold-start race where the URI arrives before GoRouter is mounted.
class DeepLinkService {
  DeepLinkService._();

  static final DeepLinkService instance = DeepLinkService._();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  void Function(String route)? _onNavigate;
  String? _pendingRoute;

  set onNavigate(void Function(String route) handler) {
    _onNavigate = handler;
    final pending = _pendingRoute;
    if (pending != null) {
      _pendingRoute = null;
      handler(pending);
    }
  }

  // Same whitelist as NotificationService — keep them in sync. Routes outside
  // this list are silently dropped to prevent deep-link injection from opening
  // internal/admin screens (or from skipping required redirects like
  // /tenant-setup).
  static const _allowedRoutes = {
    '/', '/history', '/reminders', '/settings',
    '/prayers', '/support', '/about',
  };

  /// Wires both the initial URI (terminated-state launch) and the warm-start
  /// stream. Idempotent — safe to call multiple times.
  Future<void> initialize() async {
    if (_sub != null) return;

    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handleUri(initial);
    } catch (e) {
      debugPrint('DeepLinkService: getInitialLink failed: $e');
    }

    _sub = _appLinks.uriLinkStream.listen(
      _handleUri,
      onError: (e) => debugPrint('DeepLinkService: uriLinkStream error: $e'),
    );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _onNavigate = null;
    _pendingRoute = null;
  }

  void _handleUri(Uri uri) {
    if (uri.scheme != 'pushka') return;

    // Normalize: pushka:///history → "/history", pushka://history → "/history".
    // app_links exposes the host-or-first-segment differently between iOS and
    // Android depending on whether the URI used `pushka:///x` or `pushka://x`.
    var path = uri.path;
    if (path.isEmpty || path == '/') {
      // Some platforms drop the leading slash and put "history" in `host`.
      final host = uri.host;
      path = host.isEmpty ? '/' : '/$host';
    }
    if (!path.startsWith('/')) path = '/$path';

    if (!_allowedRoutes.contains(path)) {
      debugPrint('DeepLinkService: ignoring non-whitelisted deep link: $uri');
      return;
    }

    final handler = _onNavigate;
    if (handler != null) {
      handler(path);
    } else {
      // Cold-start race: GoRouter not yet wired. Buffer for the next setter.
      _pendingRoute = path;
    }
  }
}
