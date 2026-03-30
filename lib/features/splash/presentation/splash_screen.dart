import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

// ---------------------------------------------------------------------------
// Splash screen — fully custom-drawn pushka + animated coin drop
// ---------------------------------------------------------------------------

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Phase flags
  bool _boxVisible   = false;
  bool _coinDropping = false;
  bool _coinInSlot   = false;

  late final AnimationController _boxCtrl;    // box entrance  600 ms
  late final AnimationController _coinCtrl;   // coin drop     460 ms
  late final AnimationController _bounceCtrl; // box bounce    360 ms
  late final AnimationController _flashCtrl;  // gold flash    700 ms
  late final AnimationController _glowCtrl;   // idle glow    2200 ms
  late final AnimationController _shimmerCtrl;// coin shimmer 1800 ms

  late final Animation<double> _boxScale;
  late final Animation<double> _coinY;       // 0.0 = above, 1.0 = in slot
  late final Animation<double> _glowAnim;
  late final Animation<double> _shimmerAnim;

  @override
  void initState() {
    super.initState();

    _boxCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 600));
    _boxScale = CurvedAnimation(parent: _boxCtrl, curve: Curves.easeOutBack);

    _coinCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 460));
    _coinY = CurvedAnimation(parent: _coinCtrl, curve: Curves.easeIn);

    _bounceCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 360));
    _flashCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 700));

    _glowCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 2200))
      ..repeat(reverse: true);
    _glowAnim = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);

    _shimmerCtrl = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 1800))
      ..repeat();
    _shimmerAnim = CurvedAnimation(parent: _shimmerCtrl,
        curve: Curves.easeInOut);

    _runSequence();
  }

  @override
  void dispose() {
    _boxCtrl.dispose();
    _coinCtrl.dispose();
    _bounceCtrl.dispose();
    _flashCtrl.dispose();
    _glowCtrl.dispose();
    _shimmerCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSequence() async {
    // 1. Box entrance
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() => _boxVisible = true);
    _boxCtrl.forward();

    // 2. Coin drops after box settles
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _coinDropping = true);
    _coinCtrl.forward();

    // 3. Impact
    await Future.delayed(const Duration(milliseconds: 460));
    if (!mounted) return;
    setState(() { _coinDropping = false; _coinInSlot = true; });
    _bounceCtrl.forward();
    _flashCtrl.forward();
    try {
      final p = AudioPlayer();
      await p.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}

    // 4. Stay and navigate
    await Future.delayed(const Duration(milliseconds: 2300));
    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3B7FD8),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Background radial gradient ──────────────────────────────────
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.25),
                radius: 1.15,
                colors: [
                  Color(0xFF5BA4EE),
                  Color(0xFF3A7FD8),
                  Color(0xFF1A4FA8),
                  Color(0xFF0C2250),
                  Color(0xFF060E22),
                ],
                stops: [0.0, 0.22, 0.45, 0.72, 1.0],
              ),
            ),
          ),

          // ── Warm gold at bottom ─────────────────────────────────────────
          Positioned(
            bottom: -60, left: 0, right: 0,
            child: Container(
              height: 240,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFFD4AF37).withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                  radius: 0.7,
                ),
              ),
            ),
          ),

          // ── Gold particles ──────────────────────────────────────────────
          const _GoldParticles(),

          // ── Gold flash on impact ────────────────────────────────────────
          AnimatedBuilder(
            animation: _flashCtrl,
            builder: (_, _) {
              final v = _flashCtrl.value;
              final a = v < 0.3 ? v / 0.3 : (1.0 - v) / 0.7;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.25),
                    radius: 0.55,
                    colors: [
                      const Color(0xFFD4AF37).withValues(alpha: 0.35 * a),
                      Colors.transparent,
                    ],
                  ),
                ),
              );
            },
          ),

          // ── Main content ────────────────────────────────────────────────
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Pushka + coin (custom drawn) ─────────────────────────────
              if (_boxVisible)
                AnimatedBuilder(
                  animation: Listenable.merge(
                      [_boxScale, _bounceCtrl, _glowAnim, _coinCtrl]),
                  builder: (_, _) {
                    return CustomPaint(
                      painter: _PushkaPainter(
                        boxEntrance: _boxScale.value,
                        bounceT:     _bounceCtrl.value,
                        glow:        _glowAnim.value,
                        coinProgress: _coinDropping ? _coinY.value : null,
                        coinInSlot:   _coinInSlot,
                        shimmer:      _shimmerAnim.value,
                      ),
                      size: const Size(240, 280),
                    );
                  },
                )
              else
                const SizedBox(height: 280),

              const SizedBox(height: 38),

              // ── PUSHKA ────────────────────────────────────────────────────
              ShaderMask(
                shaderCallback: (b) => const LinearGradient(
                  colors: [
                    Color(0xFFD4AF37), Colors.white,
                    Color(0xFFF5E6A0), Colors.white,
                    Color(0xFFD4AF37),
                  ],
                  stops: [0.0, 0.25, 0.50, 0.75, 1.0],
                ).createShader(b),
                child: const Text('PUSHKA',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 13,
                    )),
              )
                  .animate()
                  .fadeIn(duration: 700.ms, delay: 200.ms)
                  .slideY(begin: 0.4, end: 0.0,
                      duration: 700.ms, delay: 200.ms,
                      curve: Curves.easeOutCubic),

              const SizedBox(height: 16),

              // ── Gold divider ──────────────────────────────────────────────
              Container(
                width: 80, height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Colors.transparent,
                    const Color(0xFFD4AF37).withValues(alpha: 0.90),
                    Colors.transparent,
                  ]),
                ),
              ).animate().fadeIn(duration: 900.ms, delay: 360.ms),

              const SizedBox(height: 16),

              // ── Hebrew tagline ────────────────────────────────────────────
              Text(
                'צדקת רבי מאיר בעל הנס',
                textDirection: TextDirection.rtl,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.70),
                  fontSize: 14,
                  letterSpacing: 1.1,
                  height: 1.4,
                ),
              )
                  .animate()
                  .fadeIn(duration: 900.ms, delay: 420.ms)
                  .slideY(begin: 0.3, end: 0.0,
                      duration: 700.ms, delay: 420.ms,
                      curve: Curves.easeOutCubic),

              const SizedBox(height: 48),

              // ── COLEL CHABAD ──────────────────────────────────────────────
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _goldLine(),
                  const SizedBox(width: 12),
                  Text('COLEL CHABAD',
                      style: TextStyle(
                        color: const Color(0xFFD4AF37).withValues(alpha: 0.65),
                        fontSize: 11,
                        letterSpacing: 5,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(width: 12),
                  _goldLine(),
                ],
              ).animate().fadeIn(duration: 1100.ms, delay: 560.ms),
            ],
          ),
        ],
      ),
    );
  }

  Widget _goldLine() => Container(
      width: 26, height: 1,
      color: const Color(0xFFD4AF37).withValues(alpha: 0.40));
}

