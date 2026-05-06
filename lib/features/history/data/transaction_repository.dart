import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/transaction.dart';

class TransactionRepository {
  TransactionRepository(this._firestore);

  final firestore.FirebaseFirestore _firestore;

  firestore.CollectionReference<Map<String, dynamic>> _collection(String uid) {
    return _firestore.collection('users').doc(uid).collection('transactions');
  }

  /// Default page size for the initial history load. Pagination grows by
  /// this increment each time the user taps "Cargar más".
  static const int pageSize = 100;

  Stream<List<Transaction>> watchTransactions(
    String uid, {
    String? tenantId,
    int limit = pageSize,
  }) {
    var query = _collection(uid)
        .orderBy('createdAt', descending: true)
        .limit(limit);
    if (tenantId != null && tenantId.isNotEmpty) {
      query = query.where('tenantId', isEqualTo: tenantId);
    }
    return query.snapshots().map((snapshot) {
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
    required String? tenantId,
  }) async {
    // Firestore rules now require tenantId on every client-written transaction
    // (otherwise the multi-tenant history queries silently exclude the row,
    // and admin reports cannot attribute revenue). Reject missing tenantId at
    // the call site rather than letting Firestore reject silently with
    // permission-denied.
    if (tenantId == null || tenantId.isEmpty) {
      throw ArgumentError(
        'addTransaction requires a non-empty tenantId — the user has no active tenant.',
      );
    }
    final data = <String, dynamic>{
      'type': type.name,
      'amount': amount,
      'description': description ?? '',
      'paymentMethod': paymentMethod.name,
      'status': status.name,
      'currencyCode': currencyCode.toUpperCase(),
      'tenantId': tenantId,
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

    final donorMessageRaw = data['donorMessage'] as String?;
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
      tenantId: data['tenantId'] as String?,
      donorMessage: (donorMessageRaw == null || donorMessageRaw.trim().isEmpty)
          ? null
          : donorMessageRaw,
    );
  }
}

final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  return TransactionRepository(firestore.FirebaseFirestore.instance);
});
