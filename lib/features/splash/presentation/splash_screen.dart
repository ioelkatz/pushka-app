import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_initializer.dart';
import '../../pushka/presentation/pushka_3d_painter.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  CINEMATIC SPLASH  — 6.5 second timeline
//
//  0.0 – 1.0 s   Pushka visible; subtle entrance zoom 0.96 → 1.0
//  1.0 – 3.6 s   Coin falls from screen top (2600 ms) — grows, wobbles
//  3.6 s         IMPACT — sound, shake, flash, sparkles
//  3.6 – 4.4 s   Pause (800 ms)
//  4.4 – 5.9 s   Golden glow expands inside pushka (1500 ms)
//  5.9 – 6.4 s   Warm-gold screen flood (500 ms)
//  6.4 s         Navigate to app
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {

  // ── animation controllers ────────────────────────────────────────────────
  late final AnimationController _zoomCtrl;    // 1000 ms  pushka entrance
  late final AnimationController _coinCtrl;    // 2600 ms  coin fall
  late final AnimationController _shakeCtrl;   //  400 ms  impact shake
  late final AnimationController _flashCtrl;   //  600 ms  impact screen flash
  late final AnimationController _glowCtrl;    // 1500 ms  golden interior glow
  late final AnimationController _floodCtrl;   //  500 ms  warm-gold screen flood
  late final AnimationController _ambientCtrl; // 3000 ms  ambient halo (repeat)
  late final AnimationController _shimCtrl;    // 2500 ms  coin shimmer (repeat)

  // ── state flags ──────────────────────────────────────────────────────────
  bool _showCoin  = false;
  bool _impacted  = false;

  // ── audio players (owned here so they can be disposed) ───────────────────
  final AudioPlayer _coinAudio    = AudioPlayer();
  final AudioPlayer _successAudio = AudioPlayer();

  // ── gravity drop curve helper ────────────────────────────────────────────
  static double _dropCurve(double t) {
    // Accelerates under gravity for 72% of fall, then gently decelerates
    // as the coin aligns with the slot
    if (t <= 0.72) {
      final p = t / 0.72;
      return p * p * 0.82;
    } else {
      final p = (t - 0.72) / 0.28;
      return 0.82 + (1.0 - math.pow(1.0 - p, 2.0)) * 0.18;
    }
  }

  @override
  void initState() {
    super.initState();

    _zoomCtrl    = AnimationController(vsync: this, duration: 1000.ms);
    _coinCtrl    = AnimationController(vsync: this, duration: 2600.ms);
    _shakeCtrl   = AnimationController(vsync: this, duration:  400.ms);
    _flashCtrl   = AnimationController(vsync: this, duration:  600.ms);
    _glowCtrl    = AnimationController(vsync: this, duration: 1500.ms);
    _floodCtrl   = AnimationController(vsync: this, duration:  500.ms);
    _ambientCtrl = AnimationController(vsync: this, duration: 3000.ms)
      ..repeat(reverse: true);
    _shimCtrl    = AnimationController(vsync: this, duration: 2500.ms)
      ..repeat();

    _zoomCtrl.forward(); // pushka zooms in immediately
    _runSequence();
  }

  @override
  void dispose() {
    _zoomCtrl.dispose();
    _coinCtrl.dispose();
    _shakeCtrl.dispose();
    _flashCtrl.dispose();
    _glowCtrl.dispose();
    _floodCtrl.dispose();
    _ambientCtrl.dispose();
    _shimCtrl.dispose();
    _coinAudio.dispose();
    _successAudio.dispose();
    super.dispose();
  }

  Future<void> _runSequence() async {
    // 1.0 s — coin appears and starts falling
    await Future.delayed(1000.ms);
    if (!mounted) return;
    setState(() => _showCoin = true);
    _coinCtrl.forward();

    // 3.6 s — IMPACT
    await Future.delayed(2600.ms);
    if (!mounted) return;
    setState(() { _showCoin = false; _impacted = true; });
    _shakeCtrl.forward();
    _flashCtrl.forward();
    unawaited(_coinAudio.play(AssetSource('sounds/coin.wav')).catchError((_) {}));

    // 4.4 s — glow starts
    await Future.delayed(800.ms);
    if (!mounted) return;
    _glowCtrl.forward();
    unawaited(_successAudio.play(AssetSource('sounds/success.wav')).catchError((_) {}));

    // 5.9 s — screen flood
    await Future.delayed(1500.ms);
    if (!mounted) return;
    _floodCtrl.forward();

    // 6.4 s — navigate (timeout after 8 s so a hung init never traps the user)
    await Future.delayed(400.ms);
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
    final screenH = MediaQuery.of(context).size.height;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _zoomCtrl, _coinCtrl, _shakeCtrl, _flashCtrl,
        _glowCtrl, _floodCtrl, _ambientCtrl, _shimCtrl,
      ]),
      builder: (_, _) => Scaffold(
        backgroundColor: const Color(0xFF040A14),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Dark premium radial background
            _buildBackground(),

            // Floating gold dust particles
            const _GoldParticles(),

            // Pushka + coin + effects — centered
            Center(child: _buildPushkaScene(screenH)),

            // Impact screen flash (radial warm burst)
            if (_impacted) _buildImpactFlash(),

            // Final warm-gold screen flood before navigation
            if (_floodCtrl.value > 0) _buildScreenFlood(),
          ],
        ),
      ),
    );
  }

  // ── background gradient ──────────────────────────────────────────────────
  Widget _buildBackground() => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(0.0, -0.08),
        radius: 1.25,
        colors: [
          Color(0xFF183568), // warm blue center
          Color(0xFF0F2347), // mid blue
          Color(0xFF070F24), // near-black
          Color(0xFF040A14), // black edges
        ],
        stops: [0.0, 0.35, 0.65, 1.0],
      ),
    ),
  );

  // ── pushka scene (with shake + zoom) ────────────────────────────────────
  Widget _buildPushkaScene(double screenH) {
    const sceneW = 320.0;
    const sceneH = 420.0;

    // Entrance zoom: 0.96 → 1.0
    final zoom = 0.96 + Curves.easeOut.transform(_zoomCtrl.value) * 0.04;

    // Impact shake: exponentially decaying sine wave
    double sx = 0, sy = 0;
    final st = _shakeCtrl.value;
    if (st > 0 && st < 1.0) {
      final decay = math.pow(1.0 - st, 1.6).toDouble();
      sx = math.sin(st * math.pi * 11) * 4.5 * decay;
      sy = math.cos(st * math.pi *  8) * 2.2 * decay;
    }

    return Transform.scale(
      scale: zoom,
      child: Transform.translate(
        offset: Offset(sx, sy),
        child: SizedBox(
          width: sceneW,
          height: sceneH,
          child: Stack(
            clipBehavior: Clip.none,
            children: [

              // Soft ambient halo behind pushka
              Positioned.fill(
                child: CustomPaint(
                  painter: _AmbientHaloPainter(
                    pulse:  _ambientCtrl.value,
                    glowT: _impacted ? Curves.easeOut.transform(_glowCtrl.value) : 0,
                  ),
                ),
              ),

              // The pushka body
              CustomPaint(
                painter: Pushka3DPainter(fillFraction: 0, wavePhase: 0),
                size: const Size(sceneW, sceneH),
                isComplex: true,
              ),

              // Interior golden glow post-impact
              if (_impacted)
                CustomPaint(
                  painter: _GoldenGlowPainter(
                    glowT:  Curves.easeOut.transform(_glowCtrl.value),
                    sceneW: sceneW,
                    sceneH: sceneH,
                  ),
                  size: const Size(sceneW, sceneH),
                ),

              // Coin falling from above
              if (_showCoin) ..._buildCoin(sceneW, sceneH, screenH),

              // Impact sparkles
              if (_impacted && _flashCtrl.value < 0.90)
                ..._buildSparkles(sceneW, sceneH),
            ],
          ),
        ),
      ),
    );
  }

  // ── impact flash ─────────────────────────────────────────────────────────
  Widget _buildImpactFlash() {
    final v = _flashCtrl.value;
    final a = (v < 0.22 ? v / 0.22 : (1 - v) / 0.78).clamp(0.0, 1.0);
    if (a < 0.01) return const SizedBox.shrink();
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.0, -0.18),
            radius: 0.75,
            colors: [
              Color(0xFFFFE066).withValues(alpha: 0.55 * a),
              Color(0xFFFFD700).withValues(alpha: 0.20 * a),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }

  // ── screen flood — warm gold fills viewport before navigation ─────────────
  Widget _buildScreenFlood() {
    final a = Curves.easeInOut.transform(_floodCtrl.value);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.5,
            colors: [
              Color(0xFFFFF0A0).withValues(alpha: 0.95 * a),
              Color(0xFFFFD700).withValues(alpha: 0.92 * a),
              Color(0xFFE08800).withValues(alpha: 0.97 * a),
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
      ),
    );
  }

  // ── coin — falls from screen top, grows in perspective ───────────────────
  List<Widget> _buildCoin(double cW, double cH, double screenH) {
    final rawT  = _coinCtrl.value;           // 0→1 linear time
    final dropT = _dropCurve(rawT);          // position on 0→1 path

    // Mirror Pushka3DPainter geometry to hit slot exactly
    final pCylW   = cW * 0.42;
    final pEh     = pCylW * 0.22;
    final pCylTop = cH * 0.14;
    final slotCX  = cW / 2;
    final slotCY  = pCylTop - pEh * 0.18; // coin slot center Y

    // Perspective: coin starts 70% of final size, grows to 100% as it nears
    final finalDiam  = pCylW * 0.42;
    final perspScale = 0.70 + dropT * 0.30;
    final coinDiam   = finalDiam * perspScale;

    // Widget canvas size (includes the visible rim below the face)
    final widgetW         = coinDiam;
    final widgetH         = coinDiam * 1.40;
    final faceCXInWidget  = coinDiam * 0.50;
    final faceCYInWidget  = coinDiam * 0.34;

    // Vertical position: starts completely off-screen top, lands at slot
    final sceneTopOnScreen = (screenH - cH) / 2;
    final coinStartY = -(sceneTopOnScreen + coinDiam + 12);
    final coinEndY   = slotCY;
    double coinCenterY = coinStartY + (coinEndY - coinStartY) * dropT;

    // Lateral wobble: damped oscillation (coin rocks as it falls)
    final wobble = math.sin(rawT * math.pi * 3.8) * (1.0 - rawT * 0.9);

    // Entry phase: last 18% — coin sinks into slot and disappears
    double coinScaleY  = 1.0;
    double coinOpacity = 1.0;
    double entryP      = 0.0;

    if (rawT > 0.82) {
      entryP = ((rawT - 0.82) / 0.18).clamp(0.0, 1.0);
      coinCenterY += Curves.easeIn.transform(entryP) * coinDiam * 1.15;
      coinScaleY   = 1.0 - Curves.easeIn.transform(entryP);
      coinOpacity  = 1.0 - entryP * entryP;
    }

    if (coinOpacity < 0.01) return [];

    final wobbleX = wobble * 4.0;
    final widgets = <Widget>[];

    // Soft outer glow around coin
    final glowR = coinDiam * 0.65;
    widgets.add(Positioned(
      left: slotCX + wobbleX - glowR,
      top:  coinCenterY - glowR,
      child: Opacity(
        opacity: (coinOpacity * 0.42 * (1.0 - entryP)).clamp(0.0, 1.0),
        child: Container(
          width:  glowR * 2,
          height: glowR * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [
              const Color(0xFFFFCE45).withValues(alpha: 0.28),
              const Color(0xFFFFD700).withValues(alpha: 0.07),
              Colors.transparent,
            ], stops: const [0.0, 0.50, 1.0]),
          ),
        ),
      ),
    ));

    // Contact shadow on pushka lid (grows as coin approaches)
    if (rawT > 0.52) {
      final sp = ((rawT - 0.52) / 0.48).clamp(0.0, 1.0);
      final sW = finalDiam * 0.78 * sp;
      final sH = pEh * 0.20 * sp;
      widgets.add(Positioned(
        left: slotCX - sW / 2,
        top:  slotCY - sH * 0.5,
        child: Opacity(
          opacity: (sp * 0.32 * coinOpacity).clamp(0.0, 1.0),
          child: Container(
            width: sW, height: sH,
            decoration: BoxDecoration(
              color: const Color(0xFF040A14),
              borderRadius: BorderRadius.circular(sH / 2),
            ),
          ),
        ),
      ));
    }

    // The coin itself
    widgets.add(Positioned(
      left: slotCX + wobbleX - faceCXInWidget,
      top:  coinCenterY - faceCYInWidget,
      child: Opacity(
        opacity: coinOpacity.clamp(0.0, 1.0),
        child: Transform(
          alignment: Alignment.topCenter,
          transform: Matrix4.diagonal3Values(
            1.0, coinScaleY.clamp(0.0, 1.0), 1.0,
          ),
          child: CustomPaint(
            size: Size(widgetW, widgetH),
            painter: _ShekelCoinPainter(
              shimmerPhase: _shimCtrl.value,
              wobble:       wobble,
            ),
          ),
        ),
      ),
    ));

    return widgets;
  }

  // ── impact sparkles ──────────────────────────────────────────────────────
  List<Widget> _buildSparkles(double cW, double cH) {
    final pCylW   = cW * 0.42;
    final pEh     = pCylW * 0.22;
    final pCylTop = cH * 0.14;
    final slotCX  = cW / 2;
    final slotCY  = pCylTop - pEh * 0.18;
    final sp  = _flashCtrl.value;
    final opa = (1.0 - sp * 1.05).clamp(0.0, 1.0);
    final widgets = <Widget>[];

    // Outer gold sparks
    for (int i = 0; i < 11; i++) {
      final angle = (i / 11) * math.pi * 2 + 0.22;
      final dist  = sp * 38;
      final sx = slotCX + math.cos(angle) * dist;
      final sy = slotCY + math.sin(angle) * dist;
      final sz = 5.0 * (1.0 - sp * 0.45);
      widgets.add(Positioned(
        left: sx - sz / 2, top: sy - sz / 2,
        child: Opacity(
          opacity: opa,
          child: Container(
            width: sz, height: sz,
            decoration: BoxDecoration(
              color: const Color(0xFFFFD700),
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(
                color: const Color(0xFFFFD700).withValues(alpha: 0.65),
                blurRadius: 7,
              )],
            ),
          ),
        ),
      ));
    }

    // Inner white-hot sparks
    for (int i = 0; i < 7; i++) {
      final angle = ((i + 0.45) / 7) * math.pi * 2 + 0.55;
      final dist  = sp * 20;
      final sx = slotCX + math.cos(angle) * dist;
      final sy = slotCY + math.sin(angle) * dist;
      final sz = 2.8 * (1.0 - sp);
      widgets.add(Positioned(
        left: sx - sz / 2, top: sy - sz / 2,
        child: Opacity(
          opacity: (opa * 0.85).clamp(0.0, 1.0),
          child: Container(
            width: sz, height: sz,
            decoration: const BoxDecoration(
              color: Colors.white, shape: BoxShape.circle,
            ),
          ),
        ),
      ));
    }

    return widgets;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SHEKEL COIN PAINTER
