import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Oblique-projection illustration of 770 Eastern Parkway.
///
/// Two visible faces give immediate depth perception without real 3D:
///   • Front face  — the full facade (brick, gables, windows, entrance)
///   • Left side face — recedes up-left at a fixed angle, darker shading
///
/// [fillFraction] 0.0–1.0 drives the golden glow that rises from the bottom.
/// [glowPhase]   0.0–1.0 animates the shimmer shimmer on the fill edge.
class Building770Painter extends CustomPainter {
  final double fillFraction;
  final double glowPhase;

  const Building770Painter({required this.fillFraction, this.glowPhase = 0});

  // ── Palette ──────────────────────────────────────────────────────────────────
  static const _brickF  = Color(0xFFC1440E); // front face brick
  static const _brickS  = Color(0xFF7A2806); // side face brick (in shadow)
  static const _brickH  = Color(0xFFD05A30); // highlight brick (lit areas)
  static const _brickD  = Color(0xFF5C1C02); // deep shadow brick
  static const _trim    = Color(0xFFF5F0E8); // stone cream
  static const _trimSh  = Color(0xFFCEC3AB); // stone in shadow
  static const _trimD   = Color(0xFFAA9880); // stone edge shadow
  static const _winDark = Color(0xFF120A04); // unlit window
  static const _winLit  = Color(0xFFFFDD88); // lit window warm
  static const _wood    = Color(0xFF5C3010); // door wood
  static const _skyT    = Color(0xFFBDD4E8);
  static const _skyB    = Color(0xFFE8EFF4);
  static const _glowHot = Color(0xFFFFAA00);
  static const _glowWrm = Color(0xFFFFD060);
  static const _glowCl  = Color(0xFFFFF0B0);
  static const _glBlue  = Color(0xFF1A56A8);
  static const _glGreen = Color(0xFF2A8040);
  static const _glYellow= Color(0xFFE8B800);
  static const _fenceB  = Color(0xFFAA3308);

  // ── Layout (all fractions of canvas w/h) ─────────────────────────────────────
  // Front face rectangle
  static const double _fL   = 0.23;  // front left
  static const double _fR   = 0.975; // front right
  static const double _fTop = 0.225; // gable base Y (top of main wall)
  static const double _fBot = 0.815; // bottom of main wall

  // Side face recession (each front-face left-edge point shifts by this amount)
  static const double _sX = 0.145; // leftward recession (fraction of w)
  static const double _sY = 0.090; // upward recession (fraction of h)

  // Derived side face edges
  static const double _sL    = _fL - _sX;   // = 0.085
  static const double _sTop  = _fTop - _sY; // = 0.135
  static const double _sBot  = _fBot - _sY; // = 0.725

  // Front face width
  static const double _bW = _fR - _fL; // = 0.745

  // Three gable centers (fraction of w) and half-widths
  static const double _lgCX  = _fL + _bW * 0.225; // left gable CX   ≈ 0.398
  static const double _cgCX  = _fL + _bW * 0.500; // center gable CX ≈ 0.603
  static const double _rgCX  = _fL + _bW * 0.775; // right gable CX  ≈ 0.807
  static const double _lgHW  = _bW * 0.170;        // large half-width ≈ 0.127
  static const double _cgHW  = _bW * 0.088;        // center half-width≈ 0.066
  static const double _lgAp  = 0.040;              // large gable apex Y
  static const double _cgAp  = 0.076;              // center gable apex Y

  // Floor cornice Y fractions
  static const double _c32 = 0.430; // 3rd→2nd floor
  static const double _c21 = 0.628; // 2nd→1st floor
  static const double _cPl = 0.800; // base plinth

