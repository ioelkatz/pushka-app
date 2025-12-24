import 'package:flutter/material.dart';

class AppShell extends StatelessWidget {
  final Widget child;
  final Widget drawer;
  final PreferredSizeWidget? appBar;

  const AppShell({
    super.key,
    required this.child,
    required this.drawer,
    this.appBar,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: drawer,
      appBar: appBar,
      body: child,
    );
  }
}
