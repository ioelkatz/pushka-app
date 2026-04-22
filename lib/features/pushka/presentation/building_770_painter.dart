import 'dart:math' as math;
import 'package:flutter/material.dart';

class Building770Painter extends CustomPainter {
  final double fillFraction; // 0.0 = vacío, 1.0 = lleno
  final double glowPhase;    // 0..1 para animación de shimmer

  const Building770Painter({
    required this.fillFraction,
    this.glowPhase = 0,
  });

  // ── Paleta ───────────────────────────────────────────────────────────────────
  static const _brickMain   = Color(0xFFC1440E);
  static const _brickDark   = Color(0xFF8B2E08);
  static const _brickLight  = Color(0xFFD4603A);
  static const _trim        = Color(0xFFF5F0E8);
  static const _trimShade   = Color(0xFFD4C9B0);
  static const _trimDark    = Color(0xFFB0A08A);
  static const _windowDark  = Color(0xFF1A0E06);
  static const _doorWood    = Color(0xFF5C3010);
  static const _skyTop      = Color(0xFFBDD4E8);
  static const _skyBottom   = Color(0xFFE8EFF4);
  static const _glowHot     = Color(0xFFFFAA00);
  static const _glowWarm    = Color(0xFFFFD060);
  static const _glowCool    = Color(0xFFFFF0B0);
  static const _fenceBrick  = Color(0xFFAA3308);
  static const _glassBlue   = Color(0xFF1A56A8);
  static const _glassGreen  = Color(0xFF2A8040);
  static const _glassYellow = Color(0xFFE8B800);

