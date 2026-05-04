import 'package:flutter/material.dart';

/// Lightweight bottom-sheet wrapper that handles keyboard insets correctly.
///
/// Key optimizations for emulator/low-GPU devices:
/// - No AnimatedPadding (avoids multi-frame animation during keyboard transition)
/// - Opaque barrier reduces background compositing cost
/// - Uses built-in shape/background instead of custom Container layering
Future<T?> showKeyboardSafeSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext ctx, void Function(VoidCallback) setState) builder,
  EdgeInsets contentPadding = const EdgeInsets.fromLTRB(20, 16, 20, 18),
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Push the sheet onto the root navigator so the barrier covers the
    // shell's AppBar too — otherwise the bar stays bright above the
    // dimmed body and looks visually disconnected from the modal.
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    // Use the scaffold background color (NOT cs.surface) so tiles
    // inside the sheet — which themselves use cs.surface as fill to
    // match the Settings convention — actually have contrast against
    // the modal bg. With both being cs.surface the tiles disappeared
    // visually.
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    barrierColor: const Color(0xDD000000),
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
      ),
      child: StatefulBuilder(
        builder: (ctx, setDialogState) => SingleChildScrollView(
          padding: contentPadding,
          child: builder(ctx, setDialogState),
        ),
      ),
    ),
  );
}