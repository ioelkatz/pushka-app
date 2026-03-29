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
    with TickerProviderStateMixin {
  bool _showCoin = false;
  bool _showText = false;
  bool _showFlash = false;

  // Slow glow pulse behind pushka
  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;

  // Gold flash burst when coin hits
  late final AnimationController _flashCtrl;

  static const _gold = Color(0xFFD4AF37);
  static const _blue = Color(0xFF1A4A9E);

  @override
  void initState() {
    super.initState();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _glowAnim = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);

    _flashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _runSequence();
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    _flashCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    // Trigger coin drop + flash + sound simultaneously
    setState(() {
      _showCoin = true;
      _showFlash = true;
    });
    _flashCtrl.forward();
    try {
      final player = AudioPlayer();
      await player.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;
    setState(() => _showText = true);

    await Future.delayed(const Duration(milliseconds: 2100));
    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060F1A),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Deep background gradient ─────────────────────────────────────
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0A1628),
                  Color(0xFF060F1A),
                  Color(0xFF0D1C30),
                ],
                stops: [0.0, 0.5, 1.0],
              ),
            ),
          ),

          // ── Large warm glow — bottom center ─────────────────────────────
          Positioned(
            bottom: -120,
            left: -60,
            right: -60,
            child: Container(
              height: 420,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    _gold.withValues(alpha: 0.09),
                    _gold.withValues(alpha: 0.03),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                  radius: 0.6,
                ),
              ),
            ),
          ),

          // ── Blue glow — top ──────────────────────────────────────────────
          Positioned(
            top: -80,
            left: 0,
            right: 0,
            child: Container(
              height: 300,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    _blue.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                  radius: 0.7,
                ),
              ),
            ),
          ),

          // ── Floating gold particles ──────────────────────────────────────
          const _GoldParticles(),

          // ── Gold flash burst on coin drop ────────────────────────────────
          if (_showFlash)
            AnimatedBuilder(
              animation: _flashCtrl,
              builder: (_, _) {
                final v = _flashCtrl.value;
                // Quick flash: peaks at 0.25 then fades
                final alpha = v < 0.25
                    ? v / 0.25
                    : (1.0 - v) / 0.75;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.15),
                      radius: 0.7,
                      colors: [
                        _gold.withValues(alpha: 0.18 * alpha),
                        Colors.transparent,
                      ],
                    ),
                  ),
                );
              },
            ),

          // ── Main content ─────────────────────────────────────────────────
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Logo area ──────────────────────────────────────────────
                SizedBox(
                  width: 220,
                  height: 260,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Outer pulsing glow ring (large, subtle)
                      AnimatedBuilder(
                        animation: _glowAnim,
                        builder: (_, _) => Container(
                          width: 200 + _glowAnim.value * 36,
                          height: 200 + _glowAnim.value * 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                _blue.withValues(
                                    alpha: 0.14 + _glowAnim.value * 0.12),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ).animate().fadeIn(duration: 1200.ms),

                      // Inner pulsing glow (tighter, warmer)
                      AnimatedBuilder(
                        animation: _glowAnim,
                        builder: (_, _) => Container(
                          width: 130 + _glowAnim.value * 20,
                          height: 130 + _glowAnim.value * 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                _gold.withValues(
                                    alpha: 0.10 + _glowAnim.value * 0.08),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ).animate().fadeIn(duration: 800.ms, delay: 200.ms),

                      // Gold ring 1
                      Container(
                        width: 162,
                        height: 162,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.20),
                            width: 1.0,
                          ),
                        ),
                      )
                          .animate()
                          .fadeIn(duration: 1000.ms, delay: 200.ms)
                          .scale(
                            begin: const Offset(0.70, 0.70),
                            end: const Offset(1.0, 1.0),
                            duration: 800.ms,
                            curve: Curves.easeOutCubic,
                          ),

                      // Gold ring 2 (slightly larger, very faint)
                      Container(
                        width: 188,
                        height: 188,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.08),
                            width: 1.0,
                          ),
                        ),
                      )
                          .animate()
                          .fadeIn(duration: 1200.ms, delay: 350.ms)
                          .scale(
                            begin: const Offset(0.65, 0.65),
                            end: const Offset(1.0, 1.0),
                            duration: 900.ms,
                            curve: Curves.easeOutCubic,
                          ),

                      // Pushka logo
                      Positioned(
                        bottom: 24,
                        child: Image.asset(
                          'assets/images/pushka.png',
                          width: 140,
                          height: 140,
                        )
                            .animate()
                            .fadeIn(duration: 600.ms, curve: Curves.easeOut)
                            .scale(
                              begin: const Offset(0.70, 0.70),
                              end: const Offset(1.0, 1.0),
                              duration: 700.ms,
                              curve: Curves.easeOutBack,
                            ),
                      ),

                      // Coin Lottie drop
                      if (_showCoin)
                        Positioned(
                          top: 0,
                          child: Lottie.asset(
                            'assets/animations/coin_drop.json',
                            width: 180,
                            height: 200,
                            repeat: false,
                            fit: BoxFit.contain,
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 44),

                // ── "PUSHKA" shimmer text ──────────────────────────────────
                AnimatedOpacity(
                  opacity: _showText ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 600),
                  child: AnimatedSlide(
                    offset: _showText ? Offset.zero : const Offset(0, 0.35),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    child: ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [
                          Color(0xFFD4AF37),
                          Colors.white,
                          Color(0xFFF5E6A0),
                          Colors.white,
                          Color(0xFFD4AF37),
                        ],
                        stops: [0.0, 0.25, 0.5, 0.75, 1.0],
                      ).createShader(bounds),
                      child: const Text(
                        'PUSHKA',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 12,
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 18),

                // ── Gold gradient divider ──────────────────────────────────
                AnimatedOpacity(
                  opacity: _showText ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 1000),
                  child: Container(
                    width: 80,
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          _gold.withValues(alpha: 0.80),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 18),

                // ── Hebrew tagline ─────────────────────────────────────────
                AnimatedOpacity(
                  opacity: _showText ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 800),
                  child: Text(
                    'צדקת רבי מאיר בעל הנס',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 15,
                      letterSpacing: 1.2,
                      height: 1.4,
                    ),
                    textDirection: TextDirection.rtl,
                  ),
                ),

                const SizedBox(height: 48),

                // ── Colel Chabad branding ──────────────────────────────────
                AnimatedOpacity(
                  opacity: _showText ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 1200),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 24,
                        height: 1,
                        color: _gold.withValues(alpha: 0.35),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'COLEL CHABAD',
                        style: TextStyle(
                          color: _gold.withValues(alpha: 0.55),
                          fontSize: 11,
                          letterSpacing: 5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        width: 24,
                        height: 1,
                        color: _gold.withValues(alpha: 0.35),
                      ),
                    ],
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
    final rng = Random(17);
    for (int i = 0; i < 28; i++) {
      _particles.add(_Particle(
        x: rng.nextDouble(),
        phase: rng.nextDouble(),
        speed: 0.10 + rng.nextDouble() * 0.12,
        radius: 1.4 + rng.nextDouble() * 2.8,
        opacity: 0.22 + rng.nextDouble() * 0.45,
        drift: (rng.nextDouble() - 0.5) * 0.05,
      ));
    }
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
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
  final double drift;

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
      final t = (p.phase + progress * p.speed * 7) % 1.0;
      final alpha = t < 0.10
          ? t / 0.10
          : t > 0.75
              ? (1.0 - t) / 0.25
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
