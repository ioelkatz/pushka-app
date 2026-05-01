import 'package:intl/intl.dart';

/// Formats a monetary amount with thousand separators.
/// Drops '.00' when the value is a whole number.
/// Returns the symbol followed by "–" for NaN or infinite values.
String formatMoney(double value, {String symbol = '\$'}) {
  if (value.isNaN || value.isInfinite) return '$symbol–';
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return '$symbol${NumberFormat('#,##0').format(value.toInt())}';
  }
  return '$symbol${NumberFormat('#,##0.00').format(value)}';
}

/// Same as [formatMoney] but without any currency symbol prefix.
/// Returns "–" for NaN or infinite values.
String formatAmount(double value) {
  if (value.isNaN || value.isInfinite) return '–';
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return NumberFormat('#,##0').format(value.toInt());
  }
  return NumberFormat('#,##0.00').format(value);
}

// Stripe zero-decimal currencies — amount is in whole units, NOT cents.
// Source: https://stripe.com/docs/currencies#zero-decimal
// Mirror of the server-side ZERO_DECIMAL_CURRENCIES set in functions/index.js.
const Set<String> _zeroDecimalCurrencies = {
  'bif', 'clp', 'djf', 'gnf', 'jpy', 'kmf', 'krw', 'mga',
  'pyg', 'rwf', 'ugx', 'vnd', 'vuv', 'xaf', 'xof', 'xpf',
};

// Stripe three-decimal currencies — amount is in 1/1000 of the major unit.
// Source: https://stripe.com/docs/currencies#three-decimal
const Set<String> _threeDecimalCurrencies = {
  'bhd', 'jod', 'kwd', 'omr', 'tnd',
};

/// Returns the multiplier needed to convert a major-unit amount (e.g. 10.50 USD)
/// into Stripe's smallest-unit integer (e.g. 1050 for USD, 10 for CLP, 10500 for BHD).
///
/// MUST stay in sync with `currencyUnitDivisor` in `functions/index.js`.
int currencyUnitMultiplier(String currency) {
  final code = currency.toLowerCase();
  if (_zeroDecimalCurrencies.contains(code)) return 1;
  if (_threeDecimalCurrencies.contains(code)) return 1000;
  return 100;
}

/// Converts a major-unit amount (e.g. 10.50) into Stripe's smallest-unit
/// integer for the given currency. Use this everywhere we send `amountCents`
/// to the backend — using `* 100` blindly overcharges 100x for CLP/JPY/KRW
/// and undercharges 10x for BHD/JOD.
int amountToStripeUnits(double amount, String currency) {
  return (amount * currencyUnitMultiplier(currency)).round();
}

/// Inverse of [amountToStripeUnits]: converts a Stripe smallest-unit integer
/// back to a human-readable major-unit double (e.g. 1050 USD cents → 10.50).
double stripeUnitsToAmount(int units, String currency) {
  return units / currencyUnitMultiplier(currency);
}