// ---------------------------------------------------------------------------
// Pushka CustomPainter — draws the 3-D box + coin entirely in code
// ---------------------------------------------------------------------------

class _PushkaPainter extends CustomPainter {
  final double boxEntrance;   // 0.0 → 1.0 (scale in)
  final double bounceT;       // 0.0 → 1.0 (impact squish)
  final double glow;          // 0.0 → 1.0 (idle pulse)
  final double? coinProgress; // null = no fall; 0→1 = above→slot
  final bool   coinInSlot;    // coin resting in slot
  final double shimmer;       // 0.0→1.0 shimmer sweep

  const _PushkaPainter({
    required this.boxEntrance,
    required this.bounceT,
    required this.glow,
    required this.coinProgress,
    required this.coinInSlot,
    required this.shimmer,
  });

  // ── Box geometry constants ──────────────────────────────────────────────
  static const _fw  = 118.0; // front face width
  static const _fh  = 100.0; // front face height
  static const _ox  = 38.0;  // perspective x-offset
  static const _oy  = 17.0;  // perspective y-offset
  static const _cr  = 10.0;  // corner radius (front face)

  // ── Colours ────────────────────────────────────────────────────────────
  static const _frontTop    = Color(0xFF4A93E8);
  static const _frontBot    = Color(0xFF2860B8);
  static const _sideTop     = Color(0xFF2060C0);
  static const _sideBot     = Color(0xFF0E3880);
  static const _topLight    = Color(0xFF72BBFF);
  static const _topDark     = Color(0xFF3A85E0);
  static const _rimColor    = Color(0xFF143268);
  static const _slotColor   = Color(0xFF0A1E48);
  static const _goldBright  = Color(0xFFFFF5A0);
  static const _goldMid     = Color(0xFFFFD700);
  static const _goldDeep    = Color(0xFFD4AF37);
  static const _goldDark    = Color(0xFF9A7020);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2 + 8;

    // Bounce / entrance transform applied to the whole box
    final scale = boxEntrance * _bounceScale();
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(scale);
    canvas.translate(-cx, -cy);

    // Box center shifted slightly up so coin has room above
    final boxCy = cy + 10;

    // ── Vertices ──────────────────────────────────────────────────────────
    final fTL = Offset(cx - _fw / 2, boxCy - _fh / 2);
    final fTR = Offset(cx + _fw / 2, boxCy - _fh / 2);
    final fBR = Offset(cx + _fw / 2, boxCy + _fh / 2);
    const d = Offset(_ox, -_oy);

