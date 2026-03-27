import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Wraps the app and signs the user out after [timeout] of inactivity.
/// Only active when a user is signed in.
class InactivityDetector extends StatefulWidget {
  const InactivityDetector({
    super.key,
    required this.child,
    this.timeout = const Duration(minutes: 15),
  });

  final Widget child;
  final Duration timeout;

  @override
  State<InactivityDetector> createState() => _InactivityDetectorState();
}

class _InactivityDetectorState extends State<InactivityDetector>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resetTimer();
    } else if (state == AppLifecycleState.paused) {
      // Keep timer running in background — sign out if reopened after timeout
    }
  }

  void _resetTimer() {
    _timer?.cancel();
    _timer = Timer(widget.timeout, _handleTimeout);
  }

  Future<void> _handleTimeout() async {
    if (FirebaseAuth.instance.currentUser == null) return;
    await FirebaseAuth.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _resetTimer(),
      child: widget.child,
    );
  }
}
