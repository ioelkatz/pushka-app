import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/history/domain/transaction.dart';

void main() {
  group('Transaction model', () {
    late Transaction transaction;

    setUp(() {
      transaction = Transaction(
        id: 'txn_001',
        type: TransactionType.tzedaka,
        amount: 100.0,
        dateTime: DateTime(2026, 1, 15, 14, 30),
      );
    });

    test('default paymentMethod is card', () {
      expect(transaction.paymentMethod, PaymentMethod.card);
    });

    test('default status is completed', () {
      expect(transaction.status, PaymentStatus.completed);
    });

    test('isPending returns false for completed transactions', () {
      expect(transaction.isPending, false);
    });

    test('isPending returns true for pending transactions', () {
      final pending = Transaction(
        id: 'txn_002',
        type: TransactionType.tzedaka,
        amount: 50.0,
        dateTime: DateTime.now(),
        status: PaymentStatus.pending,
      );
      expect(pending.isPending, true);
    });
  });

  group('Transaction.typeLabel', () {
    test('tzedaka label', () {
      final t = _makeTxn(type: TransactionType.tzedaka);
      expect(t.typeLabel, 'Mi Tzedaka');
    });

    test('pushkaEmpty label', () {
      final t = _makeTxn(type: TransactionType.pushkaEmpty);
      expect(t.typeLabel, 'Pushka Vacía');
    });

    test('walletFill label', () {
      final t = _makeTxn(type: TransactionType.walletFill);
      expect(t.typeLabel, 'Billetera Rellena');
    });
  });

  group('Transaction.paymentMethodLabel', () {
    test('card label', () {
      final t = _makeTxn(method: PaymentMethod.card);
      expect(t.paymentMethodLabel, 'Tarjeta');
    });

    test('check label', () {
      final t = _makeTxn(method: PaymentMethod.check);
      expect(t.paymentMethodLabel, 'Cheque');
    });

    test('transfer label', () {
      final t = _makeTxn(method: PaymentMethod.transfer);
      expect(t.paymentMethodLabel, 'Transferencia');
    });

    test('daf label', () {
      final t = _makeTxn(method: PaymentMethod.daf);
      expect(t.paymentMethodLabel, 'DAF');
    });
  });

  group('Transaction.statusLabel', () {
    test('completed label', () {
      final t = _makeTxn(status: PaymentStatus.completed);
      expect(t.statusLabel, 'Completado');
    });

    test('pending label', () {
      final t = _makeTxn(status: PaymentStatus.pending);
      expect(t.statusLabel, 'Pendiente');
    });

    test('confirmed label', () {
      final t = _makeTxn(status: PaymentStatus.confirmed);
      expect(t.statusLabel, 'Confirmado');
    });
  });

  group('Transaction.formattedDate', () {
    test('formats morning time correctly', () {
      final t = _makeTxn(dateTime: DateTime(2026, 3, 5, 9, 5));
      expect(t.formattedDate, 'Mar. 5 - 9:05AM');
    });

    test('formats afternoon time correctly', () {
      final t = _makeTxn(dateTime: DateTime(2026, 7, 20, 15, 45));
      expect(t.formattedDate, 'Jul. 20 - 3:45PM');
    });

    test('formats noon correctly', () {
      final t = _makeTxn(dateTime: DateTime(2026, 1, 1, 12, 0));
      expect(t.formattedDate, 'Ene. 1 - 12:00PM');
    });

    test('formats midnight correctly', () {
      final t = _makeTxn(dateTime: DateTime(2026, 12, 25, 0, 0));
      expect(t.formattedDate, 'Dic. 25 - 12:00AM');
    });

    test('pads single-digit minutes', () {
      final t = _makeTxn(dateTime: DateTime(2026, 6, 10, 8, 3));
      expect(t.formattedDate, 'Jun. 10 - 8:03AM');
    });

    test('all 12 months produce correct abbreviation', () {
      final expected = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];
      for (int m = 1; m <= 12; m++) {
        final t = _makeTxn(dateTime: DateTime(2026, m, 1, 12, 0));
        expect(t.formattedDate, startsWith('${expected[m - 1]}.'));
      }
    });
  });

  group('Transaction edge cases', () {
    test('zero amount is valid', () {
      final t = _makeTxn(amount: 0.0);
      expect(t.amount, 0.0);
    });

    test('very large amount is valid', () {
      final t = _makeTxn(amount: 999999.99);
      expect(t.amount, 999999.99);
    });

    test('null description defaults correctly', () {
      final t = Transaction(
        id: 'test',
        type: TransactionType.tzedaka,
        amount: 10,
        dateTime: DateTime.now(),
      );
      expect(t.description, isNull);
    });

    test('empty string description is stored', () {
      final t = Transaction(
        id: 'test',
        type: TransactionType.tzedaka,
        amount: 10,
        dateTime: DateTime.now(),
        description: '',
      );
      expect(t.description, '');
    });
  });

  group('PaymentMethod enum', () {
    test('has exactly 5 values', () {
      expect(PaymentMethod.values.length, 5);
    });

    test('name serialization round-trips', () {
      for (final method in PaymentMethod.values) {
        final name = method.name;
        final restored = PaymentMethod.values.firstWhere((m) => m.name == name);
        expect(restored, method);
      }
    });
  });

  group('PaymentStatus enum', () {
    test('has exactly 3 values', () {
      expect(PaymentStatus.values.length, 3);
    });

    test('name serialization round-trips', () {
      for (final status in PaymentStatus.values) {
        final name = status.name;
        final restored = PaymentStatus.values.firstWhere((s) => s.name == name);
        expect(restored, status);
      }
    });
  });
}

Transaction _makeTxn({
  TransactionType type = TransactionType.tzedaka,
  double amount = 100.0,
  DateTime? dateTime,
  PaymentMethod method = PaymentMethod.card,
  PaymentStatus status = PaymentStatus.completed,
}) {
  return Transaction(
    id: 'test_id',
    type: type,
    amount: amount,
    dateTime: dateTime ?? DateTime(2026, 1, 15, 14, 30),
    paymentMethod: method,
    status: status,
  );
}
