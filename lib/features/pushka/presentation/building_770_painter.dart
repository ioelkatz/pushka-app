import 'dart:math' as math;
import 'package:flutter/material.dart';

class Building770Painter extends CustomPainter {
  final double fillFraction;
  final double glowPhase;

  const Building770Painter({required this.fillFraction, this.glowPhase = 0});

  // ── Palette ──────────────────────────────────────────────────────────────────
  static const _brickMain   = Color(0xFFC1440E);
  static const _brickDark   = Color(0xFF8B2E08);
  static const _brickLight  = Color(0xFFD05030);
  static const _brickDeep   = Color(0xFF6E2206);
  static const _trim        = Color(0xFFF5F0E8);
  static const _trimShade   = Color(0xFFD4C9B0);
  static const _trimDark    = Color(0xFFB0A08A);
  static const _winDark     = Color(0xFF1A0E06);
  static const _doorWood    = Color(0xFF5C3010);
  static const _skyTop      = Color(0xFFBDD4E8);
  static const _skyBot      = Color(0xFFE8EFF4);
  static const _glowHot     = Color(0xFFFFAA00);
  static const _glowWarm    = Color(0xFFFFD060);
  static const _glowCool    = Color(0xFFFFF0B0);
  static const _fenceBrick  = Color(0xFFAA3308);
  static const _glassBlue   = Color(0xFF1A56A8);
  static const _glassGreen  = Color(0xFF2A8040);
  static const _glassYellow = Color(0xFFE8B800);

  // ── Layout constants (fractions of w or h) ───────────────────────────────────
  // Building envelope
  static const double _bL    = 0.03;
  static const double _bR    = 0.97;
  static const double _bBot  = 0.820;
  static const double _gBase = 0.220; // Y where gable triangles meet flat roof

  // 3 gable geometry (X = fraction of w, apex = fraction of h)
  // Left and right are identical (mirror). Center is narrower and shorter.
  static const double _lgCX   = 0.258;  // large gable center X
  static const double _cgCX   = 0.500;  // center gable center X
  static const double _rgCX   = 0.742;  // right gable center X
  static const double _lgHW   = 0.148;  // large gable half-width  → right edge 0.406
  static const double _cgHW   = 0.088;  // center gable half-width → left edge 0.412
  static const double _lgApex = 0.038;  // large gable apex Y
  static const double _cgApex = 0.072;  // center gable apex Y (shorter)

  // Floor cornice Y positions
  static const double _c32   = 0.432;   // cornice between 3rd and 2nd floor
  static const double _c21   = 0.628;   // cornice between 2nd and 1st floor
  static const double _cBase = 0.800;   // base plinth Y

