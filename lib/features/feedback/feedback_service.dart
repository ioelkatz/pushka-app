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
    } catch (_) {
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
      Future.delayed(const Duration(milliseconds: 80), HapticFeedback.lightImpact);
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
      Future.delayed(const Duration(milliseconds: 100), HapticFeedback.mediumImpact);
      Future.delayed(const Duration(milliseconds: 200), HapticFeedback.heavyImpact);
    }
    try {
      await _successPlayer.stop();
      await _successPlayer.play(AssetSource('sounds/success.wav'));
    } catch (_) {}
  }

  /// Heavy thud + light echo — used when pushka is emptied.
  Future<void> vibratePushkaEmpty() async {
    if (!vibrationEnabled || kIsWeb) return;
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 120), HapticFeedback.lightImpact);
  }

  Future<void> vibrate() async {
    if (!vibrationEnabled || kIsWeb) return;
    HapticFeedback.mediumImpact();
  }

  Future<void> vibrateLight() async {
    if (!vibrationEnabled || kIsWeb) return;
    HapticFeedback.lightImpact();
  }

  Future<void> vibrateHeavy() async {
    if (!vibrationEnabled || kIsWeb) return;
    HapticFeedback.heavyImpact();
  }

  void dispose() {
    _coinPlayer.dispose();
    _successPlayer.dispose();
  }
}