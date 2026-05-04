import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

/// One option in [showOptionPickerSheet].
typedef OptionPickerOption<T> = ({T value, String label});

/// Shared bottom-sheet picker — the canonical "pick one of N" UI in Pushka.
///
/// Visual: outlined option tiles, the selected one tinted with the primary
/// color + green check on the right. Sheet pops via the root navigator with
/// a dim barrier so it covers the whole screen (including the AppBar of the
/// caller). This matches the History filter, donation reason picker,
/// language selector, and the auto-empty frequency / day-of-week pickers.
///
/// Returns the picked value or `null` if the user dismissed the sheet.
Future<T?> showOptionPickerSheet<T>({
  required BuildContext context,
  required List<OptionPickerOption<T>> options,
  required T currentValue,
}) {
  return showModalBottomSheet<T>(
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
              for (var i = 0; i < options.length; i++) ...[
                _OptionTile<T>(
                  label: options[i].label,
                  selected: options[i].value == currentValue,
                  onTap: () => Navigator.pop(sheetCtx, options[i].value),
                ),
                if (i < options.length - 1) const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _OptionTile<T> extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

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
