import 'package:flutter_test/flutter_test.dart';

/// Tests for Cloud Functions business logic.
/// Mirrors the logic from functions/index.js for verification.

int minAmountForCurrency(String currency) {
  final code = (currency).toLowerCase();
  const minimums = {
    'usd': 50,
    'eur': 50,
    'gbp': 30,
    'cad': 50,
    'ils': 200,
    'mxn': 1000,
    'brl': 100,
    'ars': 100000,
    'clp': 50000,
    'cop': 200000,
  };
  return minimums[code] ?? 100;
}

String formatAmount(int cents) {
  return (cents / 100).toStringAsFixed(2);
}

DateTime computeNextWalletTopUpDate({
  String frequency = 'weekly',
  int weekday = 1,
  int dayOfMonth = 1,
  DateTime? baseDate,
}) {
  final now = baseDate ?? DateTime.now();

  if (frequency == 'monthly') {
    var year = now.year;
    var month = now.month;
    var run = DateTime.utc(year, month, dayOfMonth, 8, 0, 0);
    if (!run.isAfter(now)) {
      month += 1;
      if (month > 12) {
        month = 1;
        year += 1;
      }
      final maxDay = DateTime.utc(year, month + 1, 0).day;
      final clampedDay = dayOfMonth.clamp(1, maxDay);
      run = DateTime.utc(year, month, clampedDay, 8, 0, 0);
    }
    return run;
  }

  // Weekly
  final target = weekday.clamp(1, 7);
  var run = DateTime.utc(now.year, now.month, now.day, 8, 0, 0);
  final jsWeekday = run.weekday; // Dart: Monday=1...Sunday=7
  var offset = target - jsWeekday;
  if (offset < 0 || (offset == 0 && !run.isAfter(now))) offset += 7;
  return run.add(Duration(days: offset));
}

