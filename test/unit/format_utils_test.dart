import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/core/format_utils.dart';

/// Tests for formatMoney and formatAmount in core/format_utils.dart.
/// These cover the NaN/infinity guard added during a previous audit.
void main() {
  _testsMontoApplePay();

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

/// Blinda el monto que se le muestra a la persona en la hoja de Apple Pay.
///
/// Esta es la ultima pantalla antes de que salga la plata: dice un numero y
/// abajo esta el Face ID. Si ese numero no coincide con el cobro, es la peor
/// clase de bug — el donante autoriza una cosa y se le cobra otra.
///
/// La trampa concreta: `(units / 100).toStringAsFixed(2)` parece correcto y
/// lo es para USD, EUR e ILS. Para CLP, JPY y KRW —que NO tienen decimales—
/// muestra un total cien veces menor, y para BHD, que tiene tres, diez veces
/// mayor. La app acepta 21 monedas, entre ellas CLP.
///
/// Se verifico que falla: devolviendo siempre 2 decimales.
void _testsMontoApplePay() {
  group('stripeUnitsToPlainString', () {
    test('monedas de dos decimales', () {
      expect(stripeUnitsToPlainString(1050, 'usd'), '10.50');
      expect(stripeUnitsToPlainString(50000, 'mxn'), '500.00');
      expect(stripeUnitsToPlainString(1, 'eur'), '0.01');
    });

    test('monedas SIN decimales no se dividen por 100', () {
      // 10000 CLP son diez mil pesos, no cien.
      expect(stripeUnitsToPlainString(10000, 'clp'), '10000');
      expect(stripeUnitsToPlainString(1000, 'jpy'), '1000');
      expect(stripeUnitsToPlainString(50000, 'krw'), '50000');
    });

    test('monedas de tres decimales se dividen por 1000', () {
      expect(stripeUnitsToPlainString(10500, 'bhd'), '10.500');
    });

    test('no distingue mayusculas', () {
      expect(stripeUnitsToPlainString(10000, 'CLP'), '10000');
      expect(stripeUnitsToPlainString(1050, 'USD'), '10.50');
    });

    test('una moneda desconocida cae en dos decimales', () {
      // Stripe usa dos decimales para casi todo: es el default correcto.
      expect(stripeUnitsToPlainString(1050, 'xyz'), '10.50');
    });
  });
}
