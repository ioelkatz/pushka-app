import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../settings/presentation/auto_empty_action_row.dart';
import '../../settings/presentation/auto_empty_screen.dart';
import '../../settings/presentation/card_brand_box.dart';
import '../../users/presentation/user_profile_provider.dart';

/// Top-level Wallet screen — surfaces card / payment-method management
/// using the same widgets as Settings so the two screens read as one
/// cohesive surface.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        _SectionLabel(tr.savedCards.toUpperCase()),
        const SizedBox(height: 6),
        _SavedCardPreview(
          profile: profile,
          tr: tr,
          onTap: () => context.go('/wallet/saved-cards'),
        ),
        const SizedBox(height: 18),
        _SectionLabel(tr.walletAutoEmptyActiveTitle.toUpperCase()),
        const SizedBox(height: 6),
        AutoEmptyActionRow(
          onTap: () {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(builder: (_) => const AutoEmptyScreen()),
            );
          },
        ),
      ],
    );
  }
}

/// Section header — same style as Settings' `_buildLabel`.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Saved-card preview — exact mirror of Settings' `_buildSavedCardPreview`:
/// brand box on the left + "Visa **** 4242" with WidgetSpan-centered
/// asterisks. Falls back to "no tienes ninguna tarjeta" when empty.
class _SavedCardPreview extends StatelessWidget {
  const _SavedCardPreview({
    required this.profile,
    required this.tr,
    required this.onTap,
  });

  final Map<String, dynamic>? profile;
  final S tr;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final brand = profile?['stripeDefaultPaymentMethodBrand'] as String?;
    final last4 = profile?['stripeDefaultPaymentMethodLast4'] as String?;
    final hasCard =
        brand != null && brand.isNotEmpty && last4 != null && last4.isNotEmpty;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: AppTokens.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (hasCard)
              cardBrandBox(brand)
            else
              Container(
                width: 40,
                height: 28,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.credit_card,
                    size: 18, color: cs.onSurfaceVariant),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: hasCard
                  ? Text.rich(
                      TextSpan(
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurface,
                        ),
                        children: [
                          TextSpan(text: '${cardBrandLabel(brand)} '),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Transform.translate(
                              offset: const Offset(0, 3),
                              child: Text(
                                '****',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: cs.onSurface,
                                  height: 1.0,
                                ),
                              ),
                            ),
                          ),
                          TextSpan(text: ' $last4'),
                        ],
                      ),
                    )
                  : Text(
                      tr.noCardsShort,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
            ),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
