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
