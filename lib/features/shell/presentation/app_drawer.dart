import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../users/presentation/user_profile_provider.dart';

enum DrawerItem { pushka, wallet, reminders, history, settings, prayers, support, about }

class AppDrawer extends ConsumerWidget {
  final DrawerItem current;

  const AppDrawer({super.key, required this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    const blue = Color(0xFF2F60C5);
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final displayName =
        (profile?['displayName'] as String?)?.trim().isNotEmpty == true
            ? (profile?['displayName'] as String)
            : (user?.displayName?.trim().isNotEmpty == true
                ? user!.displayName!
                : tr.defaultUser);
    
    return Drawer(
      child: Column(
        children: [
          // Header azul
          Container(
            decoration: const BoxDecoration(color: blue),
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
                          Text(
                            tr.hello(displayName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Pushka',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
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
                _item(context, DrawerItem.reminders, tr.reminders, '/reminders', Icons.notifications, blue),
                _item(context, DrawerItem.history, tr.history, '/history', Icons.history, blue),
                _item(context, DrawerItem.settings, tr.settings, '/settings', Icons.settings, blue),
                _item(context, DrawerItem.prayers, tr.prayersAndSegulot, '/prayers', Icons.menu_book, blue),
                _item(context, DrawerItem.support, tr.support, '/support', Icons.support_agent, blue),
                _item(context, DrawerItem.about, tr.about, '/about', Icons.info, blue),
              ],
            ),
          ),

          // Footer con versión y patrocinadores
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr.version(AppTokens.appVersion),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr.sponsoredBy,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  tr.sponsorLine1,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  tr.sponsorLine2,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w500,
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

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: selected ? blue : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        leading: Icon(
          icon,
          color: selected ? Colors.white : Colors.grey.shade700,
          size: 24,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black87,
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