//
//  Ancient bronze-gold coin viewed at ~50° tilt.
//  Key design principles:
//    - Diagonal metallic gradient (upper-left lit, lower-right shadow)
//    - Thick visible rim showing coin depth
//    - ₪ symbol CARVED in: shadow stack + highlight rim + dark floor
//    - Clip everything to face ellipse (no bleeding)
//    - Subtle wobble varies tilt during fall
// ─────────────────────────────────────────────────────────────────────────────

class _ShekelCoinPainter extends CustomPainter {
  final double shimmerPhase; // 0→1, looping
  final double wobble;       // -1→1, lateral rocking during fall

  const _ShekelCoinPainter({
    required this.shimmerPhase,
    this.wobble = 0.0,
  });

  // Antique bronze-gold palette — warm, earthy, NOT modern shiny
  static const _cBright  = Color(0xFFFAE28C); // brightest catch-light
  static const _cLight   = Color(0xFFD4A830); // lit upper area
  static const _cMid     = Color(0xFFAA8220); // mid-tone metal
  static const _cBase    = Color(0xFF886018); // base bronze
  static const _cShadow  = Color(0xFF583C0A); // shadow metal
  static const _cDark    = Color(0xFF2C1800); // deep shadow / near black-brown

  @override
  void paint(Canvas canvas, Size size) {
    final d = size.width;

    // ── Geometry ───────────────────────────────────────────────────────────
    // faceRy/faceRx ≈ 0.62 → clearly viewing coin at ~52° tilt
    // wobble subtly varies the tilt angle (coin rocks as it falls)
    final faceRx = d * 0.460;
    final tiltRatio = (0.62 + wobble * 0.035).clamp(0.52, 0.74);
    final faceRy = faceRx * tiltRatio;
    final faceCX = d * 0.500 + wobble * d * 0.014;
    final faceCY = d * 0.340;
    final faceRect = Rect.fromCenter(
      center: Offset(faceCX, faceCY),
      width:  faceRx * 2,
      height: faceRy * 2,
    );

    // Rim: the visible cylindrical edge below the face
    final rimH    = d * 0.25;
    final rimTopY = faceCY + faceRy - 1.0;

    // ════════════════════════════════════════════════════════════════════
    //  DRAW ORDER: ground shadow → rim → face → engraving → highlights
    // ════════════════════════════════════════════════════════════════════

    // ── 1. Ground shadow beneath the coin ─────────────────────────────
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(faceCX + 4, rimTopY + rimH + d * 0.09),
        width: faceRx * 3.2, height: faceRy * 0.48,
      ),
      Paint()
        ..color = _cDark.withValues(alpha: 0.36)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // ── 2. Rim — thick cylindrical edge showing coin depth ────────────
    {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(
        faceCX - faceRx - 1, rimTopY - 1,
        faceCX + faceRx + 1, rimTopY + rimH + faceRy * 0.34 + 1,
      ));