  // ── Geometría normalizada ────────────────────────────────────────────────────
  // El edificio ocupa del 5% al 95% del ancho y del 6% al 82% del alto.
  // La cerca/muro frontal ocupa h*0.82 a h*1.0.

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    _drawSky(canvas, w, h);
    _drawGroundShadow(canvas, w, h);
    _drawBuildingBase(canvas, w, h);
    _drawBrickPattern(canvas, w, h);
    _drawFloorTrimBands(canvas, w, h);
    _drawRoofZone(canvas, w, h);
    _drawThirdFloorWindows(canvas, w, h);
    _drawSecondFloor(canvas, w, h);
    _drawGroundFloor(canvas, w, h);
    _drawGlowOverlay(canvas, w, h);
    _drawBuildingEdgeShadows(canvas, w, h);
    _drawFrontFence(canvas, w, h);
  }

  // ── Cielo ────────────────────────────────────────────────────────────────────
  void _drawSky(Canvas canvas, double w, double h) {
    final rect = Rect.fromLTWH(0, 0, w, h * 0.22);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_skyTop, _skyBottom],
        ).createShader(rect),
    );
  }

  // ── Sombra suave en el suelo ──────────────────────────────────────────────────
  void _drawGroundShadow(Canvas canvas, double w, double h) {
    for (int i = 5; i >= 0; i--) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(w * 0.50, h * 0.84),
          width: w * 0.88 + i * 6,
          height: h * 0.028 + i * 2,
        ),
        Paint()..color = const Color(0xFF1A0800).withAlpha(8 + i * 3),
      );
    }
  }

  // ── Silueta del edificio ──────────────────────────────────────────────────────
  Path _buildingClipPath(double w, double h) {
    final bL = w * 0.04;
    final bR = w * 0.96;
    final bBot = h * 0.820;
    final bW = bR - bL;

    // Los 5 pináculos (3 grandes alternados con 2 medianos)
    // Base de pináculos en h*0.200, puntas entre h*0.048 y h*0.082
    final pinnacleBaseY = h * 0.200;
    final spacing = bW / 6.0;

    final path = Path();
    path.moveTo(bL, bBot);
    path.lineTo(bL, pinnacleBaseY);

    // Pináculo izq grande (pos 1)
    final p1x = bL + spacing * 1.0;
    path.lineTo(p1x - spacing * 0.42, pinnacleBaseY);
    path.lineTo(p1x, h * 0.048);
    path.lineTo(p1x + spacing * 0.42, pinnacleBaseY);

    // Pináculo mediano (pos 2)
    final p2x = bL + spacing * 2.0;
    path.lineTo(p2x - spacing * 0.30, pinnacleBaseY);
    path.lineTo(p2x, h * 0.082);
    path.lineTo(p2x + spacing * 0.30, pinnacleBaseY);

    // Pináculo central grande (pos 3)
    final p3x = bL + spacing * 3.0;
    path.lineTo(p3x - spacing * 0.44, pinnacleBaseY);
    path.lineTo(p3x, h * 0.042);
    path.lineTo(p3x + spacing * 0.44, pinnacleBaseY);

    // Pináculo mediano (pos 4)
    final p4x = bL + spacing * 4.0;
    path.lineTo(p4x - spacing * 0.30, pinnacleBaseY);
    path.lineTo(p4x, h * 0.082);
    path.lineTo(p4x + spacing * 0.30, pinnacleBaseY);

    // Pináculo der grande (pos 5)
    final p5x = bL + spacing * 5.0;
    path.lineTo(p5x - spacing * 0.42, pinnacleBaseY);
    path.lineTo(p5x, h * 0.048);
    path.lineTo(p5x + spacing * 0.42, pinnacleBaseY);

    path.lineTo(bR, pinnacleBaseY);
    path.lineTo(bR, bBot);
    path.close();
    return path;
  }

  void _drawBuildingBase(Canvas canvas, double w, double h) {
    final bL = w * 0.04;
    final bR = w * 0.96;
    final bBot = h * 0.820;
    final path = _buildingClipPath(w, h);

    // Gradiente de ladrillo: izquierda más oscura (luz viene de la derecha)
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [_brickDark, _brickMain, _brickLight, _brickMain, _brickDark],
          stops: const [0.0, 0.12, 0.50, 0.88, 1.0],
        ).createShader(Rect.fromLTRB(bL, h * 0.06, bR, bBot)),
    );

    // Gradiente vertical: más oscuro arriba y abajo
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withAlpha(55),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withAlpha(30),
          ],
          stops: const [0.0, 0.18, 0.78, 1.0],
        ).createShader(Rect.fromLTRB(bL, h * 0.06, bR, bBot)),
    );
  }

  // ── Textura de ladrillos ──────────────────────────────────────────────────────
  void _drawBrickPattern(Canvas canvas, double w, double h) {
    final bL = w * 0.04;
    final bR = w * 0.96;
    final bTop = h * 0.20;
    final bBot = h * 0.820;

    canvas.save();
    canvas.clipPath(_buildingClipPath(w, h));

    final hPaint = Paint()
      ..color = _brickDark.withAlpha(50)
      ..strokeWidth = 0.8;

    // Líneas horizontales de mortero cada ~1.6% del alto
    final courseH = h * 0.016;
    var y = bTop;
    while (y < bBot) {
      canvas.drawLine(Offset(bL, y), Offset(bR, y), hPaint);
      y += courseH;
    }

    // Líneas verticales de mortero alternadas (efecto junta de ladrillo)
    final vPaint = Paint()
      ..color = _brickDark.withAlpha(28)
      ..strokeWidth = 0.6;
    final brickW = w * 0.045;
    var row = 0;
    y = bTop;
    while (y < bBot) {
      final offset = (row % 2 == 0) ? 0.0 : brickW * 0.5;
      var x = bL + offset;
      while (x < bR) {
        canvas.drawLine(Offset(x, y), Offset(x, y + courseH), vPaint);
        x += brickW;
      }
      y += courseH;
      row++;
    }

    canvas.restore();
  }

  // ── Bandas de cornisa entre pisos ─────────────────────────────────────────────
  void _drawFloorTrimBands(Canvas canvas, double w, double h) {
    final bL = w * 0.04;
    final bR = w * 0.96;
    final bW = bR - bL;
    final trimH = h * 0.020;
    final trimPaint = Paint()..color = _trim;
    final shadePaint = Paint()..color = _trimDark.withAlpha(100);

    // Banda techo/pináculos → 3er piso
    canvas.drawRect(Rect.fromLTWH(bL, h * 0.198, bW, trimH), trimPaint);
    canvas.drawRect(Rect.fromLTWH(bL, h * 0.198 + trimH, bW, h * 0.005), shadePaint);

    // Banda 3er → 2do piso
    canvas.drawRect(Rect.fromLTWH(bL, h * 0.400, bW, trimH), trimPaint);
    canvas.drawRect(Rect.fromLTWH(bL, h * 0.400 + trimH, bW, h * 0.005), shadePaint);

    // Banda 2do → 1er piso
    canvas.drawRect(Rect.fromLTWH(bL, h * 0.622, bW, trimH), trimPaint);
    canvas.drawRect(Rect.fromLTWH(bL, h * 0.622 + trimH, bW, h * 0.005), shadePaint);

    // Zócalo inferior
    canvas.drawRect(Rect.fromLTWH(bL, h * 0.800, bW, h * 0.022), trimPaint);
  }

  // ── Zona de techo con buhardillas ─────────────────────────────────────────────
  void _drawRoofZone(Canvas canvas, double w, double h) {
    final bL = w * 0.04;
    final bW = w * 0.92;

    // 3 buhardillas principales en posiciones 1, 3, 5 (de 6 espacios)
    final spacing = bW / 6.0;
    final dormerPositions = [1, 3, 5];
    final smallPositions  = [2, 4];

    for (final i in dormerPositions) {
      _drawDormer(canvas, bL + spacing * i, h * 0.120, w * 0.130, h * 0.085, h, large: true);
    }
    for (final i in smallPositions) {
      _drawDormer(canvas, bL + spacing * i, h * 0.140, w * 0.095, h * 0.065, h, large: false);
    }

    // Bolas decorativas en cima de cada pináculo
    final pinnacleXs = [1.0, 2.0, 3.0, 4.0, 5.0];
    for (final i in pinnacleXs) {
      final cx = bL + spacing * i;
      final isLarge = (i == 1.0 || i == 3.0 || i == 5.0);
      final py = isLarge ? h * 0.040 : h * 0.076;
      canvas.drawCircle(Offset(cx, py), 4.5, Paint()..color = _trim);
      canvas.drawCircle(Offset(cx, py), 2.5, Paint()..color = _trimShade);
    }
  }

  void _drawDormer(Canvas canvas, double cx, double top, double dW, double dH, double h,
      {required bool large}) {
    final lit = fillFraction > (large ? 0.82 : 0.90);

    // Cuerpo de la buhardilla
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, top + dH / 2), width: dW, height: dH),
      Paint()..color = _brickMain,
    );

    // Marco blanco
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, top + dH / 2), width: dW, height: dH),
      Paint()
        ..color = _trim
        ..style = PaintingStyle.stroke
        ..strokeWidth = large ? 3.5 : 2.5,
    );

    // Triángulo apuntado arriba
    final triH = large ? h * 0.045 : h * 0.032;
    final triPath = Path()
      ..moveTo(cx - dW * 0.52, top)
      ..lineTo(cx, top - triH)
      ..lineTo(cx + dW * 0.52, top)
      ..close();
    canvas.drawPath(triPath, Paint()..color = _brickMain);
    canvas.drawPath(triPath, Paint()
      ..color = _trim
      ..style = PaintingStyle.stroke
      ..strokeWidth = large ? 3.0 : 2.0);

    // Ventana en buhardilla
    final wW = dW * 0.54;
    final wH = dH * 0.50;
    final wRect = Rect.fromCenter(
      center: Offset(cx, top + dH * 0.57),
      width: wW,
      height: wH,
    );
    canvas.drawRect(wRect, Paint()..color = _trim);

    final innerRect = Rect.fromCenter(
      center: Offset(cx, top + dH * 0.57),
      width: wW - 6,
      height: wH - 6,
    );
    canvas.drawRect(innerRect,
      Paint()..color = lit ? _glassYellow.withAlpha(210) : _windowDark);

    if (lit) {
      canvas.drawRect(innerRect, Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withAlpha(120), Colors.transparent],
        ).createShader(innerRect));
    }

    // Cruz divisoria de la ventana
    final divPaint = Paint()..color = _trim..strokeWidth = 1.5;
    canvas.drawLine(Offset(cx, innerRect.top), Offset(cx, innerRect.bottom), divPaint);
    canvas.drawLine(Offset(innerRect.left, top + dH * 0.57),
                    Offset(innerRect.right, top + dH * 0.57), divPaint);
  }

  // ── Tercer piso ───────────────────────────────────────────────────────────────
  void _drawThirdFloorWindows(Canvas canvas, double w, double h) {
    final bL = w * 0.04;
    final bR = w * 0.96;
    final cx = w * 0.50;
    final wW = w * 0.110;
    final wH = h * 0.110;
    final wCY = h * 0.310; // centro vertical de las ventanas
    final lit = fillFraction > 0.72;

    // 3 ventanas a cada lado (6 total), simétricas
    final offsets = [w * 0.075, w * 0.190, w * 0.305];
    for (final dx in offsets) {
      _drawClassicWindow(canvas, bL + cx * 0.04 + dx, wCY, wW, wH, lit: lit);
      _drawClassicWindow(canvas, bR - cx * 0.04 - dx, wCY, wW, wH, lit: lit);
    }
  }

  void _drawClassicWindow(Canvas canvas, double cx, double cy, double ww, double wh,
      {required bool lit, Color? glassColor}) {
    final outerR = Rect.fromCenter(center: Offset(cx, cy), width: ww + 8, height: wh + 8);
    final innerR = Rect.fromCenter(center: Offset(cx, cy), width: ww - 4, height: wh - 4);

    // Marco exterior blanco (con sombra de borde)
    canvas.drawRRect(
      RRect.fromRectAndRadius(outerR, const Radius.circular(2)),
      Paint()..color = _trimShade,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, cy), width: ww + 5, height: wh + 5),
          const Radius.circular(2)),
      Paint()..color = _trim,
    );

    // Vidrio
    final glass = glassColor ?? (lit ? const Color(0xFFFFDD88).withAlpha(200) : _windowDark);
    canvas.drawRect(innerR, Paint()..color = glass);

    if (lit) {
      canvas.drawRect(innerR, Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.3),
          radius: 0.9,
          colors: [Colors.white.withAlpha(90), Colors.transparent],
        ).createShader(innerR));
    }

    // Cruz divisoria
    final divPaint = Paint()..color = _trim.withAlpha(lit ? 180 : 255)..strokeWidth = 1.8;
    canvas.drawLine(Offset(cx, innerR.top), Offset(cx, innerR.bottom), divPaint);
    canvas.drawLine(Offset(innerR.left, cy), Offset(innerR.right, cy), divPaint);
  }

  // ── Segundo piso ──────────────────────────────────────────────────────────────
  void _drawSecondFloor(Canvas canvas, double w, double h) {
    final bL = w * 0.04;
    final bR = w * 0.96;
    final cx = w * 0.50;
    final lit2nd = fillFraction > 0.44;

    // ── Ventana bay central (elemento más icónico del 770) ─────────────────────
    final bayW = w * 0.240;
    final bayH = h * 0.185;
    final bayTop = h * 0.418;
    final bayMid = bayTop + bayH / 2;

    // Protuberancia del bay (sombra para dar profundidad)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, bayMid + h * 0.006), width: bayW + 10, height: bayH + 10),
        const Radius.circular(4),
      ),
      Paint()..color = _brickDark.withAlpha(80),
    );

    // Cuerpo del bay
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, bayMid), width: bayW, height: bayH),
        const Radius.circular(3),
      ),
      Paint()..color = _brickMain.withAlpha(230),
    );

    // Marco exterior del bay
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, bayMid), width: bayW, height: bayH),
        const Radius.circular(3),
      ),
      Paint()
        ..color = _trim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.5,
    );

    // Arco decorativo sobre el bay
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(cx, bayTop),
        width: bayW * 1.12,
        height: h * 0.072,
      ),
      math.pi, math.pi, false,
      Paint()
        ..color = _trim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0,
    );

    // 3 paneles de vitral en el bay
    final paneW = bayW * 0.27;
    final paneH = bayH * 0.62;
    final paneOffsets = [-bayW * 0.33, 0.0, bayW * 0.33];
    final paneColors = [_glassBlue, _glassYellow, _glassGreen];

    for (int i = 0; i < 3; i++) {
      final px = cx + paneOffsets[i];
      final pRect = Rect.fromCenter(center: Offset(px, bayMid + bayH * 0.04), width: paneW, height: paneH);

      // Marco blanco del panel
      canvas.drawRect(
        Rect.fromCenter(center: Offset(px, bayMid + bayH * 0.04), width: paneW + 5, height: paneH + 5),
        Paint()..color = _trim,
      );

      // Vidrio del panel
      if (lit2nd) {
        canvas.drawRect(pRect, Paint()..color = paneColors[i].withAlpha(210));
        canvas.drawRect(pRect, Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.5),
            radius: 0.9,
            colors: [Colors.white.withAlpha(100), Colors.transparent],
          ).createShader(pRect));
      } else {
        canvas.drawRect(pRect, Paint()..color = _windowDark);
      }

      // Arco superior del panel
      canvas.drawArc(
        Rect.fromCenter(center: Offset(px, bayMid + bayH * 0.04 - paneH * 0.4),
          width: paneW + 5, height: paneW * 0.7),
        math.pi, math.pi, false,
        Paint()
          ..color = _trim
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    // ── 4 ventanas laterales (2 por lado) ────────────────────────────────────
    final sWW = w * 0.115;
    final sWH = h * 0.125;
    final sWCY = h * 0.508;

    final leftGap  = cx - bayW / 2 - bL;
    final rightGap = bR - cx - bayW / 2;

    _drawClassicWindow(canvas, bL + leftGap * 0.28, sWCY, sWW, sWH, lit: lit2nd);
    _drawClassicWindow(canvas, bL + leftGap * 0.72, sWCY, sWW, sWH, lit: lit2nd);
    _drawClassicWindow(canvas, bR - rightGap * 0.28, sWCY, sWW, sWH, lit: lit2nd);
    _drawClassicWindow(canvas, bR - rightGap * 0.72, sWCY, sWW, sWH, lit: lit2nd);
  }

  // ── Planta baja ───────────────────────────────────────────────────────────────
  void _drawGroundFloor(Canvas canvas, double w, double h) {
    final bL = w * 0.04;
    final bR = w * 0.96;
    final cx = w * 0.50;
    final lit1st = fillFraction > 0.06;

    // ── Entrada central ──────────────────────────────────────────────────────
    _drawEntrance(canvas, cx, w, h);

    // ── Vitral izquierdo ─────────────────────────────────────────────────────
    final leftCx = bL + (cx - bL) * 0.38;
    _drawStainedGlassWindow(canvas, leftCx, h * 0.715, w * 0.195, h * 0.145, lit1st,
        colors: [_glassBlue, _glassGreen, _glassYellow]);

    // ── Vitral derecho ────────────────────────────────────────────────────────
    final rightCx = cx + (bR - cx) * 0.62;
    _drawStainedGlassWindow(canvas, rightCx, h * 0.715, w * 0.195, h * 0.145, lit1st,
        colors: [_glassYellow, _glassBlue, _glassGreen]);
  }

  void _drawStainedGlassWindow(Canvas canvas, double cx, double cy, double ww, double wh,
      bool lit, {required List<Color> colors}) {
    // Marco exterior (blanco, con arco en la parte superior)
    final frameW = ww + 10;
    final frameH = wh + 10;
    final archR = ww * 0.52;

    // Marco blanco completo
    final framePath = _archWindowPath(cx, cy, frameW, frameH, archR + 5);
    canvas.drawPath(framePath, Paint()..color = _trimShade);
    final framePath2 = _archWindowPath(cx, cy, frameW - 2, frameH - 2, archR + 3);
    canvas.drawPath(framePath2, Paint()..color = _trim);

    // Vidrieras: 3 paneles verticales con arcos
    final paneW = (ww - 10) / 3;
    final paneH = wh - 8;

    for (int i = 0; i < 3; i++) {
      final px = cx - ww / 2 + 4 + paneW * i + paneW / 2;
      final pTop = cy - wh / 2 + 4;
      final pRect = Rect.fromLTWH(px - paneW / 2, pTop, paneW, paneH);

      final panePath = _archWindowPath(px, pTop + paneH / 2, paneW, paneH, paneW * 0.52);

      if (lit) {
        canvas.drawPath(panePath, Paint()..color = colors[i].withAlpha(215));
        // Brillo interno
        canvas.save();
        canvas.clipPath(panePath);
        canvas.drawRect(pRect, Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.2, -0.5),
            radius: 0.8,
            colors: [Colors.white.withAlpha(110), Colors.transparent],
          ).createShader(pRect));
        canvas.restore();
      } else {
        canvas.drawPath(panePath, Paint()..color = _windowDark);
      }

      // Marco del panel
      canvas.drawPath(panePath, Paint()
        ..color = _trim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5);
    }

    // Línea horizontal divisoria
    canvas.drawLine(
      Offset(cx - ww / 2 + 4, cy + wh * 0.08),
      Offset(cx + ww / 2 - 4, cy + wh * 0.08),
      Paint()..color = _trim..strokeWidth = 2.0,
    );
  }

  Path _archWindowPath(double cx, double cy, double ww, double wh, double archR) {
    final path = Path();
    final l = cx - ww / 2;
    final r = cx + ww / 2;
    final t = cy - wh / 2;
    final b = cy + wh / 2;
    final archCY = t + archR;

    path.moveTo(l, b);
    path.lineTo(l, archCY);
    path.arcTo(
      Rect.fromCenter(center: Offset(cx, archCY), width: ww, height: archR * 2),
      math.pi, math.pi, false,
    );
    path.lineTo(r, b);
    path.close();
    return path;
  }

  void _drawEntrance(Canvas canvas, double cx, double w, double h) {
    final doorW = w * 0.155;
    final doorH = h * 0.155;
    final doorTop = h * 0.635;
    final doorBot = doorTop + doorH;

    // Pilastras blancas a los lados de la entrada
    for (int s in [-1, 1]) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(cx + s * doorW * 0.68, doorTop + doorH * 0.5),
          width: w * 0.028,
          height: doorH * 1.1,
        ),
        Paint()..color = _trim,
      );
    }

    // Arco de entrada con ornamento
    final archPath = _archWindowPath(cx, doorTop + doorH * 0.45, doorW * 1.25, doorH * 1.0, doorW * 0.65);
    canvas.drawPath(archPath, Paint()..color = _trim);

    // Dos puertas de madera
    for (int s in [-1, 1]) {
      final px = cx + s * doorW * 0.24;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(px, doorTop + doorH * 0.60), width: doorW * 0.44, height: doorH * 0.85),
          const Radius.circular(2),
        ),
        Paint()..color = _doorWood,
      );
      // Panel decorativo en la puerta
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(px, doorTop + doorH * 0.55), width: doorW * 0.30, height: doorH * 0.32),
          const Radius.circular(1),
        ),
        Paint()
          ..color = _brickDark.withAlpha(60)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      // Pomo
      canvas.drawCircle(
        Offset(cx + s * doorW * 0.07, doorTop + doorH * 0.63),
        2.5,
        Paint()..color = const Color(0xFFD4A820),
      );
    }

    // Escalones (3)
    for (int i = 0; i < 3; i++) {
      final stepW = doorW * (1.8 - i * 0.22);
      final stepH = h * 0.022;
      final stepY = doorBot + (2 - i) * stepH;
      canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, stepY + stepH / 2), width: stepW, height: stepH),
        Paint()..color = _trim,
      );
      canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, stepY + stepH / 2), width: stepW, height: stepH),
        Paint()
          ..color = _trimDark.withAlpha(80)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  // ── Gradiente de luz dorada (el llenado) ──────────────────────────────────────
  void _drawGlowOverlay(Canvas canvas, double w, double h) {
    if (fillFraction <= 0.005) return;

    final bBot = h * 0.820;
    final bTop = h * 0.048;
    final totalH = bBot - bTop;
    final glowTop = bBot - totalH * fillFraction;

    canvas.save();
    canvas.clipPath(_buildingClipPath(w, h));

    // Shimmer: la intensidad pulsa suavemente
    final pulse = (math.sin(glowPhase * 2 * math.pi) * 0.08 + 0.92).clamp(0.80, 1.0);
    final hotAlpha = (200 * pulse).round();
    final warmAlpha = (160 * pulse).round();

    final glowRect = Rect.fromLTRB(w * 0.04, glowTop, w * 0.96, bBot);

    // Capa principal del resplandor dorado
    canvas.drawRect(
      glowRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            _glowHot.withAlpha(hotAlpha),
            _glowWarm.withAlpha(warmAlpha),
            _glowCool.withAlpha(100),
            Colors.transparent,
          ],
          stops: const [0.0, 0.35, 0.70, 1.0],
        ).createShader(glowRect),
    );

    // Línea brillante en la superficie del resplandor (como lava/luz ascendiendo)
    if (fillFraction > 0.015) {
      final shimmerRect = Rect.fromLTWH(w * 0.04, glowTop - 3, w * 0.92, 6);
      canvas.drawRect(
        shimmerRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.transparent,
              Colors.white.withAlpha(160),
              Colors.white.withAlpha(200),
              Colors.white.withAlpha(160),
              Colors.transparent,
            ],
            stops: const [0.0, 0.25, 0.50, 0.75, 1.0],
          ).createShader(shimmerRect),
      );
    }

    canvas.restore();
  }

  // ── Sombras en los bordes para dar profundidad 3D ────────────────────────────
  void _drawBuildingEdgeShadows(Canvas canvas, double w, double h) {
    // Borde izquierdo
    final shadowL = Rect.fromLTWH(w * 0.04, h * 0.10, w * 0.045, h * 0.70);
    canvas.drawRect(
      shadowL,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Colors.black.withAlpha(75), Colors.transparent],
        ).createShader(shadowL),
    );

    // Borde derecho
    final shadowR = Rect.fromLTWH(w * 0.915, h * 0.10, w * 0.045, h * 0.70);
    canvas.drawRect(
      shadowR,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [Colors.black.withAlpha(55), Colors.transparent],
        ).createShader(shadowR),
    );
  }

  // ── Muro frontal con verja ────────────────────────────────────────────────────
  void _drawFrontFence(Canvas canvas, double w, double h) {
    final fTop = h * 0.820;
    final fH   = h * 0.105;
    final cx   = w * 0.50;

    // Muro de ladrillo
    final wallRect = Rect.fromLTWH(0, fTop, w, fH);
    canvas.drawRect(
      wallRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [_fenceBrick, _brickDark],
        ).createShader(wallRect),
    );

    // Líneas de mortero en la cerca
    final mPaint = Paint()..color = _brickDark.withAlpha(70)..strokeWidth = 1.0;
    for (int i = 1; i < 5; i++) {
      canvas.drawLine(Offset(0, fTop + fH * i / 5), Offset(w, fTop + fH * i / 5), mPaint);
    }

    // Remate blanco superior de la cerca
    canvas.drawRect(Rect.fromLTWH(0, fTop, w, h * 0.009), Paint()..color = _trim);
    // Sombra inferior del remate
    canvas.drawRect(Rect.fromLTWH(0, fTop + h * 0.009, w, h * 0.005),
        Paint()..color = _trimDark.withAlpha(100));

    // Apertura central (el paso a los escalones)
    final gateW = w * 0.195;
    canvas.drawRect(
      Rect.fromLTWH(cx - gateW / 2, fTop, gateW, fH * 0.82),
      Paint()..color = _skyBottom,
    );

    // Pilares del portón (a cada lado de la apertura)
    for (int s in [-1, 1]) {
      final px = cx + s * (gateW / 2 + w * 0.018);
      // Pilar
      canvas.drawRect(
        Rect.fromCenter(center: Offset(px, fTop + fH * 0.46), width: w * 0.028, height: fH * 0.92),
        Paint()..color = _trim,
      );
      // Sombreado lateral del pilar
      canvas.drawRect(
        Rect.fromCenter(center: Offset(px, fTop + fH * 0.46), width: w * 0.028, height: fH * 0.92),
        Paint()
          ..color = _trimDark.withAlpha(60)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      // Bola decorativa encima del pilar
      canvas.drawCircle(Offset(px, fTop - h * 0.006), 6.0, Paint()..color = _trim);
      canvas.drawCircle(Offset(px, fTop - h * 0.006), 3.5, Paint()..color = _trimShade);
    }
  }

  @override
  bool shouldRepaint(Building770Painter old) =>
      old.fillFraction != fillFraction || old.glowPhase != glowPhase;
}
