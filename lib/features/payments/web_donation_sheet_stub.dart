// Non-web stub for the Stripe Elements inline donation sheet. Native
// (Android/iOS) builds pick this file up via the conditional import at
// `web_donation_sheet.dart` — they never actually reach these helpers
// because callers always guard with `if (kIsWeb)`.

import 'package:flutter/material.dart';

Future<String?> showWebDonationSheet({
  required BuildContext context,
  required String clientSecret,
  required String? customerSessionClientSecret,
  required int amountCents,
  required String currency,
  required String merchantDisplayName,
  required String returnUrl,
  String? recurringInterval, // 'month', 'year', or null for one-off
  String? stripeAccount,
}) {
  throw UnsupportedError(
    'showWebDonationSheet only available on web builds',
  );
}

/// Returns 'saved' on success, null on cancel. Throws on Stripe error.
Future<String?> showWebCardSetupSheet({
  required BuildContext context,
  required String clientSecret,
  required String? customerSessionClientSecret,
  required String merchantDisplayName,
  required String returnUrl,
  String? stripeAccount,
}) {
  throw UnsupportedError(
    'showWebCardSetupSheet only available on web builds',
  );
}
