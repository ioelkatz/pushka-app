// Legacy compatibility shim. The real signal now lives in
// network_status_provider.dart which uses opportunistic detection
// (react to actual request success/failure) instead of browser APIs.
//
// Old approach used connectivity_plus which lies on web (navigator.onLine
// reports true when connected to WiFi with no internet, and can emit a
// stray ConnectivityResult.none on tab suspend). That caused a persistent
// false-positive "Sin conexión" banner in PWA even when the user had
// perfect internet.
//
// This shim keeps the old symbols working while new code should import
// network_status_provider.dart directly.
export 'network_status_provider.dart' show isOfflineProvider;
