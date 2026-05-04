import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../data/tenant_repository.dart';

// Public helper so the sheet can be opened from any screen (Settings,
// future drawer entry, etc.). Previously this lived inside
// _TenantMainAppBar in router.dart and was only reachable from the home
// AppBar — moved here so the home AppBar can show "Mi Pushka" without
// also being the multi-tenant entry point.
void showAccountSwitcher(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => const AccountSwitcherSheet(),
  );
}

class AccountSwitcherSheet extends ConsumerWidget {
  const AccountSwitcherSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final summaries = ref.watch(userTenantSummariesProvider).valueOrNull ?? [];
    final tenantConfig = ref.watch(tenantConfigProvider).valueOrNull;
    final activeTenantId = tenantConfig?.tenantId;
    final tt = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr.myOrganizations,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ...summaries.map((s) {
              final isActive = s.tenantId == activeTenantId;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _OrgAvatar(name: s.name, logoUrl: s.logoUrl),
                title: Text(
                  s.appName.isNotEmpty ? s.appName : s.name,
                  style: tt.bodyMedium?.copyWith(
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                trailing: isActive
                    ? const Icon(Icons.check_rounded,
                        color: AppTokens.primaryBlue)
                    : null,
                onTap: isActive
                    ? null
                    : () async {
                        // Capture BEFORE pop — after Navigator.pop the
                        // sheet's ConsumerWidget is disposed, which
                        // invalidates its `ref`. We need a stable handle
                        // that survives the pop. ProviderContainer is
                        // owned by the root ProviderScope, not by this
                        // widget, so it stays alive.
                        final messenger = ScaffoldMessenger.of(context);
                        final container = ProviderScope.containerOf(context);
                        Navigator.of(context).pop();
                        try {
                          await container
                              .read(tenantRepositoryProvider)
                              .switchTenant(s.tenantId);
                          // Invalidate ALL providers that depend on the
                          // active tenantId. userProfileProvider is the
                          // upstream source for tenantStateProvider —
                          // without forcing it the tenantState may keep
                          // pointing at the old tenant.
                          container.invalidate(userProfileProvider);
                          container.invalidate(tenantConfigProvider);
                          container.invalidate(tenantStateProvider);
                        } catch (e) {
                          debugPrint('switchTenant failed: $e');
                          messenger.showSnackBar(
                            SnackBar(content: Text('Error: $e')),
                          );
                        }
                      },
              );
            }),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                radius: 20,
                child: Icon(Icons.add_rounded),
              ),
              title: Text(tr.addOrganization),
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
}

class _OrgAvatar extends StatelessWidget {
  const _OrgAvatar({required this.name, this.logoUrl});

  final String name;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.primaryContainer;
    return CircleAvatar(
      radius: 20,
      backgroundColor: bg,
      child: logoUrl != null && logoUrl!.isNotEmpty
          ? ClipOval(
              child: Image.network(
                logoUrl!,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _initial(context),
              ),
            )
          : _initial(context),
    );
  }

  Widget _initial(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return Text(
      initial,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onPrimaryContainer,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
