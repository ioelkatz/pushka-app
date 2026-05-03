import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/widgets/offline_banner.dart';

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
      // Edge-to-edge: paint the Scaffold's surface all the way down
      // through the system nav bar area. Without this the OS bar is
      // transparent (per styles.xml) but the Window background shows
      // through underneath, which on dark mode = solid black band.
      // extendBody pushes the body behind the bottom system bar; we
      // wrap the child in SafeArea(top:false) so app content itself
      // still avoids being covered by the buttons.
      extendBody: true,
      extendBodyBehindAppBar: false,
      drawer: drawer,
      appBar: appBar,
      body: OfflineBanner(
        child: SafeArea(
          top: false,
          child: body,
        ),
      ),
    );
  }
}