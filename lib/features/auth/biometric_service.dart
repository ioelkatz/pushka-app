import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Distinguishable outcomes of a biometric prompt. Round-5 audit HIGH fix:
/// previously `authenticate()` collapsed every failure into `false` — user
/// cancel, missing hardware, permission denied, timeout, plugin crash all
/// looked identical to the caller. Callers couldn't tell "user backed out"
/// (silent no-op) from "device broken, offer PIN fallback".
enum BiometricOutcome {
  success,
  userCanceled,
  notAvailable,   // no hardware / not supported / user disabled biometrics
  notEnrolled,    // hardware present but no fingerprint / face registered
  permissionDenied,
  lockedOut,      // too many failed attempts — device locks biometrics
  error,          // plugin crash, timeout, unknown
}

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

  /// Legacy boolean API — kept for source-compat with call sites that just
  /// want "did the user authenticate?" Callers that need to distinguish
  /// cancel from device-broken should use [authenticateDetailed] instead.
  Future<bool> authenticate({
    String reason = 'Confirm your identity to continue',
  }) async {
    final outcome = await authenticateDetailed(reason: reason);
    return outcome == BiometricOutcome.success;
  }

  /// Round-5 audit HIGH fix: rich outcome so the caller can react
  /// differently to cancel (silent no-op) vs device-broken (offer PIN
  /// fallback / disable biometric toggle / show explanation).
  ///
  /// PlatformException codes are matched by string because
  /// `local_auth`'s error_codes.dart is not exported publicly across all
  /// package versions — the strings themselves are stable.
  Future<BiometricOutcome> authenticateDetailed({
    String reason = 'Confirm your identity to continue',
  }) async {
    if (kIsWeb) return BiometricOutcome.notAvailable;
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      if (!canCheck && !isSupported) return BiometricOutcome.notAvailable;
      final biometrics = await _auth.getAvailableBiometrics();
      if (biometrics.isEmpty) return BiometricOutcome.notEnrolled;

      final ok = await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
      return ok ? BiometricOutcome.success : BiometricOutcome.userCanceled;
    } on PlatformException catch (e, st) {
      debugPrint('[BiometricService] authenticate PlatformException: ${e.code} — ${e.message}\n$st');
      final code = e.code;
      // Standard local_auth error codes across Android + iOS. See:
      // https://pub.dev/documentation/local_auth/latest/error_codes/error_codes-library.html
      if (code == 'notAvailable') return BiometricOutcome.notAvailable;
      if (code == 'notEnrolled')  return BiometricOutcome.notEnrolled;
      if (code == 'passcodeNotSet') return BiometricOutcome.notEnrolled;
      if (code == 'lockedOut' || code == 'permanentlyLockedOut') {
        return BiometricOutcome.lockedOut;
      }
      if (code == 'permissionDenied' || code == 'appCancelled' || code == 'systemCancelled') {
        return BiometricOutcome.permissionDenied;
      }
      if (code == 'userCancel' || code == 'userFallback') {
        return BiometricOutcome.userCanceled;
      }
      return BiometricOutcome.error;
    } catch (e, st) {
      debugPrint('[BiometricService] authenticate unknown error: $e\n$st');
      return BiometricOutcome.error;
    }
  }
}
