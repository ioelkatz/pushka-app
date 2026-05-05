import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

/// Result of the donation-reason picker.
///
/// - `cancelled` — user dismissed the sheet (don't proceed with payment)
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

/// Bottom-sheet picker styled like the History filter sheet — outlined
/// option tiles with the current selection highlighted by primary color +
/// checkmark. Pass [currentSelection] to indicate which row should render
/// as selected on open.
///
/// Returns `null` when the tenant has no reasons configured (caller should
/// skip the picker entirely in that case).
Future<DonationReasonResult?> showDonationReasonPicker({
  required BuildContext context,
  required List<String> reasons,
  String? currentSelection,
}) async {
  if (reasons.isEmpty) return null;

  final selected = await showModalBottomSheet<String?>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    barrierColor: const Color(0xDD000000),
    builder: (sheetCtx) {
      final cs = Theme.of(sheetCtx).colorScheme;
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              for (final r in reasons) ...[
                _ReasonTile(
                  label: r,
                  selected: currentSelection == r,
                  onTap: () => Navigator.pop(sheetCtx, r),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      );
    },
  );

  if (selected == null) return const DonationReasonCancelled();
  return DonationReasonSelected(selected);
}

class _ReasonTile extends StatelessWidget {
  const _ReasonTile({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppTokens.primaryBlue.withValues(alpha: 0.12) : cs.surface,
          border: Border.all(color: selected ? AppTokens.primaryBlue : cs.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check, color: AppTokens.primaryBlue, size: 22),
          ],
        ),
      ),
    );
  }
}
