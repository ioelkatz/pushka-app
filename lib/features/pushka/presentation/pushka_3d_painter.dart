import 'dart:math' as math;
import 'package:flutter/material.dart';

class Pushka3DPainter extends CustomPainter {
  final double fillFraction;
  final double wavePhase; // driven by looping AnimationController (0 → 2π)

  Pushka3DPainter({required this.fillFraction, this.wavePhase = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final cylWidth  = w * 0.42;
    final cylHeight = h * 0.765;
    final ellipseH  = cylWidth * 0.22;
    final cx        = w / 2;
    final cylTop    = h * 0.14;
    final cylBottom = cylTop + cylHeight;
    final cylLeft   = cx - cylWidth / 2;
    final cylRight  = cx + cylWidth / 2;

    _drawShadow(canvas, cx, cylBottom + ellipseH * 0.5, cylWidth, ellipseH);
    _drawBottomEllipse(canvas, cx, cylBottom, cylWidth, ellipseH);
    _drawBackWall(canvas, cylLeft, cylRight, cylTop, cylBottom);

    if (fillFraction > 0.005) {
      _drawLiquid(canvas, cx, cylLeft, cylRight, cylTop, cylBottom,
          cylWidth, ellipseH, fillFraction);
    }

    _drawFrontWall(canvas, cylLeft, cylRight, cylTop, cylBottom, cylWidth, ellipseH);
    _drawTopRim(canvas, cx, cylTop, cylWidth, ellipseH);
    _drawCylinderText(canvas, cx, cylTop, cylBottom, cylWidth, cylHeight);
    _drawTopLid(canvas, cx, cylTop, cylWidth, ellipseH);
    _drawCoinSlot(canvas, cx, cylTop, cylWidth, ellipseH);
    _drawGlossHighlight(canvas, cylLeft, cylTop, cylWidth, cylHeight, ellipseH);
  }

  // ── Shadow (blue-tinted) ──────────────────────────────────────────────────

  void _drawShadow(Canvas canvas, double cx, double cy, double w, double eh) {
    for (int i = 4; i >= 0; i--) {
      final scale = 1.0 + i * 0.14;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, cy), width: w * scale, height: eh * scale),
        Paint()..color = const Color(0xFF1E40AF).withValues(alpha: 0.028),
      );
    }
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: w * 0.85, height: eh * 0.7),
      Paint()..color = const Color(0xFF1D4ED8).withValues(alpha: 0.12),
    );
  }

  // ── Bottom ellipse ────────────────────────────────────────────────────────

  void _drawBottomEllipse(Canvas canvas, double cx, double cy, double w, double eh) {
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: eh);
    canvas.drawOval(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            const Color(0xFF93C5FD),
            const Color(0xFF3B82F6),
            const Color(0xFF1D4ED8),
          ],
        ).createShader(rect),
    );
  }

  // ── Metallic rims ─────────────────────────────────────────────────────────

  void _drawTopRim(Canvas canvas, double cx, double cy, double w, double eh) {
    final rect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: w * 1.03,
      height: eh * 0.25,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            const Color(0xFF475569),
            const Color(0xFFCBD5E1),
            const Color(0xFF94A3B8),
            const Color(0xFF475569),
          ],
        ).createShader(rect),
    );
  }

  // ── Cylinder back wall ────────────────────────────────────────────────────

  void _drawBackWall(Canvas canvas, double l, double r, double top, double bot) {
    final rect = Rect.fromLTRB(l, top, r, bot);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: const [0.0, 0.07, 0.30, 0.55, 0.88, 1.0],
          colors: [
            const Color(0xFF8899AA),
            const Color(0xFFB8C4D4),
            const Color(0xFFEDF2F7),
            const Color(0xFFE2E8F0),
            const Color(0xFFB8C4D4),
            const Color(0xFF7A8FA6),
          ],
        ).createShader(rect),
    );
  }

  // ── Liquid fill with wave ─────────────────────────────────────────────────

  void _drawLiquid(Canvas canvas, double cx, double l, double r, double cylTop,
      double cylBot, double cylW, double eh, double fill) {
    final liquidHeight = (cylBot - cylTop) * fill;
    final liquidTop    = cylBot - liquidHeight;
    final waveAmp      = cylW * 0.018; // subtle wave amplitude

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(l, cylTop, r, cylBot));

    // Build wavy top-edge path.
    final liquidPath = Path();
    liquidPath.moveTo(l, cylBot);
    liquidPath.lineTo(l, liquidTop);

    const steps = 60;
    for (int i = 0; i <= steps; i++) {
      final t  = i / steps;
      final x  = l + (r - l) * t;
      final y  = liquidTop +
          math.sin(wavePhase + t * math.pi * 5) * waveAmp +
          math.sin(wavePhase * 0.7 + t * math.pi * 3) * waveAmp * 0.5;
      liquidPath.lineTo(x, y);
    }
    liquidPath.lineTo(r, cylBot);
    liquidPath.close();

    // Body fill.
    canvas.drawPath(
      liquidPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            const Color(0xFF1D4ED8).withValues(alpha: 0.58),
            const Color(0xFF3B82F6).withValues(alpha: 0.42),
            const Color(0xFF93C5FD).withValues(alpha: 0.24),
          ],
        ).createShader(Rect.fromLTRB(l, liquidTop, r, cylBot)),
    );

    // Animated surface ellipse — center follows wave.
    final surfaceY = liquidTop +
        math.sin(wavePhase) * waveAmp * 0.6;
    final surfaceRect = Rect.fromCenter(
      center: Offset(cx, surfaceY),
      width: cylW,
      height: eh,
    );

    canvas.drawOval(
      surfaceRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFBFDBFE).withValues(alpha: 0.55),
            const Color(0xFF60A5FA).withValues(alpha: 0.70),
            const Color(0xFF93C5FD).withValues(alpha: 0.40),
          ],
        ).createShader(surfaceRect),
    );

    // Surface highlight stroke.
    canvas.drawOval(
      surfaceRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );

    // Inner shimmer ring (depth effect).
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, surfaceY),
        width: cylW * 0.60,
        height: eh * 0.50,
      ),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    canvas.restore();
  }

  // ── Front wall overlay ────────────────────────────────────────────────────

  void _drawFrontWall(Canvas canvas, double l, double r, double top,
      double bot, double cylW, double eh) {
    final rect = Rect.fromLTRB(l, top, r, bot);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          stops: const [0.0, 0.10, 0.28, 1.0],
          colors: [
            Colors.white.withValues(alpha: 0.30),
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.02),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          stops: const [0.0, 0.12, 0.30, 1.0],
          colors: [
            Colors.black.withValues(alpha: 0.18),
            Colors.black.withValues(alpha: 0.07),
            Colors.black.withValues(alpha: 0.01),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
  }

  // ── Hebrew text (rotated) ─────────────────────────────────────────────────

  void _drawCylinderText(Canvas canvas, double cx, double cylTop,
      double cylBot, double cylW, double cylH) {
    final fontSize = cylW * 0.48;
    final tp = TextPainter(
      text: TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          letterSpacing: fontSize * 0.06,
        ),
        children: [
          TextSpan(text: '\u05E6', style: TextStyle(color: const Color(0xFF2563EB).withValues(alpha: 0.80))),
          TextSpan(text: '\u05D3', style: TextStyle(color: const Color(0xFF059669).withValues(alpha: 0.80))),
          TextSpan(text: '\u05E7', style: TextStyle(color: const Color(0xFFD97706).withValues(alpha: 0.80))),
          TextSpan(text: '\u05D4', style: TextStyle(color: const Color(0xFFDC2626).withValues(alpha: 0.80))),
        ],
      ),
      textDirection: TextDirection.rtl,
    )..layout();

    canvas.save();
    canvas.translate(cx - cylW * 0.07, cylTop + cylH / 2);
    canvas.rotate(-math.pi / 2);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  // ── Top lid ───────────────────────────────────────────────────────────────

  void _drawTopLid(Canvas canvas, double cx, double top, double w, double eh) {
    final rimRect = Rect.fromCenter(
      center: Offset(cx, top),
      width: w * 1.05,
      height: eh * 1.10,
    );
    canvas.drawOval(
      rimRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [const Color(0xFF64748B), const Color(0xFF334155)],
        ).createShader(rimRect),
    );

    final lidRect = Rect.fromCenter(
      center: Offset(cx, top - eh * 0.18),
      width: w * 1.05,
      height: eh * 0.90,
    );
    canvas.drawOval(
      lidRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0.0, 0.35, 0.70, 1.0],
          colors: [
            const Color(0xFFF1F5F9),
            const Color(0xFFE2E8F0),
            const Color(0xFFCBD5E1),
            const Color(0xFF94A3B8),
          ],
        ).createShader(lidRect),
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - w * 0.10, top - eh * 0.28),
        width: w * 0.38,
        height: eh * 0.32,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.60),
    );
  }

  // ── Coin slot (diagonal) ──────────────────────────────────────────────────

  void _drawCoinSlot(Canvas canvas, double cx, double top, double w, double eh) {
    final slotW  = w * 0.38;
    final slotH  = eh * 0.20;
    final slotCy = top - eh * 0.18;
    final radius = Radius.circular(slotH / 2);

    canvas.save();
    // Rotate ~12° around the slot center for a diagonal look.
    canvas.translate(cx, slotCy);
    canvas.rotate(-0.21); // ≈ 12 degrees CCW
    canvas.translate(-cx, -slotCy);

    // Shadow layer.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, slotCy + slotH * 0.4), width: slotW, height: slotH),
        radius,
      ),
      Paint()..color = const Color(0xFF0F172A).withValues(alpha: 0.55),
    );
    // Slot fill.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, slotCy), width: slotW, height: slotH),
        radius,
      ),
      Paint()..color = const Color(0xFF1E293B),
    );
    // Metal edge catch highlight.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, slotCy - slotH * 0.25),
          width: slotW * 0.85,
          height: slotH * 0.25,
        ),
        radius,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.20),
    );

    canvas.restore();
  }

  // ── Gloss highlight strip ─────────────────────────────────────────────────

  void _drawGlossHighlight(Canvas canvas, double l, double top,
      double cylW, double cylH, double eh) {
    final highlightW = cylW * 0.06;
    final highlightL = l + cylW * 0.13;
    final bodyTop    = top + eh / 2;
    final bodyBot    = top + cylH - eh / 2;
    canvas.drawRect(
      Rect.fromLTRB(highlightL, bodyTop, highlightL + highlightW, bodyBot),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.45),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(
          Rect.fromLTRB(highlightL, bodyTop, highlightL + highlightW, bodyBot),
        ),
    );
  }

  @override
  bool shouldRepaint(covariant Pushka3DPainter oldDelegate) {
    return oldDelegate.fillFraction != fillFraction ||
        oldDelegate.wavePhase != wavePhase;
  }
}
