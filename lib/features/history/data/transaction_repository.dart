import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/transaction.dart';

class TransactionRepository {
  TransactionRepository(this._firestore);

  final firestore.FirebaseFirestore _firestore;

  firestore.CollectionReference<Map<String, dynamic>> _collection(String uid) {
    return _firestore.collection('users').doc(uid).collection('transactions');
  }

  Stream<List<Transaction>> watchTransactions(String uid) {
    return _collection(uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => _fromDoc(doc)).toList();
    });
  }

  Future<void> addTransaction({
    required String uid,
    required TransactionType type,
    required double amount,
    String? description,
    PaymentMethod paymentMethod = PaymentMethod.card,
    PaymentStatus status = PaymentStatus.completed,
  }) async {
    await _collection(uid).add({
      'type': type.name,
      'amount': amount,
      'description': description ?? '',
      'paymentMethod': paymentMethod.name,
      'status': status.name,
      'createdAt': firestore.Timestamp.now(),
    });
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
    final dateTime = timestamp is firestore.Timestamp
        ? timestamp.toDate()
        : DateTime.now();

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
    );
  }
}

final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  return TransactionRepository(firestore.FirebaseFirestore.instance);
});
