import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:lottie/lottie.dart';

// ---------------------------------------------------------------------------
// Splash screen — seamless blue gradient, logo blends with background
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

  static const _logoBlueDark = Color(0xFF1A4FA8);
  static const _gold         = Color(0xFFD4AF37);

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
      duration: const Duration(milliseconds: 900),
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
    await Future.delayed(const Duration(milliseconds: 950));
    if (!mounted) return;
    setState(() => _showCoin = true);
    _flashCtrl.forward();
    try {
      final player = AudioPlayer();
      await player.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 2400));
    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Base colour matches the mid-logo blue so there is never a flash
      backgroundColor: _logoBlueDark,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Seamless background: same blues as the logo, radiating out ───
          // Center (behind logo) = logo's own blue → edges = deep navy
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.18),
                radius: 1.15,
                colors: [
                  Color(0xFF5BA4EE), // highlight — top of logo
                  Color(0xFF3A7FD8), // mid — body of logo
                  Color(0xFF1A4FA8), // lower — logo shadow
                  Color(0xFF0C2250), // screen lower-mid
                  Color(0xFF060E22), // deep bottom edge
                ],
                stops: [0.0, 0.22, 0.45, 0.72, 1.0],
              ),
            ),
          ),

          // ── Subtle gold warmth at the very bottom ────────────────────────
          Positioned(
            bottom: -80,
            left: 0,
            right: 0,
            child: Container(
              height: 280,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    _gold.withValues(alpha: 0.07),
                    Colors.transparent,
                  ],
                  radius: 0.7,
                ),
              ),
            ),
          ),

          // ── Gold particles drifting upward ───────────────────────────────
          const _GoldParticles(),

          // ── Soft gold radial burst when coin drops ────────────────────────
          AnimatedBuilder(
            animation: _flashCtrl,
            builder: (_, _) {
              final v = _flashCtrl.value;
              final alpha =
                  v < 0.30 ? v / 0.30 : (1.0 - v) / 0.70;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.30),
                    radius: 0.55,
                    colors: [
                      _gold.withValues(alpha: 0.28 * alpha),
                      Colors.transparent,
                    ],
                  ),
                ),
              );
            },
          ),

          // ── Soft pulsing halo behind logo (same blues, no visible edge) ──
          AnimatedBuilder(
            animation: _glowAnim,
            builder: (_, _) {
              final r = 180.0 + _glowAnim.value * 38;
              return Center(
                child: SizedBox(
                  width: r,
                  height: r,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          // same family as background → invisible edge
                          Color(0xFF5BA4EE)
                              .withValues(alpha: 0.18 + _glowAnim.value * 0.14),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ).animate().fadeIn(duration: 900.ms),

          // ── Main content ─────────────────────────────────────────────────
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Logo (no rings, no circular frame — sits inside gradient) ─
              SizedBox(
                width: 210,
                height: 250,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // splash_icon.png — the 3-D blue box with star + coin slot
                    // Its own blue background blends with the radial gradient
                    Positioned(
                      bottom: 20,
                      child: Image.asset(
                        'assets/images/splash_icon.png',
                        width: 168,
                        height: 168,
                      )
                          .animate()
                          .fadeIn(duration: 500.ms, curve: Curves.easeOut)
                          .scale(
                            begin: const Offset(0.72, 0.72),
                            end: const Offset(1.0, 1.0),
                            duration: 650.ms,
                            curve: Curves.easeOutBack,
                          ),
                    ),

                    // Coin Lottie drops into slot
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

              const SizedBox(height: 44),

              // ── PUSHKA — gold-shimmer letters ────────────────────────────
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [
                    Color(0xFFD4AF37),
                    Colors.white,
                    Color(0xFFF5E6A0),
                    Colors.white,
                    Color(0xFFD4AF37),
                  ],
                  stops: [0.0, 0.25, 0.50, 0.75, 1.0],
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
                  .fadeIn(duration: 700.ms, delay: 150.ms)
                  .slideY(
                    begin: 0.35,
                    end: 0.0,
                    duration: 700.ms,
                    delay: 150.ms,
                    curve: Curves.easeOutCubic,
                  ),

              const SizedBox(height: 18),

              // ── Thin gold divider ─────────────────────────────────────────
              Container(
                width: 90,
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      _gold.withValues(alpha: 0.85),
                      Colors.transparent,
                    ],
                  ),
                ),
              ).animate().fadeIn(duration: 900.ms, delay: 300.ms),

              const SizedBox(height: 18),

              // ── Hebrew tagline ────────────────────────────────────────────
              Text(
                'צדקת רבי מאיר בעל הנס',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 15,
                  letterSpacing: 1.2,
                  height: 1.4,
                ),
                textDirection: TextDirection.rtl,
              )
                  .animate()
                  .fadeIn(duration: 900.ms, delay: 350.ms)
                  .slideY(
                    begin: 0.3,
                    end: 0.0,
                    duration: 700.ms,
                    delay: 350.ms,
                    curve: Curves.easeOutCubic,
                  ),

              const SizedBox(height: 52),

              // ── COLEL CHABAD ──────────────────────────────────────────────
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
                      color: _gold.withValues(alpha: 0.65),
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
              ).animate().fadeIn(duration: 1100.ms, delay: 500.ms),
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
