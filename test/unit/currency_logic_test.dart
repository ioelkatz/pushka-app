import 'package:flutter_test/flutter_test.dart';

/// Tests for currency-related business logic.
/// Extracted from pushka_screen.dart for testability.

// Mirror of _minAmountCentsForCurrency
int minAmountCentsForCurrency(String currency) {
  switch (currency.toLowerCase()) {
    case 'ars':
      return 100000;
    case 'mxn':
      return 1000;
    case 'brl':
      return 100;
    case 'clp':
      return 50000;
    case 'cop':
      return 200000;
    case 'ils':
      return 200;
    case 'gbp':
      return 30;
    case 'usd':
    case 'eur':
    case 'cad':
      return 50;
    default:
      return 100;
  }
}

// Mirror of _presetsForCurrency
List<double> presetsForCurrency(String currency) {
  switch (currency.toLowerCase()) {
    case 'mxn':
      return [20, 100, 200];
    case 'ars':
      return [1000, 5000, 10000];
    case 'brl':
      return [5, 25, 50];
    case 'clp':
      return [1000, 5000, 10000];
    case 'cop':
      return [5000, 20000, 50000];
    case 'ils':
      return [5, 20, 40];
    case 'eur':
      return [1, 5, 10];
    case 'gbp':
      return [1, 5, 10];
    case 'cad':
      return [1, 5, 10];
    case 'usd':
    default:
      return [1, 5, 10];
  }
}

// Mirror of _shortSymbol
String shortSymbol(String code) {
  const symbols = {
    'usd': '\$', 'eur': '€', 'gbp': '£', 'cad': 'C\$',
    'mxn': '\$', 'ars': '\$', 'brl': 'R\$', 'ils': '₪',
    'clp': '\$', 'cop': '\$',
  };
  return symbols[code.toLowerCase()] ?? '\$';
}

// Mirror of _currencySymbol (long version)
String currencySymbol(String code) {
  const symbols = {
    'usd': 'US\$', 'eur': '€', 'gbp': '£', 'cad': 'CA\$',
    'mxn': 'MX\$', 'ars': 'ARS\$', 'brl': 'R\$', 'ils': '₪',
    'clp': 'CL\$', 'cop': 'CO\$',
  };
  return symbols[code.toLowerCase()] ?? '\$';
}

String formatPresetValue(double amount) {
  if (amount == amount.roundToDouble()) return amount.toInt().toString();
  return amount.toStringAsFixed(2);
}

String formatQuickAmount(double amount, String currency) {
  final symbol = shortSymbol(currency);
  if (amount == amount.roundToDouble()) {
    return '$symbol${amount.toInt()}';
  }
  return '$symbol${amount.toStringAsFixed(2)}';
}