      // Rim side — horizontal gradient simulating curved cylindrical surface
      // Lit at center-left (where cylinder curves toward viewer), dark at edges
      canvas.drawRect(
        Rect.fromLTRB(faceCX - faceRx, rimTopY, faceCX + faceRx, rimTopY + rimH),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(faceCX - faceRx, 0), Offset(faceCX + faceRx, 0),
            [_cDark, _cShadow, _cBase, _cLight, _cBright, _cMid, _cShadow, _cDark],
            const [0.0, 0.08, 0.24, 0.44, 0.55, 0.72, 0.90, 1.0],
          ),
      );

      // Bottom arc of rim
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(faceCX, rimTopY + rimH),
          width: faceRx * 2, height: faceRy * 0.46,
        ),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(faceCX - faceRx, 0), Offset(faceCX + faceRx, 0),
            [_cDark, _cShadow, _cBase, _cShadow, _cDark],
            const [0.0, 0.18, 0.50, 0.82, 1.0],
          ),
      );

      canvas.restore();

      // Catch-light at top of rim (narrow bright ellipse at rim-face junction)
      // This single detail makes the rim look 3D immediately
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(faceCX, rimTopY + 0.5),
          width:  faceRx * 1.82,
          height: faceRy * 0.26,
        ),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(faceCX - faceRx, 0), Offset(faceCX + faceRx, 0),
            [
              Colors.transparent,
              _cLight.withValues(alpha: 0.55),
              _cBright.withValues(alpha: 0.92),
              _cLight.withValues(alpha: 0.55),
              Colors.transparent,
            ],
            const [0.0, 0.18, 0.50, 0.82, 1.0],
          ),
      );
    }

    // ── 3. Coin face ───────────────────────────────────────────────────
    // Clip all face layers to the face ellipse
    final facePath = Path()..addOval(faceRect);
    canvas.save();
    canvas.clipPath(facePath);

    // Layer A: Primary diagonal metallic gradient
    // Upper-left is near-white warm, lower-right is near-black brown
    // This is the FOUNDATION of the metallic look
    canvas.drawRect(
      faceRect.inflate(2),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(faceCX - faceRx * 0.92, faceCY - faceRy * 1.05),
          Offset(faceCX + faceRx * 0.92, faceCY + faceRy * 1.05),
          [
            const Color(0xFFFFF4C8), // near-white warm highlight
            _cBright,
            _cLight,
            _cMid,
            _cBase,
            _cShadow,
            _cDark,
          ],
          const [0.0, 0.07, 0.22, 0.42, 0.62, 0.82, 1.0],
        ),
    );

    // Layer B: Radial curvature vignette — edges are darker (spherical look)
    canvas.drawRect(
      faceRect.inflate(2),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(faceCX - faceRx * 0.08, faceCY - faceRy * 0.06),
          faceRx * 1.22,
          [
            Colors.transparent,
            Colors.transparent,
            _cDark.withValues(alpha: 0.44),
          ],
          const [0.0, 0.52, 1.0],
        ),
    );

    // Layer C: Worn patina — ancient coins have surface texture variation
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(faceCX + faceRx * 0.30, faceCY + faceRy * 0.26),
        width: faceRx * 0.78, height: faceRy * 0.78,
      ),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(faceCX + faceRx * 0.30, faceCY + faceRy * 0.26),
          faceRx * 0.39,
          [_cDark.withValues(alpha: 0.18), Colors.transparent],
        ),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(faceCX - faceRx * 0.17, faceCY + faceRy * 0.06),
        width: faceRx * 0.48, height: faceRy * 0.48,
      ),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(faceCX - faceRx * 0.17, faceCY + faceRy * 0.06),
          faceRx * 0.24,
          [_cDark.withValues(alpha: 0.14), Colors.transparent],
        ),
    );

    canvas.restore(); // end face clip

    // ── 4. Edge details ────────────────────────────────────────────────
    // Dark outer border (the milled edge of an ancient coin)
    canvas.drawOval(
      faceRect.deflate(0.5),
      Paint()
        ..color = _cDark.withValues(alpha: 0.82)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    // Inner raised border ring (seen on real ancient coins between edge and design)
    canvas.drawOval(
      faceRect.deflate(5.5),
      Paint()
        ..color = _cShadow.withValues(alpha: 0.48)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );

    // ── 5. ₪ Carved engraving ──────────────────────────────────────────
    //
    // The symbol is STAMPED into the coin — a recess in the metal.
    // Light source: upper-left.
    // Rendering model:
    //   • Shadow pass 1 (far offset, darkest) — the deep floor of the pit
    //   • Shadow pass 2 (medium offset)       — shadow transition
    //   • Shadow pass 3 (small offset)        — soft penumbra
    //   • Highlight pass (opposite offset)    — light catching the cut edge
    //   • Main pass (no offset)               — the actual recessed surface
    //
    // The canvas is scaled so that drawing in a unit-circle space
    // maps to the tilted face ellipse (correct perspective foreshortening).
    canvas.save();
    canvas.translate(faceCX, faceCY);
    canvas.scale(faceRx / (d * 0.5), faceRy / (d * 0.5));

    // Clip to face (in scaled space a circle = ellipse in screen space)
    canvas.clipPath(
      Path()..addOval(
        Rect.fromCenter(center: Offset.zero, width: d * 0.98, height: d * 0.98),
      ),
    );

    final symSize = d * 0.46;

    void stamp(Offset off, Color col, double a) {
      final tp = TextPainter(
        text: TextSpan(
          text: '₪',
          style: TextStyle(
            fontSize: symSize,
            fontWeight: FontWeight.w900,
            color: col.withValues(alpha: a),
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, off + Offset(-tp.width / 2, -tp.height / 2));
    }

    // Shadow layers — offset toward lower-right (away from light)
    stamp(const Offset( 3.2,  4.2), _cDark,   1.00); // deepest pit floor shadow
    stamp(const Offset( 2.0,  2.8), _cDark,   0.88);
    stamp(const Offset( 1.0,  1.5), _cShadow, 0.72);
    // Highlight layer — offset toward upper-left (light catching cut edge)
    stamp(const Offset(-1.4, -1.8), _cBright, 0.35);
    // Main body — the recessed metal surface (must be DARKER than the face)
    stamp(Offset.zero,               const Color(0xFF3A1E00), 1.00);

    canvas.restore();

    // ── 6. Specular highlight ──────────────────────────────────────────
    // Warm, soft — ancient metal doesn't mirror-reflect
    final spX = faceCX - faceRx * 0.28;
    final spY = faceCY - faceRy * 0.30;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(spX, spY),
        width:  faceRx * 0.54,
        height: faceRy * 0.48,
      ),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(spX, spY), faceRx * 0.27,
          [
            const Color(0xFFFFF8DC).withValues(alpha: 0.65),
            const Color(0xFFD4A830).withValues(alpha: 0.18),
            Colors.transparent,
          ],
          const [0.0, 0.55, 1.0],
        ),
    );

    // Gloss band along top edge (ancient polish)
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(faceCX - faceRx * 0.04, faceCY - faceRy * 0.60),
        width:  faceRx * 1.48,
        height: faceRy * 0.28,
      ),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(faceCX, faceCY - faceRy),
          Offset(faceCX, faceCY - faceRy * 0.34),
          [
            const Color(0xFFFFF8DC).withValues(alpha: 0.26),
            Colors.transparent,
          ],
        ),
    );

    // ── 7. Animated shimmer ────────────────────────────────────────────
    // Slow warm shimmer orbiting the face like light catching worn metal
    final shimAngle = shimmerPhase * math.pi * 2 + math.pi * 0.60;
    final shimX = faceCX + math.cos(shimAngle) * faceRx * 0.36;
    final shimY = faceCY + math.sin(shimAngle) * faceRy * 0.34;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(shimX, shimY),
        width:  faceRx * 0.30,
        height: faceRy * 0.26,
      ),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(shimX, shimY), faceRx * 0.15,
          [_cLight.withValues(alpha: 0.38), Colors.transparent],
        ),
    );
  }

  @override
  bool shouldRepaint(_ShekelCoinPainter old) =>
      old.shimmerPhase != shimmerPhase || old.wobble != wobble;
}