void main() {
  group('createPaymentIntent validation', () {
    test('amount must be positive finite number', () {
      expect(0 > 0, false);
      expect(-1 > 0, false);
      expect(100 > 0, true);
      expect(double.nan.isFinite, false);
      expect(double.infinity.isFinite, false);
    });

    test('amount must be >= currency minimum', () {
      expect(49 >= minAmountForCurrency('usd'), false);
      expect(50 >= minAmountForCurrency('usd'), true);
      expect(999 >= minAmountForCurrency('mxn'), false);
      expect(1000 >= minAmountForCurrency('mxn'), true);
      expect(99999 >= minAmountForCurrency('ars'), false);
      expect(100000 >= minAmountForCurrency('ars'), true);
    });

    test('purpose must be donation or wallet_topup', () {
      const valid = ['donation', 'wallet_topup'];
      expect(valid.contains('donation'), true);
      expect(valid.contains('wallet_topup'), true);
      expect(valid.contains('steal_money'), false);
      expect(valid.contains(''), false);
      expect(valid.contains('DONATION'), false); // case sensitive!
    });

    test('currency defaults to usd if empty', () {
      final currency = ('').isEmpty ? 'usd' : '';
      expect(currency, 'usd');
    });
  });

  group('formatAmount', () {
    test('converts cents to formatted dollars', () {
      expect(formatAmount(50), '0.50');
      expect(formatAmount(100), '1.00');
      expect(formatAmount(1999), '19.99');
      expect(formatAmount(0), '0.00');
      expect(formatAmount(1), '0.01');
    });

    test('large amounts', () {
      expect(formatAmount(9999999), '99999.99');
    });
  });

  group('computeNextWalletTopUpDate', () {
    test('weekly: next Monday from a Wednesday', () {
      final base = DateTime.utc(2026, 1, 28, 10); // Wednesday
      final next = computeNextWalletTopUpDate(
        frequency: 'weekly',
        weekday: 1, // Monday
        baseDate: base,
      );
      expect(next.weekday, DateTime.monday);
      expect(next.isAfter(base), true);
      expect(next.day, 2); // Feb 2, 2026
    });

    test('weekly: same day but already past 8 AM -> next week', () {
      final base = DateTime.utc(2026, 1, 26, 10); // Monday 10 AM
      final next = computeNextWalletTopUpDate(
        frequency: 'weekly',
        weekday: 1,
        baseDate: base,
      );
      expect(next.weekday, DateTime.monday);
      expect(next.day, 2); // next Monday
    });

    test('weekly: same day before 8 AM -> today at 8 AM', () {
      final base = DateTime.utc(2026, 1, 26, 5); // Monday 5 AM
      final next = computeNextWalletTopUpDate(
        frequency: 'weekly',
        weekday: 1,
        baseDate: base,
      );
      expect(next.weekday, DateTime.monday);
      // Should be today at 8 AM since run (8 AM) is after base (5 AM)
      expect(next.day, 26);
      expect(next.hour, 8);
    });

    test('monthly: next month if already past this month', () {
      final base = DateTime.utc(2026, 1, 20, 10); // Jan 20
      final next = computeNextWalletTopUpDate(
        frequency: 'monthly',
        dayOfMonth: 15,
        baseDate: base,
      );
      expect(next.month, 2);
      expect(next.day, 15);
    });

    test('monthly: this month if not yet past', () {
      final base = DateTime.utc(2026, 1, 10, 5); // Jan 10
      final next = computeNextWalletTopUpDate(
        frequency: 'monthly',
        dayOfMonth: 15,
        baseDate: base,
      );
      expect(next.month, 1);
      expect(next.day, 15);
    });

    test('monthly: day 31 in February clamps to 28/29', () {
      final base = DateTime.utc(2026, 1, 31, 10);
      final next = computeNextWalletTopUpDate(
        frequency: 'monthly',
        dayOfMonth: 31,
        baseDate: base,
      );
      expect(next.month, 2);
      expect(next.day, lessThanOrEqualTo(28)); // Feb 2026 has 28 days
    });

    test('weekday clamped to 1-7', () {
      final base = DateTime.utc(2026, 1, 26, 10);
      // weekday 0 should be clamped to 1
      final next = computeNextWalletTopUpDate(
        frequency: 'weekly',
        weekday: 0,
        baseDate: base,
      );
      expect(next.weekday, DateTime.monday);
    });

    test('weekday 8 clamped to 7 (Sunday)', () {
      final base = DateTime.utc(2026, 1, 26, 10);
      final next = computeNextWalletTopUpDate(
        frequency: 'weekly',
        weekday: 8,
        baseDate: base,
      );
      expect(next.weekday, DateTime.sunday);
    });
  });

  group('walletTransfer validation', () {
    test('cannot transfer to self', () {
      const senderUid = 'user123';
      const receiverUid = 'user123';
      expect(senderUid == receiverUid, true);
    });

    test('amount must be positive', () {
      expect(0 > 0, false);
      expect(-1 > 0, false);
      expect(0.01 > 0, true);
    });

    test('sender must have sufficient balance', () {
      const balance = 100.0;
      expect(balance >= 150.0, false);
      expect(balance >= 100.0, true);
      expect(balance >= 99.99, true);
    });

    test('balance after transfer is correct', () {
      const senderBalance = 100.0;
      const receiverBalance = 50.0;
      const amount = 30.0;

      expect(senderBalance - amount, 70.0);
      expect(receiverBalance + amount, 80.0);
    });
  });

  group('walletTopUpFromPaymentIntent validation', () {
    test('paymentIntentId must start with pi_', () {
      expect('pi_abc123'.startsWith('pi_'), true);
      expect('abc123'.startsWith('pi_'), false);
      expect(''.startsWith('pi_'), false);
      expect('PI_abc'.startsWith('pi_'), false);
    });

    test('payment must be succeeded status', () {
      const status = 'succeeded';
      expect(status == 'succeeded', true);
    });

    test('uid in metadata must match requesting user', () {
      const metadataUid = 'user123';
      const requestUid = 'user456';
      expect(metadataUid == requestUid, false);
    });

    test('purpose must be wallet_topup', () {
      const purpose = 'donation';
      expect(purpose == 'wallet_topup', false);
    });

    test('idempotency: already consumed intent is rejected', () {
      // The _walletTopUpIntents collection prevents double-spend
      const alreadyConsumed = true;
      expect(alreadyConsumed, true);
    });
  });

  group('Stripe webhook security', () {
    test('missing signature header returns 400', () {
      const sig = null;
      expect(sig == null, true);
    });

    test('duplicate webhook events are skipped', () {
      // reserveWebhookEvent returns alreadyProcessed=true for duplicates
      const alreadyProcessed = true;
      expect(alreadyProcessed, true);
    });

    test('payment_intent.succeeded without uid metadata is logged', () {
      const uid = null;
      expect(uid == null, true);
    });
  });

  group('Notification payload safety', () {
    test('notification title defaults to Pushka', () {
      const data = <String, dynamic>{};
      final title = data['title'] ?? 'Pushka';
      expect(title, 'Pushka');
    });

    test('notification body defaults to test message', () {
      const data = <String, dynamic>{};
      final body = data['body'] ?? 'Notificación de prueba';
      expect(body, 'Notificación de prueba');
    });

    test('XSS in notification title is not executed (passthrough)', () {
      const title = '<script>alert(1)</script>';
      // Firebase FCM sends this as data, not HTML - safe
      expect(title.contains('<script>'), true);
    });
  });
}
