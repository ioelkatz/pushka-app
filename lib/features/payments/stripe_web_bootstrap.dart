// Cross-platform entry for web-only WebStripe re-initialization.
// Non-web builds get the stub (no-op); web builds delegate to
// stripe_web_bootstrap_web.dart which calls WebStripe.instance.initialise
// with the connected account. See app.dart for the caller.

export 'stripe_web_bootstrap_stub.dart'
    if (dart.library.js_interop) 'stripe_web_bootstrap_web.dart';
