import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Animation used when the donor adds an amount to the *classic* (lata)
/// pushka style. A 3D-looking coin falls from below the progress bar
/// straight down into the slot at the top of the pushka image, shrinking
/// and fading in the final ~25% to simulate "entering" the slot.
///
/// Kept as a separate widget from [BillFallAnimation] (which still drives
/// the 770 style) so each path is simple and the 770 behavior literally
/// can't regress from a coin-side change.
class CoinFallAnimation extends StatefulWidget {
  final VoidCallback onDone;
  final double startY;
  final double targetY;

  const CoinFallAnimation({
    super.key,
    required this.onDone,
    required this.startY,
    required this.targetY,
  });

  @override
  State<CoinFallAnimation> createState() => _CoinFallAnimationState();
}

class _CoinFallAnimationState extends State<CoinFallAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    // Slightly faster than the bill (1500 vs 3500ms): a coin doesn't
    // flutter, it drops with gravity. Long flights here would feel slow.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..forward();
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        // Quadratic ease-in mimics gravity acceleration (slower at start,
        // faster near the slot). Same curve the bill uses; the difference
        // is the total duration and the lack of horizontal flutter.
        final curvedT = Curves.easeInQuad.transform(t);
        final y = widget.startY + (widget.targetY - widget.startY) * curvedT;

        // 3D coin flip: rotate around the X axis so the coin shows its
        // face / edge / back face as it falls. The Matrix4 perspective
        // entry (3,2)=0.0015 is what makes the rotation look 3D instead
        // of a flat squish. ~2 full revolutions over the fall.
        final flipAngle = t * 2 * math.pi * 2;
        // Subtle Y-axis wobble — tiny, so the coin looks alive without
        // wobbling off the vertical drop line.
        final yAxisWobble = math.sin(t * math.pi * 3) * 0.15;

        // Entering the slot: final ~25% of the flight, the coin shrinks
        // from 1.0 → 0.25 and opacity fades 1.0 → 0.0. Together they
        // sell the illusion of disappearing into the slot.
        final enterT = ((t - 0.75) / 0.25).clamp(0.0, 1.0);
        final scale = 1.0 - enterT * 0.75;
        final opacity = 1.0 - enterT;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: y,
              left: 0,
              right: 0,
              child: Center(
                child: Opacity(
                  opacity: opacity,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0015) // perspective
                      ..rotateX(flipAngle)
                      ..rotateY(yAxisWobble)
                      ..scaleByDouble(scale, scale, scale, 1.0),
                    child: Image.asset(
                      'assets/images/coin.webp',
                      width: 88,
                      height: 88,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class BillFallAnimation extends StatefulWidget {
  final VoidCallback onDone;
  final double startY;

  const BillFallAnimation({super.key, required this.onDone, this.startY = -90.0});

  @override
  State<BillFallAnimation> createState() => _BillFallAnimationState();
}

class _BillFallAnimationState extends State<BillFallAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    )..forward();
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        final curvedT = Curves.easeInQuad.transform(t);

        // Fall from below the title down to ~43% of screen height
        final yEnd = screenHeight * 0.43;
        final y = widget.startY + (yEnd - widget.startY) * curvedT;

        // Sinusoidal horizontal flutter ±28 px, 2.5 cycles
        final x = math.sin(t * 2.5 * 2 * math.pi) * 28.0;

        // Rotation oscillates ±0.18 rad, slightly phase-shifted from x
        final angle = math.sin(t * 2.5 * 2 * math.pi + 0.8) * 0.18;

        // Fully visible for first 70% of flight, then fades out
        final opacity =
            t < 0.70 ? 1.0 : ((1.0 - (t - 0.70) / 0.30).clamp(0.0, 1.0));

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: y,
              left: 0,
              right: 0,
              child: Center(
                child: Opacity(
                  opacity: opacity,
                  child: Transform.rotate(
                    angle: angle,
                    child: Transform.translate(
                      offset: Offset(x, 0),
                      child: Image.asset(
                        'assets/images/rebbe_dollar.png',
                        width: 140,
                        height: 70,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
