import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../reminders/domain/reminder.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<String>? _tokenRefreshSub;
  String? _currentUid;
  bool _useUtcScheduling = false;

  Future<void> initialize() async {
    await _configureLocalTimezone();
    await _requestPermissions();
    await _requestLocalNotificationPermissions();
    await _initializeLocalNotifications();
    FirebaseMessaging.onMessage.listen(_showLocalNotification);
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
    _tokenRefreshSub = _messaging.onTokenRefresh.listen((token) async {
      await _saveToken(uid, token);
    });
  }

  Future<void> stopTokenRefresh() async {
    _currentUid = null;
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
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
    await _localNotifications.initialize(initSettings);
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    const androidDetails = AndroidNotificationDetails(
      'pushka_notifications',
      'Notificaciones Pushka',
      channelDescription: 'Notificaciones generales de Pushka',
      importance: Importance.high,
      priority: Priority.high,
    );

    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      notification.hashCode,
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

    await tokensRef.set({
      'token': token,
      'platform': Platform.operatingSystem,
      'createdAt': FieldValue.serverTimestamp(),
      'lastUsedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> scheduleReminder(Reminder reminder) async {
    if (!reminder.isEnabled) {
      await cancelReminder(reminder);
      return;
    }

    await cancelReminder(reminder);

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
        reminder.subtitle,
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
          reminder.subtitleSecondary ?? reminder.subtitle,
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
    return base + index;
  }

  NotificationDetails _notificationDetails() {
    const androidDetails = AndroidNotificationDetails(
      'pushka_reminders',
      'Recordatorios Pushka',
      channelDescription: 'Recordatorios y alertas programadas',
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
