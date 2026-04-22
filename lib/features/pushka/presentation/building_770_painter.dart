import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Front-facing illustration of 770 Eastern Parkway.
/// Built from AI reference image: vivid red brick, cream trim, stained glass.
/// [fillFraction] 0.0–1.0 → golden glow rising from base.
/// [glowPhase]   0.0–1.0 → shimmer animation on fill edge.
class Building770Painter extends CustomPainter {
  final double fillFraction;
  final double glowPhase;

  const Building770Painter({required this.fillFraction, this.glowPhase = 0});

  // ── Palette (from reference image) ──────────────────────────────────────
  static const _brick    = Color(0xFFC43A18);
  static const _brickLt  = Color(0xFFD24828);
  static const _brickDk  = Color(0xFF8A2808);
  static const _trim     = Color(0xFFF0E4B0);
  static const _trimLt   = Color(0xFFF8F0D0);
  static const _trimDk   = Color(0xFFB8A870);
  static const _roof     = Color(0xFF5A2412);
  static const _roofLt   = Color(0xFF7A3820);
  static const _winGrey  = Color(0xFF404858);
  static const _winLit   = Color(0xFFFFE090);
  static const _glassG   = Color(0xFF2A8848);
  static const _glassB   = Color(0xFF1840A0);
  static const _glassY   = Color(0xFFCC9800);
  static const _glassPu  = Color(0xFF7030A8);
  static const _glassTe  = Color(0xFF188870);
  static const _bayF     = Color(0xFF6A3018);
  static const _door     = Color(0xFF4A2010);
  static const _iron     = Color(0xFF181008);
  static const _stepGrey = Color(0xFF7A8898);
  static const _glowHot  = Color(0xFFFFAA00);
  static const _glowWrm  = Color(0xFFFFD060);
  static const _glowCl   = Color(0xFFFFF0B0);

  // ── Layout (fractions of canvas w / h) — from approved wireframe ────────
  static const _bL    = 0.060;   // building left
  static const _bR    = 0.941;   // building right
  static const _bTop  = 0.340;   // gable base Y
  static const _bBot  = 0.860;   // building base Y
  static const _d1    = 0.405;   // left / center bay divider
  static const _d2    = 0.595;   // center / right bay divider

  // Gable geometry
  static const _lgCX  = 0.231;
  static const _cgCX  = 0.500;
  static const _rgCX  = 0.769;
  static const _lgHW  = 0.171;
  static const _cgHW  = 0.095;
  static const _lgApY = 0.136;
  static const _cgApY = 0.204;

  // Floor bands
  static const _f3T   = 0.372;
  static const _f3B   = 0.476;
  static const _f2T   = 0.538;
  static const _f2B   = 0.672;
  static const _f1T   = 0.724;
  static const _f1B   = 0.860;

