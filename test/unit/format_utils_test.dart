import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/core/format_utils.dart';

/// Tests for formatMoney and formatAmount in core/format_utils.dart.
/// These cover the NaN/infinity guard added during a previous audit.
void main() {
  group('formatMoney — happy paths', () {
    test('whole number shows no decimals', () {
      expect(formatMoney(10, symbol: 'US\$'), 'US\$10');
      expect(formatMoney(1000, symbol: '\$'), '\$1,000');
      expect(formatMoney(0, symbol: '€'), '€0');
    });

    test('fractional amounts show 2 decimals', () {
      expect(formatMoney(10.50, symbol: '\$'), '\$10.50');
      expect(formatMoney(9.99, symbol: '€'), '€9.99');
    });

    test('thousand separator is present for large amounts', () {
      expect(formatMoney(1234.0, symbol: '\$'), '\$1,234');
      expect(formatMoney(1000000.0, symbol: 'R\$'), 'R\$1,000,000');
    });

    test('uses custom symbol', () {
      expect(formatMoney(5.0, symbol: '₪'), '₪5');
      expect(formatMoney(5.0, symbol: 'MX\$'), 'MX\$5');
    });

    test('default symbol is \$', () {
      expect(formatMoney(1.0), '\$1');
    });
  });

  group('formatMoney — NaN / Infinity guard (critical: would crash .round())', () {
    test('NaN returns symbol + dash, does NOT throw', () {
      expect(() => formatMoney(double.nan), returnsNormally);
      expect(formatMoney(double.nan, symbol: '\$'), '\$–');
    });

    test('positive infinity returns symbol + dash, does NOT throw', () {
      expect(() => formatMoney(double.infinity), returnsNormally);
      expect(formatMoney(double.infinity, symbol: '€'), '€–');
    });

    test('negative infinity returns symbol + dash, does NOT throw', () {
      expect(() => formatMoney(double.negativeInfinity), returnsNormally);
      expect(formatMoney(double.negativeInfinity, symbol: '£'), '£–');
    });
  });

  group('formatAmount — happy paths', () {
    test('whole number shows no decimals', () {
      expect(formatAmount(100), '100');
      expect(formatAmount(1000), '1,000');
    });

    test('fractional amount shows 2 decimals', () {
      expect(formatAmount(9.99), '9.99');
      expect(formatAmount(0.50), '0.50');
    });
  });

  group('formatAmount — NaN / Infinity guard', () {
    test('NaN returns dash, does NOT throw', () {
      expect(() => formatAmount(double.nan), returnsNormally);
      expect(formatAmount(double.nan), '–');
    });

    test('positive infinity returns dash, does NOT throw', () {
      expect(() => formatAmount(double.infinity), returnsNormally);
      expect(formatAmount(double.infinity), '–');
    });

    test('negative infinity returns dash, does NOT throw', () {
      expect(() => formatAmount(double.negativeInfinity), returnsNormally);
      expect(formatAmount(double.negativeInfinity), '–');
    });
  });

  group('formatMoney — edge values', () {
    test('very small fractional amount', () {
      expect(formatMoney(0.01, symbol: '\$'), '\$0.01');
    });

    test('amount just below 1e15 is not treated as huge', () {
      // The whole-number branch uses value.abs() < 1e15 guard
      final big = 1e14;
      expect(formatMoney(big, symbol: '\$'), contains('\$'));
    });
  });
}
