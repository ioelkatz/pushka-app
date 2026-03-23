import 'package:flutter/material.dart';

/// Bottom sheet wrapper optimized for emulator/low-GPU performance.
/// Uses simple Container decoration instead of ClipRRect + Scaffold.
Future<T?> showKeyboardSafeSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext ctx, void Function(VoidCallback) setState) builder,
  double heightFactor = 0.65,
  EdgeInsets contentPadding = const EdgeInsets.fromLTRB(20, 16, 20, 18),
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) {
      final bottomInset = MediaQuery.of(sheetCtx).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          margin: EdgeInsets.only(top: MediaQuery.of(sheetCtx).size.height * (1 - heightFactor)),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: StatefulBuilder(
              builder: (ctx, setDialogState) => SingleChildScrollView(
                padding: contentPadding,
                child: builder(ctx, setDialogState),
              ),
            ),
          ),
        ),
      );
    },
  );
}