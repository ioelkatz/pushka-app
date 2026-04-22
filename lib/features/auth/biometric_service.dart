import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

class BiometricService {
  BiometricService._();
  static final BiometricService instance = BiometricService._();

  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> isAvailable() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      if (!canCheck && !isSupported) return false;
      final biometrics = await _auth.getAvailableBiometrics();
      return biometrics.isNotEmpty;
    } catch (e, st) {
      debugPrint('[BiometricService] isAvailable error: $e\n$st');
      return false;
    }
  }

  Future<List<BiometricType>> availableTypes() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e, st) {
      debugPrint('[BiometricService] availableTypes error: $e\n$st');
      return [];
    }
  }

  Future<bool> authenticate({
    String reason = 'Confirm your identity to continue',
  }) async {
    try {
      if (!await isAvailable()) return false;
      return await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
    } catch (e, st) {
      debugPrint('[BiometricService] authenticate error: $e\n$st');
      return false;
    }
  }
}
