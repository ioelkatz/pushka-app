import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_initializer.dart';
import '../../pushka/presentation/building_770_widget.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  CINEMATIC SPLASH  — ~9 s timeline
//
//  0.0 s  Dark sky + stars appear; Building 770 fades in (0.8 s)
//  0.2 s  Dollar bill starts slow fall from very top + bill sound
//  5.5 s  Bill fully faded out
//  5.8 s  Shooting star crosses right → left (~0.8 s)
//  6.8 s  Warm-gold radial flood fills screen (1.8 s)
//  8.6 s  Navigate to main app
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {

  // ── animation controllers ────────────────────────────────────────────────
  late final AnimationController _buildingCtrl; //  800 ms  building fade-in
  late final AnimationController _starCtrl;     // 5000 ms  star twinkle (repeat)
  late final AnimationController _billCtrl;     // 7000 ms  bill slow fall
  late final AnimationController _shootCtrl;    //  800 ms  shooting star
  late final AnimationController _floodCtrl;    // 1800 ms  warm-gold flood
  late final AnimationController _moonGlowCtrl; // 2500 ms  moon single pulse

  // ── state ────────────────────────────────────────────────────────────────
  bool _showBill    = false;
  bool _showShooter = false;

  // ── audio ────────────────────────────────────────────────────────────────
  final AudioPlayer _billAudio  = AudioPlayer();
  final AudioPlayer _shootAudio = AudioPlayer();

  // ── star field — fixed seed so layout is deterministic ──────────────────
  static final _stars = _buildStars();

  // Warm gold palette for stars
  static const _starColors = [
    Color(0xFFFFD54F), // bright gold
    Color(0xFFFFE082), // pale gold
    Color(0xFFFFF8DC), // cream white
    Color(0xFFFFCC02), // vivid yellow
    Color(0xFFFFF0A0), // warm ivory
  ];

  static List<_Star> _buildStars() {
    final rng = math.Random(42);
    final list = <_Star>[];
    // 50 small pointed stars
    for (int i = 0; i < 50; i++) {
      list.add(_Star(
        x:     rng.nextDouble(),
        y:     rng.nextDouble() * 0.88,
        r:     2.2 + rng.nextDouble() * 3.0,
        phase: rng.nextDouble() * math.pi * 2,
        speed: 0.4 + rng.nextDouble() * 0.9,
        base:  0.22 + rng.nextDouble() * 0.40,
        big:   false,
        shape: rng.nextInt(2), // 0 = 4-pt, 1 = 8-pt
        color: _starColors[rng.nextInt(_starColors.length)],
      ));
    }
    // 7 larger bright stars
    for (int i = 0; i < 7; i++) {
      list.add(_Star(
        x:     rng.nextDouble(),
        y:     rng.nextDouble() * 0.75,
        r:     5.0 + rng.nextDouble() * 4.0,
        phase: rng.nextDouble() * math.pi * 2,
        speed: 0.18 + rng.nextDouble() * 0.45,
        base:  0.55 + rng.nextDouble() * 0.35,
        big:   true,
        shape: rng.nextInt(2),
        color: _starColors[rng.nextInt(_starColors.length)],
      ));
    }
    return list;
  }

  // ── init / dispose ───────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    _buildingCtrl = AnimationController(vsync: this, duration: 800.ms);
    _starCtrl     = AnimationController(vsync: this, duration: 5000.ms)
      ..repeat();
    _billCtrl     = AnimationController(vsync: this, duration: 7000.ms);
    _shootCtrl    = AnimationController(vsync: this, duration: 800.ms);
    _floodCtrl    = AnimationController(vsync: this, duration: 1300.ms);
    _moonGlowCtrl = AnimationController(vsync: this, duration: 2500.ms);

    _buildingCtrl.forward();
    // Moon pulses once at 3.5 s — middle of the presentation
    Future.delayed(3500.ms, () { if (mounted) _moonGlowCtrl.forward(); });
    _runSequence();
  }

  @override
  void dispose() {
    _buildingCtrl.dispose();
    _starCtrl.dispose();
    _billCtrl.dispose();
    _shootCtrl.dispose();
    _floodCtrl.dispose();
    _moonGlowCtrl.dispose();
    _billAudio.dispose();
    _shootAudio.dispose();
    super.dispose();
  }

  // ── main sequence ────────────────────────────────────────────────────────
  Future<void> _runSequence() async {
    // 0.2 s — bill starts
    await Future.delayed(200.ms);
    if (!mounted) return;
    setState(() => _showBill = true);
    _billCtrl.forward();
    Future.delayed(700.ms, () {
      if (mounted) {
        unawaited(
          _billAudio.play(AssetSource('sounds/bill_flutter.wav')).catchError((_) {}),
        );
      }
    });

    // 5.3 s — shooting star  (500 + 4800 = 5300 ms from start)
    await Future.delayed(4800.ms);
    if (!mounted) return;
    setState(() => _showShooter = true);
    _shootCtrl.forward();
    unawaited(
      _shootAudio.play(AssetSource('sounds/shooting_star.mp3')).catchError((_) {}),
    );

    // 7.3 s — golden flood
    await Future.delayed(1000.ms);
    if (!mounted) return;
    _floodCtrl.forward();

    // 9.1 s — wait for flood + app init, then navigate
    await Future.delayed(1600.ms);
    await appDeferredInit.timeout(
      const Duration(seconds: 8),
      onTimeout: () {},
    );
    if (!mounted) return;
    context.go('/');
  }

  // ── build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sz      = MediaQuery.of(context).size;
    final screenW = sz.width;
    final screenH = sz.height;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _buildingCtrl, _starCtrl, _billCtrl, _shootCtrl, _floodCtrl, _moonGlowCtrl,
      ]),
      builder: (_, _) => Scaffold(
        backgroundColor: const Color(0xFF040A14),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Night sky gradient
            _buildBackground(),

            // 2. Twinkling star field
            CustomPaint(
              painter: _StarFieldPainter(_stars, _starCtrl.value),
              size: Size.infinite,
            ),

            // 3. Moon — top-right corner
            _buildMoon(),

            // 4. Building 770 — perfectly centered
            Center(
              child: Opacity(
                opacity: Curves.easeOut.transform(_buildingCtrl.value),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: (screenH * 0.42).clamp(240.0, 380.0),
                  ),
                  child: const Building770Widget(fillFraction: 0),
                ),
              ),
            ),

            // 4. Falling dollar bill
            if (_showBill) _buildBill(screenW, screenH),

            // 5. Shooting star
            if (_showShooter)
              IgnorePointer(
                child: CustomPaint(
                  painter: _ShootingStarPainter(
                    t: _shootCtrl.value,
                    screenW: screenW,
                    screenH: screenH,
                  ),
                  size: Size.infinite,
                ),
              ),

            // 6. Warm-gold flood — final transition
            if (_floodCtrl.value > 0) _buildFlood(),
          ],
        ),
      ),
    );
  }

  // ── night sky background ─────────────────────────────────────────────────
  Widget _buildBackground() => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(0.0, -0.12),
        radius: 1.35,
        colors: [
          Color(0xFF1C3E72), // warm blue center glow (behind house)
          Color(0xFF0E2448), // deep midnight blue
          Color(0xFF07102C), // near-black blue
          Color(0xFF040A14), // black edges
        ],
        stops: [0.0, 0.32, 0.65, 1.0],
      ),
    ),
  );

  // ── falling dollar bill ──────────────────────────────────────────────────
  Widget _buildBill(double screenW, double screenH) {
    final t = _billCtrl.value; // 0→1 linear

    // Smoothstep: slow start, gentle acceleration
    final eased = t * t * (3.0 - 2.0 * t);

    // Vertical: starts above screen, travels to ~48% screen height
    const startY = -100.0;
    final endY = screenH * 0.48;
    final billY = startY + (endY - startY) * eased;

    // Horizontal flutter
    final flutter = math.sin(t * math.pi * 2.5) * 22.0;

    // Rotation — phase-shifted from flutter
    final rotation = math.sin(t * math.pi * 2.5 + 0.6) * 0.12;

    // Opacity: visible until 70%, then fades to nothing by 92%
    final opacity = t > 0.70
        ? (1.0 - (t - 0.70) / 0.22).clamp(0.0, 1.0)
        : 1.0;

    if (opacity < 0.01) return const SizedBox.shrink();

    const billW = 140.0;
    const billH = 70.0;

    return Positioned(
      left: screenW / 2 + flutter - billW / 2,
      top:  billY - billH / 2,
      child: Opacity(
        opacity: opacity,
        child: Transform.rotate(
          angle: rotation,
          child: Image.asset(
            'assets/images/rebbe_dollar.png',
            width:  billW,
            height: billH,
            fit:    BoxFit.contain,
          ),
        ),
      ),
    );
  }

  // ── moon — top-right corner ──────────────────────────────────────────────
  Widget _buildMoon() {
    // Pulse: triangle wave 0→1→0 — adds a subtle brightness flare
    final v     = _moonGlowCtrl.value;
    final pulse = v < 0.5 ? v * 2.0 : (1.0 - v) * 2.0;
    // Map pulse to a brightness boost: 1.0 (base) → 1.35 (peak) → 1.0
    final boost = 1.0 + pulse * 0.35;
    return Positioned(
      top:   15.0,
      right: 15.0,
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix(<double>[
          boost, 0, 0, 0, 0,
          0, boost, 0, 0, 0,
          0, 0, boost, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: Image.asset(
          'assets/images/moon.png',
          width:  100,
          height: 100,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  // ── warm-gold screen flood ───────────────────────────────────────────────
  Widget _buildFlood() {
    final a = const Cubic(0.42, 0, 0.95, 1).transform(_floodCtrl.value);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.55,
            colors: [
              Color(0xFFFFFCF0).withValues(alpha: 0.98 * a), // near-white warm core
              Color(0xFFFFE566).withValues(alpha: 0.96 * a), // bright gold
              Color(0xFFFFAD00).withValues(alpha: 0.97 * a), // deep amber edges
            ],
            stops: const [0.0, 0.38, 1.0],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  STAR FIELD
// ─────────────────────────────────────────────────────────────────────────────

class _Star {
  final double x, y, r, phase, speed, base;
  final bool big;
  final int shape;   // 0 = 4-pointed, 1 = 8-pointed
  final Color color;
  const _Star({
    required this.x,     required this.y,     required this.r,
    required this.phase, required this.speed, required this.base,
    required this.big,   required this.shape, required this.color,
  });
}

class _StarFieldPainter extends CustomPainter {
  final List<_Star> stars;
  final double t; // 0→1 repeating

  const _StarFieldPainter(this.stars, this.t);

  // Draw a 4-pointed star (elongated diamond cross)
  static void _draw4pt(Canvas canvas, double cx, double cy, double r, Paint p) {
    const inner = 0.10; // very narrow waist → sharp spikes
    final path = Path();
    for (int i = 0; i < 4; i++) {
      final out  = i * math.pi / 2 - math.pi / 2;
      final in1  = out + math.pi / 4;
      final in2  = out - math.pi / 4;
      if (i == 0) {
        path.moveTo(cx + math.cos(in2) * r * inner,
                    cy + math.sin(in2) * r * inner);
      }
      path.lineTo(cx + math.cos(out) * r, cy + math.sin(out) * r);
      path.lineTo(cx + math.cos(in1) * r * inner,
                  cy + math.sin(in1) * r * inner);
    }
    path.close();
    canvas.drawPath(path, p);
  }

  // Draw an 8-pointed star (compass rose)
  static void _draw8pt(Canvas canvas, double cx, double cy, double r, Paint p) {
    const inner = 0.38; // inner radius ratio
    final path = Path();
    for (int i = 0; i < 8; i++) {
      final out  = i * math.pi / 4 - math.pi / 2;
      final mid  = out + math.pi / 8;
      final ox = cx + math.cos(out) * r;
      final oy = cy + math.sin(out) * r;
      final mx = cx + math.cos(mid) * r * inner;
      final my = cy + math.sin(mid) * r * inner;
      if (i == 0) { path.moveTo(ox, oy); } else { path.lineTo(ox, oy); }
      path.lineTo(mx, my);
    }
    path.close();
    canvas.drawPath(path, p);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in stars) {
      final sine    = math.sin(t * math.pi * 2 * s.speed + s.phase);
      final opacity = s.base * (0.28 + 0.72 * (sine * sine));

      final cx = s.x * size.width;
      final cy = s.y * size.height;
      final paint = Paint()..color = s.color.withValues(alpha: opacity);

      if (s.big) {
        // Soft glow halo
        canvas.drawCircle(
          Offset(cx, cy), s.r * 2.8,
          Paint()
            ..color = s.color.withValues(alpha: opacity * 0.14)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
        );
      }

      if (s.shape == 0) {
        _draw4pt(canvas, cx, cy, s.r, paint);
      } else {
        _draw8pt(canvas, cx, cy, s.r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_StarFieldPainter old) => old.t != t;
}

// ─────────────────────────────────────────────────────────────────────────────
//  SHOOTING STAR
// ─────────────────────────────────────────────────────────────────────────────

class _ShootingStarPainter extends CustomPainter {
  final double t; // 0→1
  final double screenW;
  final double screenH;

  const _ShootingStarPainter({
    required this.t,
    required this.screenW,
    required this.screenH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1.0) return;

    // Start: upper-right → End: center-left, slight diagonal
    final startX = screenW * 0.92;
    final startY = screenH * 0.10;
    final endX   = screenW * 0.08;
    final endY   = screenH * 0.36;

    // Head position
    final headX = startX + (endX - startX) * t;
    final headY = startY + (endY - startY) * t;

    // Direction unit vector
    final dx   = endX - startX;
    final dy   = endY - startY;
    final dist = math.sqrt(dx * dx + dy * dy);
    final ux   = dx / dist;
    final uy   = dy / dist;

    // Tail length grows slightly as star accelerates
    final tailLen = 70.0 + 50.0 * math.min(t, 0.55);

    final tailX = headX - ux * tailLen;
    final tailY = headY - uy * tailLen;

    // Fade out in last 20%
    final opacity = t > 0.80
        ? (1.0 - (t - 0.80) / 0.20).clamp(0.0, 1.0)
        : 1.0;

    // Gradient tail: transparent → pale blue-white → white at head
    canvas.drawLine(
      Offset(tailX, tailY),
      Offset(headX, headY),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(tailX, tailY),
          Offset(headX, headY),
          [
            Colors.transparent,
            const Color(0xFFBFDFFF).withValues(alpha: 0.55 * opacity),
            Colors.white.withValues(alpha: opacity),
          ],
          const [0.0, 0.55, 1.0],
        )
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke,
    );

    // Head: soft glow halo
    canvas.drawCircle(
      Offset(headX, headY),
      5.0,
      Paint()
        ..color = const Color(0xFFE8F4FF).withValues(alpha: opacity * 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // Head: bright core dot
    canvas.drawCircle(
      Offset(headX, headY),
      1.6,
      Paint()..color = Colors.white.withValues(alpha: opacity),
    );
  }

  @override
  bool shouldRepaint(_ShootingStarPainter old) => old.t != t;
}
