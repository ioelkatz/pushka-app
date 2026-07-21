import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../network_status_provider.dart';

/// Wraps [child] with a subtle top banner that appears ONLY when we've
/// confirmed offline via real request failures (see
/// [NetworkStatusNotifier]). Dismissible with X — reappears if the user
/// comes back online and then goes offline again.
///
/// Copy is intentionally soft: "algunos datos pueden estar desactualizados",
/// not "SIN CONEXIÓN" scary red. The app is designed to work with cached
/// data — donations obviously require network, but browsing pushka + history
/// + settings works from Firestore local cache.
class OfflineBanner extends ConsumerWidget {
  final Widget child;
  const OfflineBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showBanner = ref.watch(shouldShowOfflineBannerProvider);

    return Column(
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          child: showBanner
              ? _BannerBar(
                  onDismiss: () =>
                      ref.read(networkStatusProvider.notifier).dismissBanner(),
                )
              : const SizedBox.shrink(),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _BannerBar extends StatelessWidget {
  final VoidCallback onDismiss;
  const _BannerBar({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    return Material(
      // Amber-500 — visible but not alarming. Was red-orange before which
      // felt like an error state; this is more of a "heads up" tone.
      color: const Color(0xFFF59E0B),
      child: SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr.offlineMessage,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onDismiss,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
