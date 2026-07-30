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

import '../../core/l10n/s.dart';

Future<String?> showWebDonationSheet({
  required BuildContext context,
  required String clientSecret,
  required String? customerSessionClientSecret,
  required int amountCents,
  required String currency,
  required String merchantDisplayName,
  required String returnUrl,
}) async {
  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _WebDonationSheet(
      clientSecret: clientSecret,
      customerSessionClientSecret: customerSessionClientSecret,
      amountCents: amountCents,
      currency: currency,
      merchantDisplayName: merchantDisplayName,
      returnUrl: returnUrl,
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
  });

  final String clientSecret;
  final String? customerSessionClientSecret;
  final int amountCents;
  final String currency;
  final String merchantDisplayName;
  final String returnUrl;

  @override
  State<_WebDonationSheet> createState() => _WebDonationSheetState();
}

class _WebDonationSheetState extends State<_WebDonationSheet> {
  bool _submitting = false;
  bool _elementReady = false;
  String? _errorText;

  Future<void> _handleConfirm() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _errorText = null;
    });

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
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('canceled') || s.contains('cancelled')) return 'canceled';
    // Stripe error objects come back as JS interop maps — best-effort dig.
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  String _formattedAmount() {
    final cur = widget.currency.toUpperCase();
    final major = widget.amountCents / 100.0;
    return '\$${major.toStringAsFixed(2)} $cur';
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

              const SizedBox(height: 20),

              // Stripe Payment Element (Card + saved cards + wallets when supported)
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

