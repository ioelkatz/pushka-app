import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/auth/biometric_service.dart';

void main() {
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
