import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/history/data/transaction_repository.dart';
import 'package:pushka_app/features/history/domain/transaction.dart';

void main() {
  late FakeFirebaseFirestore fakeFirestore;
  late TransactionRepository repo;
  const uid = 'user_abc';

  setUp(() {
    fakeFirestore = FakeFirebaseFirestore();
    repo = TransactionRepository(fakeFirestore);
  });

  group('TransactionRepository.addTransaction', () {
    test('writes a document to the correct path', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.tzedaka,
        amount: 50.0,
        description: 'Test donation',
        paymentMethod: PaymentMethod.card,
        status: PaymentStatus.completed,
      );

      final snap = await fakeFirestore
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .get();

      expect(snap.docs.length, 1);
      final data = snap.docs.first.data();
      expect(data['type'], 'tzedaka');
      expect(data['amount'], 50.0);
      expect(data['description'], 'Test donation');
      expect(data['paymentMethod'], 'card');
      expect(data['status'], 'completed');
    });

    test('uses provided docId when given', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.pushkaEmpty,
        amount: 100.0,
        docId: 'pi_test_stripe_id',
      );

      final doc = await fakeFirestore
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .doc('pi_test_stripe_id')
          .get();

      expect(doc.exists, true);
      expect(doc.data()?['type'], 'pushkaEmpty');
    });

    test('generates auto id when docId is null', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.walletFill,
        amount: 25.0,
      );

      final snap = await fakeFirestore
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .get();

      expect(snap.docs.first.id, isNotEmpty);
      expect(snap.docs.first.id, isNot('null'));
    });

    test('defaults description to empty string', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.tzedaka,
        amount: 10.0,
      );

      final snap = await fakeFirestore
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .get();

      expect(snap.docs.first.data()['description'], '');
    });

    test('stores all PaymentMethod values', () async {
      var i = 0;
      for (final method in PaymentMethod.values) {
        await repo.addTransaction(
          uid: uid,
          type: TransactionType.tzedaka,
          amount: 10.0 * (++i),
          paymentMethod: method,
          docId: 'doc_$i',
        );
      }

      final snap = await fakeFirestore
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .get();

      final methods = snap.docs.map((d) => d.data()['paymentMethod']).toSet();
      for (final method in PaymentMethod.values) {
        expect(methods, contains(method.name));
      }
    });

    test('stores all PaymentStatus values', () async {
      var i = 0;
      for (final status in PaymentStatus.values) {
        await repo.addTransaction(
          uid: uid,
          type: TransactionType.tzedaka,
          amount: 10.0,
          status: status,
          docId: 'status_${i++}',
        );
      }

      final snap = await fakeFirestore
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .get();

      final statuses = snap.docs.map((d) => d.data()['status']).toSet();
      for (final status in PaymentStatus.values) {
        expect(statuses, contains(status.name));
      }
    });
  });

  group('TransactionRepository.watchTransactions', () {
    test('stream emits empty list initially', () async {
      final list = await repo.watchTransactions(uid).first;
      expect(list, isEmpty);
    });

    test('stream emits added transactions', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.tzedaka,
        amount: 75.0,
        description: 'Shabbat donation',
      );

      final list = await repo.watchTransactions(uid).first;
      expect(list.length, 1);
      expect(list.first.type, TransactionType.tzedaka);
      expect(list.first.amount, 75.0);
      expect(list.first.description, 'Shabbat donation');
    });

    test('stream includes multiple transactions', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.tzedaka,
        amount: 10.0,
        docId: 'a',
      );
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.pushkaEmpty,
        amount: 200.0,
        docId: 'b',
      );

      final list = await repo.watchTransactions(uid).first;
      expect(list.length, 2);
    });

    test('transactions for different UIDs are isolated', () async {
      await repo.addTransaction(uid: uid, type: TransactionType.tzedaka, amount: 50.0, docId: 'x');
      await repo.addTransaction(uid: 'other_user', type: TransactionType.tzedaka, amount: 99.0, docId: 'y');

      final list = await repo.watchTransactions(uid).first;
      expect(list.length, 1);
      expect(list.first.amount, 50.0);
    });

    test('parsed Transaction has correct id from doc', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.walletFill,
        amount: 30.0,
        docId: 'txn_001',
      );

      final list = await repo.watchTransactions(uid).first;
      expect(list.first.id, 'txn_001');
    });

    test('parsed Transaction defaults to tzedaka on unknown type', () async {
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .doc('bad_type')
          .set({
        'type': 'UNKNOWN_TYPE',
        'amount': 5.0,
        'paymentMethod': 'card',
        'status': 'completed',
        'createdAt': Timestamp.now(),
      });

      final list = await repo.watchTransactions(uid).first;
      expect(list.first.type, TransactionType.tzedaka);
    });

    test('parsed Transaction handles missing createdAt gracefully', () async {
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .collection('transactions')
          .doc('no_date')
          .set({
        'type': 'tzedaka',
        'amount': 15.0,
        'paymentMethod': 'card',
        'status': 'completed',
        // No createdAt
      });

      final list = await repo.watchTransactions(uid).first;
      expect(list.first.dateTime, isA<DateTime>());
    });
  });

  group('TransactionRepository — pending transactions', () {
    test('isPending true for pending status', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.tzedaka,
        amount: 300.0,
        paymentMethod: PaymentMethod.check,
        status: PaymentStatus.pending,
        docId: 'pending_1',
      );

      final list = await repo.watchTransactions(uid).first;
      expect(list.first.isPending, true);
    });

    test('isPending false for completed status', () async {
      await repo.addTransaction(
        uid: uid,
        type: TransactionType.tzedaka,
        amount: 100.0,
        paymentMethod: PaymentMethod.card,
        status: PaymentStatus.completed,
        docId: 'done_1',
      );

      final list = await repo.watchTransactions(uid).first;
      expect(list.first.isPending, false);
    });
  });
}
