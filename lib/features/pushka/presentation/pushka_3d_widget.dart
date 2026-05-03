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

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
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
          animation: Listenable.merge([_fillController, _waveController]),
          builder: (context, _) {
            final fill = _fillAnimation.value;

            final cylTop    = canvasH * 0.14;
            final cylH      = canvasH * 0.765;
            final cylBottom = cylTop + cylH;
            final liquidTop = cylBottom - (cylH * fill);

            final cylWidth = canvasW * 0.38;
            final ellipseH = cylWidth * 0.20;
            const labelH   = 18.0;

            return Stack(
              children: [
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
                    Theme.of(context).brightness == Brightness.dark
                        ? Colors.white
                        : AppTokens.mutedText,
                  ),
                ),
                Positioned(
                  top: liquidTop - labelH / 2,
                  right: 0,
                  child: _buildLabel(
                    '${widget.currencySymbol}${formatAmount(widget.amount)}',
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
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
