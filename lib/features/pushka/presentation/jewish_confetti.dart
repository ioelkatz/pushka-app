import 'dart:math';
import 'package:flutter/material.dart';

// ── Controller ──────────────────────────────────────────────────────────────

class JewishConfettiController {
  VoidCallback? _play;
  void play() => _play?.call();
  void dispose() { _play = null; }
}

// ── Widget ───────────────────────────────────────────────────────────────────

class JewishConfetti extends StatefulWidget {
  final JewishConfettiController controller;
  const JewishConfetti({super.key, required this.controller});

  @override
  State<JewishConfetti> createState() => _JewishConfettiState();
}

class _JewishConfettiState extends State<JewishConfetti>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  List<_Particle> _particles = [];
  static final _rng = Random();
  bool _active = false;

  // Unicode symbols — rendered by the system font (Android Noto Emoji / iOS Apple emoji)
  static const _symbols = [
    '✡',  // Star of David
    '🕎',  // Menorah
    '🕯',  // Candle
    '📜',  // Torah scroll
    '🌟',  // Gold star
    '✨',  // Sparkles
    '🪬',  // Hamsa / Hand
    '🔯',  // Star of David with dot
  ];

  static const _shapeColors = [
    Color(0xFF0038B8), // Israeli flag blue
    Color(0xFFD4AF37), // gold
    Color(0xFFFFFFFF), // white
    Color(0xFF5B8DD9), // sky blue
    Color(0xFFE8C547), // warm gold
    Color(0xFF002FA7), // deep blue
    Color(0xFFFF6B35), // orange
    Color(0xFFFF3366), // hot pink
    Color(0xFF10B981), // emerald green
    Color(0xFFFFD700), // bright yellow
    Color(0xFFA855F7), // purple
    Color(0xFF06B6D4), // cyan
    Color(0xFFFF9500), // amber
    Color(0xFFEC4899), // pink
  ];

  @override
  void initState() {
    super.initState();
    widget.controller._play = _doPlay;
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )
      ..addListener(_tick)
      ..addStatusListener(_onStatus);
  }

  void _tick() { if (_active) setState(() {}); }

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      setState(() {
        _active = false;
        _particles.clear();
      });
    }
  }

  void _doPlay() {
    _anim.reset();
    _particles = _spawn();
    setState(() => _active = true);
    _anim.forward();
  }

  List<_Particle> _spawn() {
    final list = <_Particle>[];

    // Emoji / symbol particles — 28 spread across the top
    for (int i = 0; i < 28; i++) {
      list.add(_Particle(
        startX:    0.04 + _rng.nextDouble() * 0.92,
        startY:   -0.02 - _rng.nextDouble() * 0.10,
        vx:        (_rng.nextDouble() - 0.5) * 0.55,
        vy:         0.45 + _rng.nextDouble() * 0.45,
        gravity:    0.28 + _rng.nextDouble() * 0.30,
        wobbleAmp:  _rng.nextDouble() * 0.022,
        wobbleFreq: 1.5 + _rng.nextDouble() * 2.5,
        rotation:   0,
        rotSpeed:   0,
        symbol:     _symbols[_rng.nextInt(_symbols.length)],
        color:      Colors.white,
        size:       22 + _rng.nextDouble() * 16,
        delay:      _rng.nextDouble() * 0.18,
        shapeType:  0,
      ));
    }

    // Colored shape particles — 80 pieces (thin rects, circles, squares)
    for (int i = 0; i < 80; i++) {
      list.add(_Particle(
        startX:    0.01 + _rng.nextDouble() * 0.98,
        startY:   -0.01 - _rng.nextDouble() * 0.07,
        vx:        (_rng.nextDouble() - 0.5) * 0.65,
        vy:         0.42 + _rng.nextDouble() * 0.55,
        gravity:    0.22 + _rng.nextDouble() * 0.35,
        wobbleAmp:  _rng.nextDouble() * 0.038,
        wobbleFreq: 2.0 + _rng.nextDouble() * 5.0,
        rotation:   _rng.nextDouble() * 2 * pi,
        rotSpeed:   (_rng.nextDouble() - 0.5) * 14,
        symbol:     null,
        color:      _shapeColors[_rng.nextInt(_shapeColors.length)],
        size:        5 + _rng.nextDouble() * 10,
        delay:      _rng.nextDouble() * 0.22,
        shapeType:  _rng.nextInt(3),
      ));
    }

    return list;
  }

  @override
  void dispose() {
    widget.controller._play = null;
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _Painter(_particles, _anim.value),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

// ── Particle model ────────────────────────────────────────────────────────────

class _Particle {
  final double startX;
  final double startY;
  final double vx;
  final double vy;
  final double gravity;
  final double wobbleAmp;
  final double wobbleFreq;
  final double rotation;
  final double rotSpeed;
  final String? symbol; // null → colored shape
  final Color color;
  final double size;
  final double delay;  // 0..1 normalized start time
  final int shapeType;

  const _Particle({
    required this.startX,
    required this.startY,
    required this.vx,
    required this.vy,
    required this.gravity,
    required this.wobbleAmp,
    required this.wobbleFreq,
    required this.rotation,
    required this.rotSpeed,
    required this.symbol,
    required this.color,
    required this.size,
    required this.delay,
    required this.shapeType,
  });
}

// ── Painter ───────────────────────────────────────────────────────────────────

class _Painter extends CustomPainter {
  final List<_Particle> particles;
  final double t; // 0..1

  const _Painter(this.particles, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      // Each particle has its own delayed timeline
      final et = ((t - p.delay) / (1.0 - p.delay)).clamp(0.0, 1.0);
      if (et <= 0) continue;

      // Physics
      final px = (p.startX
              + p.vx * et
              + p.wobbleAmp * sin(et * p.wobbleFreq * 2 * pi))
          * size.width;
      final py =
          (p.startY + p.vy * et + p.gravity * et * et) * size.height;

      if (py > size.height + 80) continue;

      // Fade out over the last 25% of each particle's life
      final opacity =
          et > 0.75 ? (1.0 - (et - 0.75) / 0.25).clamp(0.0, 1.0) : 1.0;

      canvas.save();
      canvas.translate(px, py);

      if (p.symbol != null) {
        // Emoji rendered by the platform font — looks crisp and recognizable
        final tp = TextPainter(
          text: TextSpan(
            text: p.symbol,
            style: TextStyle(fontSize: p.size, height: 1),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        if (opacity < 1.0) {
          // saveLayer applies opacity to an already-composited emoji glyph
          canvas.saveLayer(
            Rect.fromLTWH(-tp.width / 2 - 2, -tp.height / 2 - 2,
                tp.width + 4, tp.height + 4),
            Paint()..color = Colors.white.withValues(alpha: opacity),
          );
          tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
          canvas.restore();
        } else {
          tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        }
      } else {
        // Colored geometric shape with rotation
        canvas.rotate(p.rotation + p.rotSpeed * et);
        final paint = Paint()..color = p.color.withValues(alpha: opacity);
        switch (p.shapeType) {
          case 0: // thin ribbon — classic confetti look
            canvas.drawRect(
              Rect.fromCenter(
                  center: Offset.zero,
                  width: p.size * 2.2,
                  height: p.size * 0.55),
              paint,
            );
            break;
          case 1: // circle dot
            canvas.drawCircle(Offset.zero, p.size * 0.5, paint);
            break;
          default: // square
            canvas.drawRect(
              Rect.fromCenter(
                  center: Offset.zero, width: p.size, height: p.size),
              paint,
            );
        }
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Painter old) => old.t != t;
}
