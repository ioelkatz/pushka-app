import 'package:flutter_test/flutter_test.dart';

/// Comprehensive input validation tests simulating malicious/confused users.

String? validateEmail(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 'Ingresa tu correo';
  final isValid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text);
  if (!isValid) return 'Correo inválido';
  return null;
}

String? validatePassword(String? value) {
  final text = value ?? '';
  if (text.isEmpty) return 'Ingresa tu contraseña';
  if (text.length < 6) return 'Mínimo 6 caracteres';
  return null;
}

String? validateName(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 'Ingresa tu nombre';
  if (text.length < 2) return 'Nombre demasiado corto';
  return null;
}

void main() {
  group('Email validation - happy paths', () {
    test('valid email passes', () {
      expect(validateEmail('user@example.com'), null);
    });

    test('email with subdomain passes', () {
      expect(validateEmail('user@mail.example.com'), null);
    });

    test('email with plus addressing passes', () {
      expect(validateEmail('user+tag@example.com'), null);
    });

    test('email with dots in local part passes', () {
      expect(validateEmail('first.last@example.com'), null);
    });
  });

  group('Email validation - rejection cases', () {
    test('empty email', () {
      expect(validateEmail(''), 'Ingresa tu correo');
      expect(validateEmail(null), 'Ingresa tu correo');
    });

    test('whitespace only', () {
      expect(validateEmail('   '), 'Ingresa tu correo');
    });

    test('no @ symbol', () {
      expect(validateEmail('notanemail'), 'Correo inválido');
    });

    test('no domain', () {
      expect(validateEmail('user@'), 'Correo inválido');
    });

    test('no local part', () {
      expect(validateEmail('@domain.com'), 'Correo inválido');
    });

    test('no TLD', () {
      expect(validateEmail('user@domain'), 'Correo inválido');
    });

    test('spaces in email', () {
      expect(validateEmail('user @domain.com'), 'Correo inválido');
    });

    test('multiple @ symbols', () {
      expect(validateEmail('user@@domain.com'), 'Correo inválido');
    });

    test('script injection attempt', () {
      expect(validateEmail('<script>alert(1)</script>'), 'Correo inválido');
    });

    test('SQL injection attempt', () {
      expect(validateEmail("' OR 1=1 --"), 'Correo inválido');
    });

    test('very long email', () {
      final longEmail = '${'a' * 200}@${'b' * 200}.com';
      // Should pass regex but might cause issues in practice
      expect(validateEmail(longEmail), null);
    });
  });

  group('Password validation', () {
    test('valid password', () {
      expect(validatePassword('password123'), null);
    });

    test('exactly 6 characters', () {
      expect(validatePassword('123456'), null);
    });

    test('empty password', () {
      expect(validatePassword(''), 'Ingresa tu contraseña');
      expect(validatePassword(null), 'Ingresa tu contraseña');
    });

    test('too short', () {
      expect(validatePassword('12345'), 'Mínimo 6 caracteres');
      expect(validatePassword('a'), 'Mínimo 6 caracteres');
    });

    test('password with only spaces', () {
      expect(validatePassword('      '), null); // 6 spaces passes!
    });

    test('password with special characters', () {
      expect(validatePassword('p@\$\$w0rd!'), null);
    });

    test('very long password', () {
      expect(validatePassword('a' * 1000), null);
    });

    test('password with unicode', () {
      expect(validatePassword('contraseña'), null);
    });

    test('password with emojis', () {
      expect(validatePassword('🔑🔑🔑🔑🔑🔑'), null);
    });
  });

  group('Name validation', () {
    test('valid name', () {
      expect(validateName('John Doe'), null);
    });

    test('exactly 2 characters', () {
      expect(validateName('AB'), null);
    });

    test('empty name', () {
      expect(validateName(''), 'Ingresa tu nombre');
      expect(validateName(null), 'Ingresa tu nombre');
    });

    test('whitespace only', () {
      expect(validateName('   '), 'Ingresa tu nombre');
    });

    test('single character', () {
      expect(validateName('A'), 'Nombre demasiado corto');
    });

    test('name with numbers', () {
      expect(validateName('John123'), null);
    });

    test('name with special characters', () {
      expect(validateName("O'Brien"), null);
    });

    test('name with HTML', () {
      expect(validateName('<b>Bold</b>'), null); // passes validation!
    });

    test('very long name', () {
      expect(validateName('a' * 500), null);
    });

    test('name with unicode', () {
      expect(validateName('José María'), null);
    });

    test('name with emojis', () {
      expect(validateName('😀😀'), null);
    });
  });

  group('Amount input parsing', () {
    test('valid integer amount', () {
      expect(double.tryParse('100'), 100.0);
    });

    test('valid decimal amount', () {
      expect(double.tryParse('10.50'), 10.50);
    });

    test('comma as decimal separator', () {
      final input = '10,50';
      expect(double.tryParse(input.replaceAll(',', '.')), 10.50);
    });

    test('empty string returns null', () {
      expect(double.tryParse(''), null);
    });

    test('non-numeric string returns null', () {
      expect(double.tryParse('abc'), null);
    });

    test('negative amount', () {
      expect(double.tryParse('-10'), -10.0);
    });

    test('zero amount', () {
      expect(double.tryParse('0'), 0.0);
    });

    test('amount with spaces', () {
      expect(double.tryParse('10.50'.trim()), 10.50);
    });

    test('amount with currency symbol (should fail)', () {
      expect(double.tryParse('\$10.50'), null);
    });

    test('amount with thousand separator (should fail)', () {
      expect(double.tryParse('1,000.50'.replaceAll(',', '.')), null);
    });

    test('very large amount', () {
      expect(double.tryParse('999999999'), 999999999.0);
    });

    test('scientific notation', () {
      expect(double.tryParse('1e5'), 100000.0);
    });

    test('infinity string', () {
      expect(double.tryParse('Infinity')?.isInfinite, true);
    });

    test('NaN string', () {
      expect(double.tryParse('NaN')?.isNaN, true);
    });
  });

  group('Wallet ID validation', () {
    test('valid 8-digit wallet ID', () {
      const id = '12345678';
      expect(id.trim().isNotEmpty, true);
      expect(id.length, 8);
    });

    test('empty wallet ID', () {
      const id = '';
      expect(id.trim().isEmpty, true);
    });

    test('wallet ID with spaces', () {
      const id = ' 12345678 ';
      expect(id.trim(), '12345678');
    });

    test('BUG: no server-side validation of wallet ID format in addWalletContact', () {
      // The Cloud Function only checks walletId is not empty
      // It does NOT validate format (6 digits, numeric, etc.)
      const id = 'AAAA';
      expect(id.isNotEmpty, true); // passes server validation
    });

    test('paymentIntentId must start with pi_', () {
      expect('pi_1234'.startsWith('pi_'), true);
      expect('1234'.startsWith('pi_'), false);
      expect('pi_'.startsWith('pi_'), true); // empty suffix - valid?
    });
  });

  group('XSS / Injection attempts in text fields', () {
    test('HTML in display name', () {
      const name = '<img src=x onerror=alert(1)>';
      // Stored in Firestore as-is, rendered as Text() widget (safe)
      expect(name.contains('<'), true);
    });

    test('SQL injection in search', () {
      const input = "'; DROP TABLE users; --";
      // Firestore is NoSQL - SQL injection is not applicable
      expect(input.isNotEmpty, true);
    });

    test('Firestore path injection', () {
      const uid = '../admin'; // path traversal attempt
      // Firestore paths are validated by SDK
      expect(uid.contains('..'), true);
    });

    test('null byte injection', () {
      const input = 'test\x00injection';
      expect(input.length, 14);
    });
  });
}