  // ── paint ────────────────────────────────────────────────────────────────────
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    _drawSky(canvas, w, h);
    _drawGroundShadow(canvas, w, h);
    _drawSideFace(canvas, w, h);
    _drawFrontFace(canvas, w, h);
    _drawSideBrickPattern(canvas, w, h);
    _drawFrontBrickPattern(canvas, w, h);
    _drawSideCornices(canvas, w, h);
    _drawFrontCornices(canvas, w, h);
    _drawGables(canvas, w, h);
    _drawQuoins(canvas, w, h);
    _drawThirdFloorWindows(canvas, w, h);
    _drawSecondFloor(canvas, w, h);
    _drawGroundFloor(canvas, w, h);
    _drawGlowOverlay(canvas, w, h);
    _drawEdgeShadows(canvas, w, h);
    _drawFence(canvas, w, h);
  }

  // ── Clip paths ───────────────────────────────────────────────────────────────

  Path _frontFaceClip(double w, double h) {
    final fL = w * _fL; final fR = w * _fR;
    final fTop = h * _fTop; final fBot = h * _fBot;
    final p = Path();
    p.moveTo(fR, fBot);
    p.lineTo(fR, fTop);
    p.lineTo(w * (_rgCX + _lgHW), fTop);
    p.lineTo(w * _rgCX, h * _lgAp);
    p.lineTo(w * (_rgCX - _lgHW), fTop);
    p.lineTo(w * (_cgCX + _cgHW), fTop);
    p.lineTo(w * _cgCX, h * _cgAp);
    p.lineTo(w * (_cgCX - _cgHW), fTop);
    p.lineTo(w * (_lgCX + _lgHW), fTop);
    p.lineTo(w * _lgCX, h * _lgAp);
    p.lineTo(w * (_lgCX - _lgHW), fTop);
    p.lineTo(fL, fTop);
    p.lineTo(fL, fBot);
    p.close();
    return p;
  }

  Path _sideFaceClip(double w, double h) {
    final fL = w * _fL; final fBot = h * _fBot; final fTop = h * _fTop;
    final sL = w * _sL; final sTop = h * _sTop; final sBot = h * _sBot;
    return Path()
      ..moveTo(fL, fTop)
      ..lineTo(sL, sTop)
      ..lineTo(sL, sBot)
      ..lineTo(fL, fBot)
      ..close();
  }

  // ── Sky ──────────────────────────────────────────────────────────────────────
  void _drawSky(Canvas canvas, double w, double h) {
    final r = Rect.fromLTWH(0, 0, w, h * 0.28);
    canvas.drawRect(r, Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [_skyT, _skyB],
      ).createShader(r));
  }

  void _drawGroundShadow(Canvas canvas, double w, double h) {
    for (int i = 5; i >= 0; i--) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(w * 0.55, h * 0.965),
            width: w * 0.82 + i * 5, height: h * 0.020 + i * 2),
        Paint()..color = const Color(0xFF1A0800).withAlpha(6 + i * 3),
      );
    }
  }

  // ── Side face (left, darker — in shadow) ─────────────────────────────────────
  void _drawSideFace(Canvas canvas, double w, double h) {
    final clip = _sideFaceClip(w, h);
    final bounds = Rect.fromLTRB(w * _sL, h * _sTop, w * _fL, h * _fBot);

    // Base brick color (darker — shadow side)
    canvas.drawPath(clip, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: const [_brickD, _brickS, _brickS, _brickD],
        stops: const [0.0, 0.15, 0.80, 1.0],
      ).createShader(bounds));

    // Left-edge vignette
    final se = Rect.fromLTRB(w * _sL, h * _sTop, w * (_sL + 0.03), h * _sBot);
    canvas.drawRect(se, Paint()
      ..shader = LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight,
        colors: [Colors.black.withAlpha(80), Colors.transparent]).createShader(se));
  }

  // ── Side face brick mortar ────────────────────────────────────────────────────
  void _drawSideBrickPattern(Canvas canvas, double w, double h) {
    canvas.save();
    canvas.clipPath(_sideFaceClip(w, h));

    final sL = w * _sL; final sR = w * _fL;
    final sTop = h * _sTop; final sBot = h * _sBot;
    final courseH = h * 0.017;
    final p = Paint()..color = _brickD.withAlpha(55)..strokeWidth = 0.7;
    var y = sTop;
    // Horizontal mortar lines run parallel to the side face angle
    // In cabinet projection the side lines are perfectly horizontal too.
    while (y < sBot) {
      canvas.drawLine(Offset(sL, y - (y - sTop) * 0), Offset(sR, y), p);
      y += courseH;
    }
    canvas.restore();
  }

  // ── Front face (main facade) ──────────────────────────────────────────────────
  void _drawFrontFace(Canvas canvas, double w, double h) {
    final clip = _frontFaceClip(w, h);
    final r = Rect.fromLTRB(w * _fL, h * _lgAp, w * _fR, h * _fBot);

    canvas.drawPath(clip, Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft, end: Alignment.centerRight,
        colors: const [_brickS, _brickF, _brickH, _brickF, _brickS],
        stops: const [0.0, 0.08, 0.50, 0.92, 1.0],
      ).createShader(r));

    canvas.drawPath(clip, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [
          Colors.black.withAlpha(55), Colors.transparent,
          Colors.transparent, Colors.black.withAlpha(22),
        ],
        stops: const [0.0, 0.12, 0.82, 1.0],
      ).createShader(r));
  }

  // ── Front face brick mortar pattern ──────────────────────────────────────────
  void _drawFrontBrickPattern(Canvas canvas, double w, double h) {
    canvas.save();
    canvas.clipPath(_frontFaceClip(w, h));

    final fL = w * _fL; final fR = w * _fR;
    final fTop = h * _lgAp; final fBot = h * _fBot;
    final cH = h * 0.016;
    final hP = Paint()..color = _brickD.withAlpha(38)..strokeWidth = 0.7;
    var y = fTop;
    while (y < fBot) { canvas.drawLine(Offset(fL, y), Offset(fR, y), hP); y += cH; }

    final vP = Paint()..color = _brickD.withAlpha(18)..strokeWidth = 0.5;
    final bW = w * 0.048; var row = 0; y = fTop;
    while (y < fBot) {
      final off = (row % 2 == 0) ? 0.0 : bW / 2;
      var x = fL + off;
      while (x < fR) { canvas.drawLine(Offset(x, y), Offset(x, y + cH), vP); x += bW; }
      y += cH; row++;
    }
    canvas.restore();
  }

  // ── Side face cornice bands (wrap around corner) ──────────────────────────────
  void _drawSideCornices(Canvas canvas, double w, double h) {
    final fL = w * _fL;
    final sL = w * _sL;

    void sideBand(double yFrac) {
      final yF = h * yFrac;
      final yS = yF - h * _sY; // same cornice on side face goes up by _sY
      // Side face cornice is a parallelogram strip
      canvas.drawPath(
        Path()
          ..moveTo(sL, yS)
          ..lineTo(fL, yF)
          ..lineTo(fL, yF + h * 0.022)
          ..lineTo(sL, yS + h * 0.022)
          ..close(),
        Paint()..color = _trimSh,
      );
      canvas.drawPath(
        Path()
          ..moveTo(sL, yS + h * 0.022)
          ..lineTo(fL, yF + h * 0.022)
          ..lineTo(fL, yF + h * 0.028)
          ..lineTo(sL, yS + h * 0.028)
          ..close(),
        Paint()..color = _trimD.withAlpha(80),
      );
    }

    sideBand(0.222);
    sideBand(_c32);
    sideBand(_c21);
    sideBand(_cPl);
  }

  // ── Front face cornice bands ──────────────────────────────────────────────────
  void _drawFrontCornices(Canvas canvas, double w, double h) {
    final fL = w * _fL; final fR = w * _fR;
    final bW2 = fR - fL;

    void band(double yFrac) {
      final y = h * yFrac;
      canvas.drawRect(Rect.fromLTWH(fL, y, bW2, h * 0.022), Paint()..color = _trim);
      canvas.drawRect(Rect.fromLTWH(fL, y + h * 0.022, bW2, h * 0.006),
          Paint()..color = _trimD.withAlpha(75));
      canvas.drawRect(Rect.fromLTWH(fL, y, bW2, h * 0.004),
          Paint()..color = Colors.white.withAlpha(65));
    }
    band(0.222);
    band(_c32);
    band(_c21);
    band(_cPl);
  }

  // ── Three Gothic gables ───────────────────────────────────────────────────────
  void _drawGables(Canvas canvas, double w, double h) {
    final fTop = h * _fTop;
    final fL = w * _fL;

    // Left gable side face (visible left side of the gable prism)
    final lgApexFront = Offset(w * _lgCX, h * _lgAp);
    final lgBaseLeft  = Offset(w * (_lgCX - _lgHW), fTop);
    // Project left base point onto side face plane
    final lgSideApex  = Offset(lgApexFront.dx - w * _sX * 0.55, lgApexFront.dy - h * _sY * 0.55);
    final lgSideBase  = Offset(lgBaseLeft.dx - w * _sX * 0.55, lgBaseLeft.dy - h * _sY * 0.55);

    // Only draw side face of left gable (it's visible from our viewing angle)
    if (lgBaseLeft.dx > fL) {
      canvas.drawPath(
        Path()
          ..moveTo(lgApexFront.dx, lgApexFront.dy)
          ..lineTo(lgBaseLeft.dx,  lgBaseLeft.dy)
          ..lineTo(lgSideBase.dx,  lgSideBase.dy)
          ..lineTo(lgSideApex.dx,  lgSideApex.dy)
          ..close(),
        Paint()..color = _brickS.withAlpha(200),
      );
    }

    void gable(double cx, double apexY, double halfW, bool large) {
      final base = h * _fTop;
      final ap   = h * apexY;
      final hW   = w * halfW;

      final tri = Path()
        ..moveTo(cx - hW, base)..lineTo(cx, ap)..lineTo(cx + hW, base)..close();

      canvas.drawPath(tri, Paint()
        ..color = _trim..style = PaintingStyle.stroke
        ..strokeWidth = large ? 5.5 : 4.0);
      canvas.drawPath(tri, Paint()
        ..color = _trimSh..style = PaintingStyle.stroke
        ..strokeWidth = large ? 2.5 : 1.8);

      // Finial ball
      final r = large ? 7.5 : 5.5;
      canvas.drawCircle(Offset(cx, ap), r + 1.5, Paint()..color = _trimSh);
      canvas.drawCircle(Offset(cx, ap), r, Paint()..color = _trim);
      canvas.drawCircle(Offset(cx, ap - 1.5), r * 0.40,
          Paint()..color = Colors.white.withAlpha(100));

      // Medallion
      if (large) {
        final mY = ap + (base - ap) * 0.52;
        canvas.drawCircle(Offset(cx, mY), w * 0.030, Paint()..color = _trimSh);
        canvas.drawCircle(Offset(cx, mY), w * 0.023, Paint()..color = _trim);
        canvas.drawCircle(Offset(cx, mY), w * 0.014,
            Paint()..color = _brickF.withAlpha(85));
      }
    }

    gable(w * _lgCX, _lgAp, _lgHW, true);
    gable(w * _cgCX, _cgAp, _cgHW, false);
    gable(w * _rgCX, _lgAp, _lgHW, true);
  }

  // ── Quoins (corner stone blocks on front-face left edge) ─────────────────────
  void _drawQuoins(Canvas canvas, double w, double h) {
    final fL = w * _fL; final fR = w * _fR;
    final qW = w * 0.038; final qH = h * 0.032; final qGap = h * 0.015;
    var y = h * _fTop + 5; var lo = true;
    while (y < h * _fBot - qH) {
      final thisW = lo ? qW : qW * 0.62;
      // Front face right edge quoins
      canvas.drawRect(Rect.fromLTWH(fR - thisW, y, thisW, qH), Paint()..color = _trim);
      canvas.drawRect(Rect.fromLTWH(fR - thisW, y, thisW, qH),
          Paint()..color = _trimD.withAlpha(50)..style = PaintingStyle.stroke..strokeWidth = 0.6);
      // Front face left edge quoins (corner between front and side)
      canvas.drawRect(Rect.fromLTWH(fL, y, thisW, qH), Paint()..color = _trimSh);
      canvas.drawRect(Rect.fromLTWH(fL, y, thisW, qH),
          Paint()..color = _trimD.withAlpha(50)..style = PaintingStyle.stroke..strokeWidth = 0.6);
      y += qH + qGap; lo = !lo;
    }
  }

  // ── 3rd floor: groups of 3 narrow windows under each gable ───────────────────
  void _drawThirdFloorWindows(Canvas canvas, double w, double h) {
    final lit = fillFraction > 0.72;
    final wCY = h * ((_fTop + _c32) / 2);

    for (final gCX in [w * _lgCX, w * _rgCX]) {
      for (int i = -1; i <= 1; i++) {
        _narrowWin(canvas, gCX + w * 0.065 * i, wCY, w * 0.050, h * 0.100, lit);
      }
    }
    for (int i = -1; i <= 1; i++) {
      _narrowWin(canvas, w * _cgCX + w * 0.052 * i, wCY, w * 0.038, h * 0.085, lit);
    }
  }

  void _narrowWin(Canvas canvas, double cx, double cy, double ww, double wh, bool lit) {
    final out = Rect.fromCenter(center: Offset(cx, cy), width: ww + 8, height: wh + 6);
    final mid = Rect.fromCenter(center: Offset(cx, cy), width: ww + 5, height: wh + 3);
    final inn = Rect.fromCenter(center: Offset(cx, cy), width: ww - 4, height: wh - 4);
    canvas.drawRRect(RRect.fromRectAndRadius(out, const Radius.circular(1.5)), Paint()..color = _trimSh);
    canvas.drawRRect(RRect.fromRectAndRadius(mid, const Radius.circular(1.5)), Paint()..color = _trim);
    canvas.drawRect(inn, Paint()..color = lit ? _winLit.withAlpha(195) : _winDark);
    if (lit) {
      canvas.drawRect(inn, Paint()
        ..shader = RadialGradient(center: const Alignment(-0.2, -0.4), radius: 0.8,
          colors: [Colors.white.withAlpha(85), Colors.transparent]).createShader(inn));
    }
    final dp = Paint()..color = _trim.withAlpha(lit ? 145 : 210)..strokeWidth = 1.6;
    canvas.drawLine(Offset(inn.left, cy), Offset(inn.right, cy), dp);
    canvas.drawLine(Offset(cx, inn.top), Offset(cx, inn.bottom),
        Paint()..color = _trim.withAlpha(lit ? 85 : 130)..strokeWidth = 1.0);
  }

  // ── 2nd floor: bay window + side windows ─────────────────────────────────────
  void _drawSecondFloor(Canvas canvas, double w, double h) {
    final lit = fillFraction > 0.44;
    _drawBayWindow(canvas, w, h, lit);

    final sCY = h * ((_c32 + _c21) / 2 + 0.010);
    final sWW = w * 0.085;
    final sWH = h * 0.108;
    final iL  = w * (_fL + 0.040);
    final iR  = w * (_fR - 0.008);
    final bayHalf = w * 0.120;
    final cx  = w * (_fL + _bW * 0.500);
    final leftW  = cx - bayHalf - iL;
    final rStart = cx + bayHalf;
    final rightW = iR - rStart;

    _classicWin(canvas, iL + leftW * 0.25, sCY, sWW, sWH, lit);
    _classicWin(canvas, iL + leftW * 0.72, sCY, sWW, sWH, lit);
    _classicWin(canvas, rStart + rightW * 0.28, sCY, sWW, sWH, lit);
    _classicWin(canvas, rStart + rightW * 0.75, sCY, sWW, sWH, lit);

    // Side face 2nd floor window (one visible on the side face)
    final sWinCX = w * _fL - w * _sX * 0.50;
    final sWinCY = sCY - h * _sY * 0.50;
    _sideWin(canvas, sWinCX, sWinCY, w * 0.042, h * 0.090, lit);
  }

  void _drawBayWindow(Canvas canvas, double w, double h, bool lit) {
    final cx    = w * (_fL + _bW * 0.500);
    final faceW = w * 0.178;
    final faceH = h * 0.155;
    final top   = h * (_c32 + 0.026);
    final bot   = top + faceH;
    final mid   = (top + bot) / 2;
    final sideD = w * 0.030; // how far bay protrudes
    final sideH = faceH + h * 0.018;

    // LEFT side face of bay (deeper shadow, very visible — this is key depth cue)
    canvas.drawPath(
      Path()
        ..moveTo(cx - faceW / 2, top - h * 0.010)
        ..lineTo(cx - faceW / 2 - sideD, top + h * 0.016)
        ..lineTo(cx - faceW / 2 - sideD, top + sideH)
        ..lineTo(cx - faceW / 2, bot)
        ..close(),
      Paint()..color = _brickD.withAlpha(185),
    );
    // RIGHT side face
    canvas.drawPath(
      Path()
        ..moveTo(cx + faceW / 2, top - h * 0.010)
        ..lineTo(cx + faceW / 2 + sideD, top + h * 0.016)
        ..lineTo(cx + faceW / 2 + sideD, top + sideH)
        ..lineTo(cx + faceW / 2, bot)
        ..close(),
      Paint()..color = _brickD.withAlpha(120),
    );

    // Front face of bay
    final fR2 = Rect.fromLTWH(cx - faceW / 2, top, faceW, faceH);
    canvas.drawRect(fR2, Paint()..color = _brickH.withAlpha(235));
    canvas.drawRect(fR2, Paint()
      ..color = _trim..style = PaintingStyle.stroke..strokeWidth = 5.5);

    // 3 stained glass panels
    final pW = faceW * 0.280; final pH = faceH * 0.670;
    final pCY = mid + faceH * 0.055;
    final offsets = [-faceW * 0.295, 0.0, faceW * 0.295];
    final colors  = [_glGreen, _glBlue, _glYellow];
    for (int i = 0; i < 3; i++) {
      final px = cx + offsets[i];
      final pr = Rect.fromCenter(center: Offset(px, pCY), width: pW, height: pH);
      final fp = _arch(px, pCY, pW + 5, pH + 5, pW * 0.52);
      final gp = _arch(px, pCY, pW - 2, pH - 2, pW * 0.46);
      canvas.drawPath(fp, Paint()..color = _trim);
      if (lit) {
        canvas.drawPath(gp, Paint()..color = colors[i].withAlpha(220));
        canvas.save(); canvas.clipPath(gp);
        canvas.drawRect(pr, Paint()
          ..shader = RadialGradient(center: const Alignment(-0.3, -0.5), radius: 0.85,
            colors: [Colors.white.withAlpha(115), Colors.transparent]).createShader(pr));
        canvas.restore();
      } else {
        canvas.drawPath(gp, Paint()..color = _winDark);
      }
    }

    // Pediment
    final pedHW = faceW * 0.56; final pedH = h * 0.034;
    canvas.drawPath(
      Path()..moveTo(cx - pedHW, top)..lineTo(cx, top - pedH)..lineTo(cx + pedHW, top)..close(),
      Paint()..color = _trim,
    );
    canvas.drawPath(
      Path()..moveTo(cx - pedHW, top)..lineTo(cx, top - pedH)..lineTo(cx + pedHW, top)..close(),
      Paint()..color = _trimSh..style = PaintingStyle.stroke..strokeWidth = 2.0,
    );
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx, top), width: faceW * 1.10, height: h * 0.046),
      math.pi, math.pi, false,
      Paint()..color = _trim..style = PaintingStyle.stroke..strokeWidth = 4.5,
    );
  }

  void _classicWin(Canvas canvas, double cx, double cy, double ww, double wh, bool lit) {
    final out = Rect.fromCenter(center: Offset(cx, cy), width: ww + 10, height: wh + 8);
    final mid = Rect.fromCenter(center: Offset(cx, cy), width: ww + 6,  height: wh + 4);
    final inn = Rect.fromCenter(center: Offset(cx, cy), width: ww - 4,  height: wh - 4);
    canvas.drawRRect(RRect.fromRectAndRadius(out, const Radius.circular(2)), Paint()..color = _trimSh);
    canvas.drawRRect(RRect.fromRectAndRadius(mid, const Radius.circular(2)), Paint()..color = _trim);
    canvas.drawRect(inn, Paint()..color = lit ? _winLit.withAlpha(195) : _winDark);
    if (lit) {
      canvas.drawRect(inn, Paint()
        ..shader = RadialGradient(center: const Alignment(-0.3, -0.3), radius: 0.9,
          colors: [Colors.white.withAlpha(80), Colors.transparent]).createShader(inn));
    }
    final dp = Paint()..color = _trim.withAlpha(lit ? 155 : 225)..strokeWidth = 1.8;
    canvas.drawLine(Offset(cx, inn.top), Offset(cx, inn.bottom), dp);
    canvas.drawLine(Offset(inn.left, cy), Offset(inn.right, cy), dp);
  }

  void _sideWin(Canvas canvas, double cx, double cy, double ww, double wh, bool lit) {
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, cy), width: ww + 4, height: wh + 4),
      Paint()..color = _trimSh,
    );
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, cy), width: ww, height: wh),
      Paint()..color = lit ? _winLit.withAlpha(140) : _winDark.withAlpha(180),
    );
  }

  // ── Ground floor: stained glass + entrance ────────────────────────────────────
  void _drawGroundFloor(Canvas canvas, double w, double h) {
    final lit  = fillFraction > 0.06;
    final cx   = w * (_fL + _bW * 0.500);
    final gCY  = h * ((_c21 + _cPl) / 2 + 0.008);
    final gH   = h * 0.122;
    final gW   = w * 0.162;
    final eHW  = w * 0.075; // entrance half-width

    final lCX = cx - eHW - (cx - eHW - w * (_fL + 0.042)) * 0.52;
    _stainedGlass(canvas, lCX, gCY, gW, gH, lit,
        colors: [_glBlue, _glGreen, _glYellow]);

    final rCX = cx + eHW + (w * (_fR - 0.010) - cx - eHW) * 0.52;
    _stainedGlass(canvas, rCX, gCY, gW, gH, lit,
        colors: [_glYellow, _glBlue, _glGreen]);

    _drawEntrance(canvas, cx, w, h);

    // Side face ground floor window
    final swCX = w * _fL - w * _sX * 0.45;
    final swCY = gCY - h * _sY * 0.45;
    _sideWin(canvas, swCX, swCY, w * 0.038, h * 0.080, lit);
  }

  void _stainedGlass(Canvas canvas, double cx, double cy, double ww, double wh,
      bool lit, {required List<Color> colors}) {
    final aR = ww * 0.50;
    canvas.drawPath(_arch(cx, cy, ww + 12, wh + 10, aR + 6), Paint()..color = _trimSh);
    canvas.drawPath(_arch(cx, cy, ww + 7,  wh + 5,  aR + 3), Paint()..color = _trim);
    final pW = (ww - 8) / 3; final pH = wh - 6;
    for (int i = 0; i < 3; i++) {
      final px  = cx - ww / 2 + 4 + pW * i + pW / 2;
      final pT  = cy - wh / 2 + 3;
      final pR  = Rect.fromLTWH(px - pW / 2, pT, pW, pH);
      final pP  = _arch(px, pT + pH / 2, pW, pH, pW * 0.50);
      if (lit) {
        canvas.drawPath(pP, Paint()..color = colors[i].withAlpha(218));
        canvas.save(); canvas.clipPath(pP);
        canvas.drawRect(pR, Paint()
          ..shader = RadialGradient(center: const Alignment(-0.2, -0.5), radius: 0.8,
            colors: [Colors.white.withAlpha(105), Colors.transparent]).createShader(pR));
        canvas.restore();
      } else {
        canvas.drawPath(pP, Paint()..color = _winDark);
      }
      canvas.drawPath(pP, Paint()
        ..color = _trim..style = PaintingStyle.stroke..strokeWidth = 2.5);
    }
    canvas.drawLine(Offset(cx - ww / 2 + 4, cy + wh * 0.10),
        Offset(cx + ww / 2 - 4, cy + wh * 0.10),
        Paint()..color = _trim..strokeWidth = 2.0);
  }

  void _drawEntrance(Canvas canvas, double cx, double w, double h) {
    final dW  = w * 0.138;
    final dH  = h * 0.130;
    final dT  = h * (_c21 + 0.026);
    final dB  = dT + dH;

    for (int s in [-1, 1]) {
      canvas.drawRect(Rect.fromCenter(
        center: Offset(cx + s * dW * 0.64, dT + dH * 0.50), width: w * 0.020, height: dH * 1.03),
        Paint()..color = _trim);
    }
    canvas.drawPath(_arch(cx, dT + dH * 0.42, dW * 1.20, dH * 0.94, dW * 0.60), Paint()..color = _trim);

    for (int s in [-1, 1]) {
      final px = cx + s * dW * 0.22;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(px, dT + dH * 0.58),
            width: dW * 0.42, height: dH * 0.80), const Radius.circular(2)),
        Paint()..color = _wood);
      canvas.drawCircle(Offset(cx + s * dW * 0.06, dT + dH * 0.60), 2.2,
          Paint()..color = const Color(0xFFD4A820));
    }
    for (int i = 0; i < 3; i++) {
      final sW = dW * (1.75 - i * 0.22);
      final sH = h * 0.019;
      final sY = dB + (2 - i) * sH;
      canvas.drawRect(Rect.fromCenter(center: Offset(cx, sY + sH / 2), width: sW, height: sH),
          Paint()..color = _trim);
      canvas.drawRect(Rect.fromCenter(center: Offset(cx, sY + sH / 2), width: sW, height: sH),
          Paint()..color = _trimD.withAlpha(60)..style = PaintingStyle.stroke..strokeWidth = 0.7);
    }
  }

  // ── Golden glow fill animation ────────────────────────────────────────────────
  void _drawGlowOverlay(Canvas canvas, double w, double h) {
    if (fillFraction <= 0.005) return;

    final bBot = h * _fBot;
    final bTop = h * _lgAp;
    final glowTop = bBot - (bBot - bTop) * fillFraction;

    final pulse    = (math.sin(glowPhase * 2 * math.pi) * 0.08 + 0.92).clamp(0.80, 1.0);
    final hotA     = (200 * pulse).round();
    final warmA    = (160 * pulse).round();

    // Front face glow
    canvas.save();
    canvas.clipPath(_frontFaceClip(w, h));
    final fGlow = Rect.fromLTRB(w * _fL, glowTop, w * _fR, bBot);
    canvas.drawRect(fGlow, Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
        colors: [_glowHot.withAlpha(hotA), _glowWrm.withAlpha(warmA),
          _glowCl.withAlpha(100), Colors.transparent],
        stops: const [0.0, 0.35, 0.70, 1.0],
      ).createShader(fGlow));
    canvas.restore();

    // Side face glow (slightly darker — it's in shadow)
    canvas.save();
    canvas.clipPath(_sideFaceClip(w, h));
    final sGlowTop = glowTop - h * _sY * fillFraction;
    final sBotY    = h * _sBot;
    if (sGlowTop < sBotY) {
      final sGlow = Rect.fromLTRB(w * _sL, sGlowTop, w * _fL, sBotY);
      canvas.drawRect(sGlow, Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter, end: Alignment.topCenter,
          colors: [_glowHot.withAlpha((hotA * 0.55).round()), _glowWrm.withAlpha((warmA * 0.40).round()),
            Colors.transparent],
          stops: const [0.0, 0.50, 1.0],
        ).createShader(sGlow));
    }
    canvas.restore();

    // Shimmer line at fill edge
    if (fillFraction > 0.015) {
      final sr = Rect.fromLTWH(w * _fL, glowTop - 3, w * (_fR - _fL), 6);
      canvas.drawRect(sr, Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft, end: Alignment.centerRight,
          colors: [Colors.transparent, Colors.white.withAlpha(150),
            Colors.white.withAlpha(195), Colors.white.withAlpha(150), Colors.transparent],
          stops: const [0.0, 0.25, 0.50, 0.75, 1.0],
        ).createShader(sr));
    }
  }

  // ── Edge shadows ──────────────────────────────────────────────────────────────
  void _drawEdgeShadows(Canvas canvas, double w, double h) {
    // Right edge
    final sr = Rect.fromLTWH(w * _fR - w * 0.035, h * 0.10, w * 0.035, h * 0.70);
    canvas.drawRect(sr, Paint()
      ..shader = LinearGradient(begin: Alignment.centerRight, end: Alignment.centerLeft,
        colors: [Colors.black.withAlpha(50), Colors.transparent]).createShader(sr));
    // Corner edge (front/side junction)
    final sc = Rect.fromLTWH(w * _fL - w * 0.005, h * 0.10, w * 0.010, h * 0.70);
    canvas.drawRect(sc, Paint()..color = Colors.black.withAlpha(55));
  }

  // ── Front fence with gate + pillars ──────────────────────────────────────────
  void _drawFence(Canvas canvas, double w, double h) {
    final fTop = h * _fBot;
    final fH   = h * 0.098;
    final cx   = w * (_fL + _bW * 0.500);

    // Side face of fence (3D wrap-around)
    final sfPath = Path()
      ..moveTo(w * _fL, fTop)
      ..lineTo(w * _sL, fTop - h * _sY)
      ..lineTo(w * _sL, fTop - h * _sY + fH * 0.85)
      ..lineTo(w * _fL, fTop + fH * 0.85)
      ..close();
    canvas.drawPath(sfPath, Paint()..color = _brickS.withAlpha(220));
    canvas.drawRect(Rect.fromLTWH(w * _sL, fTop - h * _sY, w * _sX, h * 0.008),
        Paint()..color = _trimSh);

    // Front fence wall
    final wr = Rect.fromLTWH(w * _fL, fTop, w * (_fR - _fL), fH);
    canvas.drawRect(wr, Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: const [_fenceB, _brickS]).createShader(wr));

    final mP = Paint()..color = _brickD.withAlpha(55)..strokeWidth = 0.9;
    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(w * _fL, fTop + fH * i / 4),
          Offset(w * _fR, fTop + fH * i / 4), mP);
    }

    // White capping
    canvas.drawRect(Rect.fromLTWH(w * _fL, fTop, w * (_fR - _fL), h * 0.010),
        Paint()..color = _trim);
    canvas.drawRect(Rect.fromLTWH(w * _fL, fTop + h * 0.010, w * (_fR - _fL), h * 0.005),
        Paint()..color = _trimD.withAlpha(70));

    // Gate opening
    final gW = w * 0.188;
    canvas.drawRect(Rect.fromLTWH(cx - gW / 2, fTop, gW, fH * 0.84), Paint()..color = _skyB);

    // Two pillars
    final pW = w * 0.028;
    for (int s in [-1, 1]) {
      final px = cx + s * (gW / 2 + pW * 0.60);
      canvas.drawRect(Rect.fromCenter(center: Offset(px, fTop + fH * 0.46),
          width: pW, height: fH * 0.92), Paint()..color = _trim);
      canvas.drawRect(Rect.fromCenter(center: Offset(px, fTop + fH * 0.46),
          width: pW, height: fH * 0.92),
          Paint()..color = _trimD.withAlpha(45)..style = PaintingStyle.stroke..strokeWidth = 0.7);
      canvas.drawCircle(Offset(px, fTop - h * 0.007), 7.0, Paint()..color = _trimSh);
      canvas.drawCircle(Offset(px, fTop - h * 0.007), 5.8, Paint()..color = _trim);
      canvas.drawCircle(Offset(px, fTop - h * 0.011), 2.2,
          Paint()..color = Colors.white.withAlpha(100));
    }
  }

  // ── Arch path helper ──────────────────────────────────────────────────────────
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
