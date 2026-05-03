import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

class AnalyticsService {
  AnalyticsService._();

  static final AnalyticsService instance = AnalyticsService._();

  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  // Non-fatal report so caught analytics errors are visible in production
  // (debugPrint is stripped from release builds).
  void _report(Object e, StackTrace st, String op, {Map<String, Object?>? extra}) {
    if (kDebugMode) {
      debugPrint('Analytics.$op error: $e');
    }
    try {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'analytics:$op',
        information: [
          if (extra != null)
            for (final entry in extra.entries) '${entry.key}=${entry.value}',
        ],
        fatal: false,
      );
    } catch (_) {
      // Crashlytics itself may be disabled (web, unsupported platform) — ignore.
    }
  }

  Future<void> setUserId(String? uid) async {
    try {
      await _analytics.setUserId(id: uid);
    } catch (e, st) {
      _report(e, st, 'setUserId');
    }
  }

  Future<void> logLogin(String method) async {
    try {
      await _analytics.logLogin(loginMethod: method);
    } catch (e, st) {
      _report(e, st, 'logLogin', extra: {'method': method});
    }
  }

  Future<void> logSignUp(String method) async {
    try {
      await _analytics.logSignUp(signUpMethod: method);
    } catch (e, st) {
      _report(e, st, 'logSignUp', extra: {'method': method});
    }
  }

  Future<void> logDonation(double amount, String currency) async {
    try {
      await _analytics.logEvent(
        name: 'donation',
        parameters: {
          'amount': amount,
          'currency': currency,
        },
      );
    } catch (e, st) {
      _report(e, st, 'logDonation', extra: {'amount': amount, 'currency': currency});
    }
  }

  Future<void> logPushkaEmpty(double amount) async {
    try {
      await _analytics.logEvent(
        name: 'pushka_empty',
        parameters: {'amount': amount},
      );
    } catch (e, st) {
      _report(e, st, 'logPushkaEmpty', extra: {'amount': amount});
    }
  }

  Future<void> logReminderCreated() async {
    try {
      await _analytics.logEvent(name: 'reminder_created');
    } catch (e, st) {
      _report(e, st, 'logReminderCreated');
    }
  }

  Future<void> logReminderUpdated() async {
    try {
      await _analytics.logEvent(name: 'reminder_updated');
    } catch (e, st) {
      _report(e, st, 'logReminderUpdated');
    }
  }

  Future<void> logReminderDeleted() async {
    try {
      await _analytics.logEvent(name: 'reminder_deleted');
    } catch (e, st) {
      _report(e, st, 'logReminderDeleted');
    }
  }
}
