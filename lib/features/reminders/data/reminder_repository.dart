import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/reminder.dart';

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

  Future<String> addReminder(String uid, Reminder reminder) async {
    final doc = await _collection(uid).add({
      ...reminder.toMap(),
      'createdAt': firestore.Timestamp.now(),
    });
    return doc.id;
  }

  Future<void> updateReminder(String uid, Reminder reminder) async {
    await _collection(uid).doc(reminder.id).set(
          {
            ...reminder.toMap(),
            'createdAt': firestore.Timestamp.now(),
          },
          firestore.SetOptions(merge: true),
        );
  }

  Future<void> deleteReminder(String uid, String reminderId) async {
    await _collection(uid).doc(reminderId).delete();
  }
}

final reminderRepositoryProvider = Provider<ReminderRepository>((ref) {
  return ReminderRepository(firestore.FirebaseFirestore.instance);
});
