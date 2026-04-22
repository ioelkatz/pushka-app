import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/history/domain/transaction.dart';

/// Tests for core payment/donation business logic extracted from PushkaScreen.
/// These validate the pure functions without needing Flutter widgets.
void main() {
  group('Donation amount calculations', () {
    test('cents conversion rounds correctly', () {
      expect((10.50 * 100).round(), 1050);
      expect((0.50 * 100).round(), 50);
      expect((99.99 * 100).round(), 9999);
      expect((0.01 * 100).round(), 1);
    });

    test('partial donation percentages', () {
      const pushkaAmount = 200.0;
      expect(pushkaAmount * 0.25, 50.0);
      expect(pushkaAmount * 0.50, 100.0);
      expect(pushkaAmount * 0.75, 150.0);
      expect(pushkaAmount * 1.00, 200.0);
    });

    test('remaining amount after donation is clamped to zero', () {
      const pushkaAmount = 100.0;
      const donationAmount = 150.0;
      final remaining = (pushkaAmount - donationAmount).clamp(0.0, double.infinity);
      expect(remaining, 0.0);
    });

    test('remaining amount after partial donation', () {
      const pushkaAmount = 100.0;
      const donationAmount = 25.0;
      final remaining = (pushkaAmount - donationAmount).clamp(0.0, double.infinity);
      expect(remaining, 75.0);
    });

    test('full donation leaves zero', () {
      const pushkaAmount = 100.0;
      final remaining = (pushkaAmount - pushkaAmount).clamp(0.0, double.infinity);
      expect(remaining, 0.0);
    });
  });

  group('Currency minimum amounts', () {
    // Canonical values — must match server (functions/index.js) and
    // currency_logic_test.dart.
    int minAmountCentsForCurrency(String currency) {
      switch (currency.toLowerCase()) {
        case 'usd':
        case 'eur':
        case 'cad':
          return 50;
        case 'gbp':
          return 30;
        case 'mxn':
          return 1000;
        case 'brl':
          return 100;
        case 'ars':
          return 100000;
        case 'clp':
          return 50000;
        case 'cop':
          return 200000;
        case 'ils':
          return 200;
        default:
          return 100;
      }
    }

    test('USD minimum is 50 cents', () {
      expect(minAmountCentsForCurrency('usd'), 50);
    });

    test('GBP minimum is 30 pence', () {
      expect(minAmountCentsForCurrency('gbp'), 30);
    });

    test('MXN minimum is 10 pesos (1000 centavos)', () {
      expect(minAmountCentsForCurrency('mxn'), 1000);
    });

    test('ARS minimum is 1000 pesos (100000 centavos)', () {
      expect(minAmountCentsForCurrency('ars'), 100000);
    });

    test('ILS minimum is 2 shekels (200 agorot)', () {
      expect(minAmountCentsForCurrency('ils'), 200);
    });

    test('unknown currency defaults to 100', () {
      expect(minAmountCentsForCurrency('xyz'), 100);
    });

    test('case insensitive', () {
      expect(minAmountCentsForCurrency('USD'), 50);
      expect(minAmountCentsForCurrency('Mxn'), 1000);
    });
  });

  group('Transaction recording for alternative payments', () {
    test('check donation creates pending transaction', () {
      final txn = Transaction(
        id: 'test',
        type: TransactionType.tzedaka,
        amount: 100,
        dateTime: DateTime.now(),
        paymentMethod: PaymentMethod.check,
        status: PaymentStatus.pending,
      );
      expect(txn.isPending, true);
      expect(txn.paymentMethod, PaymentMethod.check);
      expect(txn.status, PaymentStatus.pending);
    });

    test('transfer donation creates pending transaction', () {
      final txn = Transaction(
        id: 'test',
        type: TransactionType.tzedaka,
        amount: 250,
        dateTime: DateTime.now(),
        paymentMethod: PaymentMethod.transfer,
        status: PaymentStatus.pending,
      );
      expect(txn.isPending, true);
      expect(txn.paymentMethod, PaymentMethod.transfer);
    });

    test('DAF donation creates pending transaction', () {
      final txn = Transaction(
        id: 'test',
        type: TransactionType.tzedaka,
        amount: 500,
        dateTime: DateTime.now(),
        paymentMethod: PaymentMethod.daf,
        status: PaymentStatus.pending,
      );
      expect(txn.isPending, true);
      expect(txn.paymentMethod, PaymentMethod.daf);
    });

    test('card donation creates completed transaction', () {
      final txn = Transaction(
        id: 'test',
        type: TransactionType.tzedaka,
        amount: 100,
        dateTime: DateTime.now(),
        paymentMethod: PaymentMethod.card,
        status: PaymentStatus.completed,
      );
      expect(txn.isPending, false);
      expect(txn.status, PaymentStatus.completed);
    });
  });

  group('Error message handling', () {
    String donationErrorMessage(Object error) {
      if (error is Exception) {
        final msg = error.toString().replaceFirst('Exception: ', '');
        if (msg.isNotEmpty && msg != 'null') return msg;
      }
      return 'No se pudo completar la donación';
    }

    test('Exception with message shows message', () {
      final error = Exception('Tu sesión no es válida');
      expect(donationErrorMessage(error), 'Tu sesión no es válida');
    });

    test('generic Exception with null shows its string', () {
      final error = Exception(null);
      // Exception(null).toString() = 'Exception' which is not empty
      expect(donationErrorMessage(error), isNotEmpty);
    });

    test('non-Exception error shows fallback', () {
      expect(donationErrorMessage('some string error'), 'No se pudo completar la donación');
    });
  });
}
