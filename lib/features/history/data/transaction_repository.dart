import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/transaction.dart';

class TransactionRepository {
  TransactionRepository(this._firestore);

  final firestore.FirebaseFirestore _firestore;

  firestore.CollectionReference<Map<String, dynamic>> _collection(String uid) {
    return _firestore.collection('users').doc(uid).collection('transactions');
  }

  /// Maximum number of transactions fetched per query. Used by the UI to
  /// show a "showing last N" notice when this limit is reached.
  static const int pageSize = 100;

  Stream<List<Transaction>> watchTransactions(String uid) {
    return _collection(uid)
        .orderBy('createdAt', descending: true)
        .limit(pageSize)
        .snapshots()
        .map((snapshot) {
      final result = <Transaction>[];
      for (final doc in snapshot.docs) {
        try {
          result.add(_fromDoc(doc));
        } catch (_) {
          // Skip malformed document rather than killing the entire stream.
        }
      }
      return result;
    });
  }

  Future<void> addTransaction({
    required String uid,
    required TransactionType type,
    required double amount,
    String? description,
    PaymentMethod paymentMethod = PaymentMethod.card,
    PaymentStatus status = PaymentStatus.completed,
    String? docId,
    String currencyCode = 'USD',
  }) async {
    final data = {
      'type': type.name,
      'amount': amount,
      'description': description ?? '',
      'paymentMethod': paymentMethod.name,
      'status': status.name,
      'currencyCode': currencyCode.toUpperCase(),
      'createdAt': firestore.FieldValue.serverTimestamp(),
    };
    if (docId != null) {
      await _collection(uid).doc(docId).set(data);
    } else {
      await _collection(uid).add(data);
    }
  }

  Transaction _fromDoc(
    firestore.DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? {};
    final typeName = data['type'] as String? ?? 'tzedaka';
    final type = TransactionType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => TransactionType.tzedaka,
    );
    final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
    final timestamp = data['createdAt'];
    final DateTime dateTime;
    if (timestamp is firestore.Timestamp) {
      dateTime = timestamp.toDate();
    } else {
      // Field is null for pending-write docs (serverTimestamp not yet resolved).
      // Use epoch as a sentinel so the UI can detect the pending state instead
      // of committing to a fabricated device-time that may reorder after sync.
      dateTime = DateTime.fromMillisecondsSinceEpoch(0);
    }

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
      id: doc.id,
      type: type,
      amount: amount,
      dateTime: dateTime,
      description: (data['description'] as String?)?.trim().isEmpty == true
          ? null
          : data['description'] as String?,
      paymentMethod: method,
      status: paymentStatus,
      currencyCode: (data['currencyCode'] as String?) ?? 'USD',
    );
  }
}

final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  return TransactionRepository(firestore.FirebaseFirestore.instance);
});
