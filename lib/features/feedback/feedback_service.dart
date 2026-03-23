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
    } catch (e) {
      debugPrint('FeedbackService init error: $e');
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
      HapticFeedback.lightImpact();
    }
    if (!soundEnabled) return;
    try {
      await _coinPlayer.stop();
      await _coinPlayer.play(AssetSource('sounds/coin.wav'));
    } catch (e) {
      debugPrint('Coin sound error: $e');
    }
  }

  Future<void> playSuccess() async {
    if (!soundEnabled || kIsWeb) return;
    if (vibrationEnabled) {
      HapticFeedback.mediumImpact();
    }
    try {
      await _successPlayer.stop();
      await _successPlayer.play(AssetSource('sounds/success.wav'));
    } catch (e) {
      debugPrint('Success sound error: $e');
    }
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