  // ── paint ────────────────────────────────────────────────────────────────────
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    _drawGroundShadow(canvas, w, h);
    _drawSky(canvas, w, h);
    _drawBuildingBase(canvas, w, h);
    _drawBrickPattern(canvas, w, h);
    _drawQuoins(canvas, w, h);
    _drawFloorCornices(canvas, w, h);
    _drawGableDecorations(canvas, w, h);
    _drawThirdFloorWindows(canvas, w, h);
    _drawSecondFloor(canvas, w, h);
    _drawGroundFloor(canvas, w, h);
    _drawGlowOverlay(canvas, w, h);
    _drawEdgeShadows(canvas, w, h);
    _drawFrontFence(canvas, w, h);
  }

  // ── Building silhouette: exactly 3 Gothic gables ─────────────────────────────
  Path _clip(double w, double h) {
    final path = Path();
    path.moveTo(w * _bL, h * _bBot);
    path.lineTo(w * _bL, h * _gBase);

    // Left gable (large)
    path.lineTo(w * (_lgCX - _lgHW), h * _gBase);
    path.lineTo(w * _lgCX,           h * _lgApex);
    path.lineTo(w * (_lgCX + _lgHW), h * _gBase);

    // Center gable (narrower, slightly shorter) — gap of w*0.006 on each side
    path.lineTo(w * (_cgCX - _cgHW), h * _gBase);
    path.lineTo(w * _cgCX,           h * _cgApex);
    path.lineTo(w * (_cgCX + _cgHW), h * _gBase);

    // Right gable (mirror of left)
    path.lineTo(w * (_rgCX - _lgHW), h * _gBase);
    path.lineTo(w * _rgCX,           h * _lgApex);
    path.lineTo(w * (_rgCX + _lgHW), h * _gBase);

    path.lineTo(w * _bR, h * _gBase);
    path.lineTo(w * _bR, h * _bBot);
    path.close();
    return path;
  }

  // ── Sky ──────────────────────────────────────────────────────────────────────
  void _drawSky(Canvas canvas, double w, double h) {
    final r = Rect.fromLTWH(0, 0, w, h * 0.26);
    canvas.drawRect(r, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [_skyTop, _skyBot],
      ).createShader(r));
  }

  // ── Building base (brick gradient) ───────────────────────────────────────────
  void _drawBuildingBase(Canvas canvas, double w, double h) {
    final r = Rect.fromLTRB(w * _bL, h * _gBase, w * _bR, h * _bBot);
    final path = _clip(w, h);

    canvas.drawPath(path, Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft, end: Alignment.centerRight,
        colors: const [_brickDark, _brickMain, _brickLight, _brickMain, _brickDark],
        stops: const [0.0, 0.10, 0.50, 0.90, 1.0],
      ).createShader(r));

    canvas.drawPath(path, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(65), Colors.transparent,
          Colors.transparent, Colors.black.withAlpha(28),
        ],
        stops: const [0.0, 0.14, 0.80, 1.0],
      ).createShader(r));
  }

  // ── Brick mortar pattern ──────────────────────────────────────────────────────
  void _drawBrickPattern(Canvas canvas, double w, double h) {
    canvas.save();
    canvas.clipPath(_clip(w, h));

    final bL = w * _bL; final bR = w * _bR;
    final bTop = h * _gBase; final bBot = h * _bBot;
    final courseH = h * 0.016;

    final hP = Paint()..color = _brickDark.withAlpha(40)..strokeWidth = 0.7;
    var y = bTop;
    while (y < bBot) { canvas.drawLine(Offset(bL, y), Offset(bR, y), hP); y += courseH; }

    final vP = Paint()..color = _brickDark.withAlpha(20)..strokeWidth = 0.5;
    final bW = w * 0.048;
    var row = 0; y = bTop;
    while (y < bBot) {
      final off = (row % 2 == 0) ? 0.0 : bW * 0.5;
      var x = bL + off;
      while (x < bR) { canvas.drawLine(Offset(x, y), Offset(x, y + courseH), vP); x += bW; }
      y += courseH; row++;
    }
    canvas.restore();
  }

  // ── Quoins (alternating stone blocks at corners) ──────────────────────────────
  void _drawQuoins(Canvas canvas, double w, double h) {
    canvas.save();
    canvas.clipPath(_clip(w, h));

    final bL = w * _bL; final bR = w * _bR;
    final qW = w * 0.040;
    final qH = h * 0.034;
    final qGap = h * 0.016;
    var y = h * _gBase + 6;
    var longSide = true;

    while (y < h * _bBot - qH) {
      final thisW = longSide ? qW : qW * 0.62;
      final p = Paint()..color = _trim;
      final sp = Paint()..color = _trimDark.withAlpha(55)
        ..style = PaintingStyle.stroke..strokeWidth = 0.6;

      canvas.drawRect(Rect.fromLTWH(bL, y, thisW, qH), p);
      canvas.drawRect(Rect.fromLTWH(bL, y, thisW, qH), sp);
      canvas.drawRect(Rect.fromLTWH(bR - thisW, y, thisW, qH), p);
      canvas.drawRect(Rect.fromLTWH(bR - thisW, y, thisW, qH), sp);

      y += qH + qGap;
      longSide = !longSide;
    }
    canvas.restore();
  }

  // ── Horizontal cornice bands ──────────────────────────────────────────────────
  void _drawFloorCornices(Canvas canvas, double w, double h) {
    final bL = w * _bL; final bW = w * (_bR - _bL);

    void band(double yFrac) {
      final y = h * yFrac;
      canvas.drawRect(Rect.fromLTWH(bL, y, bW, h * 0.022), Paint()..color = _trim);
      canvas.drawRect(Rect.fromLTWH(bL, y + h * 0.022, bW, h * 0.006),
          Paint()..color = _trimDark.withAlpha(80));
      canvas.drawRect(Rect.fromLTWH(bL, y, bW, h * 0.004),
          Paint()..color = Colors.white.withAlpha(70));
    }

    band(0.218); // top of 3rd floor (just below gable base)
    band(_c32);  // 3rd → 2nd
    band(_c21);  // 2nd → 1st

    // Base plinth
    canvas.drawRect(
      Rect.fromLTWH(bL, h * _cBase, bW, h * 0.022),
      Paint()..color = _trim,
    );
  }

  // ── Gable triangle decorations ────────────────────────────────────────────────
  void _drawGableDecorations(Canvas canvas, double w, double h) {
    void gable(double cx, double apexY, double halfW, bool large) {
      final base = h * _gBase;
      final ap   = h * apexY;
      final hW   = w * halfW;

      final tri = Path()
        ..moveTo(cx - hW, base)
        ..lineTo(cx, ap)
        ..lineTo(cx + hW, base)
        ..close();

      // Stone trim along the gable edges
      canvas.drawPath(tri, Paint()
        ..color = _trim..style = PaintingStyle.stroke
        ..strokeWidth = large ? 5.5 : 4.0);
      canvas.drawPath(tri, Paint()
        ..color = _trimShade..style = PaintingStyle.stroke
        ..strokeWidth = large ? 2.5 : 1.8);

      // Finial ball at apex
      final r = large ? 7.5 : 5.5;
      canvas.drawCircle(Offset(cx, ap), r + 1.5, Paint()..color = _trimShade);
      canvas.drawCircle(Offset(cx, ap), r,       Paint()..color = _trim);
      canvas.drawCircle(Offset(cx, ap - 1.5), r * 0.40,
          Paint()..color = Colors.white.withAlpha(110));
    }

    // Circular medallion on each large gable face
    void medallion(double cx, double apexY) {
      final mY = h * apexY + (h * _gBase - h * apexY) * 0.52;
      canvas.drawCircle(Offset(cx, mY), w * 0.033, Paint()..color = _trimShade);
      canvas.drawCircle(Offset(cx, mY), w * 0.026, Paint()..color = _trim);
      canvas.drawCircle(Offset(cx, mY), w * 0.016,
          Paint()..color = _brickMain.withAlpha(90));
    }

    gable(w * _lgCX, _lgApex, _lgHW, true);
    gable(w * _cgCX, _cgApex, _cgHW, false);
    gable(w * _rgCX, _lgApex, _lgHW, true);

    medallion(w * _lgCX, _lgApex);
    medallion(w * _rgCX, _lgApex);
  }

  // ── 3rd floor: groups of 3 narrow windows under each gable ───────────────────
  void _drawThirdFloorWindows(Canvas canvas, double w, double h) {
    final lit = fillFraction > 0.72;
    final wCY = h * ((_gBase + _c32) / 2); // vertical center of 3rd floor

    // Under left and right large gables: 3 windows, spacing w*0.068
    for (final gCX in [w * _lgCX, w * _rgCX]) {
      for (int i = -1; i <= 1; i++) {
        _narrowWindow(canvas, gCX + w * 0.068 * i, wCY, w * 0.052, h * 0.105, lit);
      }
    }

    // Under center gable: 3 slightly narrower windows, spacing w*0.055
    for (int i = -1; i <= 1; i++) {
      _narrowWindow(canvas, w * _cgCX + w * 0.055 * i, wCY, w * 0.040, h * 0.090, lit);
    }
  }

  void _narrowWindow(Canvas canvas, double cx, double cy, double ww, double wh, bool lit) {
    final outer = Rect.fromCenter(center: Offset(cx, cy), width: ww + 8, height: wh + 6);
    final mid   = Rect.fromCenter(center: Offset(cx, cy), width: ww + 5, height: wh + 3);
    final inner = Rect.fromCenter(center: Offset(cx, cy), width: ww - 4, height: wh - 4);

    canvas.drawRRect(RRect.fromRectAndRadius(outer, const Radius.circular(1.5)),
        Paint()..color = _trimShade);
    canvas.drawRRect(RRect.fromRectAndRadius(mid, const Radius.circular(1.5)),
        Paint()..color = _trim);

    canvas.drawRect(inner, Paint()..color = lit
        ? const Color(0xFFFFDD88).withAlpha(195) : _winDark);
    if (lit) {
      canvas.drawRect(inner, Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.2, -0.4), radius: 0.8,
          colors: [Colors.white.withAlpha(85), Colors.transparent],
        ).createShader(inner));
    }

    // Horizontal mid-bar and thin vertical divider
    final dp = Paint()..color = _trim.withAlpha(lit ? 155 : 215)..strokeWidth = 1.8;
    canvas.drawLine(Offset(inner.left, cy), Offset(inner.right, cy), dp);
    canvas.drawLine(Offset(cx, inner.top), Offset(cx, inner.bottom),
        Paint()..color = _trim.withAlpha(lit ? 90 : 140)..strokeWidth = 1.0);
  }

  // ── 2nd floor: protruding bay window + side windows ───────────────────────────
  void _drawSecondFloor(Canvas canvas, double w, double h) {
    final lit = fillFraction > 0.44;
    _drawBayWindow(canvas, w, h, lit);

    final sCY   = h * ((_c32 + _c21) / 2 + 0.012);
    final sWW   = w * 0.090;
    final sWH   = h * 0.112;
    final innerL = w * (_bL + 0.04);
    final innerR = w * (_bR - 0.04);
    // Bay front face half-width + side protrusion
    final bayEdge = w * (0.50 - 0.095 - 0.024);
    final leftW   = bayEdge - innerL;
    final rightStart = w * (0.50 + 0.095 + 0.024);
    final rightW  = innerR - rightStart;

    _classicWindow(canvas, innerL + leftW * 0.25,    sCY, sWW, sWH, lit);
    _classicWindow(canvas, innerL + leftW * 0.72,    sCY, sWW, sWH, lit);
    _classicWindow(canvas, rightStart + rightW * 0.28, sCY, sWW, sWH, lit);
    _classicWindow(canvas, rightStart + rightW * 0.75, sCY, sWW, sWH, lit);
  }

  void _drawBayWindow(Canvas canvas, double w, double h, bool lit) {
    final cx      = w * 0.50;
    final faceW   = w * 0.190;
    final faceH   = h * 0.162;
    final faceTop = h * (_c32 + 0.024);
    final faceBot = faceTop + faceH;
    final faceMid = (faceTop + faceBot) / 2;
    final sideD   = w * 0.024; // protrusion depth

    // -- Left and right side faces (3-D effect) --
    final sideShade = Paint()..color = _brickDeep.withAlpha(160);
    canvas.drawPath(
      Path()
        ..moveTo(cx - faceW / 2, faceTop - h * 0.008)
        ..lineTo(cx - faceW / 2 - sideD, faceTop + h * 0.014)
        ..lineTo(cx - faceW / 2 - sideD, faceBot + h * 0.008)
        ..lineTo(cx - faceW / 2, faceBot)
        ..close(),
      sideShade,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx + faceW / 2, faceTop - h * 0.008)
        ..lineTo(cx + faceW / 2 + sideD, faceTop + h * 0.014)
        ..lineTo(cx + faceW / 2 + sideD, faceBot + h * 0.008)
        ..lineTo(cx + faceW / 2, faceBot)
        ..close(),
      Paint()..color = _brickDeep.withAlpha(110),
    );

    // -- Front face --
    final faceRect = Rect.fromLTWH(cx - faceW / 2, faceTop, faceW, faceH);
    canvas.drawRect(faceRect, Paint()..color = _brickMain.withAlpha(240));
    canvas.drawRect(faceRect, Paint()
      ..color = _trim..style = PaintingStyle.stroke..strokeWidth = 5.5);

    // -- 3 stained glass panels --
    final pW = faceW * 0.282;
    final pH = faceH * 0.680;
    final pCY = faceMid + faceH * 0.055;
    final pOffsets = [-faceW * 0.300, 0.0, faceW * 0.300];
    final pColors  = [_glassGreen, _glassBlue, _glassYellow];

    for (int i = 0; i < 3; i++) {
      final px = cx + pOffsets[i];
      final frameP = _arch(px, pCY, pW + 5, pH + 5, pW * 0.52);
      final glassP = _arch(px, pCY, pW - 2, pH - 2, pW * 0.46);
      final pRect  = Rect.fromCenter(center: Offset(px, pCY), width: pW, height: pH);

      canvas.drawPath(frameP, Paint()..color = _trim);
      if (lit) {
        canvas.drawPath(glassP, Paint()..color = pColors[i].withAlpha(218));
        canvas.save();
        canvas.clipPath(glassP);
        canvas.drawRect(pRect, Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.5), radius: 0.85,
            colors: [Colors.white.withAlpha(112), Colors.transparent],
          ).createShader(pRect));
        canvas.restore();
      } else {
        canvas.drawPath(glassP, Paint()..color = _winDark);
      }
    }

    // -- Pediment (small triangular roof above bay) --
    final pedHW = faceW * 0.58;
    final pedH  = h * 0.034;
    final pedPath = Path()
      ..moveTo(cx - pedHW, faceTop)
      ..lineTo(cx, faceTop - pedH)
      ..lineTo(cx + pedHW, faceTop)
      ..close();
    canvas.drawPath(pedPath, Paint()..color = _trim);
    canvas.drawPath(pedPath, Paint()
      ..color = _trimShade..style = PaintingStyle.stroke..strokeWidth = 2.0);

    // Arched connecting molding
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx, faceTop), width: faceW * 1.10, height: h * 0.048),
      math.pi, math.pi, false,
      Paint()..color = _trim..style = PaintingStyle.stroke..strokeWidth = 4.5,
    );
  }

  void _classicWindow(Canvas canvas, double cx, double cy, double ww, double wh, bool lit) {
    final outer = Rect.fromCenter(center: Offset(cx, cy), width: ww + 10, height: wh + 8);
    final mid   = Rect.fromCenter(center: Offset(cx, cy), width: ww + 6,  height: wh + 4);
    final inner = Rect.fromCenter(center: Offset(cx, cy), width: ww - 4,  height: wh - 4);

    canvas.drawRRect(RRect.fromRectAndRadius(outer, const Radius.circular(2)),
        Paint()..color = _trimShade);
    canvas.drawRRect(RRect.fromRectAndRadius(mid, const Radius.circular(2)),
        Paint()..color = _trim);
    canvas.drawRect(inner, Paint()..color = lit
        ? const Color(0xFFFFDD88).withAlpha(195) : _winDark);
    if (lit) {
      canvas.drawRect(inner, Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.3), radius: 0.9,
          colors: [Colors.white.withAlpha(82), Colors.transparent],
        ).createShader(inner));
    }
    final dp = Paint()..color = _trim.withAlpha(lit ? 160 : 230)..strokeWidth = 1.8;
    canvas.drawLine(Offset(cx, inner.top), Offset(cx, inner.bottom), dp);
    canvas.drawLine(Offset(inner.left, cy), Offset(inner.right, cy), dp);
  }

  // ── Ground floor: large stained glass + entrance ──────────────────────────────
  void _drawGroundFloor(Canvas canvas, double w, double h) {
    final lit  = fillFraction > 0.06;
    final cx   = w * 0.50;
    final gfCY = h * ((_c21 + _cBase) / 2 + 0.010);
    final gfH  = h * 0.128;
    final gfW  = w * 0.168;

    // Entrance half-width for clearance
    final entrW = w * 0.145;

    // Left stained glass
    final leftCx  = cx - entrW - (cx - entrW - w * (_bL + 0.04)) * 0.48;
    _stainedGlass(canvas, leftCx, gfCY, gfW, gfH, lit,
        colors: [_glassBlue, _glassGreen, _glassYellow]);

    // Right stained glass (mirror palette)
    final rightCx = cx + entrW + (w * (_bR - 0.04) - cx - entrW) * 0.48;
    _stainedGlass(canvas, rightCx, gfCY, gfW, gfH, lit,
        colors: [_glassYellow, _glassBlue, _glassGreen]);

    _drawEntrance(canvas, cx, w, h);
  }

  void _stainedGlass(Canvas canvas, double cx, double cy, double ww, double wh,
      bool lit, {required List<Color> colors}) {
    final archR = ww * 0.50;
    canvas.drawPath(_arch(cx, cy, ww + 12, wh + 10, archR + 6),
        Paint()..color = _trimShade);
    canvas.drawPath(_arch(cx, cy, ww + 7,  wh + 5,  archR + 3),
        Paint()..color = _trim);

    final pW = (ww - 8) / 3;
    final pH = wh - 6;
    for (int i = 0; i < 3; i++) {
      final px   = cx - ww / 2 + 4 + pW * i + pW / 2;
      final pTop = cy - wh / 2 + 3;
      final pR   = Rect.fromLTWH(px - pW / 2, pTop, pW, pH);
      final pP   = _arch(px, pTop + pH / 2, pW, pH, pW * 0.50);
      if (lit) {
        canvas.drawPath(pP, Paint()..color = colors[i].withAlpha(218));
        canvas.save();
        canvas.clipPath(pP);
        canvas.drawRect(pR, Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.2, -0.5), radius: 0.8,
            colors: [Colors.white.withAlpha(108), Colors.transparent],
          ).createShader(pR));
        canvas.restore();
      } else {
        canvas.drawPath(pP, Paint()..color = _winDark);
      }
      canvas.drawPath(pP, Paint()
        ..color = _trim..style = PaintingStyle.stroke..strokeWidth = 2.5);
    }
    // Horizontal transom bar
    canvas.drawLine(Offset(cx - ww / 2 + 4, cy + wh * 0.10),
        Offset(cx + ww / 2 - 4, cy + wh * 0.10),
        Paint()..color = _trim..strokeWidth = 2.2);
  }

  void _drawEntrance(Canvas canvas, double cx, double w, double h) {
    final dW   = w * 0.145;
    final dH   = h * 0.138;
    final dTop = h * (_c21 + 0.025);
    final dBot = dTop + dH;

    // Stone pilasters
    for (int s in [-1, 1]) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(cx + s * dW * 0.64, dTop + dH * 0.50),
          width: w * 0.022, height: dH * 1.04,
        ),
        Paint()..color = _trim,
      );
    }
    // Arch surround
    canvas.drawPath(
      _arch(cx, dTop + dH * 0.42, dW * 1.22, dH * 0.96, dW * 0.62),
      Paint()..color = _trim,
    );
    // Two wooden doors
    for (int s in [-1, 1]) {
      final px = cx + s * dW * 0.22;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(px, dTop + dH * 0.58), width: dW * 0.42, height: dH * 0.82),
          const Radius.circular(2),
        ),
        Paint()..color = _doorWood,
      );
      // Panel detail
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(px, dTop + dH * 0.50), width: dW * 0.28, height: dH * 0.28),
          const Radius.circular(1),
        ),
        Paint()..color = _brickDark.withAlpha(45)
          ..style = PaintingStyle.stroke..strokeWidth = 1.4,
      );
      // Knob
      canvas.drawCircle(Offset(cx + s * dW * 0.06, dTop + dH * 0.60), 2.2,
          Paint()..color = const Color(0xFFD4A820));
    }
    // 3 steps
    for (int i = 0; i < 3; i++) {
      final sW = dW * (1.78 - i * 0.22);
      final sH = h * 0.020;
      final sY = dBot + (2 - i) * sH;
      canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, sY + sH / 2), width: sW, height: sH),
        Paint()..color = _trim,
      );
      canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, sY + sH / 2), width: sW, height: sH),
        Paint()..color = _trimDark.withAlpha(65)
          ..style = PaintingStyle.stroke..strokeWidth = 0.8,
      );
    }
  }

  // ── Golden glow overlay (fill animation) ─────────────────────────────────────
  void _drawGlowOverlay(Canvas canvas, double w, double h) {
    if (fillFraction <= 0.005) return;

    final bBot    = h * _bBot;
    final bTop    = h * _lgApex;
    final glowTop = bBot - (bBot - bTop) * fillFraction;

    canvas.save();
    canvas.clipPath(_clip(w, h));

    final pulse    = (math.sin(glowPhase * 2 * math.pi) * 0.08 + 0.92).clamp(0.80, 1.0);
    final hotAlpha = (200 * pulse).round();
    final warmAlpha= (160 * pulse).round();
    final glowRect = Rect.fromLTRB(w * _bL, glowTop, w * _bR, bBot);

    canvas.drawRect(glowRect, Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
        colors: [
          _glowHot.withAlpha(hotAlpha), _glowWarm.withAlpha(warmAlpha),
          _glowCool.withAlpha(100), Colors.transparent,
        ],
        stops: const [0.0, 0.35, 0.70, 1.0],
      ).createShader(glowRect));

    if (fillFraction > 0.015) {
      final sr = Rect.fromLTWH(w * _bL, glowTop - 3, w * (_bR - _bL), 6);
      canvas.drawRect(sr, Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft, end: Alignment.centerRight,
          colors: [
            Colors.transparent,
            Colors.white.withAlpha(155), Colors.white.withAlpha(200),
            Colors.white.withAlpha(155), Colors.transparent,
          ],
          stops: const [0.0, 0.25, 0.50, 0.75, 1.0],
        ).createShader(sr));
    }
    canvas.restore();
  }

  // ── Edge depth shadows ────────────────────────────────────────────────────────
  void _drawEdgeShadows(Canvas canvas, double w, double h) {
    final sL = Rect.fromLTWH(w * _bL, h * 0.10, w * 0.038, h * 0.70);
    canvas.drawRect(sL, Paint()
      ..shader = LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight,
        colors: [Colors.black.withAlpha(68), Colors.transparent]).createShader(sL));

    final sR = Rect.fromLTWH(w * _bR - w * 0.038, h * 0.10, w * 0.038, h * 0.70);
    canvas.drawRect(sR, Paint()
      ..shader = LinearGradient(begin: Alignment.centerRight, end: Alignment.centerLeft,
        colors: [Colors.black.withAlpha(48), Colors.transparent]).createShader(sR));
  }

  // ── Front perimeter wall + gate ───────────────────────────────────────────────
  void _drawFrontFence(Canvas canvas, double w, double h) {
    final fTop = h * _bBot;
    final fH   = h * 0.100;
    final cx   = w * 0.50;

    final wr = Rect.fromLTWH(0, fTop, w, fH);
    canvas.drawRect(wr, Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: const [_fenceBrick, _brickDark]).createShader(wr));

    final mP = Paint()..color = _brickDark.withAlpha(60)..strokeWidth = 0.9;
    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(0, fTop + fH * i / 4), Offset(w, fTop + fH * i / 4), mP);
    }

    // White capping
    canvas.drawRect(Rect.fromLTWH(0, fTop, w, h * 0.010), Paint()..color = _trim);
    canvas.drawRect(Rect.fromLTWH(0, fTop + h * 0.010, w, h * 0.005),
        Paint()..color = _trimDark.withAlpha(75));

    // Gate opening
    final gW = w * 0.195;
    canvas.drawRect(Rect.fromLTWH(cx - gW / 2, fTop, gW, fH * 0.86),
        Paint()..color = _skyBot);

    // Two square pillars
    final pW = w * 0.030;
    for (int s in [-1, 1]) {
      final px = cx + s * (gW / 2 + pW * 0.65);
      canvas.drawRect(
        Rect.fromCenter(center: Offset(px, fTop + fH * 0.48), width: pW, height: fH * 0.96),
        Paint()..color = _trim,
      );
      canvas.drawRect(
        Rect.fromCenter(center: Offset(px, fTop + fH * 0.48), width: pW, height: fH * 0.96),
        Paint()..color = _trimDark.withAlpha(50)
          ..style = PaintingStyle.stroke..strokeWidth = 0.7,
      );
      // Ball finial
      canvas.drawCircle(Offset(px, fTop - h * 0.007), 7.5, Paint()..color = _trimShade);
      canvas.drawCircle(Offset(px, fTop - h * 0.007), 6.0, Paint()..color = _trim);
      canvas.drawCircle(Offset(px, fTop - h * 0.011), 2.4,
          Paint()..color = Colors.white.withAlpha(105));
    }
  }

  // ── Ground shadow ─────────────────────────────────────────────────────────────
  void _drawGroundShadow(Canvas canvas, double w, double h) {
    for (int i = 4; i >= 0; i--) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(w * 0.50, h * 0.965),
          width: w * 0.88 + i * 5, height: h * 0.022 + i * 2,
        ),
        Paint()..color = const Color(0xFF1A0800).withAlpha(7 + i * 3),
      );
    }
  }

  // ── Arch-topped window path helper ───────────────────────────────────────────
  Path _arch(double cx, double cy, double ww, double wh, double archR) {
    final l = cx - ww / 2; final r = cx + ww / 2;
    final t = cy - wh / 2; final b = cy + wh / 2;
    return Path()
      ..moveTo(l, b)
      ..lineTo(l, t + archR)
      ..arcTo(Rect.fromCenter(center: Offset(cx, t + archR), width: ww, height: archR * 2),
          math.pi, math.pi, false)
      ..lineTo(r, b)
      ..close();
  }

  @override
  bool shouldRepaint(Building770Painter old) =>
      old.fillFraction != fillFraction || old.glowPhase != glowPhase;
}
