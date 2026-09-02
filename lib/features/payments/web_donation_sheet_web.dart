// Web-only Stripe Elements inline donation sheet.
//
// Shows a modal bottom sheet with the Stripe Payment Element mounted inline
// (no full-page redirect to hosted Checkout). Saves the user's iOS PWA
// standalone context — no more "app broke" moments where the donor lands
// in Safari and can't find their way back.
//
// Public API returns:
//   - the payment intent id on success
//   - null on user cancellation
//   - throws on backend/Stripe failures (the caller shows a snackbar)
//
// Design references:
// - flutter_stripe_web 7.x PaymentElement widget
// - Stripe.js Elements + confirmPayment({elements, redirect:'if_required'})
// - iOS PWA quirk: if the issuer forces a full-page 3DS redirect, the user
//   leaves standalone context and can't return via URL. Best-effort:
//   show a warning BEFORE confirm and use redirect:'if_required' so most
//   flows resolve inline; only bank-forced redirects escape.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_stripe_web/flutter_stripe_web.dart';

import '../../core/format_utils.dart';
import '../../core/l10n/s.dart';
import 'stripe_web_bootstrap.dart';

Future<String?> showWebDonationSheet({
  required BuildContext context,
  required String clientSecret,
  required String? customerSessionClientSecret,
  required int amountCents,
  required String currency,
  required String merchantDisplayName,
  required String returnUrl,
  /// If non-null, renders a "monthly" / "yearly" badge next to the amount
  /// so the donor sees clearly this is a recurring commitment (Stage 6).
  String? recurringInterval,
  /// DIRECT CHARGES: connected account this PI + customer live on. In
  /// steady state WebStripe is already re-initialised for this account by
  /// the app-level bootstrap (see stripe_web_bootstrap_web.dart). We still
  /// call the idempotent bootstrap here as a safety net for the first-pay-
  /// after-login race where the tenantConfigProvider listener may not have
  /// fired before the user tapped Donar. When the accountId matches what
  /// was already set the call is a cheap no-op; when it differs BEFORE any
  /// PaymentElement has ever mounted (still true here — the modal is not
  /// on screen yet), the re-init lands safely.
  String? stripeAccount,
}) async {
  await initWebStripeForTenant(stripeAccount);
  if (!context.mounted) return null;
  // MF1 fix: block dismiss while confirmPayment is in flight. Otherwise the
  // user could swipe/back away, the JS confirmPayment promise still resolves,
  // the webhook charges the card, but the client throws 'canceled' →
  // double-charge risk (adversarial CB-8). A ValueNotifier lets the sheet's
  // _handleConfirm flip the modal from dismissible to sticky in real time.
  final submitting = ValueNotifier<bool>(false);
  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ValueListenableBuilder<bool>(
      valueListenable: submitting,
      builder: (_, isSubmitting, _) => PopScope(
        canPop: !isSubmitting, // blocks Android back button during confirm
        child: _WebDonationSheet(
          clientSecret: clientSecret,
          customerSessionClientSecret: customerSessionClientSecret,
          amountCents: amountCents,
          currency: currency,
          merchantDisplayName: merchantDisplayName,
          returnUrl: returnUrl,
          recurringInterval: recurringInterval,
          onSubmittingChanged: (v) => submitting.value = v,
        ),
      ),
    ),
  );
}

/// Setup-mode variant of the sheet: collects card details WITHOUT charging.
/// Backed by a Stripe SetupIntent instead of a PaymentIntent. Used by the
/// "+Agregar tarjeta" button in /wallet/saved-cards on web (native uses
/// the flutter_stripe PaymentSheet in setupIntent mode).
///
/// Returns 'saved' on success, null on user cancellation.
Future<String?> showWebCardSetupSheet({
  required BuildContext context,
  required String clientSecret,
  required String? customerSessionClientSecret,
  required String merchantDisplayName,
  required String returnUrl,
  /// DIRECT CHARGES: connected account this SetupIntent lives on. Same
  /// bootstrap as showWebDonationSheet — idempotent when already inited.
  String? stripeAccount,
}) async {
  await initWebStripeForTenant(stripeAccount);
  if (!context.mounted) return null;
  // Same MF1 pattern as showWebDonationSheet: block dismiss during confirm.
  final submitting = ValueNotifier<bool>(false);
  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ValueListenableBuilder<bool>(
      valueListenable: submitting,
      builder: (_, isSubmitting, _) => PopScope(
        canPop: !isSubmitting,
        child: _WebCardSetupSheet(
          clientSecret: clientSecret,
          customerSessionClientSecret: customerSessionClientSecret,
          merchantDisplayName: merchantDisplayName,
          returnUrl: returnUrl,
          onSubmittingChanged: (v) => submitting.value = v,
        ),
      ),
    ),
  );
}

class _WebDonationSheet extends StatefulWidget {
  const _WebDonationSheet({
    required this.clientSecret,
    required this.customerSessionClientSecret,
    required this.amountCents,
    required this.currency,
    required this.merchantDisplayName,
    required this.returnUrl,
    this.recurringInterval,
    this.onSubmittingChanged,
  });

  final String clientSecret;
  final String? customerSessionClientSecret;
  final int amountCents;
  final String currency;
  final String merchantDisplayName;
  final String returnUrl;
  final String? recurringInterval; // 'month' | 'year' | null (one-off)
  /// Notifies the outer sheet host whenever the confirmPayment call is in
  /// flight so it can flip the modal from dismissible to sticky (MF1).
  final ValueChanged<bool>? onSubmittingChanged;

  @override
  State<_WebDonationSheet> createState() => _WebDonationSheetState();
}

