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

  /// Round-8 audit HIGH fix: use GA4's standard `purchase` event so
  /// donations show up in native GA4 revenue reports (previously the custom
  /// `donation` event was invisible to GA4's revenue dashboard). Optional
  /// contextual fields for slicing: donation_reason, payment_method, tenant_id.
  Future<void> logDonation(
    double amount,
    String currency, {
    String? donationReason,
    String? paymentMethod,
    String? tenantId,
  }) async {
    try {
      await _analytics.logEvent(
        name: 'purchase',
        parameters: {
          'value': amount,
          'currency': currency.toUpperCase(),
          'transaction_id': DateTime.now().microsecondsSinceEpoch.toString(),
          if (donationReason != null && donationReason.isNotEmpty) 'donation_reason': donationReason,
          if (paymentMethod != null && paymentMethod.isNotEmpty) 'payment_method': paymentMethod,
          if (tenantId != null && tenantId.isNotEmpty) 'tenant_id': tenantId,
        },
      );
    } catch (e, st) {
      _report(e, st, 'logDonation', extra: {'amount': amount, 'currency': currency});
    }
  }

  /// Round-8 audit HIGH fix: currency dimension for slicing pushka_empty
  /// aggregations. Previously all currencies collapsed into one bucket.
  Future<void> logPushkaEmpty(double amount, {String currency = 'USD'}) async {
    try {
      await _analytics.logEvent(
        name: 'pushka_empty',
        parameters: {
          'amount': amount,
          'currency': currency.toUpperCase(),
        },
      );
    } catch (e, st) {
      _report(e, st, 'logPushkaEmpty', extra: {'amount': amount, 'currency': currency});
    }
  }

  /// Round-8 audit MEDIUM fix: track donation intent lifecycle (not just
  /// success). Lets us measure funnel drop-off (initiated -> succeeded,
  /// initiated -> failed, initiated -> canceled).
  Future<void> logDonationInitiated({
    required double amount,
    required String currency,
    String? tenantId,
  }) async {
    try {
      await _analytics.logEvent(name: 'donation_initiated', parameters: {
        'amount': amount, 'currency': currency.toUpperCase(),
        if (tenantId != null && tenantId.isNotEmpty) 'tenant_id': tenantId,
      });
    } catch (e, st) { _report(e, st, 'logDonationInitiated'); }
  }

  Future<void> logDonationFailed({
    required String reason,
    String? currency,
  }) async {
    try {
      await _analytics.logEvent(name: 'donation_failed', parameters: {
        'reason': reason,
        if (currency != null) 'currency': currency.toUpperCase(),
      });
    } catch (e, st) { _report(e, st, 'logDonationFailed'); }
  }

  Future<void> logDonationCanceled({String? currency}) async {
    try {
      await _analytics.logEvent(name: 'donation_canceled', parameters: {
        if (currency != null) 'currency': currency.toUpperCase(),
      });
    } catch (e, st) { _report(e, st, 'logDonationCanceled'); }
  }

  /// Round-8 audit HIGH fix: MRR is invisible without these. Sub create/cancel
  /// are the two key business events post-launch.
  Future<void> logSubscriptionCreated({
    required double amount,
    required String currency,
    String? interval,
    String? tenantId,
  }) async {
    try {
      await _analytics.logEvent(name: 'subscription_created', parameters: {
        'value': amount, 'currency': currency.toUpperCase(),
        if (interval != null && interval.isNotEmpty) 'interval': interval,
        if (tenantId != null && tenantId.isNotEmpty) 'tenant_id': tenantId,
      });
    } catch (e, st) { _report(e, st, 'logSubscriptionCreated'); }
  }

  Future<void> logSubscriptionCanceled({String? tenantId}) async {
    try {
      await _analytics.logEvent(name: 'subscription_canceled', parameters: {
        if (tenantId != null && tenantId.isNotEmpty) 'tenant_id': tenantId,
      });
    } catch (e, st) { _report(e, st, 'logSubscriptionCanceled'); }
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
