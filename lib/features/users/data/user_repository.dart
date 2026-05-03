import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class UserRepository {
  UserRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  /// Returns the default pushka goal for a given currency code.
  /// Values are multiples of 18 (חי) or 770 (770 Eastern Pkwy),
  /// calibrated to be roughly equivalent to $180 USD.
  static double defaultGoalForCurrency(String currencyCode) {
    switch (currencyCode.toUpperCase()) {
      case 'EUR': return 180;
      case 'GBP': return 180;
      case 'CAD': return 180;
      case 'ILS': return 770;
      case 'MXN': return 1800;
      case 'BRL': return 770;
      case 'ARS': return 180000;
      case 'CLP': return 180000;
      case 'COP': return 770000;
      case 'USD':
      default:    return 180;
    }
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
      'pushkaAmount': 0.0,
      'pushkaGoal': defaultGoalForCurrency('USD'),
      'presetAmount': 1.00,
      'presetAmounts': <double>[],
      'soundEnabled': true,
      'vibrationEnabled': true,
      'partialPaymentsEnabled': true,
      'additionalPaymentOptionsEnabled': false,
      'biometricAuthenticationEnabled': false,
      'currencyCountry': 'Estados Unidos',
      'currencyCode': 'USD',
      'autoEmptyFrequency': 'manual',
      // autoEmptyWeekday, autoEmptyDayOfMonth, autoEmptyTopOffAmount are omitted
      // intentionally: Firestore rules type-validate them (is int / is number) and
      // do not allow null. Fields are absent until the user configures auto-empty.
      'autoEmptyTopOffEnabled': false,
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
      await _users.doc(user.uid).set({
        'uid': user.uid,
        'lastLoginAt': FieldValue.serverTimestamp(),
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
      'uid': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (displayName != null) data['displayName'] = displayName;
    if (billingEmail != null) data['billingEmail'] = billingEmail;
    if (phoneNumber != null) data['phoneNumber'] = phoneNumber;
    if (mailingAddress != null) data['mailingAddress'] = mailingAddress;

    await _users.doc(uid).set(data, SetOptions(merge: true));
  }

  /// Uploads [bytes] to Firebase Storage and saves the download URL to Firestore.
  /// Returns the public download URL.
  Future<String> uploadProfilePhoto({
    required String uid,
    required Uint8List bytes,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('profile_photos')
        .child('$uid.jpg');
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    final url = await ref.getDownloadURL();
    await _users.doc(uid).set({
      'uid': uid,
      'photoURL': url,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return url;
  }

  // ---------------------------------------------------------------------------
  // Per-tenant state — pushka balance, goal, streak, auto-empty schedule
  // ---------------------------------------------------------------------------

  CollectionReference<Map<String, dynamic>> _tenantState(String uid) =>
      _users.doc(uid).collection('tenantState');

  Stream<Map<String, dynamic>?> watchTenantState(String uid, String tenantId) {
    return _tenantState(uid).doc(tenantId).snapshots()
        .map((snap) => snap.exists ? snap.data() : null);
  }

  Future<void> updatePushkaAmount({
    required String uid,
    required String tenantId,
    required double amount,
  }) async {
    await _tenantState(uid).doc(tenantId).set({
      'uid': uid,
      'tenantId': tenantId,
      'pushkaAmount': amount,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> updateTenantState({
    required String uid,
    required String tenantId,
    double? pushkaGoal,
    double? presetAmount,
    List<double>? presetAmounts,
    int? streakCount,
    DateTime? lastStreakDate,
    String? autoEmptyFrequency,
    int? autoEmptyWeekday,
    int? autoEmptyDayOfMonth,
    bool? autoEmptyTopOffEnabled,
    double? autoEmptyTopOffAmount,
    DateTime? autoEmptyNextRunAt,
    bool autoEmptyClearNextRunAt = false,
    String? autoEmptyPaymentMethodId,
    bool autoEmptyClearPaymentMethodId = false,
  }) async {
    final data = <String, dynamic>{
      'uid': uid,
      'tenantId': tenantId,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (pushkaGoal != null) data['pushkaGoal'] = pushkaGoal;
    if (presetAmount != null) data['presetAmount'] = presetAmount;
    if (presetAmounts != null) data['presetAmounts'] = presetAmounts;
    if (streakCount != null) data['streakCount'] = streakCount;
    if (lastStreakDate != null) {
      data['lastStreakDate'] = Timestamp.fromDate(lastStreakDate);
    }
    if (autoEmptyFrequency != null) data['autoEmptyFrequency'] = autoEmptyFrequency;
    if (autoEmptyWeekday != null) data['autoEmptyWeekday'] = autoEmptyWeekday;
    if (autoEmptyDayOfMonth != null) data['autoEmptyDayOfMonth'] = autoEmptyDayOfMonth;
    if (autoEmptyTopOffEnabled != null) data['autoEmptyTopOffEnabled'] = autoEmptyTopOffEnabled;
    if (autoEmptyTopOffAmount != null) data['autoEmptyTopOffAmount'] = autoEmptyTopOffAmount;
    if (autoEmptyNextRunAt != null) {
      data['autoEmptyNextRunAt'] = Timestamp.fromDate(autoEmptyNextRunAt);
    }
    if (autoEmptyClearNextRunAt) data['autoEmptyNextRunAt'] = null;
    if (autoEmptyPaymentMethodId != null) data['autoEmptyPaymentMethodId'] = autoEmptyPaymentMethodId;
    if (autoEmptyClearPaymentMethodId) data['autoEmptyPaymentMethodId'] = null;
    await _tenantState(uid).doc(tenantId).set(data, SetOptions(merge: true));
  }

  Future<void> updateSettings({
    required String uid,
    String? language,
    double? pushkaGoal,
    double? presetAmount,
    List<double>? presetAmounts,
    bool? soundEnabled,
    bool? vibrationEnabled,
    bool? ambientEnabled,
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
  }) async {
    final data = <String, dynamic>{
      'uid': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (language != null) data['language'] = language;
    if (pushkaGoal != null) data['pushkaGoal'] = pushkaGoal;
    if (presetAmount != null) data['presetAmount'] = presetAmount;
    if (presetAmounts != null) data['presetAmounts'] = presetAmounts;
    if (soundEnabled != null) data['soundEnabled'] = soundEnabled;
    if (vibrationEnabled != null) data['vibrationEnabled'] = vibrationEnabled;
    if (ambientEnabled != null) data['ambientEnabled'] = ambientEnabled;
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

    await _users.doc(uid).set(data, SetOptions(merge: true));
  }
}

final userRepositoryProvider = Provider<UserRepository>((ref) {
  return UserRepository(FirebaseFirestore.instance);
});
