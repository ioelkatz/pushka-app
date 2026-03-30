import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 3-D MATH  (Vec3 + perspective camera — all pure Dart, zero dependencies)
// ─────────────────────────────────────────────────────────────────────────────

class _V3 {
  final double x, y, z;
  const _V3(this.x, this.y, this.z);

  _V3 operator +(_V3 v) => _V3(x + v.x, y + v.y, z + v.z);
  _V3 operator -(_V3 v) => _V3(x - v.x, y - v.y, z - v.z);
  _V3 operator *(double s) => _V3(x * s, y * s, z * s);
  double dot(_V3 v) => x * v.x + y * v.y + z * v.z;
  _V3 cross(_V3 v) =>
      _V3(y * v.z - z * v.y, z * v.x - x * v.z, x * v.y - y * v.x);
  double get len => sqrt(x * x + y * y + z * z);
  _V3 get n => this * (1.0 / len);
}

/// Perspective camera — call [project] to turn a world-space point into pixels.
class _Cam {
  final _V3 pos;
  final _V3 _fwd, _right, _up;
  final double _f; // focal length in pixels

  factory _Cam({
    required _V3 pos,
    required _V3 target,
    double fovYDeg = 42,
    required double canvasH,
  }) {
    final fwd   = (target - pos).n;
    final right = fwd.cross(const _V3(0, 1, 0)).n;
    final up    = right.cross(fwd);
    final f     = (canvasH / 2) / tan(fovYDeg * pi / 360);
    return _Cam._(pos, fwd, right, up, f);
  }

  const _Cam._(this.pos, this._fwd, this._right, this._up, this._f);

