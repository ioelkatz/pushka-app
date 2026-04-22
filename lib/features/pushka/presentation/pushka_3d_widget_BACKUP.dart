import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/format_utils.dart';
import '../../../app/theme/app_tokens.dart';
import 'pushka_3d_painter.dart';

class Pushka3DWidget extends StatefulWidget {
  final double fillPercentage;
  final double goal;
  final double amount;
  final String currencySymbol;

  const Pushka3DWidget({
    super.key,
    required this.fillPercentage,
    required this.goal,
    required this.amount,
    required this.currencySymbol,
  });

  @override
  State<Pushka3DWidget> createState() => Pushka3DWidgetState();
}

class Pushka3DWidgetState extends State<Pushka3DWidget>
    with TickerProviderStateMixin {
  late AnimationController _fillController;
  late Animation<double> _fillAnimation;

  late AnimationController _coinController;
  late Animation<double> _coinProgress;
  bool _showCoin = false;

  late AnimationController _waveController;

  double _lastKnownFill = 0;

  @override
  void initState() {
    super.initState();
    _fillController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    final target = widget.fillPercentage.clamp(0.0, 1.0);
    final isSameFill = (_lastKnownFill - target).abs() < 0.001;
    _fillAnimation = Tween<double>(
      begin: isSameFill ? target : _lastKnownFill,
      end: target,
    ).animate(CurvedAnimation(
      parent: _fillController,
      curve: Curves.easeInOut,
    ));
    _lastKnownFill = target;
    if (isSameFill) {
      _fillController.value = 1.0;
    } else {
      _fillController.forward();
    }

    _coinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    );

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _coinProgress = CurvedAnimation(
      parent: _coinController,
      curve: const _CoinDropCurve(),
    );
    _coinController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (!mounted) return;
        setState(() => _showCoin = false);
        _coinController.reset();
      }
    });
  }

  void triggerCoinDrop() {
    if (_coinController.isAnimating) return;
    setState(() => _showCoin = true);
    _coinController.forward(from: 0);
  }

  @override
  void didUpdateWidget(Pushka3DWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.fillPercentage - widget.fillPercentage).abs() > 0.001) {
      _fillAnimation = Tween<double>(
        begin: _fillAnimation.value,
        end: widget.fillPercentage.clamp(0.0, 1.0),
      ).animate(CurvedAnimation(
        parent: _fillController,
        curve: Curves.easeInOut,
      ));
      _fillController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fillController.dispose();
    _coinController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasH = constraints.maxHeight;
        final canvasW = constraints.maxWidth;

        return AnimatedBuilder(
          animation: Listenable.merge([_fillController, _coinController, _waveController]),
          builder: (context, _) {
            final fill = _fillAnimation.value;

            final cylTop    = canvasH * 0.14;
            final cylH      = canvasH * 0.765;
            final cylBottom = cylTop + cylH;
            final liquidTop = cylBottom - (cylH * fill);

            final cylWidth = canvasW * 0.38;
            final ellipseH = cylWidth * 0.20;
            const labelH   = 18.0;

            final children = <Widget>[
              CustomPaint(
                painter: Pushka3DPainter(
                  fillFraction: fill,
                  wavePhase: _waveController.value * 2 * math.pi,
                ),
                size: Size(canvasW, canvasH),
                isComplex: true,
                willChange: fill > 0.005,
              ),
              Positioned(
                top: cylTop - labelH / 2 - ellipseH * 0.2,
                left: 0,
                child: _buildLabel(
                  '${widget.currencySymbol}${formatAmount(widget.goal)}',
                  AppTokens.mutedText,
                ),
              ),
              Positioned(
                top: liquidTop - labelH / 2,
                right: 0,
                child: _buildLabel(
                  '${widget.currencySymbol}${formatAmount(widget.amount)}',
                  AppTokens.primaryBlue,
                ),
              ),
            ];

            if (_showCoin) {
              _buildCoinAnimation(
                children: children,
                progress: _coinProgress.value,
                canvasW: canvasW,
                canvasH: canvasH,
                shimmerPhase: _waveController.value,
              );
            }

            return Stack(children: children);
          },
        );
      },
    );
  }

  void _buildCoinAnimation({
    required List<Widget> children,
    required double progress,
    required double canvasW,
    required double canvasH,
    required double shimmerPhase,
  }) {
    // ── Mirror painter geometry exactly ─────────────────────────────────────
    final pCylW   = canvasW * 0.42;
    final pEh     = pCylW * 0.22;
    final pCylTop = canvasH * 0.14;
    const slotAngle = -0.21;
    final slotCX  = canvasW / 2;
    final slotCY  = pCylTop - pEh * 0.18;

    // ── Coin base dimensions ─────────────────────────────────────────────────
    final coinW    = pCylW * 0.34;
    final coinH    = coinW * 0.22;     // exact lid perspective ratio
    final rimDepth = coinH * 0.75;

    // ── Trajectory ───────────────────────────────────────────────────────────
    final coinEndTop   = slotCY - coinH / 2;
    final coinStartTop = coinEndTop - 220.0;
    final coinTop      = coinStartTop + (coinEndTop - coinStartTop) * progress;

    // ── 7. Dynamic angle: starts slightly off, rotates to exact slot angle ───
    final currentAngle = lerpDouble(-0.04, slotAngle, progress.clamp(0.0, 1.0))!;

    // ── 1. Spin (tumbling): coin rotates on its Y axis while falling ─────────
    final spinPhase = progress * math.pi * 3.8;
    final rawSpin = math.max(0.12, math.sin(spinPhase).abs());
    // Lock into full width as coin reaches the slot
    final spinFactor = progress < 0.78
        ? rawSpin
        : rawSpin + (1.0 - rawSpin) * ((progress - 0.78) / 0.22);
    final visibleCoinW = coinW * spinFactor;

    // ── 6. Squish: compress vertically on final approach ─────────────────────
    final squishH = progress > 0.87
        ? coinH * (1.0 - ((progress - 0.87) / 0.13) * 0.25)
        : coinH;

    // ── 3. Wobble: dampened sinusoidal drift ─────────────────────────────────
    final wobble = math.sin(progress * math.pi * 3.5) *
        coinW * 0.08 * (1.0 - progress);
    final coinCenterX = slotCX + wobble;

    // ── Fade as coin enters slot ─────────────────────────────────────────────
    final coinOpacity =
        progress < 0.82 ? 1.0 : (1.0 - (progress - 0.82) / 0.18);

    Widget buildCoinWidget({double opacity = 1.0, double? overrideFaceH}) {
      final fh = overrideFaceH ?? squishH;
      return Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: currentAngle,
          alignment: Alignment(0.0, -rimDepth / (fh + rimDepth)),
          child: CustomPaint(
            size: Size(visibleCoinW, fh + rimDepth),
            painter: _CoinPainter(
              shimmerPhase: shimmerPhase,
              faceH: fh,
            ),
          ),
        ),
      );
    }

    // ── 2. Shadow on lid: grows as coin approaches ───────────────────────────
    if (progress > 0.28) {
      final sp = ((progress - 0.28) / 0.72).clamp(0.0, 1.0);
      final shadowW = visibleCoinW * 0.88 * sp;
      final shadowH = pEh * 0.14 * sp;
      final shadowOpacity = sp * 0.40 * coinOpacity;
      children.add(Positioned(
        left: slotCX - shadowW / 2,
        top: slotCY - shadowH / 2,
        child: Opacity(
          opacity: shadowOpacity.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: slotAngle,
            child: Container(
              width: shadowW,
              height: shadowH,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(shadowH / 2),
              ),
            ),
          ),
        ),
      ));
    }

    // ── Main coin ────────────────────────────────────────────────────────────
    children.add(Positioned(
      left: coinCenterX - visibleCoinW / 2,
      top: coinTop,
      child: buildCoinWidget(opacity: coinOpacity),
    ));

    // ── Impact sparkles ──────────────────────────────────────────────────────
    if (progress > 0.80) {
      final sp = (progress - 0.80) / 0.20;
      final sparkOpacity = (1.0 - sp * 1.15).clamp(0.0, 1.0);

      for (int i = 0; i < 8; i++) {
        final angle = (i / 8) * 2 * math.pi + slotAngle;
        final dist  = sp * 24;
        final sx = slotCX + math.cos(angle) * dist;
        final sy = slotCY + math.sin(angle) * dist;
        final sz = 4.0 * (1.0 - sp * 0.5);
        children.add(Positioned(
          left: sx - sz / 2,
          top:  sy - sz / 2,
          child: Opacity(
            opacity: sparkOpacity,
            child: Container(
              width: sz, height: sz,
              decoration: const BoxDecoration(
                color: Color(0xFFFFD700),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ));
      }

      for (int i = 0; i < 5; i++) {
        final angle = ((i + 0.5) / 5) * 2 * math.pi + slotAngle;
        final dist  = sp * 14;
        final sx = slotCX + math.cos(angle) * dist;
        final sy = slotCY + math.sin(angle) * dist;
        final sz = 2.8 * (1.0 - sp);
        children.add(Positioned(
          left: sx - sz / 2,
          top:  sy - sz / 2,
          child: Opacity(
            opacity: sparkOpacity * 0.65,
            child: Container(
              width: sz, height: sz,
              decoration: const BoxDecoration(
                color: Color(0xFFFFF176),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ));
      }
    }
  }

  Widget _buildLabel(String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// Needed for angle lerp
double? lerpDouble(num? a, num? b, double t) {
  if (a == null && b == null) return null;
  a ??= 0.0;
  b ??= 0.0;
  return a + (b - a) * t;
}

// ─────────────────────────────────────────────────────────────────────────────
// Coin drop curve: gravity for first 68% of time (covers 80% of distance),
// then decelerates sharply for the last 32% (remaining 20% of distance).
// This lets all impact effects (squish, sparkles, glint) be clearly visible.
// ─────────────────────────────────────────────────────────────────────────────

class _CoinDropCurve extends Curve {
  const _CoinDropCurve();

  @override
  double transformInternal(double t) {
    if (t <= 0.68) {
      // Gravity phase — easeIn, reaches 80% of distance at t=0.68
      final p = t / 0.68;
      return p * p * 0.80;
    } else {
      // Slow-approach phase — easeOut over the last 20% of distance
      final p = (t - 0.68) / 0.32;
      final eased = 1.0 - math.pow(1.0 - p, 2).toDouble();
      return 0.80 + eased * 0.20;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Coin CustomPainter
// ─────────────────────────────────────────────────────────────────────────────

class _CoinPainter extends CustomPainter {
  final double shimmerPhase;
  final double faceH;

  const _CoinPainter({required this.shimmerPhase, required this.faceH});

  @override
  void paint(Canvas canvas, Size size) {
    final w        = size.width;
    final cx       = w / 2;
    final rimDepth = size.height - faceH;
    final faceRect = Rect.fromLTWH(0, 0, w, faceH);
    final facePath = Path()..addOval(faceRect);

    // ── 1. Bottom edge of rim ─────────────────────────────────────────────
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, faceH / 2 + rimDepth),
        width: w, height: faceH,
      ),
      Paint()..color = const Color(0xFF2D1500),
    );

    // ── 2. Rim side band ──────────────────────────────────────────────────
    final sideRect = Rect.fromLTWH(0, faceH / 2, w, rimDepth);
    canvas.drawRect(
      sideRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Color(0xFFC8860A), Color(0xFF5A3000)],
        ).createShader(sideRect),
    );

    // ── 4. Edge glint on rim (orbits opposite the shimmer) ────────────────
    final glintAngle = (shimmerPhase + 0.5) * 2 * math.pi;
    final glintX = cx + math.cos(glintAngle) * w * 0.38;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(glintX, faceH / 2 + rimDepth * 0.18),
        width: w * 0.14,
        height: rimDepth * 0.55,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.50),
    );

    // ── 3. Face — radial gold gradient ───────────────────────────────────
    canvas.drawOval(
      faceRect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.18, -0.28),
          radius: 1.05,
          colors: const [
            Color(0xFFFFFACD),
            Color(0xFFFFD700),
            Color(0xFFDAA520),
            Color(0xFFB8860B),
          ],
          stops: const [0.0, 0.38, 0.70, 1.0],
        ).createShader(faceRect),
    );

    // Face rim stroke
    canvas.drawOval(
      faceRect,
      Paint()
        ..color = const Color(0xFF8B6000).withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.038,
    );

    // ── 3. ₪ symbol embossed on face ─────────────────────────────────────
    if (w > 6) {
      final tp = TextPainter(
        text: TextSpan(
          text: '₪',
          style: TextStyle(
            fontSize: faceH * 1.1,
            color: const Color(0xFF7A4E00).withValues(alpha: 0.62),
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.clipPath(facePath);
      tp.paint(
        canvas,
        Offset(cx - tp.width / 2, faceH / 2 - tp.height / 2),
      );
      canvas.restore();
    }

    // ── Animated shimmer spot orbiting the face ───────────────────────────
    canvas.save();
    canvas.clipPath(facePath);
    final shimmerAngle  = shimmerPhase * 2 * math.pi;
    final shimmerCenter = Offset(
      cx + math.cos(shimmerAngle) * w * 0.24,
      faceH / 2 + math.sin(shimmerAngle) * faceH * 0.24,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: shimmerCenter,
        width: w * 0.42,
        height: faceH * 0.42,
      ),
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.70),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(
          Rect.fromCircle(center: shimmerCenter, radius: w * 0.21),
        ),
    );

    // Static specular top-left
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - w * 0.22, faceH * 0.24),
        width: w * 0.26, height: faceH * 0.26,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.34),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CoinPainter old) =>
      old.shimmerPhase != shimmerPhase || old.faceH != faceH;
}
