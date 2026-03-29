import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:lottie/lottie.dart';

// ---------------------------------------------------------------------------
// Splash screen — premium experience
// ---------------------------------------------------------------------------

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  bool _showCoin = false;

  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;
  late final AnimationController _flashCtrl;

  static const _gold = Color(0xFFD4AF37);
  static const _blue = Color(0xFF1A4A9E);
  static const _navyBg = Color(0xFF060F1A);

  @override
  void initState() {
    super.initState();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _glowAnim = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);

    _flashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
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
    // Coin drops at 900ms — everything else enters immediately via flutter_animate
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() => _showCoin = true);
    _flashCtrl.forward();
    try {
      final player = AudioPlayer();
      await player.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}

    // Navigate after user has time to enjoy the full screen
    await Future.delayed(const Duration(milliseconds: 2400));
    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return Scaffold(
      backgroundColor: _navyBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Rich dark gradient ────────────────────────────────────────────
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.2),
                radius: 1.1,
                colors: [
                  Color(0xFF0F2040),
                  Color(0xFF060F1A),
                ],
              ),
            ),
          ),

          // ── Wide gold glow at bottom ──────────────────────────────────────
          Positioned(
            bottom: -100,
            left: 0,
            right: 0,
            child: Container(
              height: size.height * 0.5,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    _gold.withValues(alpha: 0.11),
                    _gold.withValues(alpha: 0.04),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.4, 1.0],
                  radius: 0.65,
                ),
              ),
            ),
          ).animate().fadeIn(duration: 600.ms),

          // ── Floating gold particles ───────────────────────────────────────
          const _GoldParticles(),

          // ── Gold radial flash on coin drop ────────────────────────────────
          AnimatedBuilder(
            animation: _flashCtrl,
            builder: (_, _) {
              final v = _flashCtrl.value;
              final alpha = v < 0.3
                  ? v / 0.3
                  : (1.0 - v) / 0.7;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.25),
                    radius: 0.65,
                    colors: [
                      _gold.withValues(alpha: 0.22 * alpha),
                      Colors.transparent,
                    ],
                  ),
                ),
              );
            },
          ),

          // ── Main content ──────────────────────────────────────────────────
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Logo area ────────────────────────────────────────────────
              SizedBox(
                width: 230,
                height: 270,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Outer blue glow pulse
                    AnimatedBuilder(
                      animation: _glowAnim,
                      builder: (_, _) => Container(
                        width: 210 + _glowAnim.value * 40,
                        height: 210 + _glowAnim.value * 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              _blue.withValues(
                                  alpha: 0.16 + _glowAnim.value * 0.12),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ).animate().fadeIn(duration: 1000.ms),

                    // Inner gold glow pulse
                    AnimatedBuilder(
                      animation: _glowAnim,
                      builder: (_, _) => Container(
                        width: 140 + _glowAnim.value * 22,
                        height: 140 + _glowAnim.value * 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              _gold.withValues(
                                  alpha: 0.12 + _glowAnim.value * 0.10),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ).animate().fadeIn(duration: 700.ms, delay: 150.ms),

                    // Outer gold ring
                    Container(
                      width: 192,
                      height: 192,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _gold.withValues(alpha: 0.20),
                          width: 1.0,
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 800.ms, delay: 100.ms)
                        .scale(
                          begin: const Offset(0.6, 0.6),
                          end: const Offset(1.0, 1.0),
                          duration: 700.ms,
                          curve: Curves.easeOutCubic,
                        ),

                    // Inner gold ring
                    Container(
                      width: 165,
                      height: 165,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _gold.withValues(alpha: 0.30),
                          width: 1.5,
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 700.ms, delay: 50.ms)
                        .scale(
                          begin: const Offset(0.6, 0.6),
                          end: const Offset(1.0, 1.0),
                          duration: 650.ms,
                          curve: Curves.easeOutCubic,
                        ),

                    // Pushka logo
                    Positioned(
                      bottom: 24,
                      child: Image.asset(
                        'assets/images/pushka.png',
                        width: 148,
                        height: 148,
                      )
                          .animate()
                          .fadeIn(duration: 500.ms, curve: Curves.easeOut)
                          .scale(
                            begin: const Offset(0.65, 0.65),
                            end: const Offset(1.0, 1.0),
                            duration: 600.ms,
                            curve: Curves.easeOutBack,
                          ),
                    ),

                    // Coin Lottie
                    if (_showCoin)
                      Positioned(
                        top: 0,
                        child: Lottie.asset(
                          'assets/animations/coin_drop.json',
                          width: 190,
                          height: 210,
                          repeat: false,
                          fit: BoxFit.contain,
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 48),

              // ── PUSHKA — gold shimmer ─────────────────────────────────────
              ShaderMask(
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
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 14,
                  ),
                ),
              )
                  .animate()
                  .fadeIn(duration: 700.ms, delay: 200.ms)
                  .slideY(
                    begin: 0.4,
                    end: 0.0,
                    duration: 700.ms,
                    delay: 200.ms,
                    curve: Curves.easeOutCubic,
                  ),

              const SizedBox(height: 20),

              // ── Gold divider ──────────────────────────────────────────────
              Container(
                width: 90,
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      _gold.withValues(alpha: 0.90),
                      Colors.transparent,
                    ],
                  ),
                ),
              )
                  .animate()
                  .fadeIn(duration: 900.ms, delay: 350.ms),

              const SizedBox(height: 20),

              // ── Hebrew tagline ────────────────────────────────────────────
              Text(
                'צדקת רבי מאיר בעל הנס',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.68),
                  fontSize: 15,
                  letterSpacing: 1.2,
                  height: 1.4,
                ),
                textDirection: TextDirection.rtl,
              )
                  .animate()
                  .fadeIn(duration: 900.ms, delay: 400.ms)
                  .slideY(
                    begin: 0.3,
                    end: 0.0,
                    duration: 700.ms,
                    delay: 400.ms,
                    curve: Curves.easeOutCubic,
                  ),

              const SizedBox(height: 52),

              // ── COLEL CHABAD ─────────────────────────────────────────────
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 28,
                    height: 1,
                    color: _gold.withValues(alpha: 0.40),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'COLEL CHABAD',
                    style: TextStyle(
                      color: _gold.withValues(alpha: 0.60),
                      fontSize: 11,
                      letterSpacing: 5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 28,
                    height: 1,
                    color: _gold.withValues(alpha: 0.40),
                  ),
                ],
              ).animate().fadeIn(duration: 1100.ms, delay: 550.ms),
            ],
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
    for (int i = 0; i < 30; i++) {
      _particles.add(_Particle(
        x: rng.nextDouble(),
        phase: rng.nextDouble(),
        speed: 0.09 + rng.nextDouble() * 0.11,
        radius: 1.6 + rng.nextDouble() * 3.0,
        opacity: 0.28 + rng.nextDouble() * 0.48,
        drift: (rng.nextDouble() - 0.5) * 0.06,
      ));
    }
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
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
      final t = (p.phase + progress * p.speed * 8) % 1.0;
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
