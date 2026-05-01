import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../reminders/domain/reminder.dart';
import '../../core/l10n/s.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<String>? _tokenRefreshSub;
  String? _currentUid;
  bool _useUtcScheduling = false;

  // Monotonically increasing ID so notifications never overwrite each other.
  // hashCode is not unique across different objects — a counter is safe.
  int _nextNotificationId = 1;

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
    await _configureLocalTimezone();
    try {
      await _requestPermissions();
    } catch (e) {
      debugPrint('NotificationService.initialize: FCM permission request failed: $e');
    }
    try {
      await _requestLocalNotificationPermissions();
    } catch (e) {
      debugPrint('NotificationService.initialize: local permission request failed: $e');
    }
    await _initializeLocalNotifications();
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
    '/', '/history', '/reminders', '/settings',
    '/prayers', '/support', '/about',
  };

  String? _routeFromMessage(RemoteMessage message) {
    final data = message.data;
    // Cloud Functions can send { "route": "/history" } etc.
    // Always validate against the whitelist before navigating.
    final explicit = data['route'] as String?;
    if (explicit != null && _allowedRoutes.contains(explicit)) return explicit;

    final type = data['type'] as String?;
    return switch (type) {
      'pushkaEmpty' => '/history',
      'reminder' => '/',
      _ => null,
    };
  }

  Future<void> syncFcmToken(String uid) async {
    final token = await _messaging.getToken();
    if (token == null) return;
    await _saveToken(uid, token);
  }

  void listenForTokenRefresh(String uid) {
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
      token = await _messaging.getToken();
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
  }

  Future<void> _requestPermissions() async {
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  Future<void> _requestLocalNotificationPermissions() async {
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.requestExactAlarmsPermission();

    final iosPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    await iosPlugin?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

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
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

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

    await _localNotifications.show(
      _nextNotificationId++,
      notification.title,
      notification.body,
      details,
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

    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isIOS
            ? 'ios'
            : Platform.operatingSystem;
    await tokensRef.set({
      'token': token,
      'platform': platform,
      'createdAt': FieldValue.serverTimestamp(),
      'lastUsedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> scheduleReminder(Reminder reminder, {S? tr}) async {
    if (!reminder.isEnabled) {
      await cancelReminder(reminder);
      return;
    }

    await cancelReminder(reminder);

    final body = tr != null ? reminder.subtitleFor(tr) : reminder.subtitle;
    final bodySecondary = tr != null
        ? reminder.subtitleSecondaryFor(tr)
        : reminder.subtitleSecondary;

    var index = 0;
    for (final weekday in reminder.days) {
      final scheduleTime = _nextInstanceOfWeekday(
        weekday,
        reminder.time,
        reminder.minutesBefore,
      );
      await _localNotifications.zonedSchedule(
        _notificationId(reminder.id, index++),
        reminder.title,
        body,
        scheduleTime,
        _notificationDetails(),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    }

    if (reminder.secondTime != null && reminder.secondDays.isNotEmpty) {
      for (final weekday in reminder.secondDays) {
        final scheduleTime = _nextInstanceOfWeekday(
          weekday,
          reminder.secondTime!,
          null,
        );
        await _localNotifications.zonedSchedule(
          _notificationId(reminder.id, index++),
          reminder.title,
          bodySecondary ?? body,
          scheduleTime,
          _notificationDetails(),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        );
      }
    }
  }

  Future<void> cancelReminder(Reminder reminder) async {
    const maxSlots = 14; // 7 dias x 2 horarios
    for (var i = 0; i < maxSlots; i++) {
      await _localNotifications.cancel(_notificationId(reminder.id, i));
    }
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
