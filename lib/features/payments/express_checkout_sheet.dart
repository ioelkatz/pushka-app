// Express checkout bottom sheet — shown BEFORE PaymentSheet when the user
// has a default payment method cached. Lets them confirm with the default
// in one tap, or switch to the full picker for choosing another card.
//
// Rationale: flutter_stripe v12 PaymentSheet ordena PMs por MRU
// (most-recently-used), NO por customer.invoice_settings.default_payment_method.
// Es una limitacion documentada del mobile_payment_element component. La API
// para forzar preseleccion (customerSessionComponent.defaultPaymentMethodId)
// esta en beta privada de Stripe. Sin este workaround, el user con multiples
// tarjetas ve la ultima usada, no la que marco como default.
//
// Devuelve:
//   - true  → el user tocó "Confirmar" con la default
//   - false → el user tocó "Cambiar tarjeta" (caller cae al PaymentSheet)
//   - null  → el user cerró/canceló la sheet

import 'package:flutter/material.dart';

import '../../core/format_utils.dart';
import '../../core/l10n/s.dart';
import '../settings/presentation/card_brand_box.dart';

Future<bool?> showExpressCheckoutSheet({
  required BuildContext context,
  required String cardBrand,
  required String cardLast4,
  // Stripe smallest-unit integer (whatever `amountToStripeUnits` produced for
  // this currency). Rendering must go through `formatStripeUnits` so JPY / CLP
  // / BHD render right and use the correct currency symbol.
  required int amountStripeUnits,
  required String currency,
}) async {
  final formattedAmount = formatStripeUnits(amountStripeUnits, currency);

  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _ExpressCheckoutSheet(
      cardBrand: cardBrand,
      cardLast4: cardLast4,
      formattedAmount: formattedAmount,
    ),
  );
}

class _ExpressCheckoutSheet extends StatelessWidget {
  const _ExpressCheckoutSheet({
    required this.cardBrand,
    required this.cardLast4,
    required this.formattedAmount,
  });

  final String cardBrand;
  final String cardLast4;
  final String formattedAmount;

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
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
              // Title
              Text(
                tr.donateNowTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                formattedAmount,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 20),
              // Card row
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outline),
                ),
                child: Row(
                  children: [
                    cardBrandBox(cardBrand),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface,
                          ),
                          children: [
                            TextSpan(text: '${cardBrandLabel(cardBrand)} '),
                            const TextSpan(text: '••••'),
                            TextSpan(text: ' $cardLast4'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Confirm button
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    '${tr.donateNowBtn} · $formattedAmount',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Change card button
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  tr.changeCard,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
