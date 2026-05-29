import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FeedbackService {
  FeedbackService._();
  static final FeedbackService instance = FeedbackService._();

  final AudioPlayer _successPlayer = AudioPlayer();
  final AudioPlayer _billPlayer = AudioPlayer();
  final AudioPlayer _coinPlayer = AudioPlayer();
  final AudioPlayer _ambientPlayer = AudioPlayer();
  bool _initialized = false;

  bool soundEnabled = true;
  bool vibrationEnabled = true;
  bool ambientEnabled = false;

  // Held so we can cancel the previous onPlayerComplete listener before
  // re-attaching when playSuccess() is called repeatedly. Without this,
  // a user spamming the donate button would accumulate one listener per tap.
  StreamSubscription<void>? _successCompleteSub;

  double _ambientVolume = 0.85;
  static const _ambientDuck   = 0.12;
  static const _ambientNormal = 0.85;

  static const _ambientUrl =
      'https://storage.googleapis.com/pushka-app-ioel.firebasestorage.app/ambient/nigunim.mp3';

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      // Set persistent audio focus so sounds aren't blocked by each other on Android.
      await AudioPlayer.global.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
          isSpeakerphoneOn: false,
          stayAwake: false,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
        ),
      ));
      await _successPlayer.setSource(AssetSource('sounds/success.wav'));
      await _billPlayer.setSource(AssetSource('sounds/bill_flutter.wav'));
      await _successPlayer.setVolume(1.0);
      await _billPlayer.setVolume(0.8);
      _initialized = true;
    } catch (e, st) {
      debugPrint('FeedbackService init error: $e\n$st');
    }
  }

  void updatePreferences({
    bool? sound,
    bool? vibration,
    bool? ambient,
  }) {
    if (sound != null) soundEnabled = sound;
    if (vibration != null) vibrationEnabled = vibration;
    if (ambient != null && ambient != ambientEnabled) {
      ambientEnabled = ambient;
      if (ambient) {
        startAmbient();
      } else {
        stopAmbient();
      }
    }
  }

  Future<void> startAmbient() async {
    if (kIsWeb) return;
    ambientEnabled = true;
    _ambientVolume = _ambientNormal;
    try {
      await _ambientPlayer.setVolume(_ambientVolume);
      await _ambientPlayer.setReleaseMode(ReleaseMode.loop);
      await _ambientPlayer.play(UrlSource(_ambientUrl));
    } catch (e) {
      debugPrint('[FeedbackService] startAmbient error: $e');
    }
  }

  Future<void> _fadeAmbientTo(double target, {int durationMs = 300}) async {
    if (!ambientEnabled || kIsWeb) return;
    const steps = 8;
    final stepMs = durationMs ~/ steps;
    final delta  = (target - _ambientVolume) / steps;
    for (int i = 0; i < steps; i++) {
      await Future<void>.delayed(Duration(milliseconds: stepMs));
      _ambientVolume = (_ambientVolume + delta).clamp(0.0, 1.0);
      try { await _ambientPlayer.setVolume(_ambientVolume); } catch (_) {}
    }
    _ambientVolume = target;
    try { await _ambientPlayer.setVolume(_ambientVolume); } catch (_) {}

    // If restoring to normal, ensure the ambient is actually playing —
    // Android audio focus may have paused it while the effect played.
    if (target >= _ambientNormal) {
      try {
        await _ambientPlayer.resume();
      } catch (_) {
        // resume() failed (e.g. player was stopped entirely) — restart from scratch
        await startAmbient();
      }
    }
  }

  Future<void> stopAmbient() async {
    ambientEnabled = false;
    try {
      await _ambientPlayer.stop();
    } catch (_) {}
  }

  Future<void> playSuccess() async {
    if (!soundEnabled || kIsWeb) return;
    if (vibrationEnabled) {
      HapticFeedback.mediumImpact();
      unawaited(Future.delayed(const Duration(milliseconds: 100), HapticFeedback.mediumImpact));
      unawaited(Future.delayed(const Duration(milliseconds: 200), HapticFeedback.heavyImpact));
    }
    try { await _billPlayer.stop(); } catch (_) {}
    unawaited(_fadeAmbientTo(_ambientDuck));
    try {
      await _successPlayer.stop();
      // Cancel any prior listener so rapid repeats don't accumulate subs.
      await _successCompleteSub?.cancel();
      _successCompleteSub = _successPlayer.onPlayerComplete.listen((_) {
        _successCompleteSub?.cancel();
        _successCompleteSub = null;
        unawaited(_fadeAmbientTo(_ambientNormal));
      });
      await _successPlayer.play(AssetSource('sounds/success.wav'), volume: 1.0);
    } catch (e) {
      debugPrint('[FeedbackService] playSuccess error: $e');
      unawaited(_fadeAmbientTo(_ambientNormal));
    }
  }

  /// Soft flutter at start of bill fall, then a thud at 2.5 s when it enters.
  Future<void> playBillFall() async {
    if (!soundEnabled || kIsWeb) return;
    unawaited(_fadeAmbientTo(_ambientDuck));
    try {
      await _billPlayer.stop();
      await _billPlayer.setVolume(0.8);
      await _billPlayer.play(AssetSource('sounds/bill_flutter.wav'),
          position: const Duration(milliseconds: 300));
      // Fade out over the last 600 ms to match the bill's opacity fade
      unawaited(Future.delayed(const Duration(milliseconds: 2900), () async {
        for (final step in [0.65, 0.45, 0.28, 0.14, 0.04]) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          try { await _billPlayer.setVolume(step); } catch (_) {}
        }
        try { await _billPlayer.stop(); } catch (_) {}
        unawaited(_fadeAmbientTo(_ambientNormal));
      }));
    } catch (_) {
      unawaited(_fadeAmbientTo(_ambientNormal));
    }
  }

  /// Coin sparkle/drop — used when the donor adds an amount to the
  /// classic pushka style. 770 style still uses [playBillFall]. Same
  /// soundEnabled gate as the rest of FeedbackService — flips to silent
  /// instantly when the user toggles "sonido" off in settings.
  Future<void> playCoinDrop() async {
    if (!soundEnabled || kIsWeb) return;
    // 800 ms delay para que el sparkle suene cerca del momento en que
    // la moneda entra por la ranura, no cuando recién empieza a caer
    // desde arriba. Ioel ajustó este timing visualmente.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    unawaited(_fadeAmbientTo(_ambientDuck));
    try {
      await _coinPlayer.stop();
      await _coinPlayer.setVolume(0.85);
      await _coinPlayer.play(AssetSource('sounds/coin_drop.wav'));
      // Coin sound is shorter than the bill flutter (no 2.5s fade tail).
      // Restore ambient after the typical sample length.
      unawaited(Future.delayed(const Duration(milliseconds: 1500), () {
        unawaited(_fadeAmbientTo(_ambientNormal));
      }));
    } catch (_) {
      unawaited(_fadeAmbientTo(_ambientNormal));
    }
  }

  /// Heavy thud + light echo — used when pushka is emptied.
  void vibratePushkaEmpty() {
    if (!vibrationEnabled || kIsWeb) return;
    HapticFeedback.heavyImpact();
    unawaited(Future.delayed(const Duration(milliseconds: 120), HapticFeedback.lightImpact));
  }

  void vibrate() {
    if (!vibrationEnabled || kIsWeb) return;
    HapticFeedback.mediumImpact();
  }

  void vibrateLight() {
    if (!vibrationEnabled || kIsWeb) return;
    HapticFeedback.lightImpact();
  }

  void vibrateHeavy() {
    if (!vibrationEnabled || kIsWeb) return;
    HapticFeedback.heavyImpact();
  }

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _successCompleteSub?.cancel();
    _successCompleteSub = null;
    _successPlayer.dispose();
    _billPlayer.dispose();
    _ambientPlayer.dispose();
  }
}