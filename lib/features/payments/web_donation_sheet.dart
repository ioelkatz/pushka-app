// Cross-platform entry point for the Stripe Elements inline donation sheet.
// Conditional import routes to the web-only implementation when compiling
// for browsers, and to the stub on native builds (where this code path is
// never reached — callers guard with kIsWeb).

export 'web_donation_sheet_stub.dart'
    if (dart.library.html) 'web_donation_sheet_web.dart';
