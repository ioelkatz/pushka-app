import 'package:flutter/material.dart';
import 'building_770_painter.dart';

class Building770Widget extends StatefulWidget {
  final double fillFraction; // 0.0 – 1.0

  const Building770Widget({super.key, required this.fillFraction});

  @override
  State<Building770Widget> createState() => _Building770WidgetState();
}

class _Building770WidgetState extends State<Building770Widget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glowController,
      builder: (context, _) {
        return CustomPaint(
          painter: Building770Painter(
            fillFraction: widget.fillFraction,
            glowPhase: _glowController.value,
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}
