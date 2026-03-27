import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:lottie/lottie.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _showCoin = false;
  bool _showText = false;

  @override
  void initState() {
    super.initState();
    _runSequence();
  }

  Future<void> _runSequence() async {
    // Logo entrance: 600ms
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    setState(() => _showCoin = true);

    // Play coin sound
    try {
      final player = AudioPlayer();
      await player.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}

    // Text appears shortly after
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    setState(() => _showText = true);

    // Lottie plays ~1.67s (50 frames @ 30fps) + brief pause
    await Future.delayed(const Duration(milliseconds: 1700));
    if (!mounted) return;

    // Router redirect handles auth + onboarding state
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0D1B2A), Color(0xFF122338), Color(0xFF0A1929)],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pushka + coin stack
              SizedBox(
                width: 180,
                height: 220,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Subtle glow behind pushka
                    Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xFF2563EB).withValues(alpha: 0.25),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 800.ms, curve: Curves.easeOut),

                    // Pushka logo
                    Positioned(
                      bottom: 20,
                      child: Image.asset(
                        'assets/images/pushka.png',
                        width: 130,
                        height: 130,
                      )
                          .animate()
                          .fadeIn(duration: 550.ms, curve: Curves.easeOut)
                          .scale(
                            begin: const Offset(0.75, 0.75),
                            end: const Offset(1.0, 1.0),
                            duration: 550.ms,
                            curve: Curves.easeOutBack,
                          ),
                    ),

                    // Coin Lottie - drops into pushka
                    if (_showCoin)
                      Positioned(
                        top: 0,
                        child: Lottie.asset(
                          'assets/animations/coin_drop.json',
                          width: 160,
                          height: 180,
                          repeat: false,
                          fit: BoxFit.contain,
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // App name
              AnimatedOpacity(
                opacity: _showText ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 500),
                child: AnimatedSlide(
                  offset: _showText ? Offset.zero : const Offset(0, 0.3),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutCubic,
                  child: const Text(
                    'PUSHKA',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 10,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // Hebrew tagline
              AnimatedOpacity(
                opacity: _showText ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 700),
                child: Text(
                  'צדקת רבי מאיר בעל הנס',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 14,
                    letterSpacing: 1.5,
                    height: 1.4,
                  ),
                  textDirection: TextDirection.rtl,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