    // ── Ambient glow behind box ───────────────────────────────────────────
    final glowR = 100.0 + glow * 28;
    canvas.drawCircle(
      Offset(cx, boxCy),
      glowR,
      Paint()
        ..shader = RadialGradient(colors: [
          const Color(0xFF5BA4EE).withValues(alpha: 0.22 + glow * 0.14),
          Colors.transparent,
        ]).createShader(Rect.fromCircle(
            center: Offset(cx, boxCy), radius: glowR)),
    );

    // ── Right side face ───────────────────────────────────────────────────
    _drawFace(canvas, [fTR, fTR + d, fBR + d, fBR],
        _sideTop, _sideBot, Alignment.topLeft, Alignment.bottomRight);

    // ── Front face (with rounded corners) ────────────────────────────────
    _drawFrontFace(canvas, fTL, fBR, cx, boxCy);

    // ── Top face ──────────────────────────────────────────────────────────
    _drawFace(canvas, [fTL, fTR, fTR + d, fTL + d],
        _topLight, _topDark, Alignment.topLeft, Alignment.bottomRight);

    // ── Coin slot ─────────────────────────────────────────────────────────
    _drawCoinSlot(canvas, cx, boxCy, fTR + d, fTL + d);

    canvas.restore();

    // ── Coin (outside box transform so it animates independently) ─────────
    // Slot world Y after scale transform
    final slotWorldY = cy + (boxCy - _fh / 2 - cy - _oy) * scale;
    final coinRadius = 18.0;