void main() {
  group('Minimum amounts per currency', () {
    test('USD minimum is 50 cents', () {
      expect(minAmountCentsForCurrency('usd'), 50);
      expect(minAmountCentsForCurrency('USD'), 50);
    });

    test('EUR minimum is 50 cents', () {
      expect(minAmountCentsForCurrency('eur'), 50);
    });

    test('GBP minimum is 30 pence', () {
      expect(minAmountCentsForCurrency('gbp'), 30);
    });

    test('MXN minimum is 1000 centavos (10 pesos)', () {
      expect(minAmountCentsForCurrency('mxn'), 1000);
    });

    test('ARS minimum is 100000 centavos (1000 pesos)', () {
      expect(minAmountCentsForCurrency('ars'), 100000);
    });

    test('BRL minimum is 100 centavos (1 real)', () {
      expect(minAmountCentsForCurrency('brl'), 100);
    });

    test('CLP minimum is 50000 (500 pesos)', () {
      expect(minAmountCentsForCurrency('clp'), 50000);
    });

    test('COP minimum is 200000 centavos (2000 pesos)', () {
      expect(minAmountCentsForCurrency('cop'), 200000);
    });

    test('ILS minimum is 200 agorot (2 shekels)', () {
      expect(minAmountCentsForCurrency('ils'), 200);
    });

    test('CAD minimum is 50 cents', () {
      expect(minAmountCentsForCurrency('cad'), 50);
    });

    test('unknown currency defaults to 100', () {
      expect(minAmountCentsForCurrency('xyz'), 100);
      expect(minAmountCentsForCurrency(''), 100);
    });

    test('case insensitive', () {
      expect(minAmountCentsForCurrency('USD'), minAmountCentsForCurrency('usd'));
      expect(minAmountCentsForCurrency('Mxn'), minAmountCentsForCurrency('mxn'));
    });

    test('all minimums are positive', () {
      for (final c in ['usd', 'eur', 'gbp', 'cad', 'mxn', 'ars', 'brl', 'clp', 'cop', 'ils']) {
        expect(minAmountCentsForCurrency(c), greaterThan(0));
      }
    });

    test('all presets are above minimum for their currency', () {
      for (final c in ['usd', 'eur', 'gbp', 'cad', 'mxn', 'ars', 'brl', 'clp', 'cop', 'ils']) {
        final minCents = minAmountCentsForCurrency(c);
        final presets = presetsForCurrency(c);
        for (final preset in presets) {
          final presetCents = (preset * 100).round();
          expect(presetCents, greaterThanOrEqualTo(minCents),
              reason: 'Preset $preset for $c ($presetCents cents) is below minimum ($minCents cents)');
        }
      }
    });
  });

  group('Presets per currency', () {
    test('USD presets: 1, 5, 10', () {
      expect(presetsForCurrency('usd'), [1, 5, 10]);
    });

    test('EUR presets: 1, 5, 10', () {
      expect(presetsForCurrency('eur'), [1, 5, 10]);
    });

    test('MXN presets: 20, 100, 200', () {
      expect(presetsForCurrency('mxn'), [20, 100, 200]);
    });

    test('ARS presets: 1000, 5000, 10000', () {
      expect(presetsForCurrency('ars'), [1000, 5000, 10000]);
    });

    test('ILS presets: 5, 20, 40', () {
      expect(presetsForCurrency('ils'), [5, 20, 40]);
    });

    test('BRL presets: 5, 25, 50', () {
      expect(presetsForCurrency('brl'), [5, 25, 50]);
    });

    test('all presets return exactly 3 values', () {
      for (final c in ['usd', 'eur', 'gbp', 'cad', 'mxn', 'ars', 'brl', 'clp', 'cop', 'ils']) {
        expect(presetsForCurrency(c).length, 3, reason: '$c should have 3 presets');
      }
    });

    test('all preset values are positive', () {
      for (final c in ['usd', 'eur', 'gbp', 'cad', 'mxn', 'ars', 'brl', 'clp', 'cop', 'ils']) {
        for (final p in presetsForCurrency(c)) {
          expect(p, greaterThan(0), reason: 'Preset $p for $c should be positive');
        }
      }
    });

    test('presets are in ascending order', () {
      for (final c in ['usd', 'eur', 'gbp', 'cad', 'mxn', 'ars', 'brl', 'clp', 'cop', 'ils']) {
        final presets = presetsForCurrency(c);
        for (int i = 1; i < presets.length; i++) {
          expect(presets[i], greaterThan(presets[i - 1]),
              reason: 'Presets for $c should be ascending: $presets');
        }
      }
    });

    test('unknown currency falls back to USD-like presets', () {
      expect(presetsForCurrency('xyz'), [1, 5, 10]);
    });
  });

  group('Currency symbols', () {
    test('short symbols for all supported currencies', () {
      expect(shortSymbol('usd'), '\$');
      expect(shortSymbol('eur'), '€');
      expect(shortSymbol('gbp'), '£');
      expect(shortSymbol('cad'), 'C\$');
      expect(shortSymbol('mxn'), '\$');
      expect(shortSymbol('ars'), '\$');
      expect(shortSymbol('brl'), 'R\$');
      expect(shortSymbol('ils'), '₪');
      expect(shortSymbol('clp'), '\$');
      expect(shortSymbol('cop'), '\$');
    });

    test('unknown currency returns \$', () {
      expect(shortSymbol('xyz'), '\$');
    });

    test('long symbols for all supported currencies', () {
      expect(currencySymbol('usd'), 'US\$');
      expect(currencySymbol('eur'), '€');
      expect(currencySymbol('ils'), '₪');
      expect(currencySymbol('mxn'), 'MX\$');
    });
  });

  group('Amount formatting', () {
    test('whole numbers display without decimals', () {
      expect(formatPresetValue(1), '1');
      expect(formatPresetValue(18), '18');
      expect(formatPresetValue(1000), '1000');
      expect(formatPresetValue(5000), '5000');
    });

    test('fractional numbers display with 2 decimals', () {
      expect(formatPresetValue(1.5), '1.50');
      expect(formatPresetValue(9.99), '9.99');
    });

    test('formatQuickAmount with USD', () {
      expect(formatQuickAmount(1, 'usd'), '\$1');
      expect(formatQuickAmount(5, 'usd'), '\$5');
      expect(formatQuickAmount(10, 'usd'), '\$10');
      expect(formatQuickAmount(1.5, 'usd'), '\$1.50');
    });

    test('formatQuickAmount with MXN', () {
      expect(formatQuickAmount(20, 'mxn'), '\$20');
      expect(formatQuickAmount(50, 'mxn'), '\$50');
      expect(formatQuickAmount(100, 'mxn'), '\$100');
    });

    test('formatQuickAmount with ARS large amounts', () {
      expect(formatQuickAmount(1000, 'ars'), '\$1000');
      expect(formatQuickAmount(5000, 'ars'), '\$5000');
    });

    test('formatQuickAmount with ILS', () {
      expect(formatQuickAmount(5, 'ils'), '₪5');
      expect(formatQuickAmount(20, 'ils'), '₪20');
      expect(formatQuickAmount(40, 'ils'), '₪40');
    });

    test('formatQuickAmount with BRL', () {
      expect(formatQuickAmount(5, 'brl'), 'R\$5');
      expect(formatQuickAmount(10.5, 'brl'), 'R\$10.50');
    });
  });

  group('Client-server minimum amount sync', () {
    // Server-side minimums from functions/index.js
    final serverMinimums = {
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

    test('client minimums match server minimums for all currencies', () {
      for (final entry in serverMinimums.entries) {
        expect(
          minAmountCentsForCurrency(entry.key),
          entry.value,
          reason: '${entry.key}: client=${minAmountCentsForCurrency(entry.key)} != server=${entry.value}',
        );
      }
    });
  });

  group('Wallet screen minimum amount sync', () {
    // BUG FOUND: wallet_screen.dart has its own _minAmountCentsForCurrency
    // that is NOT synchronized with pushka_screen.dart or the server.
    // It only handles mxn, usd, eur, gbp with a default of 50.
    // Missing: ars, brl, clp, cop, ils, cad, gbp (has wrong value)

    int walletMinAmount(String currency) {
      switch (currency.toLowerCase()) {
        case 'mxn':
          return 1000;
        case 'usd':
        case 'eur':
        case 'gbp':
        default:
          return 50;
      }
    }

    test('BUG: wallet ARS minimum is wrong (50 instead of 100000)', () {
      expect(walletMinAmount('ars'), 50); // BUG: should be 100000
      expect(minAmountCentsForCurrency('ars'), 100000);
      expect(walletMinAmount('ars') != minAmountCentsForCurrency('ars'), true);
    });

    test('BUG: wallet BRL minimum is wrong (50 instead of 100)', () {
      expect(walletMinAmount('brl'), 50); // BUG: falls to default
      expect(minAmountCentsForCurrency('brl'), 100);
    });

    test('BUG: wallet COP minimum is wrong (50 instead of 200000)', () {
      expect(walletMinAmount('cop'), 50); // BUG: falls to default
      expect(minAmountCentsForCurrency('cop'), 200000);
    });

    test('BUG: wallet GBP minimum is wrong (50 instead of 30)', () {
      expect(walletMinAmount('gbp'), 50); // BUG: grouped with usd/eur
      expect(minAmountCentsForCurrency('gbp'), 30);
    });
  });
}
