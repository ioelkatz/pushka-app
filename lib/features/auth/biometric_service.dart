import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

class BiometricService {
  BiometricService._();
  static final BiometricService instance = BiometricService._();

  final LocalAuthentication _auth = LocalAuthentication();

  // Web (PWA) no soporta biometría — el package local_auth solo tiene
  // implementaciones Android/iOS/macOS/Windows. Cualquier llamada en web
  // tira UnimplementedError. Retornamos false silencioso para que la UI
  // esconda los toggles biométricos, y authenticate() retorna false para
  // que el caller siga sin bloquear.
  Future<bool> isAvailable() async {
    if (kIsWeb) return false;
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
    if (kIsWeb) return const [];
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
    if (kIsWeb) return false;
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