// ─────────────────────────────────────────────────────────────────────────────
//  GOLDEN GLOW  — small point at coin slot → expands to fill cylinder body
//  Late stage: bleeds outside cylinder as warm external bloom
// ─────────────────────────────────────────────────────────────────────────────

class _GoldenGlowPainter extends CustomPainter {
  final double glowT;   // 0→1, already eased
  final double sceneW;
  final double sceneH;

  const _GoldenGlowPainter({
    required this.glowT,
    required this.sceneW,
    required this.sceneH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (glowT <= 0) return;

    final cylW   = sceneW * 0.42;
    final cylH   = sceneH * 0.765;
    final cx     = sceneW / 2;
    final cylTop = sceneH * 0.14;
    final cylBot = cylTop + cylH;
    final cylL   = cx - cylW / 2;
    final cylR   = cx + cylW / 2;

    // Ramp up opacity in the first 10%
    final fadeIn = glowT < 0.10 ? glowT / 0.10 : 1.0;
    final alpha  = fadeIn.clamp(0.0, 1.0);

    // ── Interior glow (clipped to cylinder) ───────────────────────────
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(cylL, cylTop, cylR, cylBot));

    // Glow origin: just inside the coin slot
    final origin = Offset(cx, cylTop + cylH * 0.11);

    // Radius: starts at 5px, expands to fill the entire cylinder diagonally
    final maxR    = math.sqrt(cylW * cylW + cylH * cylH) * 0.98;
    final currentR = 5.0 + glowT * (maxR - 5.0);

    canvas.drawCircle(
      origin, currentR,
      Paint()
        ..shader = ui.Gradient.radial(
          origin, currentR,
          [
            Colors.white.withValues(alpha:              0.96 * alpha),
            const Color(0xFFFFF8C8).withValues(alpha:   0.86 * alpha),
            const Color(0xFFFFD700).withValues(alpha:   0.72 * alpha),
            const Color(0xFFE8A800).withValues(alpha:   0.42 * alpha),
            const Color(0xFFAA6600).withValues(alpha:   0.16 * alpha),
            Colors.transparent,
          ],
          const [0.0, 0.07, 0.26, 0.54, 0.78, 1.0],
        ),
    );

    canvas.restore();

    // ── External bloom — glow bleeds out of glass walls after 65% ─────
    if (glowT > 0.65) {
      final bloomT = (glowT - 0.65) / 0.35;
      final bloomR = cylW * 0.70 + bloomT * cylW * 1.30;
      final bloomCY = cylTop + cylH * 0.50;

      canvas.drawCircle(
        Offset(cx, bloomCY), bloomR,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(cx, bloomCY), bloomR,
            [
              const Color(0xFFFFD700).withValues(alpha: 0.22 * bloomT * alpha),
              const Color(0xFFFF9000).withValues(alpha: 0.08 * bloomT * alpha),
              Colors.transparent,
            ],
            const [0.0, 0.55, 1.0],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_GoldenGlowPainter o) => o.glowT != glowT;
}

// ─────────────────────────────────────────────────────────────────────────────
//  AMBIENT HALO  — soft blue halo that breathes behind the pushka.
//  Warms to gold after impact.
// ─────────────────────────────────────────────────────────────────────────────

class _AmbientHaloPainter extends CustomPainter {
  final double pulse; // 0→1 repeat reverse
  final double glowT; // 0→1 post-impact warmth

  const _AmbientHaloPainter({required this.pulse, required this.glowT});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height * 0.44;
    final r  = size.width  * 0.48 + pulse * 22;

    // Blue ambient halo
    canvas.drawCircle(
      Offset(cx, cy), r,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, cy), r,
          [
            const Color(0xFF2E6CC8).withValues(alpha: 0.10 + pulse * 0.05),
            Colors.transparent,
          ],
        ),
    );