  // ── paint ────────────────────────────────────────────────────────────────
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    _drawBackground(canvas, w, h);
    _drawRoofBody(canvas, w, h);
    _drawFacade(canvas, w, h);
    _drawMortar(canvas, w, h);
    _drawCornices(canvas, w, h);
    _drawQuoins(canvas, w, h);
    _drawGables(canvas, w, h);
    _drawChimneys(canvas, w, h);
    _drawFloor3(canvas, w, h);
    _drawFloor2(canvas, w, h);
    _drawFloor1(canvas, w, h);
    _drawGlowOverlay(canvas, w, h);
    _drawFence(canvas, w, h);
  }

  // ── Facade clip ──────────────────────────────────────────────────────────
  Path _clip(double w, double h) {
    final fT = h * _bTop;
    return Path()
      ..moveTo(w * _bL,              h * _bBot)
      ..lineTo(w * _bL,              fT)
      ..lineTo(w * (_lgCX - _lgHW), fT)
      ..lineTo(w * _lgCX,           h * _lgApY)
      ..lineTo(w * (_lgCX + _lgHW), fT)
      ..lineTo(w * (_cgCX - _cgHW), fT)
      ..lineTo(w * _cgCX,           h * _cgApY)
      ..lineTo(w * (_cgCX + _cgHW), fT)
      ..lineTo(w * (_rgCX - _lgHW), fT)
      ..lineTo(w * _rgCX,           h * _lgApY)
      ..lineTo(w * (_rgCX + _lgHW), fT)
      ..lineTo(w * _bR,              fT)
      ..lineTo(w * _bR,              h * _bBot)
      ..close();
  }

  // ── White background ─────────────────────────────────────────────────────
  void _drawBackground(Canvas canvas, double w, double h) {
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
  }

  // ── Dark roof body between gables ────────────────────────────────────────
  void _drawRoofBody(Canvas canvas, double w, double h) {
    final rY   = h * _cgApY;
    final fTop = h * _bTop;
    final paint = Paint()..color = _roof;

    // Rear horizontal band (full width, gables will overdraw their triangles)
    canvas.drawRect(Rect.fromLTRB(w * _bL, rY, w * _bR, fTop), paint);

    // Diagonal flanks connecting rear line to outer corners
    canvas.drawPath(
      Path()
        ..moveTo(w * _bL + w * 0.014, rY)
        ..lineTo(w * _bL,              fTop)
        ..lineTo(w * _bL,              rY)
        ..close(),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(w * _bR - w * 0.014, rY)
        ..lineTo(w * _bR,              fTop)
        ..lineTo(w * _bR,              rY)
        ..close(),
      paint,
    );
  }

  // ── Main brick facade ────────────────────────────────────────────────────
  void _drawFacade(Canvas canvas, double w, double h) {
    final r = Rect.fromLTRB(w * _bL, h * _lgApY, w * _bR, h * _bBot);
    canvas.drawPath(_clip(w, h), Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft, end: Alignment.centerRight,
        colors: const [_brickDk, _brick, _brickLt, _brick, _brickDk],
        stops: const [0.0, 0.10, 0.50, 0.90, 1.0],
      ).createShader(r));
    // Top shadow
    canvas.drawPath(_clip(w, h), Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Colors.black.withAlpha(55), Colors.transparent],
        stops: const [0.0, 0.20],
      ).createShader(r));
  }

  // ── Brick mortar lines ───────────────────────────────────────────────────
  void _drawMortar(Canvas canvas, double w, double h) {
    canvas.save();
    canvas.clipPath(_clip(w, h));
    final cH = h * 0.018;
    final hp = Paint()..color = _brickDk.withAlpha(35)..strokeWidth = 0.6;
    var y = h * _lgApY;
    while (y < h * _bBot) {
      canvas.drawLine(Offset(w * _bL, y), Offset(w * _bR, y), hp);
      y += cH;
    }
    canvas.restore();
  }

  // ── Horizontal cream cornice bands ───────────────────────────────────────
  void _drawCornices(Canvas canvas, double w, double h) {
    final fL = w * _bL; final bW = w * (_bR - _bL);
    for (final yf in [_bTop, _f3B, _f2B, _f1B]) {
      final y = h * yf;
      canvas.drawRect(Rect.fromLTWH(fL, y, bW, h * 0.022), Paint()..color = _trim);
      canvas.drawRect(Rect.fromLTWH(fL, y + h * 0.022, bW, h * 0.005),
          Paint()..color = _trimDk.withAlpha(90));
      canvas.drawRect(Rect.fromLTWH(fL, y, bW, h * 0.003),
          Paint()..color = _trimLt.withAlpha(80));
    }
  }

  // ── Quoin corner blocks (alternating long/short cream blocks) ────────────
  void _drawQuoins(Canvas canvas, double w, double h) {
    final qW = w * 0.028; final qH = h * 0.029; final qGap = h * 0.012;
    // Edges: outer left, bay dividers, outer right
    final edgesLeft  = [w * _bL, w * _d1, w * _d2];
    final edgesRight = [w * _d1, w * _d2, w * _bR];
    for (int ei = 0; ei < edgesLeft.length; ei++) {
      final xL = edgesLeft[ei]; final xR = edgesRight[ei];
      var y = h * _bTop + 4; var alt = false;
      while (y < h * _bBot - qH) {
        final thisW = alt ? qW * 0.65 : qW;
        // Left quoin of each section
        canvas.drawRect(Rect.fromLTWH(xL, y, thisW, qH),
            Paint()..color = ei == 0 ? _trimDk : _trim);
        // Right quoin of each section
        canvas.drawRect(Rect.fromLTWH(xR - thisW, y, thisW, qH),
            Paint()..color = ei == 2 ? _trimDk : _trim);
        // Subtle border
        final qp = Paint()
          ..color = _trimDk.withAlpha(40)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5;
        canvas.drawRect(Rect.fromLTWH(xL, y, thisW, qH), qp);
        canvas.drawRect(Rect.fromLTWH(xR - thisW, y, thisW, qH), qp);
        y += qH + qGap; alt = !alt;
      }
    }
  }

  // ── Three Gothic gables ──────────────────────────────────────────────────
  void _drawGables(Canvas canvas, double w, double h) {
    _gable(canvas, w, h, _lgCX, _lgApY, _lgHW, large: true);
    _gable(canvas, w, h, _cgCX, _cgApY, _cgHW, large: false);
    _gable(canvas, w, h, _rgCX, _lgApY, _lgHW, large: true);
  }

  void _gable(Canvas canvas, double w, double h,
      double cxF, double apYF, double hwF, {required bool large}) {
    final cx   = w * cxF;
    final ap   = h * apYF;
    final hW   = w * hwF;
    final base = h * _bTop;
    final sw   = large ? 7.0 : 5.0;

    // Roof fill inside triangle
    canvas.drawPath(
      Path()..moveTo(cx - hW, base)..lineTo(cx, ap)..lineTo(cx + hW, base)..close(),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: const [_roof, _roofLt],
        ).createShader(Rect.fromLTRB(cx - hW, ap, cx + hW, base)),
    );

    // Cream trim (shadow + main + highlight)
    final tri = Path()
      ..moveTo(cx - hW, base)..lineTo(cx, ap)..lineTo(cx + hW, base);
    canvas.drawPath(tri,
        Paint()..color = _trimDk..style = PaintingStyle.stroke..strokeWidth = sw + 3.5);
    canvas.drawPath(tri,
        Paint()..color = _trim..style = PaintingStyle.stroke..strokeWidth = sw);
    canvas.drawPath(tri,
        Paint()..color = _trimLt.withAlpha(70)..style = PaintingStyle.stroke..strokeWidth = 1.5);

    // Inner coping line
    final innerAp = Offset(cx, ap + 6.0);
    canvas.drawPath(
      Path()
        ..moveTo(cx - hW + 2, base)
        ..lineTo(innerAp.dx, innerAp.dy)
        ..lineTo(cx + hW - 2, base),
      Paint()..color = _trimDk.withAlpha(120)..style = PaintingStyle.stroke..strokeWidth = 1.0,
    );

    // Finial
    final fr = large ? 7.0 : 5.5;
    final fcy = ap - fr;
    canvas.drawRect(Rect.fromCenter(center: Offset(cx, ap), width: 5, height: fr * 1.2),
        Paint()..color = _trim);
    canvas.drawCircle(Offset(cx, fcy), fr + 1.5, Paint()..color = _trimDk);
    canvas.drawCircle(Offset(cx, fcy), fr,        Paint()..color = _trim);
    canvas.drawCircle(Offset(cx, fcy - fr * 0.45), fr * 0.32,
        Paint()..color = _trimLt.withAlpha(130));

    // Medallion square
    final mY = ap + (base - ap) * (large ? 0.52 : 0.50);
    final mS = large ? w * 0.058 : w * 0.034;
    canvas.drawRect(Rect.fromCenter(center: Offset(cx, mY), width: mS + 5, height: mS + 5),
        Paint()..color = _trimDk);
    canvas.drawRect(Rect.fromCenter(center: Offset(cx, mY), width: mS, height: mS),
        Paint()..color = _trim);
    canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, mY), width: mS * 0.58, height: mS * 0.58),
        Paint()..color = _brickDk.withAlpha(90));
  }

  // ── Chimney stacks ───────────────────────────────────────────────────────
  void _drawChimneys(Canvas canvas, double w, double h) {
    final base = h * _bTop;
    final chW  = w * 0.015;
    final chH  = h * 0.115;
    for (final xF in [
      w * (_lgCX - _lgHW) - w * 0.028,
      w * (_lgCX - _lgHW) - w * 0.052,
      w * (_rgCX + _lgHW) + w * 0.028,
      w * (_rgCX + _lgHW) + w * 0.052,
    ]) {
      canvas.drawRect(Rect.fromLTWH(xF - chW / 2, base - chH, chW, chH),
          Paint()..color = _brickDk);
      canvas.drawRect(Rect.fromLTWH(xF - chW / 2 - 2, base - chH, chW + 4, h * 0.013),
          Paint()..color = _trimDk);
    }
  }

  // ── 3rd floor: 3 narrow windows per bay ─────────────────────────────────
  void _drawFloor3(Canvas canvas, double w, double h) {
    final lit = fillFraction > 0.72;
    final cy  = h * (_f3T + (_f3B - _f3T) / 2);
    final wh  = h * (_f3B - _f3T) * 0.76;
    final ww  = w * 0.040;
    _winGroup3(canvas, w * _lgCX, cy, ww,        wh,        lit);
    _winGroup3(canvas, w * _cgCX, cy, ww * 0.78, wh * 0.84, lit);
    _winGroup3(canvas, w * _rgCX, cy, ww,        wh,        lit);
  }

  void _winGroup3(Canvas canvas, double cx, double cy,
      double ww, double wh, bool lit) {
    final gap    = ww * 0.28;
    final totalW = ww * 3 + gap * 2;
    // Outer quoin frame
    canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: totalW + 17, height: wh + 15),
        Paint()..color = _trimDk);
    canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: totalW + 10, height: wh + 8),
        Paint()..color = _trim);
    // 3 panes
    for (int i = 0; i < 3; i++) {
      final wx  = cx - totalW / 2 + ww / 2 + i * (ww + gap);
      final inn = Rect.fromCenter(center: Offset(wx, cy), width: ww - 2, height: wh - 4);
      canvas.drawRect(inn, Paint()..color = lit ? _winLit.withAlpha(200) : _winGrey);
      if (lit) {
        canvas.drawRect(inn, Paint()
          ..shader = RadialGradient(center: const Alignment(-0.2, -0.4), radius: 0.8,
            colors: [Colors.white.withAlpha(85), Colors.transparent]).createShader(inn));
      }
      canvas.drawLine(Offset(wx, inn.top), Offset(wx, inn.bottom),
          Paint()..color = _trim.withAlpha(lit ? 100 : 160)..strokeWidth = 1.2);
    }
  }

  // ── 2nd floor: bay window + 3 windows L/R ───────────────────────────────
  void _drawFloor2(Canvas canvas, double w, double h) {
    final lit = fillFraction > 0.44;
    _drawBayWindow(canvas, w, h, lit);

    final cy  = h * (_f2T + (_f2B - _f2T) / 2);
    final wh  = h * (_f2B - _f2T) * 0.74;
    final ww  = w * 0.046;
    _winGroup3(canvas, w * _lgCX, cy, ww, wh, lit);
    _winGroup3(canvas, w * _rgCX, cy, ww, wh, lit);
  }

  void _drawBayWindow(Canvas canvas, double w, double h, bool lit) {
    final cx    = w * _cgCX;
    final faceW = w * 0.158;
    final top   = h * _f2T + h * 0.005;
    final bot   = h * _f2B - h * 0.005;
    final faceH = bot - top;
    final protr = w * 0.020;

    // Left & right depth faces
    canvas.drawPath(
      Path()
        ..moveTo(cx - faceW / 2,          top)
        ..lineTo(cx - faceW / 2 - protr,  top + faceH * 0.18)
        ..lineTo(cx - faceW / 2 - protr,  bot - faceH * 0.18)
        ..lineTo(cx - faceW / 2,          bot)
        ..close(),
      Paint()..color = _brickDk.withAlpha(200),
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx + faceW / 2,          top)
        ..lineTo(cx + faceW / 2 + protr,  top + faceH * 0.18)
        ..lineTo(cx + faceW / 2 + protr,  bot - faceH * 0.18)
        ..lineTo(cx + faceW / 2,          bot)
        ..close(),
      Paint()..color = _brickDk.withAlpha(130),
    );

    // Front face (dark wood frame)
    canvas.drawRect(Rect.fromLTWH(cx - faceW / 2, top, faceW, faceH),
        Paint()..color = _bayF);
    canvas.drawRect(Rect.fromLTWH(cx - faceW / 2, top, faceW, faceH),
        Paint()..color = _trim..style = PaintingStyle.stroke..strokeWidth = 4.5);

    // Faceted grey roof cap
    final roofH = h * 0.044;
    canvas.drawPath(
      Path()
        ..moveTo(cx - faceW / 2 - protr - 2, top + faceH * 0.18)
        ..lineTo(cx - faceW / 2 - 2,          top)
        ..lineTo(cx + faceW / 2 + 2,          top)
        ..lineTo(cx + faceW / 2 + protr + 2,  top + faceH * 0.18)
        ..lineTo(cx,                           top - roofH)
        ..close(),
      Paint()..color = const Color(0xFF808898),
    );
    // Roof shading (left face darker)
    canvas.drawPath(
      Path()
        ..moveTo(cx - faceW / 2 - protr - 2, top + faceH * 0.18)
        ..lineTo(cx - faceW / 2 - 2,          top)
        ..lineTo(cx,                           top - roofH)
        ..close(),
      Paint()..color = Colors.black.withAlpha(40),
    );

    // 5 stained glass panels
    const pCount = 5;
    final pW = (faceW - 8) / pCount;
    final pH = faceH * 0.68;
    final pCY = top + faceH * 0.48;
    const bayCols = [_glassTe, _glassG, _glassTe, _glassG, _glassTe];
    for (int i = 0; i < pCount; i++) {
      final px = cx - faceW / 2 + 4 + pW * i + pW / 2;
      final pR = Rect.fromCenter(center: Offset(px, pCY), width: pW - 2, height: pH);
      canvas.drawRect(pR,
          Paint()..color = lit ? bayCols[i].withAlpha(215) : _bayF.withAlpha(200));
      if (lit) {
        canvas.drawRect(pR, Paint()
          ..shader = RadialGradient(center: const Alignment(-0.2, -0.5), radius: 0.85,
            colors: [Colors.white.withAlpha(100), Colors.transparent]).createShader(pR));
      }
      if (i < pCount - 1) {
        canvas.drawLine(
          Offset(cx - faceW / 2 + 4 + pW * (i + 1), pR.top),
          Offset(cx - faceW / 2 + 4 + pW * (i + 1), pR.bottom),
          Paint()..color = _trim.withAlpha(100)..strokeWidth = 1.0,
        );
      }
    }

    // Pediment below bay (inverted triangle = sill/base)
    final pedH  = h * 0.034;
    final pedHW = faceW * 0.55;
    canvas.drawPath(
      Path()
        ..moveTo(cx - pedHW, bot)
        ..lineTo(cx,          bot + pedH)
        ..lineTo(cx + pedHW, bot)
        ..close(),
      Paint()..color = _trim,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - pedHW, bot)
        ..lineTo(cx,          bot + pedH)
        ..lineTo(cx + pedHW, bot),
      Paint()..color = _trimDk..style = PaintingStyle.stroke..strokeWidth = 2.0,
    );
  }

  // ── 1st floor: stained glass + arched entrance ───────────────────────────
  void _drawFloor1(Canvas canvas, double w, double h) {
    final lit   = fillFraction > 0.06;
    final cx    = w * _cgCX;
    final cy    = h * (_f1T + (_f1B - _f1T) * 0.44);
    final gh    = h * (_f1B - _f1T) * 0.80;
    final gw    = w * 0.165;
    final eHW   = w * 0.082;

    _stainedGroup(canvas,
        cx - eHW - (cx - eHW - w * (_bL + 0.078)) * 0.50,
        cy, gw, gh, lit,
        cols: [_glassPu, _glassG, _glassY, _glassB]);

    _stainedGroup(canvas,
        cx + eHW + (w * (_bR - 0.010) - cx - eHW) * 0.50,
        cy, gw, gh, lit,
        cols: [_glassY, _glassB, _glassPu, _glassG]);

    _drawEntrance(canvas, cx, w, h);
  }

  void _stainedGroup(Canvas canvas, double cx, double cy,
      double ww, double wh, bool lit, {required List<Color> cols}) {
    canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: ww + 17, height: wh + 15),
        Paint()..color = _trimDk);
    canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: ww + 10, height: wh + 8),
        Paint()..color = _trim);

    final pW = (ww - 8) / cols.length;
    final pH = wh - 8;
    for (int i = 0; i < cols.length; i++) {
      final px  = cx - ww / 2 + 4 + pW * i + pW / 2;
      final pR  = Rect.fromCenter(center: Offset(px, cy), width: pW - 1, height: pH);
      final sqH = pW * 0.92;
      if (lit) {
        canvas.drawRect(pR, Paint()..color = cols[i].withAlpha(215));
        canvas.drawRect(pR, Paint()
          ..shader = RadialGradient(center: const Alignment(-0.2, -0.5), radius: 0.85,
            colors: [Colors.white.withAlpha(100), Colors.transparent]).createShader(pR));
      } else {
        canvas.drawRect(pR, Paint()..color = _brickDk.withAlpha(180));
      }
      // Horizontal divider: square top + tall bottom
      final divY = pR.top + sqH;
      canvas.drawLine(Offset(pR.left, divY), Offset(pR.right, divY),
          Paint()..color = _trim..strokeWidth = 1.5);
    }
  }

  void _drawEntrance(Canvas canvas, double cx, double w, double h) {
    final dW = w * 0.124;
    final dH = h * (_f1B - _f1T) * 0.90;
    final dT = h * _f1T + h * 0.008;
    final aR = dW * 0.58;

    // Outer frame
    canvas.drawPath(_archP(cx, dT, dW * 1.25, dH, aR + 6),
        Paint()..color = _trimDk);
    canvas.drawPath(_archP(cx, dT, dW * 1.18, dH, aR + 3),
        Paint()..color = _trim);

    // Side pilasters
    for (final s in [-1, 1]) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(cx + s * dW * 0.68, dT + dH * 0.52),
          width: dW * 0.17, height: dH * 0.90,
        ),
        Paint()..color = _trim,
      );
    }

    // Double door panels
    for (final s in [-1, 1]) {
      final px = cx + s * dW * 0.24;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(px, dT + dH * 0.58),
              width: dW * 0.44, height: dH * 0.82),
          const Radius.circular(2),
        ),
        Paint()..color = _door,
      );
      canvas.drawCircle(Offset(cx + s * dW * 0.07, dT + dH * 0.60),
          2.5, Paint()..color = const Color(0xFFD4A820));
    }

    // Steps (grey)
    for (int i = 0; i < 3; i++) {
      final sW = dW * (1.80 - i * 0.22);
      final sH = h * 0.020;
      final sY = dT + dH + i * sH;
      canvas.drawRect(
          Rect.fromCenter(center: Offset(cx, sY + sH / 2), width: sW, height: sH),
          Paint()..color = _stepGrey);
    }
  }

  // ── Golden glow fill animation ───────────────────────────────────────────
  void _drawGlowOverlay(Canvas canvas, double w, double h) {
    if (fillFraction <= 0.005) return;
    final bBot    = h * _bBot;
    final bTop    = h * _lgApY;
    final glowTop = bBot - (bBot - bTop) * fillFraction;
    final pulse   = (math.sin(glowPhase * 2 * math.pi) * 0.08 + 0.92).clamp(0.80, 1.0);
    final hotA    = (200 * pulse).round();
    final warmA   = (155 * pulse).round();

    canvas.save();
    canvas.clipPath(_clip(w, h));
    final glow = Rect.fromLTRB(w * _bL, glowTop, w * _bR, bBot);
    canvas.drawRect(glow, Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
        colors: [
          _glowHot.withAlpha(hotA), _glowWrm.withAlpha(warmA),
          _glowCl.withAlpha(90), Colors.transparent,
        ],
        stops: const [0.0, 0.35, 0.70, 1.0],
      ).createShader(glow));

    if (fillFraction > 0.015) {
      final sr = Rect.fromLTWH(w * _bL, glowTop - 3, w * (_bR - _bL), 6);
      canvas.drawRect(sr, Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft, end: Alignment.centerRight,
          colors: [
            Colors.transparent, Colors.white.withAlpha(155),
            Colors.white.withAlpha(200), Colors.white.withAlpha(155), Colors.transparent,
          ],
          stops: const [0.0, 0.25, 0.50, 0.75, 1.0],
        ).createShader(sr));
    }
    canvas.restore();
  }

  // ── Fence wall + iron railings + gate ────────────────────────────────────
  void _drawFence(Canvas canvas, double w, double h) {
    final fTop = h * _bBot;
    final fH   = h * 0.095;
    final cx   = w * _cgCX;
    final fL   = w * _bL; final fR = w * _bR;
    final bW   = fR - fL;

    // Brick wall
    final wr = Rect.fromLTWH(fL, fTop, bW, fH);
    canvas.drawRect(wr, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: const [_brick, _brickDk],
      ).createShader(wr));
    // Mortar
    for (int i = 1; i < 4; i++) {
      canvas.drawLine(Offset(fL, fTop + fH * i / 4), Offset(fR, fTop + fH * i / 4),
          Paint()..color = _brickDk.withAlpha(50)..strokeWidth = 0.8);
    }
    // Cream capping
    canvas.drawRect(Rect.fromLTWH(fL, fTop, bW, h * 0.010), Paint()..color = _trim);

    // Gate opening
    final gW = w * 0.168;
    canvas.drawRect(Rect.fromLTWH(cx - gW / 2, fTop + h * 0.010, gW, fH - h * 0.010),
        Paint()..color = Colors.black.withAlpha(25));

    // Gate pillars with ball caps
    final pW = w * 0.025;
    for (final s in [-1, 1]) {
      final px = cx + s * (gW / 2 + pW * 0.55);
      canvas.drawRect(
          Rect.fromCenter(center: Offset(px, fTop + fH * 0.48), width: pW, height: fH * 0.90),
          Paint()..color = _trim);
      canvas.drawCircle(Offset(px, fTop - h * 0.007), 6.5, Paint()..color = _trimDk);
      canvas.drawCircle(Offset(px, fTop - h * 0.007), 5.2, Paint()..color = _trim);
      canvas.drawCircle(Offset(px, fTop - h * 0.011), 2.0,
          Paint()..color = Colors.white.withAlpha(100));
    }

    // Iron railings left & right of gate
    final rTop = fTop + h * 0.012;
    final rBot = fTop + fH * 0.85;
    final rP   = Paint()..color = _iron..strokeWidth = 1.5;
    final lEnd  = cx - gW / 2 - pW;
    final rStart = cx + gW / 2 + pW;
    for (int side = 0; side < 2; side++) {
      final segL = side == 0 ? fL + pW : rStart;
      final segR = side == 0 ? lEnd     : fR - pW;
      if (segR <= segL) continue;
      canvas.drawLine(Offset(segL, rTop), Offset(segR, rTop), rP);
      final count = ((segR - segL) / (w * 0.022)).round().clamp(2, 40);
      for (int i = 0; i <= count; i++) {
        final rx = segL + (segR - segL) * i / count;
        canvas.drawLine(Offset(rx, rTop), Offset(rx, rBot), rP);
      }
    }
  }

  // ── Path helpers ─────────────────────────────────────────────────────────

  /// Open-top arch outline (no bottom closing line).
  Path _archP(double cx, double dT, double dW, double dH, double aR) {
    final l = cx - dW / 2; final r = cx + dW / 2;
    return Path()
      ..moveTo(l, dT + dH)
      ..lineTo(l, dT + aR)
      ..arcTo(
          Rect.fromCenter(center: Offset(cx, dT + aR), width: dW, height: aR * 2),
          math.pi, math.pi, false)
      ..lineTo(r, dT + dH);
  }

  @override
  bool shouldRepaint(Building770Painter old) =>
      old.fillFraction != fillFraction || old.glowPhase != glowPhase;
}
