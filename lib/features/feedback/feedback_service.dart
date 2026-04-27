import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FeedbackService {
  FeedbackService._();
  static final FeedbackService instance = FeedbackService._();

  final AudioPlayer _coinPlayer = AudioPlayer();
  final AudioPlayer _successPlayer = AudioPlayer();
  final AudioPlayer _billPlayer = AudioPlayer();
  final AudioPlayer _ambientPlayer = AudioPlayer();
  bool _initialized = false;

  bool soundEnabled = true;
  bool coinJingleEnabled = true;
  bool vibrationEnabled = true;
  bool ambientEnabled = false;

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
      await _coinPlayer.setSource(AssetSource('sounds/coin.wav'));
      await _successPlayer.setSource(AssetSource('sounds/success.wav'));
      await _billPlayer.setSource(AssetSource('sounds/bill_flutter.wav'));
      await _coinPlayer.setVolume(0.7);
      await _successPlayer.setVolume(1.0);
      await _billPlayer.setVolume(0.8);
      _initialized = true;
    } catch (e, st) {
      debugPrint('FeedbackService init error: $e\n$st');
    }
  }

  void updatePreferences({
    bool? sound,
    bool? coinJingle,
    bool? vibration,
    bool? ambient,
  }) {
    if (sound != null) soundEnabled = sound;
    if (coinJingle != null) coinJingleEnabled = coinJingle;
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
  }

  Future<void> stopAmbient() async {
    ambientEnabled = false;
    try {
      await _ambientPlayer.stop();
    } catch (_) {}
  }

  Future<void> playCoinDrop() async {
    if (!coinJingleEnabled || kIsWeb) return;
    if (vibrationEnabled) {
      // Double-tap pattern: coin bounce feel
      HapticFeedback.lightImpact();
      unawaited(Future.delayed(const Duration(milliseconds: 80), HapticFeedback.lightImpact));
    }
    if (!soundEnabled) return;
    try {
      await _coinPlayer.stop();
      await _coinPlayer.play(AssetSource('sounds/coin.wav'));
    } catch (_) {}
  }

  Future<void> playSuccess() async {
    if (!soundEnabled || kIsWeb) return;
    if (vibrationEnabled) {
      HapticFeedback.mediumImpact();
      unawaited(Future.delayed(const Duration(milliseconds: 100), HapticFeedback.mediumImpact));
      unawaited(Future.delayed(const Duration(milliseconds: 200), HapticFeedback.heavyImpact));
    }
    try { await _coinPlayer.stop(); } catch (_) {}
    try { await _billPlayer.stop(); } catch (_) {}
    unawaited(_fadeAmbientTo(_ambientDuck));
    late StreamSubscription<void> sub;
    sub = _successPlayer.onPlayerComplete.listen((_) {
      sub.cancel();
      unawaited(_fadeAmbientTo(_ambientNormal));
    });
    try {
      await _successPlayer.stop();
      await _successPlayer.play(AssetSource('sounds/success.wav'), volume: 1.0);
    } catch (e) {
      debugPrint('[FeedbackService] playSuccess error: $e');
      sub.cancel();
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
    _coinPlayer.dispose();
    _successPlayer.dispose();
    _billPlayer.dispose();
    _ambientPlayer.dispose();
  }
}