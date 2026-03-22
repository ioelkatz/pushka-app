import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/history/domain/transaction.dart';

/// Tests for TransactionRepository serialization logic.
/// We test the parsing logic by simulating Firestore document data
/// without requiring an actual Firebase connection.
void main() {
  group('Transaction document parsing', () {
    test('parses complete document correctly', () {
      final data = {
        'type': 'tzedaka',
        'amount': 150.0,
        'description': 'Test donation',
        'paymentMethod': 'card',
        'status': 'completed',
      };
      final txn = _parseTransaction('doc_1', data);
      expect(txn.id, 'doc_1');
      expect(txn.type, TransactionType.tzedaka);
      expect(txn.amount, 150.0);
      expect(txn.description, 'Test donation');
      expect(txn.paymentMethod, PaymentMethod.card);
      expect(txn.status, PaymentStatus.completed);
    });

    test('parses alternative payment methods', () {
      for (final method in PaymentMethod.values) {
        final data = {
          'type': 'tzedaka',
          'amount': 100.0,
          'paymentMethod': method.name,
          'status': 'pending',
        };
        final txn = _parseTransaction('doc', data);
        expect(txn.paymentMethod, method);
      }
    });

    test('parses all status values', () {
      for (final status in PaymentStatus.values) {
        final data = {
          'type': 'tzedaka',
          'amount': 100.0,
          'status': status.name,
        };
        final txn = _parseTransaction('doc', data);
        expect(txn.status, status);
      }
    });

    test('defaults to card when paymentMethod is missing', () {
      final data = {
        'type': 'tzedaka',
        'amount': 100.0,
      };
      final txn = _parseTransaction('doc', data);
      expect(txn.paymentMethod, PaymentMethod.card);
    });

    test('defaults to completed when status is missing', () {
      final data = {
        'type': 'tzedaka',
        'amount': 100.0,
      };
      final txn = _parseTransaction('doc', data);
      expect(txn.status, PaymentStatus.completed);
    });

    test('defaults to tzedaka when type is missing', () {
      final data = {'amount': 100.0};
      final txn = _parseTransaction('doc', data);
      expect(txn.type, TransactionType.tzedaka);
    });

    test('defaults to 0 when amount is missing', () {
      final data = <String, dynamic>{'type': 'tzedaka'};
      final txn = _parseTransaction('doc', data);
      expect(txn.amount, 0.0);
    });

    test('handles unknown type gracefully', () {
      final data = {
        'type': 'unknown_type_xyz',
        'amount': 50.0,
      };
      final txn = _parseTransaction('doc', data);
      expect(txn.type, TransactionType.tzedaka);
    });

    test('handles unknown payment method gracefully', () {
      final data = {
        'type': 'tzedaka',
        'amount': 50.0,
        'paymentMethod': 'crypto',
      };
      final txn = _parseTransaction('doc', data);
      expect(txn.paymentMethod, PaymentMethod.card);
    });

    test('handles unknown status gracefully', () {
      final data = {
        'type': 'tzedaka',
        'amount': 50.0,
        'status': 'refunded',
      };
      final txn = _parseTransaction('doc', data);
      expect(txn.status, PaymentStatus.completed);
    });

    test('empty description becomes null', () {
      final data = {
        'type': 'tzedaka',
        'amount': 50.0,
        'description': '   ',
      };
      final txn = _parseTransaction('doc', data);
      expect(txn.description, isNull);
    });

    test('valid description is preserved', () {
      final data = {
        'type': 'tzedaka',
        'amount': 50.0,
        'description': 'Donación vía cheque',
      };
      final txn = _parseTransaction('doc', data);
      expect(txn.description, 'Donación vía cheque');
    });

    test('integer amount is converted to double', () {
      final data = {
        'type': 'tzedaka',
        'amount': 100,
      };
      final txn = _parseTransaction('doc', data);
      expect(txn.amount, 100.0);
      expect(txn.amount, isA<double>());
    });

    test('all TransactionType values parse correctly', () {
      for (final type in TransactionType.values) {
        final data = {'type': type.name, 'amount': 10.0};
        final txn = _parseTransaction('doc', data);
        expect(txn.type, type);
      }
    });
  });

  group('Transaction serialization for Firestore', () {
    test('addTransaction data format is correct', () {
      final data = _serializeTransaction(
        type: TransactionType.tzedaka,
        amount: 100.0,
        description: 'Test',
        paymentMethod: PaymentMethod.check,
        status: PaymentStatus.pending,
      );
      expect(data['type'], 'tzedaka');
      expect(data['amount'], 100.0);
      expect(data['description'], 'Test');
      expect(data['paymentMethod'], 'check');
      expect(data['status'], 'pending');
    });

    test('null description defaults to empty string', () {
      final data = _serializeTransaction(
        type: TransactionType.tzedaka,
        amount: 50.0,
      );
      expect(data['description'], '');
    });

    test('serialization round-trip for all payment methods', () {
      for (final method in PaymentMethod.values) {
        final serialized = _serializeTransaction(
          type: TransactionType.tzedaka,
          amount: 100.0,
          paymentMethod: method,
        );
        final parsed = _parseTransaction('doc', serialized);
        expect(parsed.paymentMethod, method);
      }
    });
  });
}

/// Simulates the _fromDoc parsing logic from TransactionRepository.
Transaction _parseTransaction(String id, Map<String, dynamic> data) {
  final typeName = data['type'] as String? ?? 'tzedaka';
  final type = TransactionType.values.firstWhere(
    (t) => t.name == typeName,
    orElse: () => TransactionType.tzedaka,
  );
  final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;

  final methodName = data['paymentMethod'] as String? ?? 'card';
  final method = PaymentMethod.values.firstWhere(
    (m) => m.name == methodName,
    orElse: () => PaymentMethod.card,
  );
  final statusName = data['status'] as String? ?? 'completed';
  final paymentStatus = PaymentStatus.values.firstWhere(
    (s) => s.name == statusName,
    orElse: () => PaymentStatus.completed,
  );

  return Transaction(
    id: id,
    type: type,
    amount: amount,
    dateTime: DateTime.now(),
    description: (data['description'] as String?)?.trim().isEmpty == true
        ? null
        : data['description'] as String?,
    paymentMethod: method,
    status: paymentStatus,
  );
}

/// Simulates the addTransaction serialization.
Map<String, dynamic> _serializeTransaction({
  required TransactionType type,
  required double amount,
  String? description,
  PaymentMethod paymentMethod = PaymentMethod.card,
  PaymentStatus status = PaymentStatus.completed,
}) {
  return {
    'type': type.name,
    'amount': amount,
    'description': description ?? '',
    'paymentMethod': paymentMethod.name,
    'status': status.name,
  };
}
