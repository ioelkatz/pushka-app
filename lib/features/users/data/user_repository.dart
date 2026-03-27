import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class UserRepository {
  UserRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  static String walletIdFromUid(String uid) {
    final hash = uid.codeUnits.fold<int>(17, (acc, c) => (acc * 31 + c) & 0x7fffffff);
    final code = 100000 + (hash % 900000);
    return code.toString();
  }

  Stream<Map<String, dynamic>?> watchUser(String uid) {
    return _users.doc(uid).snapshots().map((doc) => doc.data());
  }

  Future<void> createUserDocument({
    required User? user,
    required String? displayName,
  }) async {
    if (user == null) return;

    await _users.doc(user.uid).set({
      'uid': user.uid,
      'email': user.email,
      'displayName': displayName ?? user.displayName ?? '',
      'createdAt': FieldValue.serverTimestamp(),
      'lastLoginAt': FieldValue.serverTimestamp(),
      'billingEmail': '',
      'phoneNumber': '',
      'mailingAddress': '',
      'walletId': walletIdFromUid(user.uid),
      'walletBalance': 0.0,
      'walletAutoTopUpEnabled': false,
      'walletAutoTopUpAmount': 0.0,
      'walletAutoTopUpFrequency': 'weekly',
      'walletAutoTopUpWeekday': DateTime.monday,
      'walletAutoTopUpDayOfMonth': 1,
      'walletAutoTopUpNextRunAt': null,
      'pushkaAmount': 0.0,
      'pushkaGoal': 3600.00,
      'presetAmount': 1.00,
      'presetAmounts': <double>[],
      'soundEnabled': true,
      'coinJingleEnabled': true,
      'vibrationEnabled': true,
      'partialPaymentsEnabled': false,
      'additionalPaymentOptionsEnabled': false,
      'biometricAuthenticationEnabled': false,
      'currencyCountry': 'Estados Unidos',
      'currencyCode': 'USD',
      'autoEmptyFrequency': 'manual',
      'autoEmptyWeekday': null,
      'autoEmptyDayOfMonth': null,
      'autoEmptyTopOffEnabled': false,
      'autoEmptyTopOffAmount': null,
      'streakCount': 0,
      'lastStreakDate': null,
      'language': 'es',
    }, SetOptions(merge: true));
  }

  Future<void> ensureUserDocument({
    required User? user,
    required String? displayName,
  }) async {
    if (user == null) return;

    final doc = await _users.doc(user.uid).get();
    if (!doc.exists) {
      await createUserDocument(user: user, displayName: displayName);
    } else {
      final data = doc.data() ?? const <String, dynamic>{};
      final patch = <String, dynamic>{
        'lastLoginAt': FieldValue.serverTimestamp(),
      };
      if ((data['walletId'] as String?)?.trim().isEmpty != false) {
        patch['walletId'] = walletIdFromUid(user.uid);
      }
      if (data['walletBalance'] == null || data['walletBalance'] is! num) {
        patch['walletBalance'] = 0.0;
      }
      if (data['walletAutoTopUpEnabled'] == null || data['walletAutoTopUpEnabled'] is! bool) {
        patch['walletAutoTopUpEnabled'] = false;
      }
      if (data['walletAutoTopUpAmount'] == null || data['walletAutoTopUpAmount'] is! num) {
        patch['walletAutoTopUpAmount'] = 0.0;
      }
      if ((data['walletAutoTopUpFrequency'] as String?)?.trim().isEmpty != false) {
        patch['walletAutoTopUpFrequency'] = 'weekly';
      }
      if (data['walletAutoTopUpWeekday'] == null || data['walletAutoTopUpWeekday'] is! num) {
        patch['walletAutoTopUpWeekday'] = DateTime.monday;
      }
      if (data['walletAutoTopUpDayOfMonth'] == null || data['walletAutoTopUpDayOfMonth'] is! num) {
        patch['walletAutoTopUpDayOfMonth'] = 1;
      }
      await _users.doc(user.uid).set({
        ...patch,
      }, SetOptions(merge: true));
    }
  }

  Future<void> updateProfile({
    required String uid,
    String? displayName,
    String? billingEmail,
    String? phoneNumber,
    String? mailingAddress,
  }) async {
    final data = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (displayName != null) data['displayName'] = displayName;
    if (billingEmail != null) data['billingEmail'] = billingEmail;
    if (phoneNumber != null) data['phoneNumber'] = phoneNumber;
    if (mailingAddress != null) data['mailingAddress'] = mailingAddress;

    await _users.doc(uid).set(data, SetOptions(merge: true));
  }

  Future<void> updatePushkaAmount({
    required String uid,
    required double amount,
  }) async {
    await _users.doc(uid).set({
      'pushkaAmount': amount,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> updateSettings({
    required String uid,
    String? language,
    double? pushkaGoal,
    double? presetAmount,
    List<double>? presetAmounts,
    bool? soundEnabled,
    bool? coinJingleEnabled,
    bool? vibrationEnabled,
    bool? partialPaymentsEnabled,
    bool? additionalPaymentOptionsEnabled,
    bool? biometricAuthenticationEnabled,
    String? currencyCountry,
    String? currencyCode,
    String? autoEmptyFrequency,
    int? autoEmptyWeekday,
    int? autoEmptyDayOfMonth,
    bool? autoEmptyTopOffEnabled,
    double? autoEmptyTopOffAmount,
    DateTime? autoEmptyNextRunAt,
    bool autoEmptyClearNextRunAt = false,
    bool? walletAutoTopUpEnabled,
    double? walletAutoTopUpAmount,
    String? walletAutoTopUpFrequency,
    int? walletAutoTopUpWeekday,
    int? walletAutoTopUpDayOfMonth,
    DateTime? walletAutoTopUpNextRunAt,
    bool walletAutoTopUpClearNextRunAt = false,
  }) async {
    final data = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (language != null) data['language'] = language;
    if (pushkaGoal != null) data['pushkaGoal'] = pushkaGoal;
    if (presetAmount != null) data['presetAmount'] = presetAmount;
    if (presetAmounts != null) data['presetAmounts'] = presetAmounts;
    if (soundEnabled != null) data['soundEnabled'] = soundEnabled;
    if (coinJingleEnabled != null) data['coinJingleEnabled'] = coinJingleEnabled;
    if (vibrationEnabled != null) data['vibrationEnabled'] = vibrationEnabled;
    if (partialPaymentsEnabled != null) {
      data['partialPaymentsEnabled'] = partialPaymentsEnabled;
    }
    if (additionalPaymentOptionsEnabled != null) {
      data['additionalPaymentOptionsEnabled'] = additionalPaymentOptionsEnabled;
    }
    if (biometricAuthenticationEnabled != null) {
      data['biometricAuthenticationEnabled'] = biometricAuthenticationEnabled;
    }
    if (currencyCountry != null) data['currencyCountry'] = currencyCountry;
    if (currencyCode != null) data['currencyCode'] = currencyCode;
    if (autoEmptyFrequency != null) {
      data['autoEmptyFrequency'] = autoEmptyFrequency;
    }
    if (autoEmptyWeekday != null) data['autoEmptyWeekday'] = autoEmptyWeekday;
    if (autoEmptyDayOfMonth != null) {
      data['autoEmptyDayOfMonth'] = autoEmptyDayOfMonth;
    }
    if (autoEmptyTopOffEnabled != null) {
      data['autoEmptyTopOffEnabled'] = autoEmptyTopOffEnabled;
    }
    if (autoEmptyTopOffAmount != null) {
      data['autoEmptyTopOffAmount'] = autoEmptyTopOffAmount;
    }
    if (autoEmptyNextRunAt != null) {
      data['autoEmptyNextRunAt'] = Timestamp.fromDate(autoEmptyNextRunAt);
    }
    if (autoEmptyClearNextRunAt) {
      data['autoEmptyNextRunAt'] = null;
    }
    if (walletAutoTopUpEnabled != null) {
      data['walletAutoTopUpEnabled'] = walletAutoTopUpEnabled;
    }
    if (walletAutoTopUpAmount != null) {
      data['walletAutoTopUpAmount'] = walletAutoTopUpAmount;
    }
    if (walletAutoTopUpFrequency != null) {
      data['walletAutoTopUpFrequency'] = walletAutoTopUpFrequency;
    }
    if (walletAutoTopUpWeekday != null) {
      data['walletAutoTopUpWeekday'] = walletAutoTopUpWeekday;
    }
    if (walletAutoTopUpDayOfMonth != null) {
      data['walletAutoTopUpDayOfMonth'] = walletAutoTopUpDayOfMonth;
    }
    if (walletAutoTopUpNextRunAt != null) {
      data['walletAutoTopUpNextRunAt'] = Timestamp.fromDate(walletAutoTopUpNextRunAt);
    }
    if (walletAutoTopUpClearNextRunAt) {
      data['walletAutoTopUpNextRunAt'] = null;
    }

    await _users.doc(uid).set(data, SetOptions(merge: true));
  }
}

final userRepositoryProvider = Provider<UserRepository>((ref) {
  return UserRepository(FirebaseFirestore.instance);
});
