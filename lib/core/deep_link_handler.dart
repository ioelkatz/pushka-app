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

String? _slugFromUri(Uri uri) {
  // Handles: https://pushka.app/join/chabadmexico
  //      and: pushka:///join/chabadmexico
  final segments = uri.pathSegments;
  if (segments.length >= 2 && segments[0] == 'join') {
    final slug = segments[1].trim().toLowerCase();
    return slug.isNotEmpty ? slug : null;
  }
  return null;
}
