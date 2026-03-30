import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

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
  bool _coinDropping = false;

  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;
  late final AnimationController _coinCtrl;   // coin fall (480 ms)
  late final AnimationController _bounceCtrl; // box bounce on impact (340 ms)
  late final AnimationController _flashCtrl;  // gold flash (700 ms)

  static const _gold = Color(0xFFD4AF37);

  // ── Coin Y animation ────────────────────────────────────────────────────
  // SizedBox is 230×270. Image (168×168) sits at bottom: 24.
  //   image-top  = 270 − 168 − 24 = 78
  //   clip hides top 28 % of image (≈ 47 px) → clip-boundary = 78 + 47 = 125
  //   coin-center should end at y = 125 → coin-top end = 125 − 22 = 103
  //   coin continues to 155 so it fully disappears behind the image.
  late final Animation<double> _coinY;
  late final Animation<double> _coinRotation;

  @override
  void initState() {
    super.initState();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _glowAnim = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);

    _coinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _coinY = Tween<double>(begin: -108.0, end: 155.0).animate(
      CurvedAnimation(parent: _coinCtrl, curve: Curves.easeIn),
    );
    _coinRotation = Tween<double>(begin: -0.18, end: 0.18).animate(
      CurvedAnimation(parent: _coinCtrl, curve: Curves.easeIn),
    );

    _bounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _flashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _runSequence();
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    _coinCtrl.dispose();
    _bounceCtrl.dispose();
    _flashCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 880));
    if (!mounted) return;
    setState(() => _coinDropping = true);
    _coinCtrl.forward();

    // Wait for coin to reach slot
    await Future.delayed(const Duration(milliseconds: 480));
    if (!mounted) return;

    // Impact
    _bounceCtrl.forward();
    _flashCtrl.forward();
    try {
      final player = AudioPlayer();
      await player.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 2200));
    if (!mounted) return;
    context.go('/');
  }

  double _boxScale() {
    final t = _bounceCtrl.value;
    if (t < 0.25) return 1.0 + t / 0.25 * 0.07;        // 1.00 → 1.07
    if (t < 0.55) return 1.07 - (t - 0.25) / 0.30 * 0.11; // 1.07 → 0.96
    if (t < 0.80) return 0.96 + (t - 0.55) / 0.25 * 0.05; // 0.96 → 1.01
    return 1.01 - (t - 0.80) / 0.20 * 0.01;               // 1.01 → 1.00
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Matches the native-splash blue → no dark flash on transition
      backgroundColor: const Color(0xFF3B7FD8),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Background: same blues as splash_icon.png, radial from center ──
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.20),
                radius: 1.15,
                colors: [
                  Color(0xFF5BA4EE), // bright centre — matches logo highlight
                  Color(0xFF3A7FD8), // mid blue — logo body
                  Color(0xFF1A4FA8), // deeper — logo shadow
                  Color(0xFF0C2250), // lower screen
                  Color(0xFF060E22), // deep bottom edge
                ],
                stops: [0.0, 0.22, 0.45, 0.72, 1.0],
              ),
            ),
          ),

          // ── Subtle warm glow at bottom ────────────────────────────────────
          Positioned(
            bottom: -80,
            left: 0,
            right: 0,
            child: Container(
              height: 260,
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

          // ── Gold particles ────────────────────────────────────────────────
          const _GoldParticles(),

          // ── Gold radial burst on coin impact ──────────────────────────────
          AnimatedBuilder(
            animation: _flashCtrl,
            builder: (_, _) {
              final v = _flashCtrl.value;
              final alpha = v < 0.30 ? v / 0.30 : (1.0 - v) / 0.70;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.28),
                    radius: 0.50,
                    colors: [
                      _gold.withValues(alpha: 0.32 * alpha),
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
                  // Clip.none lets the coin start above this SizedBox
                  clipBehavior: Clip.none,
                  children: [
                    // Pulsing blue halo (same colour family → no visible rim)
                    AnimatedBuilder(
                      animation: _glowAnim,
                      builder: (_, _) {
                        final r = 185.0 + _glowAnim.value * 36;
                        return Positioned.fill(
                          child: Center(
                            child: SizedBox(
                              width: r,
                              height: r,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      const Color(0xFF5BA4EE).withValues(
                                          alpha: 0.20 + _glowAnim.value * 0.14),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ).animate().fadeIn(duration: 800.ms),

                    // ── Animated coin (BEHIND the logo image in z-order) ────
                    // When it crosses the clip boundary (y ≈ 125) the image
                    // covers it, giving the illusion it entered the slot.
                    if (_coinDropping)
                      AnimatedBuilder(
                        animation: _coinCtrl,
                        builder: (_, _) => Positioned(
                          left: (230 - 44) / 2, // centred
                          top: _coinY.value,
                          child: Transform.rotate(
                            angle: _coinRotation.value,
                            child: const _GoldCoin(size: 44),
                          ),
                        ),
                      ),

                    // ── Logo image — ON TOP of coin in z-order ───────────
                    // Clipped: hides top 28 % (the static coin of the PNG).
                    // When the animated coin falls to y ≈ 125, it passes
                    // behind this widget and disappears — entering the slot.
                    Positioned(
                      bottom: 24,
                      left: (230 - 168) / 2,
                      child: AnimatedBuilder(
                        animation: _bounceCtrl,
                        builder: (_, child) => Transform.scale(
                          scale: _boxScale(),
                          child: child,
                        ),
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            heightFactor: 0.72, // hide top 28 % (coin area)
                            child: Image.asset(
                              'assets/images/splash_icon.png',
                              width: 168,
                              height: 168,
                            ),
                          ),
                        ),
                      ),
                    )
                        .animate()
                        .fadeIn(duration: 500.ms)
                        .scale(
                          begin: const Offset(0.72, 0.72),
                          end: const Offset(1.0, 1.0),
                          duration: 600.ms,
                          curve: Curves.easeOutBack,
                        ),
                  ],
                ),
              ),

              const SizedBox(height: 44),

              // ── "PUSHKA" gold-shimmer ─────────────────────────────────────
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

              // ── Gold divider ──────────────────────────────────────────────
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
                      color: _gold.withValues(alpha: 0.40)),
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
                      color: _gold.withValues(alpha: 0.40)),
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
// Gold coin widget (drawn via CustomPainter to match splash_icon.png style)
// ---------------------------------------------------------------------------

class _GoldCoin extends StatelessWidget {
  final double size;
  const _GoldCoin({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFFD700).withValues(alpha: 0.70),
            blurRadius: 18,
            spreadRadius: 5,
          ),
        ],
      ),
      child: CustomPaint(
        painter: const _CoinPainter(),
        size: Size(size, size),
      ),
    );
  }
}

class _CoinPainter extends CustomPainter {
  const _CoinPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Main gold radial gradient
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.30, -0.40),
          radius: 0.90,
          colors: const [
            Color(0xFFFFF5A0), // bright top-left highlight
            Color(0xFFFFD700), // pure gold
            Color(0xFFD4AF37), // mid gold
            Color(0xFF9A7020), // dark edge
          ],
          stops: const [0.0, 0.28, 0.65, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // Outer rim
    canvas.drawCircle(
      c,
      r - 1.5,
      Paint()
        ..color = const Color(0xFFA07820)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Inner specular shine
    final shineC = Offset(c.dx - r * 0.20, c.dy - r * 0.22);
    canvas.drawCircle(
      shineC,
      r * 0.36,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: shineC, radius: r * 0.36)),
    );
  }

  @override
  bool shouldRepaint(_CoinPainter old) => false;
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
  final double x, phase, speed, radius, opacity, drift;
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
