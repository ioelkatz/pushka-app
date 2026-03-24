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

  static double _lastKnownFill = 0;

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
      duration: const Duration(milliseconds: 420),
    );
    _coinProgress = CurvedAnimation(
      parent: _coinController,
      curve: Curves.easeIn,
    );
    _coinController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasH = constraints.maxHeight;
        final canvasW = constraints.maxWidth;

        return AnimatedBuilder(
          animation: Listenable.merge([_fillController, _coinController]),
          builder: (context, _) {
            final fill = _fillAnimation.value;

            final cylTop = canvasH * 0.08;
            final cylH = canvasH * 0.78;
            final cylBottom = cylTop + cylH;
            final liquidTop = cylBottom - (cylH * fill);

            final cylWidth = canvasW * 0.38;
            final ellipseH = cylWidth * 0.20;
            final labelH = 18.0;

            final children = <Widget>[
              CustomPaint(
                painter: Pushka3DPainter(fillFraction: fill),
                size: Size(canvasW, canvasH),
                isComplex: true,
                willChange: false,
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
              final progress = _coinProgress.value;
              final coinStartY = cylTop - 36;
              final coinEndY = cylTop + 2;
              final coinY = coinStartY + (coinEndY - coinStartY) * progress;
              final coinSize = 28.0 * (1.0 - progress * 0.3);
              final coinOpacity = progress < 0.7 ? 1.0 : (1.0 - (progress - 0.7) / 0.3);

              children.add(
                Positioned(
                  top: coinY,
                  left: canvasW / 2 - coinSize / 2,
                  child: Opacity(
                    opacity: coinOpacity.clamp(0.0, 1.0),
                    child: Container(
                      width: coinSize,
                      height: coinSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFFD700), Color(0xFFC5960C)],
                        ),

                      ),
                      child: Center(
                        child: Text(
                          '\$',
                          style: TextStyle(
                            color: const Color(0xFF7A5C00),
                            fontSize: coinSize * 0.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            return Stack(children: children);
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
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
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
