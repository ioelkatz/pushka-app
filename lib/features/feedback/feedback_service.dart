import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FeedbackService {
  FeedbackService._();
  static final FeedbackService instance = FeedbackService._();

  final AudioPlayer _coinPlayer = AudioPlayer();
  final AudioPlayer _successPlayer = AudioPlayer();
  bool _initialized = false;

  bool soundEnabled = true;
  bool coinJingleEnabled = true;
  bool vibrationEnabled = true;

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      await _coinPlayer.setSource(AssetSource('sounds/coin.wav'));
      await _successPlayer.setSource(AssetSource('sounds/success.wav'));
      await _coinPlayer.setVolume(0.7);
      await _successPlayer.setVolume(0.6);
      _initialized = true;
    } catch (e, st) {
      debugPrint('FeedbackService init error: $e\n$st');
    }
  }

  void updatePreferences({
    bool? sound,
    bool? coinJingle,
    bool? vibration,
  }) {
    if (sound != null) soundEnabled = sound;
    if (coinJingle != null) coinJingleEnabled = coinJingle;
    if (vibration != null) vibrationEnabled = vibration;
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
      // Triple rising pattern: triumphant goal-reached feel
      HapticFeedback.mediumImpact();
      unawaited(Future.delayed(const Duration(milliseconds: 100), HapticFeedback.mediumImpact));
      unawaited(Future.delayed(const Duration(milliseconds: 200), HapticFeedback.heavyImpact));
    }
    try {
      await _successPlayer.stop();
      await _successPlayer.play(AssetSource('sounds/success.wav'));
    } catch (_) {}
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
  }
}