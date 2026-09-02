import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../reminders/domain/reminder.dart';
import '../../core/hive_cache.dart';
import '../../core/l10n/s.dart';

/// Outcome of [NotificationService.ensureNotificationPermission].
///
/// The three-way split is the whole point of using `permission_handler`
/// instead of the plain `bool` return the plugins used to give us:
/// `permanentlyDenied` is what Android reports once the user has ticked
/// "Don't allow" twice (or once on API 33+ with "Don't ask again"), and it
/// means the OS will NOT show its prompt anymore — the caller has to
/// send the user into system settings via `openAppSettings()` for anything
/// to happen. Conflating it with `deniedByUser` (a fresh rejection where a
/// re-request WILL still show the prompt) is exactly what confused users
/// and produced the "toggle silently reopens the sheet with no prompt" UX.
enum NotificationPermissionResult {
  /// Notifications are enabled — the caller can proceed to schedule.
  granted,

  /// User dismissed the OS prompt this time, but a future request will still
  /// show the prompt (Android under the two-strike limit, or iOS pre-block).
  deniedByUser,

  /// OS will no longer show its native prompt — only OS Settings can flip
  /// this. Callers should route the user to `openAppSettings()` instead of
  /// firing another doomed request.
  permanentlyDenied,
}

/// Opens the app's system notification/settings page. Exposed as a top-level
/// helper so UI layers don't have to import `permission_handler` directly.
Future<bool> openNotificationSettings() async {
  if (kIsWeb) return false;
  try {
    return await ph.openAppSettings();
  } catch (e) {
    debugPrint('openNotificationSettings failed: $e');
    return false;
  }
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<String>? _tokenRefreshSub;
  String? _currentUid;
  bool _useUtcScheduling = false;

  /// Set to true when [_configureLocalTimezone] fell back to raw UTC because
  /// no IANA/Etc zone matched the device. In that mode, `matchDateTimeComponents`
  /// pins a UTC instant which doesn't shift with the device's DST — so post-DST
  /// recurring reminders fire an hour off. We surface the flag via
  /// [utcFallbackActive] so a caller (e.g. reminders screen) can warn the user.
  bool get utcFallbackActive => _useUtcScheduling;

  /// Dedicated Hive box for reminder metadata that doesn't belong on the
  /// Firestore doc (device-local, per-install):
  ///   `os:<id>` → int millisSinceEpoch for one-shot reminders (chooseDate)
  ///   `needs_resync` → bool flag driving cold-start resync gating
  ///   `utc_fallback` → bool flag stamped when the tz DB has no local zone
  static const _remindersMetaBox = 'reminders_meta';
  static const _kOneShotPrefix = 'os:';
  static const _kNeedsResync = 'needs_resync';
  static const _kUtcFallback = 'utc_fallback';
  Box? _metaBox;

  Future<Box?> _openMetaBox() async {
    if (_metaBox != null) return _metaBox;
    try {
      // HiveCache.init() calls Hive.initFlutter() once. Ensure it's ready before
      // opening our own box — otherwise Hive.openBox throws HiveError on cold
      // start when NotificationService.initialize() beats HiveCache.init().
      await HiveCache.instance.init();
      _metaBox = await Hive.openBox(_remindersMetaBox);
    } catch (e) {
      debugPrint('NotificationService: openMetaBox failed: $e');
    }
    return _metaBox;
  }

  /// One-shot chooseDate metadata — persisted device-local so cold-start
  /// resync can distinguish "custom recurring on this weekday" from
  /// "one-shot on this date". Firestore has no dateOnly field (schema owned
  /// by another agent), so we cache it locally per install.
  Future<void> setOneShotDate(String reminderId, DateTime date) async {
    final box = await _openMetaBox();
    if (box == null) return;
    await box.put('$_kOneShotPrefix$reminderId',
        DateTime(date.year, date.month, date.day).millisecondsSinceEpoch);
  }

  Future<void> clearOneShotDate(String reminderId) async {
    final box = await _openMetaBox();
    if (box == null) return;
    await box.delete('$_kOneShotPrefix$reminderId');
  }

  DateTime? _readOneShotDate(String reminderId) {
    final v = _metaBox?.get('$_kOneShotPrefix$reminderId');
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    return null;
  }

  /// Public read for the reminders form so re-editing a chooseDate reminder
  /// can restore the picked date. Synchronous — assumes the Hive box was
  /// opened during initialize(); returns null if not.
  DateTime? readOneShotDateForReminder(String reminderId) =>
      _readOneShotDate(reminderId);

  /// True when a resync is needed on cold-start. Defaults to true when the
  /// key has never been written (fresh install, upgrade, or clear-data).
  bool get needsResync => (_metaBox?.get(_kNeedsResync) as bool?) ?? true;

  Future<void> markResyncDone() async {
    final box = await _openMetaBox();
    if (box == null) return;
    await box.put(_kNeedsResync, false);
  }

  Future<void> _markResyncNeeded() async {
    final box = await _openMetaBox();
    if (box == null) return;
    await box.put(_kNeedsResync, true);
  }

  // Monotonically increasing ID so notifications never overwrite each other.
  // hashCode is not unique across different objects — a counter is safe.
  int _nextNotificationId = 1;

  /// True when the user has granted SCHEDULE_EXACT_ALARM (Android 12+).
  /// When false we fall back to AndroidScheduleMode.inexactAllowWhileIdle —
  /// otherwise zonedSchedule throws and the reminder silently never fires.
  bool _canScheduleExact = true;

  /// Called whenever a notification tap should navigate somewhere.
  /// Set this from the router/shell once GoRouter is available.
  void Function(String route)? _onNavigate;

  /// A pending route buffered when [onNavigate] was not yet set at the moment
  /// the cold-start notification tap was processed. Flushed when [onNavigate]
  /// is assigned.
  String? _pendingRoute;

  set onNavigate(void Function(String route) handler) {
    _onNavigate = handler;
    final pending = _pendingRoute;
    if (pending != null) {
      _pendingRoute = null;
      handler(pending);
    }
  }

  void _navigate(String route) {
    final handler = _onNavigate;
    if (handler != null) {
      handler(route);
    } else {
      // Router not yet wired (cold-start race). Buffer so it fires once wired.
      _pendingRoute = route;
    }
  }

  Future<void> initialize() async {
    // Open the reminders_meta box early — needsResync + one-shot-date reads
    // during cold-start resync return real values (not defaults). Safe on
    // web too (Hive uses IndexedDB there).
    await _openMetaBox();

    // Web (PWA) doesn't support flutter_local_notifications and doesn't need
    // the timezone DB (both are for LOCAL scheduling only). But it DOES need
    // the Firebase Messaging listeners registered so foreground/background
    // push routes work. The permission request itself must NOT run at cold
    // start on web — browsers reject requestPermission() without a user
    // gesture. Instead we register an opt-in UI (see enableWebPush()) and
    // silent-refresh here only if the user previously opted in.
    if (!kIsWeb) {
      await _configureLocalTimezone();
      // Fix: NO pedir permisos de notificaciones en cold start.
      // Antes: la app pedía permiso al arrancar sin contexto — si el user
      // decía "Don't allow" volvía a preguntar en próximos launches en
      // Android 13+ (comportamiento del OS), forzando al user a activarlas
      // igual. Ahora respetamos que el user pueda usar la app sin
      // notificaciones. El permiso se pide RECIÉN cuando el user intenta
      // crear un recordatorio (contextual, via ensureNotificationPermission).
      // Los listeners de FCM se registran igual (abajo) para que si el
      // user activa notificaciones más tarde, todo funcione sin restart.
      await _initializeLocalNotifications();
    }

    // FCM listeners work on BOTH native and web. On web, onMessage fires when
    // the PWA tab is focused and the SW receives a push. onMessageOpenedApp
    // + getInitialMessage fire when the user taps a notification shown by
    // the SW (background) while the app is closed or backgrounded.
    FirebaseMessaging.onMessage.listen(
      _showLocalNotification,
      onError: (e) => debugPrint('NotificationService: onMessage stream error: $e'),
    );
    _listenForNotificationTaps();
  }

  void _listenForNotificationTaps() {
    // Background FCM tap
    FirebaseMessaging.onMessageOpenedApp.listen(
      _handleRemoteMessageTap,
      onError: (e) => debugPrint('NotificationService: onMessageOpenedApp stream error: $e'),
    );

    // Terminated state FCM tap (check once on launch)
    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message != null) _handleRemoteMessageTap(message);
    }).catchError((e) {
      debugPrint('NotificationService: getInitialMessage error: $e');
    });
  }

  void _handleRemoteMessageTap(RemoteMessage message) {
    final route = _routeFromMessage(message);
    if (route != null) _navigate(route);
  }

  // Only these routes may be opened via FCM — prevents deep-link injection.
  static const _allowedRoutes = {
    '/', '/history', '/reminders', '/settings', '/settings/saved-cards',
    '/wallet', '/prayers', '/support', '/about',
  };

  String? _routeFromMessage(RemoteMessage message) {
    final data = message.data;
    // Cloud Functions can send either `data.route` (legacy) or
    // `data.click_action` (the key the SW reads on web — kept in sync so a
    // single payload works everywhere). Both go through the whitelist to
    // prevent deep-link injection.
    final explicit = (data['route'] as String?) ?? (data['click_action'] as String?);
    if (explicit != null && _allowedRoutes.contains(explicit)) return explicit;

    final type = data['type'] as String?;
    return switch (type) {
      'pushkaEmpty' => '/history',
      'reminder' => '/reminders',
      // A donation cleared, refund landed, chargeback opened, or the
      // scheduled pushka auto-empty failed — surface the ledger so the user
      // can see the entry rather than dropping the tap on the floor.
      'tzedaka' => '/history',
      'refund' => '/history',
      'chargeback' => '/history',
      'pushkaAutoEmptyFailed' => '/',
      _ => null,
    };
  }

  /// Public VAPID key for Firebase Web Push (RFC 8292). This is safe to
  /// hardcode in the client bundle — the whole point of an application-server
  /// key pair is that the public half is shipped to the browser. Rotating
  /// it requires updating Firebase Console → Cloud Messaging → Web Push
  /// certificates AND redeploying with the new value.
  ///
  /// PROD project: pushka-app-ioel. DEV project has a separate certificate
  /// that we haven't generated yet — kept null until we do (dev flavor
  /// gracefully skips web push registration if the key is missing).
  static const String _vapidKeyProd =
      'BIOHaG2kFiKvJwZIefzg4u1ldSRzsmbVoBY31_01VshteSE4kXiqRzqp6V8Xcf_sMIX9EgL9rLLpF6BpQY7lHfE';
  static const String? _vapidKeyDev = null;

  /// Hive flag: user explicitly opted into web push via the Settings toggle.
  /// Used to gate the cold-start silent refresh so we never prompt for
  /// permission unbidden (browsers reject that anyway without a gesture).
  static const _kWebPushOptedIn = 'web_push_opted_in';

  bool get _webPushOptedIn {
    if (!kIsWeb) return false;
    try {
      return _metaBox?.get(_kWebPushOptedIn, defaultValue: false) == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setWebPushOptedIn(bool value) async {
    if (!kIsWeb) return;
    final box = await _openMetaBox();
    if (box == null) return;
    await box.put(_kWebPushOptedIn, value);
  }

  /// Returns the vapidKey for the currently-configured Firebase project, or
  /// null if we don't have one yet (e.g. dev flavor). Callers must handle
  /// null by skipping web push registration.
  String? _resolveVapidKey() {
    final projectId = FirebaseFirestore.instance.app.options.projectId;
    if (projectId == 'pushka-app-ioel') return _vapidKeyProd;
    return _vapidKeyDev;
  }

  Future<void> syncFcmToken(String uid) async {
    if (kIsWeb) {
      // Only silent-refresh if the user previously opted in — never prompt
      // for permission here (cold-start gesture-less call would fail on
      // Safari and denials waste the browser's one-shot budget).
      if (!_webPushOptedIn) return;
      final vapidKey = _resolveVapidKey();
      if (vapidKey == null) return;
      try {
        final token = await _messaging.getToken(vapidKey: vapidKey);
        if (token == null) return;
        await _saveToken(uid, token);
      } catch (e) {
        // Do NOT delete the backend token on failure — iOS Safari PWA
        // sometimes returns permission-blocked as a false negative after a
        // reload; wiping the token would break a working subscription.
        debugPrint('NotificationService.syncFcmToken web silent-refresh failed: $e');
      }
      return;
    }
    final token = await _messaging.getToken();
    if (token == null) return;
    await _saveToken(uid, token);
  }

  /// Explicit opt-in flow for web push. MUST be called from a user gesture
  /// (button tap in Settings). Requests browser permission, obtains an FCM
  /// token, persists it to Firestore, and stores the opt-in flag so future
  /// cold-starts silent-refresh transparently.
  ///
  /// Round-8 audit HIGH fix: some iOS versions (<16.4) don't support
  /// web push at all. `_messaging.isSupported()` returns false there.
  /// UIs should call this BEFORE showing the enable toggle so users
  /// on unsupported platforms see a "not available" message instead of
  /// a toggle that silently fails.
  Future<bool> isWebPushSupported() async {
    if (!kIsWeb) return false;
    try {
      return await FirebaseMessaging.instance.isSupported();
    } catch (_) {
      return false;
    }
  }

  /// Returns true if the user granted permission and a token was saved.
  Future<bool> enableWebPush(String uid) async {
    if (!kIsWeb) return false;
    // Round-8 audit HIGH fix: bail early on unsupported browsers (iOS <16.4)
    // — before this check the requestPermission call silently returned
    // 'denied' and the user thought their toggle was broken.
    if (!await isWebPushSupported()) {
      debugPrint('NotificationService.enableWebPush: browser does not support push');
      return false;
    }
    final vapidKey = _resolveVapidKey();
    if (vapidKey == null) return false;
    try {
      // Ask FCM to request browser permission — it wraps
      // Notification.requestPermission() and returns the granted status.
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        return false;
      }
      final token = await _messaging.getToken(vapidKey: vapidKey);
      if (token == null) return false;
      await _saveToken(uid, token);
      await _setWebPushOptedIn(true);
      // Also start the refresh listener so token rotations are captured.
      listenForTokenRefresh(uid);
      return true;
    } catch (e) {
      debugPrint('NotificationService.enableWebPush failed: $e');
      return false;
    }
  }

  /// Disable web push: delete the backend token, deleteToken() so FCM rotates,
  /// clear the opt-in flag. Called from the Settings toggle when the user
  /// opts out (or from signOut, transparently).
  Future<void> disableWebPush(String uid) async {
    if (!kIsWeb) return;
    await _setWebPushOptedIn(false);
    await revokeFcmTokenForUser(uid);
  }

  /// Whether the user has explicitly opted into web push on this browser.
  bool webPushIsEnabled() => _webPushOptedIn;

  void listenForTokenRefresh(String uid) {
    // Works cross-platform. On web the onTokenRefresh stream fires whenever
    // the SW is reinstalled, the vapidKey rotates, or the user clears site
    // data. If the user hasn't opted into web push, keep the listener
    // dormant — the guard mirrors syncFcmToken's cold-start behavior.
    if (kIsWeb && !_webPushOptedIn) return;
    if (_currentUid == uid && _tokenRefreshSub != null) return;
    _currentUid = uid;
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = _messaging.onTokenRefresh.listen(
      (token) async {
        try {
          await _saveToken(uid, token);
        } catch (e) {
          debugPrint('NotificationService: token refresh save failed: $e');
        }
      },
      onError: (e) => debugPrint('NotificationService: onTokenRefresh stream error: $e'),
    );
  }

  Future<void> stopTokenRefresh() async {
    _currentUid = null;
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
  }

  /// Removes this device's FCM token from `users/{uid}/fcmTokens` AND deletes
  /// the token from FCM's side, then stops the refresh listener.
  ///
  /// Must be called BEFORE `FirebaseAuth.signOut()` — otherwise the Firestore
  /// delete is rejected by rules (`isOwner(uid)` requires the auth context).
  ///
  /// Without this, after a user signs out:
  /// - their token doc lingers in Firestore, so server-side `sendToUser(uid)`
  ///   keeps pushing to this device for the previous account
  /// - if a new user signs in, the same FCM token gets written to their docs
  ///   too, so a single push from the previous account arrives even after the
  ///   new sign-in (privacy leak: notifications meant for user A reach user B's
  ///   eyes if they share the device)
  Future<void> revokeFcmTokenForUser(String uid) async {
    String? token;
    try {
      // getToken on web REQUIRES vapidKey; native accepts no args. If we're
      // on web and don't have a key (dev flavor), skip token lookup — the
      // most recent listenForTokenRefresh handler already saved it, and
      // getToken here would only fail loudly.
      if (kIsWeb) {
        final vapidKey = _resolveVapidKey();
        if (vapidKey != null) {
          token = await _messaging.getToken(vapidKey: vapidKey);
        }
      } else {
        token = await _messaging.getToken();
      }
    } catch (e) {
      debugPrint('NotificationService.revokeFcmTokenForUser: getToken failed: $e');
    }

    if (token != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('fcmTokens')
            .doc(token)
            .delete();
      } catch (e) {
        // Most likely the token was never registered (sync failed earlier),
        // or the user has no Firestore connectivity. Either way, swallow —
        // we still want sign-out to complete.
        debugPrint('NotificationService.revokeFcmTokenForUser: delete failed: $e');
      }
    }

    // Force FCM to issue a new token for the next sign-in. Without this, the
    // next user signs in with the SAME token, which (a) leaks history if the
    // previous user's token doc still exists and (b) keeps the previous
    // user's stale push subscriptions on the FCM side.
    try {
      await _messaging.deleteToken();
    } catch (e) {
      debugPrint('NotificationService.revokeFcmTokenForUser: deleteToken failed: $e');
    }

    await stopTokenRefresh();
  }

  Future<void> _configureLocalTimezone() async {
    tz.initializeTimeZones();
    final timeZoneName = DateTime.now().timeZoneName;
    try {
      tz.setLocalLocation(tz.getLocation(timeZoneName));
      _useUtcScheduling = false;
      return;
    } catch (_) {
      // Ignore and try offset-based fallback.
    }

    final offset = DateTime.now().timeZoneOffset;
    if (offset.inMinutes % 60 == 0) {
      final hours = offset.inHours;
      final sign = hours >= 0 ? '-' : '+';
      final name = hours == 0 ? 'Etc/UTC' : 'Etc/GMT$sign${hours.abs()}';
      try {
        tz.setLocalLocation(tz.getLocation(name));
        _useUtcScheduling = false;
        return;
      } catch (_) {
        // Ignore and fall back to UTC scheduling.
      }
    }

    tz.setLocalLocation(tz.UTC);
    _useUtcScheduling = true;
    debugPrint(
      'NotificationService: WARNING no IANA/Etc zone matched device tz — '
      'falling back to raw UTC. matchDateTimeComponents pins a UTC instant '
      'that does NOT shift with the device DST; recurring reminders will '
      'fire an hour off after every DST transition until the device zone '
      'DB is patched or FlutterNativeTimezone integration lands.',
    );
    try {
      final box = await _openMetaBox();
      await box?.put(_kUtcFallback, true);
    } catch (e) {
      debugPrint('NotificationService: could not stamp UTC fallback flag: $e');
    }
  }

  /// Exposed so a settings/diagnostics screen can surface the warning.
  bool get utcFallbackPersisted =>
      (_metaBox?.get(_kUtcFallback) as bool?) ?? false;

  /// Verifica si las notificaciones ya están permitidas SIN mostrar
  /// prompt al user. Útil para gate un toggle: si el user activa un
  /// switch de "recordar" y el permiso ya está concedido, no molestar
  /// con el diálogo; si no está, entonces sí pedir (via ensureNotificationPermission).
  /// Web retorna `false` — usar `webPushIsEnabled()` para el path web.
  ///
  /// Round-12 fix: chequea DOS fuentes (FCM + flutter_local_notifications)
  /// y considera concedido si CUALQUIERA reporta true. Motivo: en algunas
  /// versiones de firebase_messaging el `getNotificationSettings()` de
  /// Android devuelve un valor cacheado post-plugin-init que no refleja el
  /// cambio hecho por el user en Settings del sistema. El check de
  /// `areNotificationsEnabled()` del plugin local usa
  /// `NotificationManagerCompat.from(ctx).areNotificationsEnabled()` que
  /// SIEMPRE es real-time. Si el user habilita notifs en Settings del OS y
  /// vuelve a la app, la próxima llamada a este método devuelve true, en
  /// vez de quedar bloqueado en un valor stale.
  Future<bool> hasNotificationPermission() async {
    if (kIsWeb) return false;
    // On Android, prefer the real-time OS check via flutter_local_notifications
    // (uses NotificationManagerCompat.areNotificationsEnabled() — the source
    // of truth for whether posted notifications will actually be shown). The
    // firebase_messaging `getNotificationSettings()` cache can drift after
    // the user changes the OS toggle without a cold-start, so leaning on it
    // exclusively risks BOTH a false-positive (user revoked in Settings,
    // FCM still cached "authorized" → toggle turns ON but reminders never
    // fire) AND a false-negative (user granted in Settings, FCM cached
    // "denied" → toggle stays broken until app restart — the exact bug
    // reported by the user this round). Falling back to FCM only when the
    // Android plugin isn't available (iOS + edge errors) preserves iOS
    // correctness.
    try {
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        final enabled = await androidPlugin.areNotificationsEnabled();
        if (enabled != null) return enabled;
        // Pre-Android-13 devices with no runtime permission concept return
        // null here — fall through to FCM (which reports via legacy path).
      }
    } catch (e) {
      debugPrint('hasNotificationPermission: local check failed: $e');
    }
    try {
      final settings = await _messaging.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('hasNotificationPermission: FCM check failed: $e');
      return false;
    }
  }

  /// Pide permisos de notificaciones (FCM + local). Devuelve un tri-estado
  /// que distingue rechazo temporal ("Don't allow" con el prompt aún vivo)
  /// de rechazo permanente (Android agotó los dos disparos del prompt del
  /// sistema, o el user marcó "Don't ask again"). El caller usa la
  /// diferencia para decidir entre volver a intentar o mandar al user a
  /// Settings del OS via `openNotificationSettings()`.
  ///
  /// - `granted`             → todo listo, agendar el reminder
  /// - `deniedByUser`        → user dijo que no; un próximo intento va a
  ///                           mostrar el prompt del OS otra vez
  /// - `permanentlyDenied`   → el OS NO va a mostrar más el prompt. El
  ///                           caller debe abrir OS Settings.
  ///
  /// Web retorna `granted` para no bloquear el flujo — la app web tiene un
  /// opt-in separado en Settings (`enableWebPush()`); acá tratamos el gate
  /// como "no aplica" y dejamos que el resto del flujo siga.
  ///
  /// Round-12 fix: NO abre el settings del OS para SCHEDULE_EXACT_ALARM
  /// dentro de este método. Ahora exact alarms se releen sin prompt
  /// (`refreshExactAlarmsFlag`) y el `_safeZonedSchedule` cae a inexact si
  /// hace falta.
  ///
  /// Round-13 fix: retornar enum en lugar de bool para que la UI pueda
  /// diferenciar el caso "permanently denied" y abrir Settings del OS
  /// directamente en vez de mostrar snackbars inútiles.
  Future<NotificationPermissionResult> ensureNotificationPermission() async {
    if (kIsWeb) return NotificationPermissionResult.granted;

    // ANDROID PATH — usar EXCLUSIVAMENTE permission_handler.
    //
    // Bug histórico: llamar `_messaging.requestPermission()` + luego
    // `ph.Permission.notification.request()` consumía DOS disparos del
    // prompt del OS por cada tap del user en "Activar". Después de 2 taps
    // ya estaba `permanentlyDenied` y el prompt dejaba de aparecer. Ahora
    // en Android solo pasamos por permission_handler y solo pedimos si el
    // status es `denied` (no `permanentlyDenied`). En iOS mantenemos FCM
    // + iosPlugin porque son el path canónico ahí y no tienen el problema
    // del budget de 2 disparos.
    if (!Platform.isIOS) {
      ph.PermissionStatus status;
      try {
        status = await ph.Permission.notification.status;
      } catch (e) {
        debugPrint('ensureNotificationPermission (android): status read failed: $e');
        return NotificationPermissionResult.deniedByUser;
      }

      if (status.isGranted || status.isLimited || status.isProvisional) {
        await refreshExactAlarmsFlag();
        return NotificationPermissionResult.granted;
      }

      if (status.isPermanentlyDenied) {
        // No pedir de nuevo — el OS retorna denied sin UI. El caller abre
        // Settings via openNotificationSettings().
        return NotificationPermissionResult.permanentlyDenied;
      }

      // status.isDenied — el OS aún permite un disparo del prompt.
      try {
        final requested = await ph.Permission.notification.request();
        if (requested.isGranted ||
            requested.isLimited ||
            requested.isProvisional) {
          await refreshExactAlarmsFlag();
          return NotificationPermissionResult.granted;
        }
        if (requested.isPermanentlyDenied) {
          return NotificationPermissionResult.permanentlyDenied;
        }
        return NotificationPermissionResult.deniedByUser;
      } catch (e) {
        debugPrint('ensureNotificationPermission (android): request failed: $e');
        return NotificationPermissionResult.deniedByUser;
      }
    }

    // iOS PATH — FCM + local plugin son el canonical path aquí.
    bool fcmOk = false;
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      fcmOk =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
              settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('ensureNotificationPermission (ios): FCM request failed: $e');
    }

    try {
      final iosPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>();
      await iosPlugin?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (e) {
      debugPrint('ensureNotificationPermission (ios): local request failed: $e');
    }

    ph.PermissionStatus status;
    try {
      status = await ph.Permission.notification.status;
    } catch (e) {
      debugPrint('ensureNotificationPermission (ios): status read failed: $e');
      return fcmOk
          ? NotificationPermissionResult.granted
          : NotificationPermissionResult.deniedByUser;
    }

    if (status.isGranted || status.isLimited || status.isProvisional) {
      await refreshExactAlarmsFlag();
      return NotificationPermissionResult.granted;
    }

    if (status.isPermanentlyDenied) {
      return NotificationPermissionResult.permanentlyDenied;
    }

    // iOS status still denied — try one explicit request via permission_handler.
    try {
      final requested = await ph.Permission.notification.request();
      if (requested.isGranted ||
          requested.isLimited ||
          requested.isProvisional) {
        await refreshExactAlarmsFlag();
        return NotificationPermissionResult.granted;
      }
      if (requested.isPermanentlyDenied) {
        return NotificationPermissionResult.permanentlyDenied;
      }
      if (fcmOk) {
        await refreshExactAlarmsFlag();
        return NotificationPermissionResult.granted;
      }
      return NotificationPermissionResult.deniedByUser;
    } catch (e) {
      debugPrint('ensureNotificationPermission: request failed: $e');
      return fcmOk
          ? NotificationPermissionResult.granted
          : NotificationPermissionResult.deniedByUser;
    }
  }

  /// Reads `canScheduleExactNotifications()` — a real-time OS check that
  /// does NOT open settings — and updates `_canScheduleExact`. Called on
  /// each `scheduleReminder` so a user who grants SCHEDULE_EXACT_ALARM via
  /// OS Settings mid-session picks up exact scheduling without a restart.
  Future<void> refreshExactAlarmsFlag() async {
    if (kIsWeb) return;
    try {
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin == null) return; // iOS — not applicable.
      final can = await androidPlugin.canScheduleExactNotifications();
      // Null = older Android with no exact-alarm concept → treat as allowed.
      _canScheduleExact = can ?? true;
      if (!_canScheduleExact) {
        debugPrint(
          'NotificationService: SCHEDULE_EXACT_ALARM currently denied — '
          'reminders will fire within ~15min of target via inexact alarm.',
        );
      }
    } catch (e) {
      debugPrint('refreshExactAlarmsFlag: check failed: $e');
    }
  }

  AndroidScheduleMode get _androidScheduleMode => _canScheduleExact
      ? AndroidScheduleMode.exactAllowWhileIdle
      : AndroidScheduleMode.inexactAllowWhileIdle;

  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          _navigate(payload);
        }
      },
    );

    // Pre-create both channels so Samsung One UI doesn't silence the first
    // fire of a never-before-seen channel. Lazy creation (on first show) is
    // documented to "work" but reliably surfaces silently the first time on
    // some Samsung devices.
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    debugPrint('NotificationService: pre-creating channels '
        '(androidPlugin=${androidPlugin != null})');
    if (androidPlugin != null) {
      try {
        await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
          'pushka_notifications',
          'Pushka Notifications',
          description: 'General Pushka notifications',
          importance: Importance.high,
        ));
        await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
          'pushka_reminders',
          'Pushka Reminders',
          description: 'Scheduled reminders and alerts',
          importance: Importance.high,
        ));
        debugPrint('NotificationService: channels created OK');
      } catch (e) {
        debugPrint('NotificationService: channel creation failed: $e');
      }
    }
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    // On web, foreground push messages arrive here but we can't call
    // flutter_local_notifications (mobile-only). The browser also
    // intentionally does NOT auto-show a system notification while the tab
    // is focused (avoids duplicates with the SW-side background handler).
    // Skip silently — a future enhancement can surface an in-app snackbar
    // via a global ScaffoldMessengerKey.
    if (kIsWeb) return;

    const androidDetails = AndroidNotificationDetails(
      'pushka_notifications',
      'Pushka Notifications',
      channelDescription: 'General Pushka notifications',
      importance: Importance.high,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Foreground FCM: derive the route via the same whitelist used for
    // background/terminated taps and hand it in as payload. Without this the
    // tap fires `onDidReceiveNotificationResponse` with a null payload and
    // navigation never runs.
    final route = _routeFromMessage(message);

    await _localNotifications.show(
      _nextNotificationId++,
      notification.title,
      notification.body,
      details,
      payload: route,
    );
  }

  Future<void> showTestNotification() async {
    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'Pushka',
      'Notificación de prueba',
      _notificationDetails(),
    );
  }

  Future<void> _saveToken(String uid, String token) async {
    final tokensRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('fcmTokens')
        .doc(token);

    // MUST branch kIsWeb BEFORE any Platform.* access — dart:io Platform
    // throws UnsupportedError on web at first symbol touch. The Firestore
    // rules (validTokenDoc in firestore.rules) accept 'web' as a valid
    // platform value alongside 'android'/'ios'.
    final String platform;
    if (kIsWeb) {
      platform = 'web';
    } else {
      platform = Platform.isAndroid
          ? 'android'
          : Platform.isIOS
              ? 'ios'
              : Platform.operatingSystem;
    }
    // Round-5 audit MEDIUM fix: `createdAt` used to be overwritten on every
    // cold-start sync (merge doesn't preserve — it replaces). Read the doc
    // first and only set createdAt if it's missing (first write). lastUsedAt
    // always advances so cleanupStaleFcmTokens can prune inactive devices.
    final existing = await tokensRef.get();
    final payload = <String, dynamic>{
      'token': token,
      'platform': platform,
      'lastUsedAt': FieldValue.serverTimestamp(),
    };
    if (!existing.exists || existing.data()?['createdAt'] == null) {
      payload['createdAt'] = FieldValue.serverTimestamp();
    }
    await tokensRef.set(payload, SetOptions(merge: true));
  }

  /// Builds an [S] instance for the user's persisted language preference,
  /// falling back to Spanish if Hive isn't ready or the key is unset.
  ///
  /// Cold-start reminder resync runs without a [BuildContext] (main() has no
  /// widget tree yet), so we can't reach the S delegate through Localizations.
  /// Reading the same Hive key the LocaleNotifier writes on every language
  /// change keeps EN/FR/HE users from getting their reminder body reset to
  /// Spanish after every app relaunch.
  static S localizedTranslator() {
    try {
      final code = HiveCache.instance.loadLanguage();
      return S(Locale(code ?? 'es'));
    } catch (_) {
      return S(const Locale('es'));
    }
  }

  Future<void> scheduleReminder(Reminder reminder, {S? tr}) async {
    // Reminders programados no funcionan en PWA (flutter_local_notifications
    // es mobile-only). Falla silencioso — el user puede crear un reminder
    // en la PWA, se guarda en Firestore, pero no dispara hasta migrar
    // a app nativa. Trade-off aceptado del sideload plan.
    if (kIsWeb) return;
    if (!reminder.isEnabled) {
      await cancelReminder(reminder);
      return;
    }

    await cancelReminder(reminder);

    // Round-12 fix: re-check exact-alarms permission on every schedule so a
    // user who granted SCHEDULE_EXACT_ALARM via OS Settings mid-session
    // gets exact scheduling without a full app restart. Read-only — does
    // NOT open Settings. If revoked mid-session, _safeZonedSchedule still
    // catches the exact_alarms_not_permitted PlatformException and falls
    // back to inexact.
    await refreshExactAlarmsFlag();

    debugPrint('NotificationService.scheduleReminder: id=${reminder.id} '
        'title="${reminder.title}" days=${reminder.days} time=${reminder.time.hour}:${reminder.time.minute} '
        'minutesBefore=${reminder.minutesBefore} secondTime=${reminder.secondTime} '
        'secondDays=${reminder.secondDays} mode=${_androidScheduleMode.name} '
        'utcScheduling=$_useUtcScheduling');

    // Default the translator to the persisted language when the caller
    // didn't supply one (cold-start resync path — no BuildContext available).
    // Previously this fell through to the Spanish-only `reminder.subtitle`
    // getter, so EN/FR/HE users saw their reminder body revert to Spanish
    // after every app relaunch.
    final effectiveTr = tr ?? localizedTranslator();
    final body = reminder.subtitleFor(effectiveTr);
    final bodySecondary = reminder.subtitleSecondaryFor(effectiveTr);

    // Build the schedule plan up-front (cheap, in-memory) then fan out the
    // platform-channel calls in parallel. Sequential awaits used to take
    // ~7×2 = 14 round-trips per reminder; with several reminders + multi-
    // language scheduling each containing inner loops, the cumulative wait
    // dominated app start. Future.wait fans them out in one batch — the
    // plugin's underlying NotificationManager handles concurrent inserts
    // safely (each notification has a distinct integer ID via _notificationId).
    // One-shot chooseDate override. When the reminder was created with
    // "elegir fecha", we persisted the picked date in the reminders_meta
    // Hive box. Schedule a single non-recurring alarm — the previous code
    // path (days=[weekday] + dayOfWeekAndTime) reinterpreted the pick as
    // "every week on this weekday forever", which fires on the WRONG date
    // if today is not the picked weekday, and then keeps firing weekly.
    //
    // Round-5 audit HIGH fix: prefer reminder.oneShotDate (from Firestore
    // doc) over Hive-local. On a secondary device Hive never saw the pick
    // — falling back would schedule the reminder as WEEKLY recurring on
    // the wrong day.
    final oneShot = reminder.oneShotDate ?? _readOneShotDate(reminder.id);
    if (oneShot != null) {
      final when = _oneShotAt(oneShot, reminder.time, reminder.minutesBefore);
      if (when == null) {
        // Date is fully in the past — a leftover one-shot from an install
        // whose owner never opened the app in time. Drop it and clear the
        // local flag so we don't keep trying every cold-start.
        await clearOneShotDate(reminder.id);
        await _markResyncNeeded();
        return;
      }
      await _safeZonedSchedule(
        id: _notificationId(reminder.id, 0),
        title: reminder.title,
        body: body,
        when: when,
        payload: '/reminders',
        recurring: false,
      );
      await _markResyncNeeded();
      return;
    }

    final futures = <Future<void>>[];
    var index = 0;
    for (final weekday in reminder.days) {
      final scheduleTime = _nextInstanceOfWeekday(
        weekday,
        reminder.time,
        reminder.minutesBefore,
      );
      futures.add(_safeZonedSchedule(
        id: _notificationId(reminder.id, index++),
        title: reminder.title,
        body: body,
        when: scheduleTime,
        payload: '/reminders',
      ));
    }
    if (reminder.secondTime != null && reminder.secondDays.isNotEmpty) {
      for (final weekday in reminder.secondDays) {
        final scheduleTime = _nextInstanceOfWeekday(
          weekday,
          reminder.secondTime!,
          null,
        );
        futures.add(_safeZonedSchedule(
          id: _notificationId(reminder.id, index++),
          title: reminder.title,
          body: bodySecondary ?? body,
          when: scheduleTime,
          payload: '/reminders',
        ));
      }
    }
    await Future.wait(futures);
    // CRUD path — mark the meta flag so the NEXT cold-start resync knows the
    // Firestore state has diverged from OS-level alarms (defensive; the
    // schedule we just wrote is already correct).
    await _markResyncNeeded();
  }

  /// Builds the absolute wall-clock instant for a chooseDate one-shot.
  /// Returns null if the resulting DateTime is already in the past — the
  /// caller must then drop/cancel the reminder.
  tz.TZDateTime? _oneShotAt(DateTime date, TimeOfDay time, int? minutesBefore) {
    var scheduledLocal = DateTime(date.year, date.month, date.day,
        time.hour, time.minute);
    if (minutesBefore != null) {
      scheduledLocal = scheduledLocal.subtract(Duration(minutes: minutesBefore));
    }
    if (scheduledLocal.isBefore(DateTime.now())) return null;
    if (_useUtcScheduling) {
      return tz.TZDateTime.from(scheduledLocal.toUtc(), tz.UTC);
    }
    return tz.TZDateTime.from(scheduledLocal, tz.local);
  }

  /// Wraps `zonedSchedule` so an `exact_alarms_not_permitted` PlatformException
  /// (raised mid-session if the user revokes the permission after first grant)
  /// downgrades to inexact instead of dropping the schedule on the floor.
  Future<void> _safeZonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime when,
    String? payload,
    // Recurring reminders match on dayOfWeekAndTime so the OS re-fires
    // weekly. One-shot chooseDate reminders MUST omit this — otherwise the
    // OS treats them as weekly recurrences on the same weekday.
    bool recurring = true,
  }) async {
    debugPrint('NotificationService._safeZonedSchedule: id=$id '
        'when=$when timezone=${when.location.name} '
        'now=${tz.TZDateTime.now(when.location)} recurring=$recurring '
        'payload=$payload');
    final matchComponents =
        recurring ? DateTimeComponents.dayOfWeekAndTime : null;
    try {
      await _localNotifications.zonedSchedule(
        id,
        title,
        body,
        when,
        _notificationDetails(),
        androidScheduleMode: _androidScheduleMode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: matchComponents,
        payload: payload,
      );
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('exact_alarms_not_permitted') && _canScheduleExact) {
        debugPrint('NotificationService: exact alarms revoked at runtime, '
            'falling back to inexact scheduling.');
        _canScheduleExact = false;
        await _localNotifications.zonedSchedule(
          id,
          title,
          body,
          when,
          _notificationDetails(),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: matchComponents,
          payload: payload,
        );
      } else {
        rethrow;
      }
    }
  }

  Future<void> cancelReminder(Reminder reminder) async {
    if (kIsWeb) return;
    // 14 (7 days × 2 horarios) cancel calls fanned out in parallel — saves
    // ~14× the per-call platform-channel latency on app start, where the
    // app_initializer rescheduler cancels-then-reschedules every saved
    // reminder. cancel() is idempotent on a non-existent id, so concurrent
    // calls are safe.
    const maxSlots = 14;
    await Future.wait([
      for (var i = 0; i < maxSlots; i++)
        _localNotifications.cancel(_notificationId(reminder.id, i)),
    ]);
    await _markResyncNeeded();
  }

  /// Called from the reminders repo delete path so we don't leave a stale
  /// one-shot Hive entry pointing to a nonexistent reminder.
  Future<void> forgetReminder(Reminder reminder) async {
    await cancelReminder(reminder);
    await clearOneShotDate(reminder.id);
  }

  int _notificationId(String reminderId, int index) {
    final base = reminderId.hashCode & 0x7fffffff;
    // Mask the final value so the sum never exceeds 0x7fffffff (signed 32-bit
    // max). Android notification IDs are Java ints; overflow causes the plugin
    // to pass the wrong ID, breaking cancellation.
    return (base + index) & 0x7fffffff;
  }

  NotificationDetails _notificationDetails() {
    const androidDetails = AndroidNotificationDetails(
      'pushka_reminders',
      'Pushka Reminders',
      channelDescription: 'Scheduled reminders and alerts',
      importance: Importance.high,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails();
    return const NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
  }

  tz.TZDateTime _nextInstanceOfWeekday(
    int weekday,
    TimeOfDay time,
    int? minutesBefore,
  ) {
    final nowLocal = DateTime.now();
    var scheduledLocal = DateTime(
      nowLocal.year,
      nowLocal.month,
      nowLocal.day,
      time.hour,
      time.minute,
    );

    while (scheduledLocal.weekday != weekday) {
      scheduledLocal = scheduledLocal.add(const Duration(days: 1));
    }

    if (minutesBefore != null) {
      scheduledLocal = scheduledLocal.subtract(Duration(minutes: minutesBefore));
    }

    if (scheduledLocal.isBefore(nowLocal)) {
      scheduledLocal = scheduledLocal.add(const Duration(days: 7));
    }

    if (_useUtcScheduling) {
      return tz.TZDateTime.from(scheduledLocal.toUtc(), tz.UTC);
    }
    return tz.TZDateTime.from(scheduledLocal, tz.local);
  }
}
