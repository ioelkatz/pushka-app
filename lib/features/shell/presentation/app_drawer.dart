import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

enum DrawerItem { pushka, wallet, reminders, history, settings, prayers, support, about }

class AppDrawer extends StatelessWidget {
  final DrawerItem current;
  final String userName;

  const AppDrawer({super.key, required this.current, this.userName = 'Ioel'});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Color(0xFF2F60C5)),
            child: Text(
              'HI ${userName.toUpperCase()}',
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),

          _item(context, DrawerItem.pushka, 'Mi Pushka', '/', Icons.home),
          _item(context, DrawerItem.wallet, 'Billetera', '/wallet', Icons.account_balance_wallet),
          _item(context, DrawerItem.reminders, 'Recordatorios', '/reminders', Icons.notifications),
          _item(context, DrawerItem.history, 'Historial', '/history', Icons.history),
          _item(context, DrawerItem.settings, 'Configuración', '/settings', Icons.settings),
          _item(context, DrawerItem.prayers, 'Segulot y Rezós', '/prayers', Icons.menu_book),
          _item(context, DrawerItem.support, 'Soporte', '/support', Icons.support_agent),
          _item(context, DrawerItem.about, 'Acerca de', '/about', Icons.info),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, DrawerItem item, String title, String route, IconData icon) {
    final selected = item == current;

    return ListTile(
      leading: Icon(icon, color: selected ? const Color(0xFF2F60C5) : null),
      title: Text(title, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
      selected: selected,
      onTap: () {
  Navigator.pop(context);
  if (GoRouterState.of(context).uri.toString() != route) {
    context.go(route);
  }
}



    );
  }
}
