import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:cached_network_image/cached_network_image.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../data/tenant_repository.dart';
import '../domain/tenant_summary.dart';
import 'tenant_switch_reset.dart';

// Public helper so the sheet can be opened from any screen (Settings,
// future drawer entry, etc.). Previously this lived inside
// _TenantMainAppBar in router.dart and was only reachable from the home
// AppBar — moved here so the home AppBar can show "Mi Pushka" without
// also being the multi-tenant entry point.
void showAccountSwitcher(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    barrierColor: const Color(0xDD000000),
    builder: (_) => const AccountSwitcherSheet(),
  );
}

class AccountSwitcherSheet extends ConsumerWidget {
  const AccountSwitcherSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final summaries = ref.watch(userTenantSummariesProvider).valueOrNull ?? [];
    final tenantConfig = ref.watch(tenantConfigProvider).valueOrNull;
    final activeTenantId = tenantConfig?.tenantId;

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
            for (var i = 0; i < summaries.length; i++) ...[
              _OrgTile(
                summary: summaries[i],
                selected: summaries[i].tenantId == activeTenantId,
                onTap: summaries[i].tenantId == activeTenantId
                    ? null
                    : () => _switchTo(context, summaries[i].tenantId),
              ),
              const SizedBox(height: 8),
            ],
            _AddOrgTile(
              label: tr.addOrganization,
              onTap: () {
                Navigator.of(context).pop();
                context.push('/tenant-setup');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _switchTo(BuildContext context, String tenantId) async {
    // Capture BEFORE pop — after Navigator.pop the sheet's ConsumerWidget
    // is disposed, which invalidates its `ref`. ProviderContainer is owned
    // by the root ProviderScope, not by this widget, so it survives.
    final messenger = ScaffoldMessenger.of(context);
    final container = ProviderScope.containerOf(context);
    // Snapshot the OUTGOING tenantId so we can purge its cached entries
    // before the new one paints. Without this, the home screen briefly
    // shows the old tenant's pushka amount + branding when reloading
    // from Hive while the new tenantConfig/state streams in.
    final outgoingTenantId = container
        .read(userProfileProvider)
        .valueOrNull?['tenantId'] as String?;
    final uid = container.read(currentUserProvider)?.uid;
    Navigator.of(context).pop();
    try {
      // Reset Hive cache + tenant-scoped providers via the shared helper so
      // this stays in lockstep with tenant_code_screen / join_via_link_screen.
      // Runs BEFORE the CF so any provider re-read while the network call is
      // in flight doesn't serve stale Hive data from the old tenant.
      await resetTenantScopedState(
        container,
        uid: uid,
        outgoingTenantId: outgoingTenantId,
      );
      await container.read(tenantRepositoryProvider).switchTenant(tenantId);
      // Second pass invalidates providers so they resubscribe with the new
      // tenantId that Firestore now reports. tenantThemeProvider auto-derives
      // from tenantConfigProvider via ref.watch(...select(...)) — no explicit
      // invalidation needed here.
      await resetTenantScopedState(
        container,
        uid: uid,
        outgoingTenantId: null,
      );
    } catch (e) {
      debugPrint('switchTenant failed: $e');
      messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }
}

class _OrgTile extends StatelessWidget {
  const _OrgTile({
    required this.summary,
    required this.selected,
    required this.onTap,
  });

  final TenantSummary summary;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = summary.appName.isNotEmpty ? summary.appName : summary.name;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppTokens.primaryBlue.withValues(alpha: 0.12) : cs.surface,
          border: Border.all(color: selected ? AppTokens.primaryBlue : cs.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            _OrgAvatar(name: summary.name, logoUrl: summary.logoUrl),
            const SizedBox(width: 12),
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
              const Icon(Icons.check, color: AppTokens.primaryBlue, size: 22),
          ],
        ),
      ),
    );
  }
}

class _AddOrgTile extends StatelessWidget {
  const _AddOrgTile({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.add_rounded, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrgAvatar extends StatelessWidget {
  const _OrgAvatar({required this.name, this.logoUrl});

  final String name;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: logoUrl != null && logoUrl!.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: logoUrl!,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _initial(context),
              // Don't show a placeholder spinner — for a 40px circle the
              // flicker between fallback initial and decoded image is more
              // jarring than just showing the initial briefly.
              placeholder: (_, _) => _initial(context),
            )
          : _initial(context),
    );
  }

  Widget _initial(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return Text(
      initial,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w700,
        fontSize: 16,
      ),
    );
  }
}
