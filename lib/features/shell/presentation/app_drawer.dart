import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../users/presentation/user_profile_provider.dart';

enum DrawerItem { pushka, wallet, reminders, history, settings, prayers, support, about }

class AppDrawer extends ConsumerWidget {
  final DrawerItem current;

  const AppDrawer({super.key, required this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const blue = Color(0xFF2F60C5);
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final displayName =
        (profile?['displayName'] as String?)?.trim().isNotEmpty == true
            ? (profile?['displayName'] as String)
            : (user?.displayName?.trim().isNotEmpty == true
                ? user!.displayName!
                : 'Usuario');
    
    return Drawer(
      child: Column(
        children: [
          // Header azul
          Container(
            height: 120,
            decoration: const BoxDecoration(color: blue),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 50, 20, 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'HOLA ${displayName.toUpperCase()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),

          // Lista de items del menú
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _item(context, DrawerItem.pushka, 'Mi Pushka', '/', Icons.home, blue),
                _item(context, DrawerItem.wallet, 'Billetera', '/wallet', Icons.account_balance_wallet, blue),
                _item(context, DrawerItem.reminders, 'Recordatorios', '/reminders', Icons.notifications, blue),
                _item(context, DrawerItem.history, 'Historial', '/history', Icons.history, blue),
                _item(context, DrawerItem.settings, 'Configuración', '/settings', Icons.settings, blue),
                _item(context, DrawerItem.prayers, 'Segulot y Rezós', '/prayers', Icons.menu_book, blue),
                _item(context, DrawerItem.support, 'Soporte', '/support', Icons.support_agent, blue),
                _item(context, DrawerItem.about, 'Acerca de', '/about', Icons.info, blue),
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
                  'Versión 3.2.0',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Patrocinado por',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Rabino Dovid (Roberto)',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  'y Margie Szerer',
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
          if (GoRouterState.of(context).uri.toString() != route) {
            context.go(route);
          }
        },
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}
