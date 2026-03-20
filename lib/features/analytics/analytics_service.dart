import 'package:firebase_analytics/firebase_analytics.dart';

class AnalyticsService {
  AnalyticsService._();

  static final AnalyticsService instance = AnalyticsService._();

  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  Future<void> setUserId(String? uid) async {
    await _analytics.setUserId(id: uid);
  }

  Future<void> logLogin(String method) async {
    await _analytics.logLogin(loginMethod: method);
  }

  Future<void> logSignUp(String method) async {
    await _analytics.logSignUp(signUpMethod: method);
  }

  Future<void> logDonation(double amount, String currency) async {
    await _analytics.logEvent(
      name: 'donation',
      parameters: {
        'amount': amount,
        'currency': currency,
      },
    );
  }

  Future<void> logPushkaEmpty(double amount) async {
    await _analytics.logEvent(
      name: 'pushka_empty',
      parameters: {'amount': amount},
    );
  }

  Future<void> logWalletFill(double amount) async {
    await _analytics.logEvent(
      name: 'wallet_fill',
      parameters: {'amount': amount},
    );
  }

  Future<void> logWalletTransfer(double amount) async {
    await _analytics.logEvent(
      name: 'wallet_transfer',
      parameters: {'amount': amount},
    );
  }

  Future<void> logReminderCreated() async {
    await _analytics.logEvent(name: 'reminder_created');
  }

  Future<void> logReminderUpdated() async {
    await _analytics.logEvent(name: 'reminder_updated');
  }

  Future<void> logReminderDeleted() async {
    await _analytics.logEvent(name: 'reminder_deleted');
  }
}
