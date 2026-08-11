import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../users/presentation/user_profile_provider.dart';

enum DrawerItem { pushka, wallet, reminders, history, settings, prayers, support, about }

class AppDrawer extends ConsumerWidget {
  final DrawerItem current;

  const AppDrawer({super.key, required this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final blue = Theme.of(context).colorScheme.primary;
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final profileName = (profile?['displayName'] as String?)?.trim();
    final authName = user?.displayName?.trim();
    final displayName = (profileName != null && profileName.isNotEmpty)
        ? profileName
        : (authName != null && authName.isNotEmpty ? authName : tr.defaultUser);
    final tenantConfig = ref.watch(tenantConfigProvider).valueOrNull;
    final brandName = (tenantConfig?.appName.isNotEmpty == true)
        ? tenantConfig!.appName
        : 'Pushka';
    
    return Drawer(
      child: Column(
        children: [
          // Header azul
          Container(
            decoration: BoxDecoration(color: blue),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Semantics(
                        label: 'Pushka',
                        child: Image.asset(
                          'assets/images/logo.png',
                          width: 48,
                          height: 48,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Round-5 audit CRITICAL fix: use colorScheme.onPrimary
                          // (derived from primary luminance) instead of hardcoded
                          // white so a tenant with a light primary color (yellow /
                          // cream / cyan) still gets readable text.
                          Text(
                            tr.hello(displayName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            brandName,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.75),
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Lista de items del menú
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _item(context, DrawerItem.pushka, tr.myPushka, '/', Icons.home, blue),
                _item(context, DrawerItem.wallet, tr.wallet, '/wallet', Icons.account_balance_wallet, blue),
                // Reminders: server-side scheduling via Cloud Scheduler +
                // processDueReminders CF (Stage 3 deployed). Fires push
                // notifications on all platforms including PWA — user still
                // needs to opt into web push in Settings for the PWA path.
                _item(context, DrawerItem.reminders, tr.reminders, '/reminders', Icons.notifications, blue),
                _item(context, DrawerItem.history, tr.history, '/history', Icons.history, blue),
                _item(context, DrawerItem.settings, tr.settings, '/settings', Icons.settings, blue),
                _item(context, DrawerItem.prayers, tr.prayersAndSegulot, '/prayers', Icons.menu_book, blue),
                _item(context, DrawerItem.support, tr.support, '/support', Icons.support_agent, blue),
                _item(context, DrawerItem.about, tr.about, '/about', Icons.info, blue),
              ],
            ),
          ),

          // Footer con versión y patrocinadores. Padding-left ajustado
          // para alinear con la posición horizontal de los iconos del nav:
          // Container.margin 8 (del _item) + ListTile.contentPadding 16
          // = 24 px del borde del drawer.
          //
          // Todos los textos con el mismo color/peso (onSurfaceVariant +
          // w400) para dar consistencia visual — antes el nombre del Rab
          // resaltaba con onSurface + w500 y rompía la armonía del footer.
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 20, 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr.version(AppTokens.appVersion),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr.sponsoredBy,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  tr.sponsorLine1,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(
    BuildContext context,
    DrawerItem item,
    String title,
    String route,
    IconData icon,
    Color blue,
  ) {
    final selected = item == current;
    // Round-5 audit fix: readable foreground based on primary luminance.
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: selected ? blue : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(
          icon,
          color: selected ? onPrimary : Theme.of(context).colorScheme.onSurface,
          size: 24,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: selected ? onPrimary : Theme.of(context).colorScheme.onSurface,
            fontSize: 16,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        onTap: () {
          Navigator.pop(context);
          // 'selected' is already true when current route == route, so only navigate when not selected.
          if (!selected) context.go(route);
        },
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}
