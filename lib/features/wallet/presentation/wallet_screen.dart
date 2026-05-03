import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/s.dart';

/// Top-level Wallet screen — surfaces all card / payment-method management
/// in one place. Currently a single entry (saved cards); kept as its own
/// screen so future wallet-style features (transaction-source defaults,
/// per-tenant payout routing, billing email) can land here without
/// re-shuffling navigation.
class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        _WalletRow(
          icon: Icons.credit_card,
          color: cs.primary,
          title: tr.savedCards,
          subtitle: tr.walletSavedCardsSubtitle,
          chevron: Icon(
            isRtl ? Icons.chevron_left : Icons.chevron_right,
            color: cs.onSurfaceVariant,
          ),
          onTap: () => context.go('/wallet/saved-cards'),
        ),
      ],
    );
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.chevron,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final Widget chevron;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              chevron,
            ],
          ),
        ),
      ),
    );
  }
}
