import 'dart:async';

import 'package:app_links/app_links.dart';

/// Set from main() before runApp via [initDeepLinks].
/// Holds the slug from the initial link if the app was launched cold via a join link.
String? pendingJoinSlug;

final _appLinks = AppLinks();
StreamSubscription<Uri>? _linkSubscription;

/// Call once in main() before runApp to capture the cold-start link.
Future<void> initDeepLinks() async {
  try {
    final uri = await _appLinks.getInitialLink();
    if (uri != null) pendingJoinSlug = _slugFromUri(uri);
  } catch (_) {}
}

/// Call after runApp to start listening for links while the app is running.
/// [onJoinSlug] is invoked (on the main isolate) whenever a join link arrives.
void startDeepLinkListener(void Function(String slug) onJoinSlug) {
  _linkSubscription?.cancel();
  _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
    final slug = _slugFromUri(uri);
    if (slug != null) onJoinSlug(slug);
  }, onError: (_) {});
}

void stopDeepLinkListener() {
  _linkSubscription?.cancel();
  _linkSubscription = null;
}

/// Trusted origins that may deliver a join link. Anything else is rejected
/// so a hostile link like https://evil.example/join/legit-slug can't drive
/// the user into a real tenant.
const _trustedHttpsHosts = <String>{
  'pushka-app-ioel.web.app',
  'pushka-app-ioel.firebaseapp.com',
  'pushka-pwa.web.app',
  'pushka-pwa.firebaseapp.com',
  'pushkapp.cc',
  'www.pushkapp.cc',
  'app.pushkapp.cc',
};

String? _slugFromUri(Uri uri) {
  // Handles:
  //   https://<trusted-host>/join/<slug>   — universal / app link
  //   pushka:///join/<slug>                — custom scheme, 3-slash form
  //   pushka://join/<slug>                 — custom scheme, 2-slash form
  //     (Users often type/share the shorter form; without normalization the
  //     slug ends up in uri.host and pathSegments has only [<slug>], so the
  //     old code silently dropped it.)
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();

  final bool schemeOk = scheme == 'pushka' ||
      (scheme == 'https' && _trustedHttpsHosts.contains(host));
  if (!schemeOk) {
    assert(() {
      // Only visible in debug builds; production stays silent.
      // ignore: avoid_print
      print('[deep_link] rejected untrusted origin: ${uri.scheme}://${uri.host}');
      return true;
    }());
    return null;
  }

  final segments = uri.pathSegments;

  String? rawSlug;
  if (scheme == 'pushka' && host == 'join') {
    // 2-slash form: pushka://join/<slug>  → host='join', pathSegments=[<slug>]
    if (segments.isNotEmpty) rawSlug = segments[0];
  } else if (segments.length >= 2 && segments[0] == 'join') {
    // 3-slash form and https form: /join/<slug>
    rawSlug = segments[1];
  }

  if (rawSlug == null) return null;
  final slug = rawSlug.trim().toLowerCase();
  return slug.isNotEmpty ? slug : null;
}
