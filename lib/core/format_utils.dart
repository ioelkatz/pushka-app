import 'package:intl/intl.dart';

/// Round-6 audit MEDIUM fix: NumberFormat was created without a locale
/// which fell back to en-US thousand/decimal separators (`1,500.00`)
/// regardless of the user's language. Now uses Intl.defaultLocale when set
/// so ES/FR users see `1.500,00`, EN users `1,500.00`, and HE users get
/// Hebrew digits when Intl.defaultLocale is 'he'. Callers can override via
/// the [locale] param when they know the context (e.g. history screen
/// wants the tx's original locale, not the user's active one).
String formatMoney(double value, {String symbol = '\$', String? locale}) {
  final l = locale ?? Intl.defaultLocale;
  if (value.isNaN || value.isInfinite) return '$symbol–';
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return '$symbol${NumberFormat('#,##0', l).format(value.toInt())}';
  }
  return '$symbol${NumberFormat('#,##0.00', l).format(value)}';
}

/// Same as [formatMoney] but without any currency symbol prefix.
/// Returns "–" for NaN or infinite values.
String formatAmount(double value, {String? locale}) {
  final l = locale ?? Intl.defaultLocale;
  if (value.isNaN || value.isInfinite) return '–';
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return NumberFormat('#,##0', l).format(value.toInt());
  }
  return NumberFormat('#,##0.00', l).format(value);
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
  // Round-7 regression fix: CHF used to map to 'CHF ' which combined with
  // _renderAmount's trailing ISO-code append produced 'CHF 100 CHF'.
  // Currencies without a dedicated glyph fall through to `null` and
  // _renderAmount uses the ISO-code-only "CHF 100" fallback.
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
  return _renderAmount(amount, code, currency.toUpperCase());
}

/// Same as [formatStripeUnits] but takes a MAJOR-unit double (e.g. 10.50).
/// Use when the amount already lives in the currency's display units —
/// snackbars, subscription tiles, chart tooltips, transaction detail
/// modals. Never lie with `$` on an EUR/JPY/ILS charge again.
String formatCurrencyAmount(double amount, String currency) {
  final code = currency.toLowerCase();
  return _renderAmount(amount, code, currency.toUpperCase());
}

/// Currency-aware amount formatter with a caller-provided prefix (usually
/// a symbol). Unlike [formatMoney] which was locked to 2-decimal-max,
/// this honors zero-decimal (CLP/JPY/KRW → integer) and three-decimal
/// (BHD/JOD → three decimals) currencies. Use when the ISO code is shown
/// separately alongside and you don't want it embedded in the numeric.
String formatCurrencyAmountWithSymbol(double amount, String currency, {String symbol = '\$'}) {
  final code = currency.toLowerCase();
  if (amount.isNaN || amount.isInfinite) return '$symbol–';
  String body;
  if (_zeroDecimalCurrencies.contains(code)) {
    body = NumberFormat('#,##0').format(amount.round());
  } else if (_threeDecimalCurrencies.contains(code)) {
    body = NumberFormat('#,##0.000').format(amount);
  } else {
    body = formatAmount(amount);
  }
  return '$symbol$body';
}

/// Returns the display symbol for a currency (e.g. `$`, `€`, `MX$`) —
/// use only when you already know the currency and the context is
/// unambiguous. Prefer `formatCurrencyAmount` for anything with a number
/// so the ISO code is always present.
String currencySymbol(String currency) {
  return _currencySymbols[currency.toLowerCase()] ?? '${currency.toUpperCase()} ';
}

/// Short (usually 1-3 char) currency prefix for text fields where only
/// the symbol goes before the amount — e.g. TextField prefixText. Uses
/// disambiguating prefixes for the ambiguous `$` glyph (MX$, AR$, R$,
/// CL$, CO$, CA$, US$) so a MXN user never mistakes their amount for USD.
/// Single source of truth used by pushka_screen, settings_screen and
/// auto_empty_screen (previously each had its own 4-6 line copy that
/// drifted).
String shortCurrencySymbol(String code) {
  switch (code.toUpperCase()) {
    case 'USD': return 'US\$';
    case 'CAD': return 'CA\$';
    case 'AUD': return 'AU\$';
    case 'MXN': return 'MX\$';
    case 'ARS': return 'AR\$';
    case 'CLP': return 'CL\$';
    case 'COP': return 'CO\$';
    case 'UYU': return 'U\$';
    case 'BRL': return 'R\$';
    case 'EUR': return '€';
    case 'GBP': return '£';
    case 'ILS': return '₪';
    case 'JPY': return '¥';
    case 'CNY': return '¥';
    case 'KRW': return '₩';
    case 'INR': return '₹';
    case 'RUB': return '₽';
    case 'TRY': return '₺';
    case 'CHF': return 'CHF';
    // Round-9 regression fix: appending '$' to unknown codes produced
    // nonsense like 'PEN$', 'SEK$', 'PLN$', 'BHD$' — none of those use
    // a dollar sign. Fall back to the ISO code itself with a trailing
    // space so it reads correctly as a prefix ("PEN 100.00").
    default:    return '${code.toUpperCase()} ';
  }
}

String _renderAmount(double amount, String lowerCode, String upperCode) {
  final symbol = _currencySymbols[lowerCode];
  String body;
  if (_zeroDecimalCurrencies.contains(lowerCode)) {
    body = NumberFormat('#,##0').format(amount.round());
  } else if (_threeDecimalCurrencies.contains(lowerCode)) {
    body = NumberFormat('#,##0.000').format(amount);
  } else {
    body = formatAmount(amount);
  }
  if (symbol != null) return '$symbol$body $upperCode';
  return '$upperCode $body';
}
