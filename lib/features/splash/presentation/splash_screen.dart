import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:lottie/lottie.dart';

// ---------------------------------------------------------------------------
// Splash screen
// ---------------------------------------------------------------------------

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  bool _showCoin = false;
  bool _showText = false;

  // Glow pulse behind pushka
  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;

  static const _gold = Color(0xFFD4AF37);
  static const _blue = Color(0xFF2563EB);

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _glowAnim = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);
    _runSequence();
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    setState(() => _showCoin = true);
    try {
      final player = AudioPlayer();
      await player.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    setState(() => _showText = true);
    await Future.delayed(const Duration(milliseconds: 1700));
    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: Stack(
        children: [
          // ── Background gradient ──────────────────────────────────────────
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0D1B2A),
                  Color(0xFF122338),
                  Color(0xFF0C1D30),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),

          // ── Warm amber glow at bottom center ────────────────────────────
          Positioned(
            bottom: -80,
            left: 0,
            right: 0,
            child: Container(
              height: 320,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    _gold.withValues(alpha: 0.07),
                    Colors.transparent,
                  ],
                  radius: 0.75,
                ),
              ),
            ),
          ),

          // ── Floating gold particles ──────────────────────────────────────
          const _GoldParticles(),

          // ── Main content ─────────────────────────────────────────────────
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo area
                SizedBox(
                  width: 200,
                  height: 240,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Pulsing blue glow
                      AnimatedBuilder(
                        animation: _glowAnim,
                        builder: (_, _) => Container(
                          width: 148 + _glowAnim.value * 28,
                          height: 148 + _glowAnim.value * 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                _blue.withValues(
                                    alpha: 0.17 + _glowAnim.value * 0.10),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ).animate().fadeIn(duration: 900.ms),

                      // Subtle gold ring
                      Container(
                        width: 150,
                        height: 150,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.18),
                            width: 1,
                          ),
                        ),
                      )
                          .animate()
                          .fadeIn(duration: 900.ms, delay: 300.ms)
                          .scale(
                            begin: const Offset(0.78, 0.78),
                            end: const Offset(1.0, 1.0),
                            duration: 700.ms,
                            curve: Curves.easeOutCubic,
                          ),

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

                      // Coin Lottie
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

                const SizedBox(height: 36),

                // "PUSHKA" — warm shimmer gradient on letters
                AnimatedOpacity(
                  opacity: _showText ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 500),
                  child: AnimatedSlide(
                    offset:
                        _showText ? Offset.zero : const Offset(0, 0.3),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    child: ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [
                          Colors.white,
                          Color(0xFFF0E4C2),
                          Colors.white,
                        ],
                        stops: [0.0, 0.5, 1.0],
                      ).createShader(bounds),
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
                ),

                const SizedBox(height: 16),

                // Gold divider line
                AnimatedOpacity(
                  opacity: _showText ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 900),
                  child: Container(
                    width: 64,
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          _gold.withValues(alpha: 0.65),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Hebrew tagline
                AnimatedOpacity(
                  opacity: _showText ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 700),
                  child: Text(
                    'צדקת רבי מאיר בעל הנס',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.58),
                      fontSize: 14,
                      letterSpacing: 1.5,
                      height: 1.4,
                    ),
                    textDirection: TextDirection.rtl,
                  ),
                ),

                const SizedBox(height: 40),

                // Colel Chabad branding
                AnimatedOpacity(
                  opacity: _showText ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 1100),
                  child: Text(
                    'COLEL CHABAD',
                    style: TextStyle(
                      color: _gold.withValues(alpha: 0.48),
                      fontSize: 11,
                      letterSpacing: 4.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Gold floating particles
// ---------------------------------------------------------------------------

class _GoldParticles extends StatefulWidget {
  const _GoldParticles();

  @override
  State<_GoldParticles> createState() => _GoldParticlesState();
}

class _GoldParticlesState extends State<_GoldParticles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final List<_Particle> _particles = [];

  @override
  void initState() {
    super.initState();
    final rng = Random(42); // fixed seed → consistent layout
    for (int i = 0; i < 18; i++) {
      _particles.add(_Particle(
        x: rng.nextDouble(),
        phase: rng.nextDouble(),
        speed: 0.12 + rng.nextDouble() * 0.10,
        radius: 1.2 + rng.nextDouble() * 2.2,
        opacity: 0.15 + rng.nextDouble() * 0.35,
        drift: (rng.nextDouble() - 0.5) * 0.04,
      ));
    }
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) => CustomPaint(
        painter: _ParticlePainter(_particles, _ctrl.value),
        size: Size.infinite,
      ),
    );
  }
}

class _Particle {
  final double x;
  final double phase;
  final double speed;
  final double radius;
  final double opacity;
  final double drift; // gentle horizontal sway

  const _Particle({
    required this.x,
    required this.phase,
    required this.speed,
    required this.radius,
    required this.opacity,
    required this.drift,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double progress;

  const _ParticlePainter(this.particles, this.progress);

  static const _gold = Color(0xFFD4AF37);

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final t = (p.phase + progress * p.speed * 6) % 1.0;
      // fade in at bottom, fade out at top
      final alpha = t < 0.12
          ? t / 0.12
          : t > 0.78
              ? (1.0 - t) / 0.22
              : 1.0;

      final px = (p.x + sin(t * pi * 2) * p.drift) * size.width;
      final py = size.height * (1.0 - t);

      canvas.drawCircle(
        Offset(px, py),
        p.radius,
        Paint()
          ..color = _gold.withValues(alpha: p.opacity * alpha)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.progress != progress;
}
