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

// Currencies whose glyph is legibly different from the ISO code. Anything not
// in this table falls back to "<CODE> <amount>" so we never lie with `$` on a
// EUR / ILS / JPY charge (which express_checkout_sheet used to do).
const Map<String, String> _currencySymbols = {
  'usd': '\$',
  'cad': '\$',
  'aud': '\$',
  'nzd': '\$',
  'mxn': '\$',
  'ars': '\$',
  'clp': '\$',
  'cop': '\$',
  'uyu': '\$',
  'brl': 'R\$',
  'eur': '€',
  'gbp': '£',
  'jpy': '¥',
  'cny': '¥',
  'krw': '₩',
  'ils': '₪',
  'inr': '₹',
  'rub': '₽',
  'try': '₺',
  'chf': 'CHF ',
};

/// Renders a Stripe smallest-unit integer for a given currency into a
/// human-readable string, e.g. (10000, "clp") → "$10,000 CLP",
/// (1500, "bhd") → "BHD 1.500", (1050, "usd") → "$10.50 USD".
///
/// Rules:
///   - Zero-decimal currencies (CLP, JPY, KRW, …): integer, no decimals.
///   - Three-decimal (BHD, JOD, KWD, …): always three decimals.
///   - Everything else: two decimals, dropping ".00" when whole.
///
/// Prefer this over hand-rolled `'$' + (units/100)` — that formula
/// misrepresents 21 of Stripe's supported currencies.
String formatStripeUnits(int units, String currency) {
  final code = currency.toLowerCase();
  final amount = stripeUnitsToAmount(units, code);
  final symbol = _currencySymbols[code];
  final upper = currency.toUpperCase();

  String body;
  if (_zeroDecimalCurrencies.contains(code)) {
    body = NumberFormat('#,##0').format(amount.round());
  } else if (_threeDecimalCurrencies.contains(code)) {
    body = NumberFormat('#,##0.000').format(amount);
  } else {
    body = formatAmount(amount);
  }

  if (symbol != null) return '$symbol$body $upper';
  return '$upper $body';
}
