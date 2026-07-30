// Web implementation of the browser-only helpers used by the settings
// screen and NotificationService. dart:html is safe here — this file is
// only imported when the app is compiled for web (`if (dart.library.html)`
// in the conditional import at the call site).

// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

String webUserAgent() => html.window.navigator.userAgent;

/// True when the PWA is running from the home-screen icon (Add-to-Home-Screen
/// on iOS, install on Chrome/Edge/Samsung, or a shortcut on desktop). False
/// when running as a browser tab. Used to gate iOS push registration since
/// Safari only wires webpush inside standalone context.
bool webIsStandalonePwa() {
  try {
    final mm = html.window.matchMedia('(display-mode: standalone)');
    if (mm.matches == true) return true;
  } catch (_) {}
  // iOS Safari exposes a non-standard navigator.standalone bool.
  try {
    final navStandalone = (html.window.navigator as dynamic).standalone;
    if (navStandalone == true) return true;
  } catch (_) {}
  return false;
}
