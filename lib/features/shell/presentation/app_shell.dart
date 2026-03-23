import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../app/theme/app_tokens.dart';

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
    Widget body = child;
    if (kIsWeb) {
      body = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: child,
        ),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: AppTokens.surface,
      drawer: drawer,
      appBar: appBar,
      body: body,
    );
  }
}