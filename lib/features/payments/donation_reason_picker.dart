import 'package:flutter/material.dart';

import '../../core/l10n/s.dart';

/// Result of the donation-reason picker.
///
/// - `cancelled` — user dismissed the dialog (don't proceed with payment)
/// - `selected(null)` — user explicitly chose "Sin designación" (proceed)
/// - `selected(reason)` — user picked a designación (proceed with reason)
sealed class DonationReasonResult {
  const DonationReasonResult();
}

class DonationReasonCancelled extends DonationReasonResult {
  const DonationReasonCancelled();
}

class DonationReasonSelected extends DonationReasonResult {
  const DonationReasonSelected(this.reason);
  final String? reason;
}

/// Compact menu-style picker for the donation reason. Sized to wrap content
/// (not a full bottom sheet) so it reads as a discreet menu the user
/// dismisses with one tap. The first row is always "Sin designación" so the
/// donor can opt out without hunting for a skip button.
///
/// Returns `null` when the tenant has no reasons configured (caller should
/// skip the picker entirely in that case).
Future<DonationReasonResult?> showDonationReasonPicker({
  required BuildContext context,
  required List<String> reasons,
}) async {
  if (reasons.isEmpty) return null;

  final selected = await showDialog<String?>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black54,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      final tr = S.of(ctx);
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text(
                  tr.donationReasonTitle,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ReasonItem(
                        label: tr.donationReasonNone,
                        muted: true,
                        onTap: () => Navigator.pop(ctx, ''),
                      ),
                      Divider(height: 1, color: cs.outlineVariant),
                      for (var i = 0; i < reasons.length; i++) ...[
                        _ReasonItem(
                          label: reasons[i],
                          onTap: () => Navigator.pop(ctx, reasons[i]),
                        ),
                        if (i < reasons.length - 1)
                          Divider(height: 1, color: cs.outlineVariant),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  if (selected == null) return const DonationReasonCancelled();
  return DonationReasonSelected(selected.isEmpty ? null : selected);
}

class _ReasonItem extends StatelessWidget {
  const _ReasonItem({
    required this.label,
    required this.onTap,
    this.muted = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: muted ? FontWeight.w400 : FontWeight.w500,
            color: muted ? cs.onSurfaceVariant : cs.onSurface,
          ),
        ),
      ),
    );
  }
}
