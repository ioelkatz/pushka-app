import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

class AnalyticsService {
  AnalyticsService._();

  static final AnalyticsService instance = AnalyticsService._();

  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  Future<void> setUserId(String? uid) async {
    try {
      await _analytics.setUserId(id: uid);
    } catch (e) {
      debugPrint('Analytics.setUserId error: $e');
    }
  }

  Future<void> logLogin(String method) async {
    try {
      await _analytics.logLogin(loginMethod: method);
    } catch (e) {
      debugPrint('Analytics.logLogin error: $e');
    }
  }

  Future<void> logSignUp(String method) async {
    try {
      await _analytics.logSignUp(signUpMethod: method);
    } catch (e) {
      debugPrint('Analytics.logSignUp error: $e');
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
    } catch (e) {
      debugPrint('Analytics.logDonation error: $e');
    }
  }

  Future<void> logPushkaEmpty(double amount) async {
    try {
      await _analytics.logEvent(
        name: 'pushka_empty',
        parameters: {'amount': amount},
      );
    } catch (e) {
      debugPrint('Analytics.logPushkaEmpty error: $e');
    }
  }

  Future<void> logWalletFill(double amount) async {
    try {
      await _analytics.logEvent(
        name: 'wallet_fill',
        parameters: {'amount': amount},
      );
    } catch (e) {
      debugPrint('Analytics.logWalletFill error: $e');
    }
  }

  Future<void> logWalletTransfer(double amount) async {
    try {
      await _analytics.logEvent(
        name: 'wallet_transfer',
        parameters: {'amount': amount},
      );
    } catch (e) {
      debugPrint('Analytics.logWalletTransfer error: $e');
    }
  }

  Future<void> logReminderCreated() async {
    try {
      await _analytics.logEvent(name: 'reminder_created');
    } catch (e) {
      debugPrint('Analytics.logReminderCreated error: $e');
    }
  }

  Future<void> logReminderUpdated() async {
    try {
      await _analytics.logEvent(name: 'reminder_updated');
    } catch (e) {
      debugPrint('Analytics.logReminderUpdated error: $e');
    }
  }

  Future<void> logReminderDeleted() async {
    try {
      await _analytics.logEvent(name: 'reminder_deleted');
    } catch (e) {
      debugPrint('Analytics.logReminderDeleted error: $e');
    }
  }
}
