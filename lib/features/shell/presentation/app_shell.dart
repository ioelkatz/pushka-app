import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatelessWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pushka')),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text(
                'HI IOEL',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
            ),
            _item(context, 'My Pushka', '/', Icons.home),
            _item(context, 'Wallet', '/wallet', Icons.account_balance_wallet),
            _item(context, 'Reminders', '/reminders', Icons.notifications),
            _item(context, 'History', '/history', Icons.history),
            _item(context, 'Settings', '/settings', Icons.settings),
            _item(context, 'Segulot & Prayers', '/prayers', Icons.menu_book),
            _item(context, 'Support', '/support', Icons.support),
            _item(context, 'About Us', '/about', Icons.info),
          ],
        ),
      ),
      body: child,
    );
  }

  ListTile _item(BuildContext context, String title, String route, IconData icon) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      onTap: () {
        Navigator.pop(context);
        context.go(route);
      },
    );
  }
}