    if (coinProgress != null) {
      // Coin falls from 170 px above slot to slot
      final startY = slotWorldY - 170;
      final endY   = slotWorldY + coinRadius * 0.3; // just entering slot
      final coinCY = startY + (endY - startY) * coinProgress!;
      _drawCoin(canvas, Offset(cx, coinCY), coinRadius,
          rotation: (coinProgress! * 0.4) - 0.2);
    } else if (coinInSlot) {
      // Coin resting in slot with shimmer
      _drawCoin(canvas, Offset(cx, slotWorldY), coinRadius,
          shimmer: shimmer);
    }
  }

  // ── Front face with rounded corners and gradient + Star of David ────────
  void _drawFrontFace(Canvas canvas, Offset tl, Offset br, double cx, double cy) {
    final rect = RRect.fromLTRBR(
      tl.dx, tl.dy, br.dx, br.dy,
      const Radius.circular(_cr),
    );

    // Gradient fill
    canvas.drawRRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [_frontTop, _frontBot],
        ).createShader(Rect.fromLTRB(tl.dx, tl.dy, br.dx, br.dy)),
    );

    // Inner highlight (glass gloss on top-left)
    canvas.drawRRect(
      RRect.fromLTRBR(
        tl.dx + 4, tl.dy + 4,
        br.dx - 4, tl.dy + _fh * 0.38,
        const Radius.circular(_cr - 2),
      ),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.18),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTRB(
            tl.dx + 4, tl.dy + 4, br.dx - 4, tl.dy + _fh * 0.38)),
    );

    // Rim / border
    canvas.drawRRect(
      rect,
      Paint()
        ..color = _rimColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Star of David
    final starC = Offset(cx, (tl.dy + br.dy) / 2 + 4);
    _drawStarOfDavid(canvas, starC, 28);
  }

  // ── Generic parallelogram face ───────────────────────────────────────────
  void _drawFace(Canvas canvas, List<Offset> pts,
      Color c1, Color c2, Alignment a1, Alignment a2) {
    final path = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();

    final bounds = path.getBounds();
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: a1, end: a2, colors: [c1, c2],
        ).createShader(bounds),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = _rimColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  // ── Coin slot on top face ────────────────────────────────────────────────
  void _drawCoinSlot(Canvas canvas, double cx, double boxCy,
      Offset topRight, Offset topLeft) {
    // Slot is a dark rounded rectangle near the front edge of the top face
    final slotMidX = cx;
    final slotMidY = boxCy - _fh / 2 - _oy / 2;
    final slotW = 28.0;
    final slotH = 8.0;

    final slotRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset(slotMidX, slotMidY),
          width: slotW,
          height: slotH),
      const Radius.circular(4),
    );

    // Shadow inside slot (depth)
    canvas.drawRRect(
      slotRect,
      Paint()
        ..color = _slotColor
        ..style = PaintingStyle.fill,
    );

    // Inner glow (light reflecting off slot edge)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(slotMidX, slotMidY - 1),
            width: slotW - 4,
            height: 2),
        const Radius.circular(1),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.15),
    );
  }

  // ── Star of David ────────────────────────────────────────────────────────
  void _drawStarOfDavid(Canvas canvas, Offset c, double size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final r = size / 2;
    // Triangle pointing up
    _drawTriangle(canvas, c, r, 0, paint);
    // Triangle pointing down
    _drawTriangle(canvas, c, r, pi, paint);
  }

  void _drawTriangle(
      Canvas canvas, Offset c, double r, double rot, Paint paint) {
    final path = Path();
    for (int i = 0; i < 3; i++) {
      final angle = rot + (i * 2 * pi / 3) - pi / 2;
      final pt = Offset(c.dx + r * cos(angle), c.dy + r * sin(angle));
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  // ── Coin ─────────────────────────────────────────────────────────────────
  void _drawCoin(Canvas canvas, Offset c, double r,
      {double rotation = 0, double shimmer = 0}) {
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(rotation);
    canvas.translate(-c.dx, -c.dy);

    // Outer glow
    final glowR = r + 10 + glow * 4;
    canvas.drawCircle(
      c, glowR,
      Paint()
        ..shader = RadialGradient(colors: [
          _goldMid.withValues(alpha: 0.55 + glow * 0.15),
          _goldMid.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: c, radius: glowR)),
    );

    // Main gold gradient
    canvas.drawCircle(
      c, r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.30, -0.40),
          radius: 0.90,
          colors: const [_goldBright, _goldMid, _goldDeep, _goldDark],
          stops: const [0.0, 0.28, 0.65, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // Rim
    canvas.drawCircle(c, r - 1.5,
        Paint()
          ..color = _goldDark
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0);

    // Specular highlight
    final hiC = Offset(c.dx - r * 0.22, c.dy - r * 0.24);
    canvas.drawCircle(
      hiC, r * 0.36,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.60),
          Colors.white.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: hiC, radius: r * 0.36)),
    );

    // Shimmer sweep when at rest
    if (shimmer > 0) {
      final sweepX = c.dx - r + shimmer * r * 2.4;
      canvas.drawCircle(
        Offset(sweepX, c.dy - r * 0.1),
        r * 0.28,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: 0.45 * sin(shimmer * pi)),
            Colors.white.withValues(alpha: 0.0),
          ]).createShader(Rect.fromCircle(
              center: Offset(sweepX, c.dy - r * 0.1), radius: r * 0.28)),
      );
    }

    canvas.restore();
  }

  // ── Bounce scale ─────────────────────────────────────────────────────────
  double _bounceScale() {
    if (bounceT == 0) return 1.0;
    final t = bounceT;
    if (t < 0.22) return 1.0 + t / 0.22 * 0.06;
    if (t < 0.52) return 1.06 - (t - 0.22) / 0.30 * 0.10;
    if (t < 0.78) return 0.96 + (t - 0.52) / 0.26 * 0.05;
    return 1.01 - (t - 0.78) / 0.22 * 0.01;
  }

  @override
  bool shouldRepaint(_PushkaPainter o) =>
      o.boxEntrance != boxEntrance ||
      o.bounceT     != bounceT     ||
      o.glow        != glow        ||
      o.coinProgress != coinProgress ||
      o.coinInSlot  != coinInSlot  ||
      o.shimmer     != shimmer;
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
  final _particles = <_Particle>[];

  @override
  void initState() {
    super.initState();
    final rng = Random(17);
    for (int i = 0; i < 30; i++) {
      _particles.add(_Particle(
        x:       rng.nextDouble(),
        phase:   rng.nextDouble(),
        speed:   0.09 + rng.nextDouble() * 0.11,
        radius:  1.6  + rng.nextDouble() * 2.8,
        opacity: 0.28 + rng.nextDouble() * 0.46,
        drift:   (rng.nextDouble() - 0.5) * 0.06,
      ));
    }
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 8))
      ..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) => CustomPaint(
          painter: _ParticlePainter(_particles, _ctrl.value),
          size: Size.infinite,
        ),
      );
}

class _Particle {
  final double x, phase, speed, radius, opacity, drift;
  const _Particle({
    required this.x, required this.phase, required this.speed,
    required this.radius, required this.opacity, required this.drift,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double progress;
  const _ParticlePainter(this.particles, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final t = (p.phase + progress * p.speed * 8) % 1.0;
      final alpha =
          t < 0.10 ? t / 0.10 : t > 0.75 ? (1 - t) / 0.25 : 1.0;
      canvas.drawCircle(
        Offset(
          (p.x + sin(t * pi * 2) * p.drift) * size.width,
          size.height * (1.0 - t),
        ),
        p.radius,
        Paint()
          ..color = const Color(0xFFD4AF37).withValues(
              alpha: p.opacity * alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter o) => o.progress != progress;
}