    // Post-impact: halo warms to golden as glow expands
    if (glowT > 0.01) {
      final warm = (glowT < 0.35 ? glowT / 0.35 : 1.0) * 0.24;
      canvas.drawCircle(
        Offset(cx, cy), r * 1.15,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(cx, cy), r * 1.15,
            [
              const Color(0xFFFFD700).withValues(alpha: warm),
              Colors.transparent,
            ],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_AmbientHaloPainter o) =>
      o.pulse != pulse || o.glowT != glowT;
}

// ─────────────────────────────────────────────────────────────────────────────
//  GOLD PARTICLES  — subtle floating dust particles
// ─────────────────────────────────────────────────────────────────────────────

class _GoldParticles extends StatefulWidget {
  const _GoldParticles();
  @override
  State<_GoldParticles> createState() => _GoldParticlesState();
}

class _GoldParticlesState extends State<_GoldParticles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final _ps = <_P>[];

  @override
  void initState() {
    super.initState();
    final rng = math.Random(17);
    for (int i = 0; i < 30; i++) {
      _ps.add(_P(
        x:       rng.nextDouble(),
        phase:   rng.nextDouble(),
        speed:   0.08 + rng.nextDouble() * 0.10,
        radius:  1.4  + rng.nextDouble() * 2.6,
        opacity: 0.22 + rng.nextDouble() * 0.42,
        drift:   (rng.nextDouble() - 0.5) * 0.055,
      ));
    }
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 9))
      ..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ctrl,
    builder: (_, _) => CustomPaint(
      painter: _PPainter(_ps, _ctrl.value),
      size: Size.infinite,
    ),
  );
}

class _P {
  final double x, phase, speed, radius, opacity, drift;
  const _P({
    required this.x,     required this.phase, required this.speed,
    required this.radius, required this.opacity, required this.drift,
  });
}

class _PPainter extends CustomPainter {
  final List<_P> ps;
  final double t;
  const _PPainter(this.ps, this.t);

  @override
  void paint(Canvas canvas, Size sz) {
    for (final p in ps) {
      final ft = (p.phase + t * p.speed * 8) % 1.0;
      final a  = ft < 0.10 ? ft / 0.10 : ft > 0.75 ? (1 - ft) / 0.25 : 1.0;
      canvas.drawCircle(
        Offset(
          (p.x + math.sin(ft * math.pi * 2) * p.drift) * sz.width,
          sz.height * (1.0 - ft),
        ),
        p.radius,
        Paint()
          ..color = const Color(0xFFD4AF37)
              .withValues(alpha: p.opacity * a * 0.65),
      );
    }
  }

  @override
  bool shouldRepaint(_PPainter o) => o.t != t;
}
