import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/reminder.dart';

/// Maximum number of reminders a single user may have.
/// Enforced in [addReminder] via a server-side aggregate COUNT query.
const int kMaxReminders = 25;

class ReminderRepository {
  ReminderRepository(this._firestore);

  final firestore.FirebaseFirestore _firestore;

  firestore.CollectionReference<Map<String, dynamic>> _collection(String uid) {
    return _firestore.collection('users').doc(uid).collection('reminders');
  }

  Stream<List<Reminder>> watchReminders(String uid) {
    return _collection(uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return Reminder.fromMap(doc.id, doc.data());
      }).toList();
    });
  }

  /// One-shot fetch used at app cold-start to re-arm OS-level alarms after
  /// uninstall / clear-data. The stream-based `watchReminders` is fine for the
  /// UI but would keep the Firestore listener open just to read once.
  Future<List<Reminder>> fetchAll(String uid) async {
    final snap = await _collection(uid).get();
    return snap.docs.map((d) => Reminder.fromMap(d.id, d.data())).toList();
  }

  static const _keyReminderCount = 'reminderCount';

  firestore.DocumentReference<Map<String, dynamic>> _userRef(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Adds a new reminder, enforcing [kMaxReminders] atomically via a
  /// transaction counter on the user document.  This eliminates the
  /// TOCTOU race between a count read and the subsequent write.
  Future<String> addReminder(String uid, Reminder reminder) async {
    final collection = _collection(uid);
    final userRef = _userRef(uid);
    // Pre-generate doc ID outside the transaction (cannot call .add() inside).
    final newDocRef = collection.doc();

    // Bootstrap the counter the first time this code runs for a user:
    // if the field is missing, seed it from the aggregate count.
    // A tiny race remains on the very first concurrent add but disappears
    // permanently once the counter exists.
    final userSnap = await userRef.get();
    if (userSnap.data()?[_keyReminderCount] == null) {
      final aggSnap = await collection.count().get();
      await userRef.set(
        {_keyReminderCount: aggSnap.count ?? 0},
        firestore.SetOptions(merge: true),
      );
    }

    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(userRef);
      final count = (snap.data()?[_keyReminderCount] as int?) ?? 0;
      if (count >= kMaxReminders) {
        throw firestore.FirebaseException(
          plugin: 'cloud_firestore',
          code: 'resource-exhausted',
          message: 'Se alcanzó el límite de $kMaxReminders recordatorios.',
        );
      }
      txn.update(userRef, {_keyReminderCount: firestore.FieldValue.increment(1)});
      txn.set(newDocRef, {
        ...reminder.toMap(),
        'createdAt': firestore.FieldValue.serverTimestamp(),
      });
    });

    return newDocRef.id;
  }

  Future<void> updateReminder(String uid, Reminder reminder) async {
    await _collection(uid).doc(reminder.id).set(
          reminder.toMap(),
          firestore.SetOptions(merge: true),
        );
  }

  Future<void> deleteReminder(String uid, String reminderId) async {
    final userRef = _userRef(uid);
    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(userRef);
      final count = (snap.data()?[_keyReminderCount] as int?) ?? 0;
      txn.delete(_collection(uid).doc(reminderId));
      if (count > 0) {
        txn.update(userRef, {_keyReminderCount: firestore.FieldValue.increment(-1)});
      }
    });
  }
}

final reminderRepositoryProvider = Provider<ReminderRepository>((ref) {
  return ReminderRepository(firestore.FirebaseFirestore.instance);
});
