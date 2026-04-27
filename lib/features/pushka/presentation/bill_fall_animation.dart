import 'dart:math' as math;
import 'package:flutter/material.dart';

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
