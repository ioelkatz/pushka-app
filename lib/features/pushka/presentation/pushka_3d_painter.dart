import 'package:flutter/material.dart';

class Pushka3DPainter extends CustomPainter {
  final double fillFraction;

  Pushka3DPainter({required this.fillFraction});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final cylWidth = w * 0.38;
    final cylHeight = h * 0.78;
    final ellipseH = cylWidth * 0.20;
    final cx = w / 2;
    final cylTop = h * 0.08;
    final cylBottom = cylTop + cylHeight;

    final cylLeft = cx - cylWidth / 2;
    final cylRight = cx + cylWidth / 2;

    _drawGlow(canvas, cx, cylTop + cylHeight / 2, cylWidth, cylHeight);
    _drawShadow(canvas, cx, cylBottom + ellipseH * 0.5, cylWidth, ellipseH);
    _drawBottomEllipse(canvas, cx, cylBottom, cylWidth, ellipseH);
    _drawBackWall(canvas, cylLeft, cylRight, cylTop, cylBottom);

    if (fillFraction > 0.005) {
      _drawLiquid(canvas, cx, cylLeft, cylRight, cylTop, cylBottom,
          cylWidth, ellipseH, fillFraction);
    }

    _drawFrontWall(canvas, cylLeft, cylRight, cylTop, cylBottom, cylWidth, ellipseH);
    _drawCylinderText(canvas, cx, cylTop, cylBottom, cylWidth, cylHeight);
    _drawTopLid(canvas, cx, cylTop, cylWidth, ellipseH);
    _drawCoinSlot(canvas, cx, cylTop, cylWidth, ellipseH);
    _drawGlossHighlight(canvas, cylLeft, cylTop, cylWidth, cylHeight, ellipseH);
  }

  void _drawGlow(Canvas canvas, double cx, double cy, double cylW, double cylH) {
    final paint = Paint()
      ..color = const Color(0xFF60A5FA).withValues(alpha: 0.07);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy),
        width: cylW * 2.0,
        height: cylH * 1.1,
      ),
      paint,
    );
  }

  void _drawShadow(Canvas canvas, double cx, double cy, double w, double eh) {
    final paint = Paint()
      ..color = const Color(0xFF94A3B8).withValues(alpha: 0.13);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: w * 1.15, height: eh * 1.5),
      paint,
    );
  }

  void _drawBottomEllipse(Canvas canvas, double cx, double cy, double w, double eh) {
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: eh);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          const Color(0xFF60A5FA),
          const Color(0xFF3B82F6),
          const Color(0xFF2563EB),
        ],
      ).createShader(rect);
    canvas.drawOval(rect, paint);
  }

  void _drawBackWall(Canvas canvas, double l, double r, double top, double bot) {
    final rect = Rect.fromLTRB(l, top, r, bot);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        stops: const [0.0, 0.12, 0.5, 0.88, 1.0],
        colors: [
          const Color(0xFFCBD5E1),
          const Color(0xFFEBEFF3),
          const Color(0xFFF8FAFC),
          const Color(0xFFEBEFF3),
          const Color(0xFFCBD5E1),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  void _drawLiquid(Canvas canvas, double cx, double l, double r, double cylTop,
      double cylBot, double cylW, double eh, double fill) {
    final liquidHeight = (cylBot - cylTop) * fill;
    final liquidTop = cylBot - liquidHeight;

    final bodyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          const Color(0xFF2563EB).withValues(alpha: 0.40),
          const Color(0xFF60A5FA).withValues(alpha: 0.30),
          const Color(0xFF93C5FD).withValues(alpha: 0.18),
        ],
      ).createShader(Rect.fromLTRB(l, liquidTop, r, cylBot));

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(l, cylTop, r, cylBot));

    final bodyPath = Path();
    bodyPath.addRect(Rect.fromLTRB(l, liquidTop, r, cylBot));
    canvas.drawPath(bodyPath, bodyPaint);

    final surfaceRect = Rect.fromCenter(
      center: Offset(cx, liquidTop),
      width: cylW,
      height: eh,
    );
    final surfacePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF93C5FD).withValues(alpha: 0.30),
          const Color(0xFF60A5FA).withValues(alpha: 0.45),
          const Color(0xFF93C5FD).withValues(alpha: 0.30),
        ],
      ).createShader(surfaceRect);
    canvas.drawOval(surfaceRect, surfacePaint);

    final surfaceHighlight = Paint()
      ..color = Colors.white.withValues(alpha: 0.40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawOval(surfaceRect, surfaceHighlight);

    canvas.restore();
  }

  void _drawFrontWall(Canvas canvas, double l, double r, double top,
      double bot, double cylW, double eh) {
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        stops: const [0.0, 0.15, 0.85, 1.0],
        colors: [
          Colors.white.withValues(alpha: 0.10),
          Colors.transparent,
          Colors.transparent,
          Colors.black.withValues(alpha: 0.04),
        ],
      ).createShader(Rect.fromLTRB(l, top, r, bot));

    canvas.drawRect(Rect.fromLTRB(l, top, r, bot), paint);
  }

  void _drawCylinderText(Canvas canvas, double cx, double cylTop,
      double cylBot, double cylW, double cylH) {
    final letters = ['\u05E6', '\u05D3', '\u05E7', '\u05D4'];
    final colors = [
      const Color(0xFF2563EB),
      const Color(0xFF059669),
      const Color(0xFFD97706),
      const Color(0xFFDC2626),
    ];

    final fontSize = cylH * 0.20;
    final gap = fontSize * -0.30;

    final painters = <TextPainter>[];
    for (int i = 0; i < letters.length; i++) {
      final tp = TextPainter(
        text: TextSpan(
          text: letters[i],
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            color: colors[i].withValues(alpha: 0.75),
          ),
        ),
        textDirection: TextDirection.rtl,
      )..layout();
      painters.add(tp);
    }

    double totalHeight = 0;
    for (final tp in painters) {
      totalHeight += tp.height;
    }
    totalHeight += gap * (painters.length - 1);

    final startY = cylTop + (cylH - totalHeight) / 2;

    double currentY = startY;
    for (int i = 0; i < painters.length; i++) {
      final tp = painters[i];
      tp.paint(canvas, Offset(cx - tp.width / 2, currentY));
      currentY += tp.height + gap;
    }
  }

  void _drawTopLid(Canvas canvas, double cx, double top, double w, double eh) {
    final rect = Rect.fromCenter(center: Offset(cx, top), width: w, height: eh);

    final rimPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF94A3B8),
          const Color(0xFFCBD5E1),
          const Color(0xFF94A3B8),
        ],
      ).createShader(rect);
    canvas.drawOval(rect, rimPaint);

    final innerRect = Rect.fromCenter(
      center: Offset(cx, top - eh * 0.05),
      width: w * 0.90,
      height: eh * 0.72,
    );
    final innerPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFFE2E8F0),
          const Color(0xFFCBD5E1),
        ],
      ).createShader(innerRect);
    canvas.drawOval(innerRect, innerPaint);
  }

  void _drawCoinSlot(Canvas canvas, double cx, double top, double w, double eh) {
    final slotW = w * 0.32;
    final slotH = eh * 0.16;
    final slotRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, top - eh * 0.08),
        width: slotW,
        height: slotH,
      ),
      Radius.circular(slotH / 2),
    );
    canvas.drawRRect(slotRect, Paint()..color = const Color(0xFF475569));
    canvas.drawRRect(
      slotRect,
      Paint()
        ..color = const Color(0xFF334155)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
  }

  void _drawGlossHighlight(Canvas canvas, double l, double top,
      double cylW, double cylH, double eh) {
    final highlightW = cylW * 0.07;
    final highlightL = l + cylW * 0.14;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.40),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(
        Rect.fromLTRB(highlightL, top + eh / 2, highlightL + highlightW, top + cylH - eh / 2),
      );
    canvas.drawRect(
      Rect.fromLTRB(highlightL, top + eh / 2, highlightL + highlightW, top + cylH - eh / 2),
      paint,
    );

    final edgePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.black.withValues(alpha: 0.0),
          Colors.black.withValues(alpha: 0.04),
        ],
      ).createShader(
        Rect.fromLTRB(l + cylW * 0.85, top, l + cylW, top + cylH),
      );
    canvas.drawRect(
      Rect.fromLTRB(l + cylW * 0.85, top + eh / 2, l + cylW, top + cylH - eh / 2),
      edgePaint,
    );
  }

  @override
  bool shouldRepaint(covariant Pushka3DPainter oldDelegate) {
    return oldDelegate.fillFraction != fillFraction;
  }

}
