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
//  0.5 s  Dollar bill starts slow fall from very top + bill sound
//  5.5 s  Bill fully faded out
//  6.3 s  Shooting star crosses right → left (~0.8 s)
//  7.3 s  Warm-gold radial flood fills screen (1.8 s)
//  9.1 s  Navigate to main app
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
  late final AnimationController _billCtrl;     // 5000 ms  bill slow fall
  late final AnimationController _shootCtrl;    //  800 ms  shooting star
  late final AnimationController _floodCtrl;    // 1800 ms  warm-gold flood

  // ── state ────────────────────────────────────────────────────────────────
  bool _showBill    = false;
  bool _showShooter = false;

  // ── audio ────────────────────────────────────────────────────────────────
  final AudioPlayer _billAudio = AudioPlayer();

  // ── star field — fixed seed so layout is deterministic ──────────────────
  static final _stars = _buildStars();

  static List<_Star> _buildStars() {
    final rng = math.Random(42);
    final list = <_Star>[];
    // 50 small background stars
    for (int i = 0; i < 50; i++) {
      list.add(_Star(
        x:     rng.nextDouble(),
        y:     rng.nextDouble() * 0.88,
        r:     0.8 + rng.nextDouble() * 1.8,
        phase: rng.nextDouble() * math.pi * 2,
        speed: 0.4 + rng.nextDouble() * 0.9,
        base:  0.25 + rng.nextDouble() * 0.45,
        big:   false,
      ));
    }
    // 7 larger bright stars
    for (int i = 0; i < 7; i++) {
      list.add(_Star(
        x:     rng.nextDouble(),
        y:     rng.nextDouble() * 0.75,
        r:     3.2 + rng.nextDouble() * 2.4,
        phase: rng.nextDouble() * math.pi * 2,
        speed: 0.18 + rng.nextDouble() * 0.45,
        base:  0.55 + rng.nextDouble() * 0.35,
        big:   true,
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
    _billCtrl     = AnimationController(vsync: this, duration: 5000.ms);
    _shootCtrl    = AnimationController(vsync: this, duration: 800.ms);
    _floodCtrl    = AnimationController(vsync: this, duration: 1800.ms);

    _buildingCtrl.forward();
    _runSequence();
  }

  @override
  void dispose() {
    _buildingCtrl.dispose();
    _starCtrl.dispose();
    _billCtrl.dispose();
    _shootCtrl.dispose();
    _floodCtrl.dispose();
    _billAudio.dispose();
    super.dispose();
  }

  // ── main sequence ────────────────────────────────────────────────────────
  Future<void> _runSequence() async {
    // 0.5 s — bill starts
    await Future.delayed(500.ms);
    if (!mounted) return;
    setState(() => _showBill = true);
    _billCtrl.forward();
    unawaited(
      _billAudio.play(AssetSource('sounds/bill_flutter.wav')).catchError((_) {}),
    );

    // 6.3 s — shooting star  (500 + 5000 + 800 = 6300 ms from start)
    await Future.delayed(5800.ms);
    if (!mounted) return;
    setState(() => _showShooter = true);
    _shootCtrl.forward();

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
        _buildingCtrl, _starCtrl, _billCtrl, _shootCtrl, _floodCtrl,
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

            // 3. Building 770 — perfectly centered
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

    // Opacity: visible until 62%, then fades to nothing by 85%
    final opacity = t > 0.62
        ? (1.0 - (t - 0.62) / 0.26).clamp(0.0, 1.0)
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

  // ── warm-gold screen flood ───────────────────────────────────────────────
  Widget _buildFlood() {
    final a = Curves.easeInOut.transform(_floodCtrl.value);
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
  const _Star({
    required this.x,     required this.y,     required this.r,
    required this.phase, required this.speed, required this.base,
    required this.big,
  });
}

class _StarFieldPainter extends CustomPainter {
  final List<_Star> stars;
  final double t; // 0→1 repeating

  const _StarFieldPainter(this.stars, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in stars) {
      // Smooth sinusoidal twinkle: squared so dips to near-zero between pulses
      final sine    = math.sin(t * math.pi * 2 * s.speed + s.phase);
      final opacity = s.base * (0.30 + 0.70 * (sine * sine));

      final cx = s.x * size.width;
      final cy = s.y * size.height;

      if (s.big) {
        // Soft outer glow
        canvas.drawCircle(
          Offset(cx, cy),
          s.r * 3.0,
          Paint()
            ..color = const Color(0xFFD8EEFF).withValues(alpha: opacity * 0.16)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
        // Bright core
        canvas.drawCircle(
          Offset(cx, cy),
          s.r,
          Paint()..color = Colors.white.withValues(alpha: opacity),
        );
      } else {
        canvas.drawCircle(
          Offset(cx, cy),
          s.r,
          Paint()..color = const Color(0xFFEAF4FF).withValues(alpha: opacity),
        );
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