  Offset? project(_V3 world, Size sz) {
    final d = world - pos;
    final z = d.dot(_fwd);
    if (z < 0.01) return null;
    final x = d.dot(_right);
    final y = d.dot(_up);
    return Offset(sz.width / 2 + x * _f / z, sz.height / 2 - y * _f / z);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SPLASH SCREEN WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {

  // ── controllers ─────────────────────────────────────────────────────────
  late final AnimationController _enterCtrl;    // 800 ms  box entrance
  late final AnimationController _coinCtrl;     // 650 ms  coin fall
  late final AnimationController _impactCtrl;   // 450 ms  bounce + flash
  late final AnimationController _innerGlowCtrl;// 700 ms  internal glow fade-in
  late final AnimationController _glowCtrl;     // 2400 ms repeat — ambient pulse
  late final AnimationController _shimCtrl;     // 1800 ms repeat — coin shimmer

  // ── phase flags ──────────────────────────────────────────────────────────
  bool _showCoin  = false;
  bool _coinInBox = false;

  @override
  void initState() {
    super.initState();
    _enterCtrl     = AnimationController(vsync: this, duration: 800.ms);
    _coinCtrl      = AnimationController(vsync: this, duration: 650.ms);
    _impactCtrl    = AnimationController(vsync: this, duration: 450.ms);
    _innerGlowCtrl = AnimationController(vsync: this, duration: 700.ms);
    _glowCtrl      = AnimationController(vsync: this, duration: 2400.ms)
      ..repeat(reverse: true);
    _shimCtrl      = AnimationController(vsync: this, duration: 1800.ms)
      ..repeat();
    _runSequence();
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _coinCtrl.dispose();
    _impactCtrl.dispose();
    _innerGlowCtrl.dispose();
    _glowCtrl.dispose();
    _shimCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSequence() async {
    // 1 — box slides in
    await Future.delayed(250.ms);
    if (!mounted) return;
    _enterCtrl.forward();

    // 2 — coin appears and falls
    await Future.delayed(1050.ms);
    if (!mounted) return;
    setState(() => _showCoin = true);
    _coinCtrl.forward();

    // 3 — impact
    await Future.delayed(650.ms);
    if (!mounted) return;
    setState(() { _showCoin = false; _coinInBox = true; });
    _impactCtrl.forward();
    _innerGlowCtrl.forward();
    try {
      final p = AudioPlayer();
      await p.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}

    // 4 — settle then go
    await Future.delayed(2400.ms);
    if (!mounted) return;
    context.go('/');
  }

  // ── build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3A7FD8),
      body: Stack(
        fit: StackFit.expand,
        children: [

          // ── Background gradient ──────────────────────────────────────────
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.22),
                radius: 1.18,
                colors: [
                  Color(0xFF5BA8EE),
                  Color(0xFF3A7FD8),
                  Color(0xFF1A4FA8),
                  Color(0xFF0C2250),
                  Color(0xFF060E22),
                ],
                stops: [0.0, 0.22, 0.46, 0.72, 1.0],
              ),
            ),
          ),

          // ── Gold particles drifting upward ───────────────────────────────
          const _GoldParticles(),

          // ── Gold flash on coin impact ────────────────────────────────────
          AnimatedBuilder(
            animation: _impactCtrl,
            builder: (_, _) {
              final v = _impactCtrl.value;
              final a = (v < 0.3 ? v / 0.3 : (1 - v) / 0.7).clamp(0.0, 1.0);
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.08, -0.20),
                    radius: 0.52,
                    colors: [
                      const Color(0xFFD4AF37).withValues(alpha: 0.32 * a),
                      Colors.transparent,
                    ],
                  ),
                ),
              );
            },
          ),

          // ── Scene + text ─────────────────────────────────────────────────
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [

              // 3-D pushka scene
              AnimatedBuilder(
                animation: Listenable.merge([
                  _enterCtrl, _coinCtrl, _impactCtrl,
                  _innerGlowCtrl, _glowCtrl, _shimCtrl,
                ]),
                builder: (_, _) {
                  final entrance = CurvedAnimation(
                      parent: _enterCtrl, curve: Curves.easeOutBack).value;
                  final coinProg = _showCoin
                      ? CurvedAnimation(
                          parent: _coinCtrl, curve: Curves.easeIn).value
                      : null;
                  return CustomPaint(
                    painter: _PushkaPainter(
                      entrance:     entrance,
                      coinProgress: coinProg,
                      coinInBox:    _coinInBox,
                      impactT:      _impactCtrl.value,
                      innerGlow:    CurvedAnimation(
                          parent: _innerGlowCtrl,
                          curve: Curves.easeOut).value,
                      ambientGlow:  CurvedAnimation(
                          parent: _glowCtrl,
                          curve: Curves.easeInOut).value,
                      shimmer: _shimCtrl.value,
                    ),
                    size: const Size(300, 300),
                  );
                },
              ),

              const SizedBox(height: 32),

              // PUSHKA — gold shimmer text
              ShaderMask(
                shaderCallback: (b) => const LinearGradient(
                  colors: [
                    Color(0xFFD4AF37), Colors.white,
                    Color(0xFFF5E6A0), Colors.white,
                    Color(0xFFD4AF37),
                  ],
                  stops: [0.0, 0.25, 0.50, 0.75, 1.0],
                ).createShader(b),
                child: const Text(
                  'PUSHKA',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 13,
                  ),
                ),
              )
                  .animate()
                  .fadeIn(duration: 700.ms, delay: 200.ms)
                  .slideY(begin: 0.4, end: 0.0,
                      duration: 700.ms, delay: 200.ms,
                      curve: Curves.easeOutCubic),

              const SizedBox(height: 14),

              // Gold divider
              Container(
                width: 80, height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Colors.transparent,
                    const Color(0xFFD4AF37).withValues(alpha: 0.88),
                    Colors.transparent,
                  ]),
                ),
              ).animate().fadeIn(duration: 900.ms, delay: 360.ms),

              const SizedBox(height: 14),

              // Hebrew tagline
              Text(
                'צדקת רבי מאיר בעל הנס',
                textDirection: TextDirection.rtl,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.70),
                  fontSize: 14, letterSpacing: 1.1, height: 1.4,
                ),
              )
                  .animate()
                  .fadeIn(duration: 900.ms, delay: 420.ms)
                  .slideY(begin: 0.3, end: 0.0,
                      duration: 700.ms, delay: 420.ms,
                      curve: Curves.easeOutCubic),

              const SizedBox(height: 46),

              // COLEL CHABAD
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _goldLine(),
                  const SizedBox(width: 12),
                  Text(
                    'COLEL CHABAD',
                    style: TextStyle(
                      color: const Color(0xFFD4AF37).withValues(alpha: 0.65),
                      fontSize: 11, letterSpacing: 5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
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
    color: const Color(0xFFD4AF37).withValues(alpha: 0.38),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PUSHKA PAINTER  — fully custom 3-D glassmorphism box + coin
// ─────────────────────────────────────────────────────────────────────────────

class _PushkaPainter extends CustomPainter {
  final double  entrance;     // 0→1 box scale-in
  final double? coinProgress; // null=hidden; 0→1 fall
  final bool    coinInBox;    // true once coin is inside
  final double  impactT;      // 0→1 bounce curve
  final double  innerGlow;    // 0→1 internal light
  final double  ambientGlow;  // 0→1 idle pulse
  final double  shimmer;      // 0→1 repeating

  const _PushkaPainter({
    required this.entrance,
    required this.coinProgress,
    required this.coinInBox,
    required this.impactT,
    required this.innerGlow,
    required this.ambientGlow,
    required this.shimmer,
  });

  // ── scene config ──────────────────────────────────────────────────────────
  // Camera positioned to show front, right and top faces cleanly.
  static const _hs   = 0.54;  // box half-size (world units)
  static const _camP = _V3(0.85, 0.95, 2.20);
  static const _camT = _V3(0.0,  0.0,  0.0);

  // Key light direction (normalised by caller)
  static final _kLight = const _V3(1.0, 2.4, 1.3).n;
  // Rim light (back-top-left)
  static final _rLight = const _V3(-0.9, 0.6, -0.4).n;

  // ── palette ───────────────────────────────────────────────────────────────
  static const _faceColors = <String, List<Color>>{
    'top':   [Color(0xFF7BC5FF), Color(0xFF4A98EC)],
    'front': [Color(0xFF4A90E8), Color(0xFF1C5CB0)],
    'right': [Color(0xFF2268C8), Color(0xFF0D3A88)],
  };
  static const _edgeColor    = Color(0xFFAAD8FF);
  static const _slotDark     = Color(0xFF04101E);
  static const _glassOpacity = 0.74;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void paint(Canvas canvas, Size size) {
    // Set up camera
    final cam = _Cam(
      pos: _camP, target: _camT,
      fovYDeg: 42, canvasH: size.height,
    );
    Offset? p(_V3 w) => cam.project(w, size);

    // Entrance + bounce scale (pivot = visual centre of box)
    final pivot = p(const _V3(0, 0, 0)) ?? Offset(size.width/2, size.height/2);
    final sc = entrance * _bounceScale(impactT);

    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.scale(sc);
    canvas.translate(-pivot.dx, -pivot.dy);

    // ── 8 projected box vertices ─────────────────────────────────────────
    //  Index layout (standard cube):
    //  0(-,-,-) 1(+,-,-) 2(+,+,-) 3(-,+,-)
    //  4(-,-,+) 5(+,-,+) 6(+,+,+) 7(-,+,+)
    final pts = [
      p(const _V3(-_hs,-_hs,-_hs)),  // 0
      p(const _V3( _hs,-_hs,-_hs)),  // 1
      p(const _V3( _hs, _hs,-_hs)),  // 2
      p(const _V3(-_hs, _hs,-_hs)),  // 3
      p(const _V3(-_hs,-_hs, _hs)),  // 4
      p(const _V3( _hs,-_hs, _hs)),  // 5
      p(const _V3( _hs, _hs, _hs)),  // 6
      p(const _V3(-_hs, _hs, _hs)),  // 7
    ];

    // Abort if any vertex failed to project
    if (pts.any((o) => o == null)) {
      canvas.restore();
      return;
    }
    final v = pts.map((o) => o!).toList();

    // ── Soft shadow under box ─────────────────────────────────────────────
    _drawShadow(canvas, size, sc);

    // ── Ambient blue halo behind box ──────────────────────────────────────
    final haloCentre = _avgOffset([v[4], v[5], v[6], v[7], v[2], v[3]]);
    canvas.drawCircle(
      haloCentre,
      90 + ambientGlow * 22,
      Paint()
        ..shader = ui.Gradient.radial(
          haloCentre,
          90 + ambientGlow * 22,
          [
            const Color(0xFF4A98EC).withValues(
                alpha: 0.22 + ambientGlow * 0.12),
            Colors.transparent,
          ],
        ),
    );

    // ── Back faces (very transparent — gives glass depth) ─────────────────
    // Back face (z–): v0,v1,v2,v3  — only bottom strip visible for depth
    _drawFaceRaw(canvas, [v[0], v[1], v[2], v[3]],
        const Color(0xFF6AABFF).withValues(alpha: 0.10));
    // Left face (x–): v4,v0,v3,v7
    _drawFaceRaw(canvas, [v[4], v[0], v[3], v[7]],
        const Color(0xFF5590E0).withValues(alpha: 0.10));

    // ── Right face ────────────────────────────────────────────────────────
    _drawGlassFace(
      canvas,
      verts:   [v[5], v[1], v[2], v[6]],
      topColor: _faceColors['right']![0],
      botColor: _faceColors['right']![1],
      normal:  const _V3(1, 0, 0),
      opacity: _glassOpacity - 0.08,
      glossRatio: 0.30,
      innerGlow:  innerGlow,
    );

    // ── Front face ────────────────────────────────────────────────────────
    _drawGlassFace(
      canvas,
      verts:    [v[4], v[5], v[6], v[7]],
      topColor: _faceColors['front']![0],
      botColor: _faceColors['front']![1],
      normal:   const _V3(0, 0, 1),
      opacity:  _glassOpacity,
      glossRatio: 0.40,
      innerGlow:  innerGlow,
    );

    // Star of David on front face
    final frontCentre = _avgOffset([v[4], v[5], v[6], v[7]]);
    // Estimate star radius from face width
    final faceW = (v[5] - v[4]).distance;
    _drawStarOfDavid(canvas, frontCentre + Offset(0, faceW * 0.06), faceW * 0.18);

    // ── Top face ──────────────────────────────────────────────────────────
    _drawGlassFace(
      canvas,
      verts:    [v[7], v[6], v[2], v[3]],
      topColor: _faceColors['top']![0],
      botColor: _faceColors['top']![1],
      normal:   const _V3(0, 1, 0),
      opacity:  _glassOpacity + 0.04,
      glossRatio: 0.55,
      innerGlow:  innerGlow,
    );

    // ── Edge highlights (lit edges — simulate glass thickness) ────────────
    _drawEdges(canvas, v);

    // ── Coin slot ─────────────────────────────────────────────────────────
    final slotPts = [
      p(const _V3(-0.15, _hs + 0.003, -0.13)),
      p(const _V3( 0.15, _hs + 0.003, -0.13)),
      p(const _V3( 0.15, _hs + 0.003,  0.01)),
      p(const _V3(-0.15, _hs + 0.003,  0.01)),
    ];
    if (slotPts.every((o) => o != null)) {
      final sp = slotPts.map((o) => o!).toList();
      final slotPath = _polyPath(sp);
      canvas.drawPath(slotPath, Paint()..color = _slotDark);
      // Slot edge highlight
      canvas.drawPath(
        slotPath,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.22)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }

    canvas.restore(); // ← end of box transform

    // ── Coin (drawn after restore — independent of box transform) ─────────
    if (coinProgress != null) {
      // World position along fall path
      const startY = _hs + 1.30;
      const endY   = _hs + 0.05;
      final worldY = startY + (endY - startY) * coinProgress!;
      final coinWorld = _V3(0.0, worldY, -0.06);
      _drawCoin(canvas, cam, coinWorld, size,
          rotation: sin(coinProgress! * pi * 1.4) * 0.14,
          shimmer: 0.0);
    } else if (coinInBox && innerGlow < 0.3) {
      // Brief "coin just entered" flash on slot
    }
  }

  // ── Glassmorphism face ───────────────────────────────────────────────────

  void _drawGlassFace(
    Canvas canvas, {
    required List<Offset> verts,
    required Color topColor,
    required Color botColor,
    required _V3 normal,
    required double opacity,
    required double glossRatio,
    required double innerGlow,
  }) {
    // Phong diffuse from key light
    final diffuse = max(0.0, normal.dot(_kLight));
    // Rim light
    final rim     = max(0.0, normal.dot(_rLight)) * 0.18;
    final light   = (0.38 + 0.62 * diffuse + rim).clamp(0.0, 1.0);

    final path   = _polyPath(verts);
    final bounds = path.getBounds();
    final top    = Offset(bounds.left  + bounds.width  * 0.5, bounds.top);
    final bot    = Offset(bounds.right - bounds.width  * 0.5, bounds.bottom);

    // Base glass fill
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(top, bot, [
          topColor.withValues(alpha: opacity * light),
          botColor.withValues(alpha: opacity * light * 0.72),
        ]),
    );

    // Gloss highlight (top portion of face)
    if (glossRatio > 0) {
      final glossBot = Offset(
        bounds.left  + bounds.width  * 0.5,
        bounds.top   + bounds.height * glossRatio,
      );
      final glossPath = Path()
        ..moveTo(verts[0].dx, verts[0].dy)
        ..lineTo(verts[1].dx, verts[1].dy)
        ..lineTo(
          verts[1].dx * (1 - glossRatio) + verts[2].dx * glossRatio,
          verts[1].dy * (1 - glossRatio) + verts[2].dy * glossRatio,
        )
        ..lineTo(
          verts[0].dx * (1 - glossRatio) + verts[3].dx * glossRatio,
          verts[0].dy * (1 - glossRatio) + verts[3].dy * glossRatio,
        )
        ..close();
      canvas.drawPath(
        glossPath,
        Paint()
          ..shader = ui.Gradient.linear(top, glossBot, [
            Colors.white.withValues(alpha: 0.22 * light),
            Colors.white.withValues(alpha: 0.0),
          ]),
      );
    }

    // Internal glow — warm cyan pulse after coin enters
    if (innerGlow > 0.01) {
      final centre = Offset(
        (verts[0].dx + verts[1].dx + verts[2].dx + verts[3].dx) / 4,
        (verts[0].dy + verts[1].dy + verts[2].dy + verts[3].dy) / 4,
      );
      final r = bounds.width * 0.6;
      canvas.drawCircle(
        centre, r,
        Paint()
          ..shader = ui.Gradient.radial(centre, r, [
            const Color(0xFF80DDFF).withValues(alpha: 0.28 * innerGlow),
            Colors.transparent,
          ]),
      );
    }

    // Face rim (thin border — glass edge)
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  // ── Back-face raw fill (transparency depth) ──────────────────────────────
  void _drawFaceRaw(Canvas canvas, List<Offset> verts, Color color) {
    canvas.drawPath(_polyPath(verts), Paint()..color = color);
  }

  // ── Lit edges ────────────────────────────────────────────────────────────
  void _drawEdges(Canvas canvas, List<Offset> v) {
    void e(Offset a, Offset b, double alpha, double w) {
      canvas.drawLine(
        a, b,
        Paint()
          ..color = _edgeColor.withValues(alpha: alpha)
          ..strokeWidth = w
          ..strokeCap = StrokeCap.round,
      );
    }
    // Top edges — brightest (lit from above)
    e(v[7], v[6], 0.65, 2.2); // top-front
    e(v[3], v[7], 0.50, 1.8); // top-left
    e(v[6], v[2], 0.40, 1.6); // top-right
    e(v[2], v[3], 0.28, 1.4); // top-back
    // Vertical front edges
    e(v[4], v[7], 0.35, 1.6); // front-left
    e(v[5], v[6], 0.25, 1.4); // front-right
    // Bottom edges (subtle)
    e(v[4], v[5], 0.18, 1.2); // bottom-front
    // Right-face bottom
    e(v[1], v[5], 0.14, 1.2);
    e(v[2], v[1], 0.12, 1.0);
  }

  // ── Star of David ────────────────────────────────────────────────────────
  void _drawStarOfDavid(Canvas canvas, Offset centre, double r) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.82)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round
      ..strokeCap  = StrokeCap.round;

    for (int t = 0; t < 2; t++) {
      final rot = t * pi;
      final path = Path();
      for (int i = 0; i < 3; i++) {
        final a = rot + i * (2 * pi / 3) - pi / 2;
        final pt = Offset(centre.dx + r * cos(a), centre.dy + r * sin(a));
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  // ── Drop shadow ──────────────────────────────────────────────────────────
  void _drawShadow(Canvas canvas, Size size, double sc) {
    final c = Offset(size.width / 2 + 9, size.height * 0.71);
    final r = Rect.fromCenter(center: c, width: 168 * sc, height: 34 * sc);
    canvas.drawOval(
      r,
      Paint()
        ..shader = ui.Gradient.radial(c, 84 * sc, [
          Colors.black.withValues(alpha: 0.38),
          Colors.transparent,
        ])
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
  }

  // ── 3-D Coin ─────────────────────────────────────────────────────────────
  void _drawCoin(
    Canvas canvas, _Cam cam, _V3 worldPos, Size size, {
    required double rotation,
    required double shimmer,
  }) {
    const r = 0.132; // coin radius in world units

    final centre = cam.project(worldPos, size);
    if (centre == null) return;

    // Project disc cardinal points to find screen ellipse axes
    final rPt  = cam.project(worldPos + const _V3(r, 0, 0), size);
    final fwPt = cam.project(worldPos + const _V3(0, 0, r), size);
    if (rPt == null || fwPt == null) return;

    final rx = (rPt - centre).distance;
    // Depth-axis compression (disc horizontal, viewed from above-ish)
    final ry = (fwPt - centre).distance * 0.52;

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(rotation);

    // Outer glow
    final glowR = rx * 2.2;
    canvas.drawCircle(
      Offset.zero, glowR,
      Paint()
        ..shader = ui.Gradient.radial(Offset.zero, glowR, [
          const Color(0xFFFFD700).withValues(alpha: 0.60),
          const Color(0xFFFFD700).withValues(alpha: 0.0),
        ]),
    );

    // Coin body (ellipse)
    final coinRect = Rect.fromCenter(
        center: Offset.zero, width: rx * 2, height: ry * 2);
    canvas.drawOval(
      coinRect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(-rx * 0.4, -ry * 0.5),
          Offset( rx * 0.5,  ry * 0.5),
          const [
            Color(0xFFFFF8B0),
            Color(0xFFFFD700),
            Color(0xFFD4AF37),
            Color(0xFF9A7020),
          ],
          const [0.0, 0.28, 0.65, 1.0],
        ),
    );

    // Rim
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: rx*2-2, height: ry*2-1.5),
      Paint()
        ..color = const Color(0xFFA07820)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // Specular
    final hiOff = Offset(-rx * 0.26, -ry * 0.32);
    canvas.drawOval(
      Rect.fromCenter(center: hiOff, width: rx * 0.9, height: ry * 0.65),
      Paint()
        ..shader = ui.Gradient.radial(hiOff, rx * 0.45, [
          Colors.white.withValues(alpha: 0.72),
          Colors.transparent,
        ]),
    );

    // Shimmer sweep
    if (shimmer > 0.01) {
      final sx = -rx + shimmer * rx * 2.6;
      final so = Offset(sx, -ry * 0.12);
      canvas.drawOval(
        Rect.fromCenter(center: so, width: rx * 0.72, height: ry * 0.52),
        Paint()
          ..shader = ui.Gradient.radial(so, rx * 0.36, [
            Colors.white.withValues(alpha: 0.50 * sin(shimmer * pi)),
            Colors.transparent,
          ]),
      );
    }

    canvas.restore();
  }

  // ── Bounce/squish curve ───────────────────────────────────────────────────
  double _bounceScale(double t) {
    if (t == 0.0) return 1.0;
    if (t < 0.22) return 1.0 + t / 0.22 * 0.065;
    if (t < 0.52) return 1.065 - (t - 0.22) / 0.30 * 0.105;
    if (t < 0.78) return 0.960 + (t - 0.52) / 0.26 * 0.050;
    return 1.010 - (t - 0.78) / 0.22 * 0.010;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  static Path _polyPath(List<Offset> pts) {
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    return path..close();
  }

  static Offset _avgOffset(List<Offset> pts) {
    double sx = 0, sy = 0;
    for (final p in pts) { sx += p.dx; sy += p.dy; }
    return Offset(sx / pts.length, sy / pts.length);
  }

  @override
  bool shouldRepaint(_PushkaPainter o) =>
      o.entrance     != entrance     ||
      o.coinProgress != coinProgress ||
      o.coinInBox    != coinInBox    ||
      o.impactT      != impactT      ||
      o.innerGlow    != innerGlow    ||
      o.ambientGlow  != ambientGlow  ||
      o.shimmer      != shimmer;
}

// ─────────────────────────────────────────────────────────────────────────────
// GOLD PARTICLES
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
    final rng = Random(17);
    for (int i = 0; i < 32; i++) {
      _ps.add(_P(
        x:       rng.nextDouble(),
        phase:   rng.nextDouble(),
        speed:   0.09 + rng.nextDouble() * 0.11,
        radius:  1.5  + rng.nextDouble() * 2.8,
        opacity: 0.26 + rng.nextDouble() * 0.46,
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
          painter: _PPainter(_ps, _ctrl.value),
          size: Size.infinite,
        ),
      );
}

class _P {
  final double x, phase, speed, radius, opacity, drift;
  const _P({
    required this.x, required this.phase, required this.speed,
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
          (p.x + sin(ft * pi * 2) * p.drift) * sz.width,
          sz.height * (1.0 - ft),
        ),
        p.radius,
        Paint()
          ..color = const Color(0xFFD4AF37).withValues(alpha: p.opacity * a),
      );
    }
  }

  @override
  bool shouldRepaint(_PPainter o) => o.t != t;
}