class _WebDonationSheetState extends State<_WebDonationSheet> {
  bool _submitting = false;
  bool _elementReady = false;
  String? _errorText;
  Timer? _readyTimeout;

  @override
  void initState() {
    super.initState();
    // MF5: if Stripe.js is blocked (Brave shields, adblock, corporate proxy)
    // or the publishableKey wasn't set in time, PaymentElement never fires
    // onCardChanged and the button stays disabled forever. Escape hatch:
    // 6s timeout pops the sheet with a sentinel so pay() can fall back to
    // the Checkout redirect flow.
    _readyTimeout = Timer(const Duration(seconds: 6), () {
      if (!mounted || _elementReady) return;
      Navigator.of(context).pop('__element_failed__');
    });
  }

  @override
  void dispose() {
    _readyTimeout?.cancel();
    super.dispose();
  }

  Future<void> _handleConfirm() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    // Flip the outer sheet host to sticky so the user can't dismiss while
    // confirmPayment is in flight — MF1 fix (would-be double-charge).
    widget.onSubmittingChanged?.call(true);

    try {
      // `redirect: 'if_required'` keeps most flows inline. If the issuer
      // requires a full-page 3DS redirect, Stripe will still navigate away
      // — that's out of our control and DonationResultScreen picks up the
      // return leg by parsing the payment_intent query param.
      final intent = await WebStripe.instance.confirmPaymentElement(
        ConfirmPaymentElementOptions(
          confirmParams: ConfirmPaymentParams(
            return_url: widget.returnUrl,
          ),
          redirect: PaymentConfirmationRedirect.ifRequired,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(intent.id);
    } catch (e) {
      if (!mounted) return;
      final msg = _friendlyError(e);
      setState(() {
        _submitting = false;
        _errorText = msg;
      });
      widget.onSubmittingChanged?.call(false);
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('canceled') || s.contains('cancelled')) return 'canceled';
    // Stripe error objects come back as JS interop maps — best-effort dig.
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  String _formattedAmount() {
    // Uses the shared formatter so zero-decimal (JPY/CLP/KRW…) and
    // three-decimal (BHD/JOD/KWD…) currencies render right, and the symbol
    // matches the currency (no more hardcoded `$` on EUR / JPY / ILS charges).
    return formatStripeUnits(widget.amountCents, widget.currency);
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Grip
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              Text(
                tr.donateNowTitle,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formattedAmount(),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: theme.colorScheme.primary,
                ),
              ),
              if (widget.recurringInterval != null) ...[
                const SizedBox(height: 4),
                Text(
                  tr.donateMonthly, // Only monthly is UI-exposed today (Stage 6)
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.secondary,
                    letterSpacing: 0.4,
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Stripe Payment Element (Card + saved cards + wallets when supported)
              Container(
                constraints: const BoxConstraints(minHeight: 320),
                child: PaymentElement(
                  clientSecret: widget.clientSecret,
                  customerSessionClientSecret: widget.customerSessionClientSecret,
                  onCardChanged: (event) {
                    if (mounted && !_elementReady) {
                      _readyTimeout?.cancel();
                      setState(() => _elementReady = true);
                    }
                  },
                ),
              ),

              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _errorText!,
                    style: TextStyle(
                      color: theme.colorScheme.onErrorContainer,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),

              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: (_submitting || !_elementReady) ? null : _handleConfirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          '${tr.donateNowBtn} · ${_formattedAmount()}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(null),
                child: Text(tr.cancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WebCardSetupSheet extends StatefulWidget {
  const _WebCardSetupSheet({
    required this.clientSecret,
    required this.customerSessionClientSecret,
    required this.merchantDisplayName,
    required this.returnUrl,
    this.onSubmittingChanged,
  });

  final String clientSecret;
  final String? customerSessionClientSecret;
  final String merchantDisplayName;
  final String returnUrl;
  final ValueChanged<bool>? onSubmittingChanged;

  @override
  State<_WebCardSetupSheet> createState() => _WebCardSetupSheetState();
}

class _WebCardSetupSheetState extends State<_WebCardSetupSheet> {
  bool _submitting = false;
  bool _elementReady = false;
  String? _errorText;

  Future<void> _handleConfirm() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    widget.onSubmittingChanged?.call(true); // MF1: block dismiss during confirm
    try {
      // confirmSetupElement returns void — on resolve without throw, the
      // SetupIntent is confirmed and the PM is attached to the customer.
      // The Firestore transactions listener is NOT relevant here (no txn
      // is written by setup). The caller reloads /wallet/saved-cards to
      // see the new card via listSavedCards CF.
      await WebStripe.instance.confirmSetupElement(
        ConfirmSetupElementOptions(
          confirmParams: ConfirmSetupParams(
            return_url: widget.returnUrl,
          ),
          redirect: SetupConfirmationRedirect.ifRequired,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop('saved');
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _submitting = false;
        _errorText = s.length > 200 ? '${s.substring(0, 200)}…' : s;
      });
      widget.onSubmittingChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                tr.addCard,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                constraints: const BoxConstraints(minHeight: 320),
                child: PaymentElement(
                  clientSecret: widget.clientSecret,
                  customerSessionClientSecret: widget.customerSessionClientSecret,
                  onCardChanged: (event) {
                    if (mounted && !_elementReady) {
                      setState(() => _elementReady = true);
                    }
                  },
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _errorText!,
                    style: TextStyle(
                      color: theme.colorScheme.onErrorContainer,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: (_submitting || !_elementReady) ? null : _handleConfirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          tr.addCard,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(null),
                child: Text(tr.cancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
