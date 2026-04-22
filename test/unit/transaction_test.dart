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
