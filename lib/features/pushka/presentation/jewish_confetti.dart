import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

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

  // Pre-decoded ui.Image handles for the symbol particles. CustomPainter
  // can't render Image widgets — it draws on a Canvas — so we have to
  // decode the assets once into ui.Image and let _Painter call
  // canvas.drawImageRect with them. Decoding happens in initState so the
  // first celebration doesn't pay the decode cost mid-animation.
  List<ui.Image> _images = const [];
  bool _imagesReady = false;

  // Asset paths (kept here, not in pubspec, so adding/removing a particle
  // type is a one-line code change). Pubspec exposes the folder, individual
  // additions don't need a pub get.
  static const _imageAssets = [
    'assets/images/confetti/magen_david.webp',
    'assets/images/confetti/menora.png',
    'assets/images/confetti/torah.webp',
    'assets/images/confetti/jala.webp',
    'assets/images/confetti/vino.webp',
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
    _loadImages();
  }

  Future<void> _loadImages() async {
    final loaded = <ui.Image>[];
    for (final path in _imageAssets) {
      try {
        final data = await rootBundle.load(path);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(),
        );
        final frame = await codec.getNextFrame();
        loaded.add(frame.image);
      } catch (e) {
        // Log with the path so we can distinguish a single bad asset from
        // a total load failure (which would leave the confetti with only
        // colored shapes — the user's report of "missing celebration
        // images" on PWA points at silent failures here).
        debugPrint('[JewishConfetti] failed to load $path: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _images = loaded;
      _imagesReady = loaded.isNotEmpty;
    });
    debugPrint('[JewishConfetti] loaded ${loaded.length}/${_imageAssets.length} images, ready=$_imagesReady');
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

    // Image particles — 28 spread across the top. Each picks a random
    // index into _images; the Painter looks up the actual ui.Image when
    // drawing. If images haven't finished loading yet (very fast taps
    // after cold start) we skip this group and only the color shapes
    // play — the next celebration will have the full set.
    if (_imagesReady) {
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
          imageIndex: _rng.nextInt(_images.length),
          color:      Colors.white,
          size:       38 + _rng.nextDouble() * 22, // bumped from 22-38 to 38-60
                                                    // since the images have more
                                                    // detail than emoji glyphs
                                                    // and look small at the
                                                    // emoji baseline size
          delay:      _rng.nextDouble() * 0.18,
          shapeType:  0,
        ));
      }
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
        imageIndex: null,
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
    for (final img in _images) {
      img.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _Painter(_particles, _anim.value, _images),
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
  final int? imageIndex; // null → colored shape; otherwise index into _images
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
    required this.imageIndex,
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
  final List<ui.Image> images;

  const _Painter(this.particles, this.t, this.images);

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

      if (p.imageIndex != null && p.imageIndex! < images.length) {
        // Image particle — draw the pre-decoded ui.Image scaled into a
        // square centered on origin. Image particles don't rotate (the
        // figures are recognizable assets like a menorah / torah, and
        // tumbling them upside-down looks wrong).
        final img = images[p.imageIndex!];
        final s = p.size;
        final dst = Rect.fromCenter(
          center: Offset.zero,
          width: s,
          height: s,
        );
        final src = Rect.fromLTWH(
          0,
          0,
          img.width.toDouble(),
          img.height.toDouble(),
        );
        final paint = Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Colors.white.withValues(alpha: opacity);
        canvas.drawImageRect(img, src, dst, paint);
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
