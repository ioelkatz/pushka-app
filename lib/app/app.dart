import 'package:flutter/material.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class PushkaApp extends StatelessWidget {
  const PushkaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Pushka',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: AppTheme.light(),
    );
  }
}
