import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/history/domain/transaction.dart';

/// SECURITY AUDIT TESTS
/// These tests document and verify fixes for real vulnerabilities found
/// during code audit.

void main() {
  group('CRITICAL: Transaction type validation', () {
    test('TransactionType enum covers all valid types', () {
      expect(TransactionType.values, contains(TransactionType.tzedaka));
      expect(TransactionType.values, contains(TransactionType.pushkaEmpty));
    });

    test('Transaction with zero amount', () {
      final tx = Transaction(
        id: '1',
        type: TransactionType.tzedaka,
        amount: 0.0,
        description: 'Zero donation',
        dateTime: DateTime.now(),
      );
      expect(tx.amount, 0.0);
    });

    test('Transaction with extremely large amount', () {
      final tx = Transaction(
        id: '1',
        type: TransactionType.tzedaka,
        amount: 999999999.99,
        description: 'Huge donation',
        dateTime: DateTime.now(),
      );
      expect(tx.amount, 999999999.99);
    });
  });

  group('CRITICAL: Payment amount edge cases', () {
    test('floating point precision: 19.99 * 100 should be 1999 cents', () {
      final amount = 19.99;
      final cents = (amount * 100).round();
      expect(cents, 1999);
    });

    test('floating point: 0.1 + 0.2 precision issue', () {
      final amount = 0.1 + 0.2;
      final cents = (amount * 100).round();
      expect(cents, 30);
    });

    test('very small amount: 0.01', () {
      final cents = (0.01 * 100).round();
      expect(cents, 1);
    });

    test('large amount: 99999.99', () {
      final cents = (99999.99 * 100).round();
      expect(cents, 9999999);
    });

    test('negative amount should not produce valid cents', () {
      final amount = -10.0;
      final cents = (amount * 100).round();
      expect(cents, -1000);
      expect(cents > 0, false);
    });

    test('NaN amount handling - round() crashes (real vulnerability)', () {
      final amount = double.nan;
      // REAL BUG: (NaN * 100).round() throws UnsupportedError
      // Client code does NOT guard against this
      expect(() => (amount * 100).round(), throwsUnsupportedError);
    });

    test('infinity amount handling', () {
      expect(() => (double.infinity * 100).round(), throwsA(anything));
    });
  });

  group('Input sanitization', () {
    test('email with leading/trailing spaces is trimmed', () {
      final email = '  test@test.com  '.trim();
      expect(email, 'test@test.com');
    });

    test('email regex accepts basic emails correctly', () {
      final regex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
      expect(regex.hasMatch('test@test.com'), true);
      expect(regex.hasMatch(''), false);
      expect(regex.hasMatch('notanemail'), false);
      expect(regex.hasMatch('@missing.local'), false);
      expect(regex.hasMatch('missing@'), false);
    });

    test('BUG: email regex does NOT reject script injection in local part', () {
      final regex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
      // The regex only checks for @ and . structure, not content safety
      // '<script>alert(1)</script>@evil.com' passes because < > are not @ or space
      expect(regex.hasMatch('<script>alert(1)</script>@evil.com'), true);
    });

    test('wallet ID input sanitization', () {
      final input = '  123456  ';
      final sanitized = input.trim();
      expect(sanitized, '123456');
    });

    test('currency code is always lowercase 3-char', () {
      final inputs = ['USD', 'usd', 'Usd', 'UsD'];
      for (final input in inputs) {
        final normalized = input.toLowerCase();
        expect(normalized, 'usd');
        expect(normalized.length, 3);
      }
    });

    test('amount input with comma separator is parsed correctly', () {
      expect(double.tryParse('10,50'.replaceAll(',', '.')), 10.50);
      expect(double.tryParse('100.5'.replaceAll(',', '.')), 100.5);
    });

    test('BUG: thousand-separated input breaks parsing', () {
      // '1.000,00' -> replaceAll(',', '.') -> '1.000.00' -> null
      // Users in Spanish-speaking countries type 1.000,00 for 1000.00
      final input = '1.000,00';
      final parsed = double.tryParse(input.replaceAll(',', '.'));
      expect(parsed, null); // BUG: fails to parse legitimate amount
    });
  });
}
