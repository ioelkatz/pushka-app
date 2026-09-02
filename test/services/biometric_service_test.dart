import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/auth/biometric_service.dart';

void main() {
  // BiometricService llega a local_auth, que habla por MethodChannel. Sin el
  // binding inicializado, `ServicesBinding.instance` lanza y los tests que
  // llaman a isAvailable/availableTypes/authenticate fallan con
  // "Binding has not yet been initialized".
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/local_auth_android');

  setUp(() {
    // En el entorno de test no hay plataforma que responda. Se simula el canal
    // para que los métodos devuelvan algo determinista en vez de depender de
    // que la excepción se trague por dentro: así estos tests verifican de
    // verdad el contrato de tipos y no el camino de error.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'deviceSupportsBiometrics':
            case 'isDeviceSupported':
            case 'authenticate':
              return false;
            case 'getEnrolledBiometrics':
              return <String>[];
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('BiometricService', () {
    test('instance is a singleton', () {
      final a = BiometricService.instance;
      final b = BiometricService.instance;
      expect(identical(a, b), true);
    });

    test('isAvailable returns a bool', () async {
      final result = await BiometricService.instance.isAvailable();
      expect(result, isA<bool>());
    });

    test('availableTypes returns a list', () async {
      final result = await BiometricService.instance.availableTypes();
      expect(result, isA<List>());
    });

    test('authenticate returns a bool', () async {
      final result = await BiometricService.instance.authenticate(
        reason: 'Test authentication',
      );
      expect(result, isA<bool>());
    });
  });
}
