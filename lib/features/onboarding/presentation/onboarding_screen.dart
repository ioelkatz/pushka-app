import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _ctrl = PageController();
  int _page = 0;
  static const _total = 3;
  bool _completing = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (_completing) return;
    setState(() => _completing = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      // Attempt up to 2 times so a transient network hiccup doesn't leave the
      // user stuck in an onboarding loop on every subsequent launch.
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .set({'onboardingCompleted': true}, SetOptions(merge: true));
          break; // success
        } catch (_) {
          if (attempt == 1) {
            // Both attempts failed — navigate anyway. The router will show
            // onboarding again next launch, which is preferable to blocking
            // the user forever on a network error.
          }
        }
      }
    }
    if (!mounted) return;
    context.go('/');
  }

  void _next() {
    if (_page < _total - 1) {
      _ctrl.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } else {
      _complete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final isLast = _page == _total - 1;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // Skip button
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _completing ? null : _complete,
                child: Text(
                  tr.onboardingSkip,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
                ),
              ),
            ),

            // Pages
            Expanded(
              child: PageView(
                controller: _ctrl,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _OnboardingPage(
                    icon: Icons.volunteer_activism_rounded,
                    color: const Color(0xFF2563EB),
                    title: tr.onboarding1Title,
                    body: tr.onboarding1Body,
                  ),
                  _OnboardingPage(
                    icon: Icons.savings_rounded,
                    color: const Color(0xFF059669),
                    title: tr.onboarding2Title,
                    body: tr.onboarding2Body,
                  ),
                  _OnboardingPage(
                    icon: Icons.notifications_active_rounded,
                    color: const Color(0xFFD97706),
                    title: tr.onboarding3Title,
                    body: tr.onboarding3Body,
                  ),
                ],
              ),
            ),

            // Dots + button
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Column(
                children: [
                  SmoothPageIndicator(
                    controller: _ctrl,
                    count: _total,
                    effect: WormEffect(
                      dotColor: Colors.grey.shade300,
                      activeDotColor: AppTokens.primaryBlue,
                      dotHeight: 8,
                      dotWidth: 8,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: AppTokens.buttonHeight,
                    child: ElevatedButton(
                      onPressed: _completing ? null : _next,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTokens.primaryBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                        ),
                      ),
                      child: Text(
                        isLast ? tr.onboardingDone : tr.onboardingNext,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;

  const _OnboardingPage({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 60, color: color),
          ),
          const SizedBox(height: 40),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onSurface,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
