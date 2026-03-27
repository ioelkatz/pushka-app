import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/users/data/user_repository.dart';

void main() {
  late FakeFirebaseFirestore fakeFirestore;
  late UserRepository repo;
  late MockUser mockUser;

  setUp(() {
    fakeFirestore = FakeFirebaseFirestore();
    repo = UserRepository(fakeFirestore);
    mockUser = MockUser(
      uid: 'test_uid_123',
      email: 'test@example.com',
      displayName: 'Test User',
    );
  });

  group('UserRepository.walletIdFromUid', () {
    test('returns a 6-digit numeric string', () {
      final id = UserRepository.walletIdFromUid('some_uid');
      expect(id.length, 6);
      expect(int.tryParse(id), isNotNull);
    });

    test('is deterministic — same uid → same wallet id', () {
      final a = UserRepository.walletIdFromUid('uid_abc');
      final b = UserRepository.walletIdFromUid('uid_abc');
      expect(a, b);
    });

    test('different uids produce different wallet ids (probabilistic)', () {
      final ids = {'uid_1', 'uid_2', 'uid_3', 'uid_4', 'uid_5'}
          .map(UserRepository.walletIdFromUid)
          .toSet();
      // Highly unlikely all 5 collide
      expect(ids.length, greaterThan(1));
    });

    test('result is always in [100000, 999999] range', () {
      for (final uid in ['a', 'abc123', 'very_long_uid_string_here_1234567890']) {
        final code = int.parse(UserRepository.walletIdFromUid(uid));
        expect(code, inInclusiveRange(100000, 999999));
      }
    });
  });

  group('UserRepository.createUserDocument', () {
    test('does nothing when user is null', () async {
      await repo.createUserDocument(user: null, displayName: 'Name');

      final snap = await fakeFirestore.collection('users').get();
      expect(snap.docs, isEmpty);
    });

    test('writes document to users/{uid}', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final doc = await fakeFirestore.collection('users').doc(mockUser.uid).get();
      expect(doc.exists, true);
    });

    test('stores uid and email from the User object', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['uid'], mockUser.uid);
      expect(data['email'], mockUser.email);
    });

    test('uses provided displayName over user.displayName', () async {
      await repo.createUserDocument(user: mockUser, displayName: 'Override Name');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['displayName'], 'Override Name');
    });

    test('falls back to user.displayName when displayName param is null', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['displayName'], mockUser.displayName);
    });

    test('falls back to empty string when both displayNames are null', () async {
      final noNameUser = MockUser(uid: 'uid_noname', email: 'x@x.com');
      await repo.createUserDocument(user: noNameUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(noNameUser.uid).get()).data()!;
      expect(data['displayName'], '');
    });

    test('sets default numeric fields', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['walletBalance'], 0.0);
      expect(data['pushkaAmount'], 0.0);
      expect(data['pushkaGoal'], 3600.00);
      expect(data['presetAmount'], 1.00);
      expect(data['streakCount'], 0);
    });

    test('sets default boolean fields', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['soundEnabled'], true);
      expect(data['coinJingleEnabled'], true);
      expect(data['vibrationEnabled'], true);
      expect(data['walletAutoTopUpEnabled'], false);
      expect(data['partialPaymentsEnabled'], false);
      expect(data['biometricAuthenticationEnabled'], false);
    });

    test('sets walletId using walletIdFromUid', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['walletId'], UserRepository.walletIdFromUid(mockUser.uid));
    });

    test('sets autoEmptyFrequency to manual by default', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['autoEmptyFrequency'], 'manual');
    });

    test('sets currency defaults to USD / Estados Unidos', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['currencyCode'], 'USD');
      expect(data['currencyCountry'], 'Estados Unidos');
    });
  });

  group('UserRepository.ensureUserDocument', () {
    test('does nothing when user is null', () async {
      await repo.ensureUserDocument(user: null, displayName: null);

      final snap = await fakeFirestore.collection('users').get();
      expect(snap.docs, isEmpty);
    });

    test('creates document if it does not exist', () async {
      await repo.ensureUserDocument(user: mockUser, displayName: 'New User');

      final doc = await fakeFirestore.collection('users').doc(mockUser.uid).get();
      expect(doc.exists, true);
      expect(doc.data()?['displayName'], 'New User');
    });

    test('does not overwrite existing document fields', () async {
      // Pre-create with custom pushkaAmount
      await fakeFirestore.collection('users').doc(mockUser.uid).set({
        'displayName': 'Existing User',
        'pushkaAmount': 99.0,
        'walletId': '123456',
        'walletBalance': 50.0,
        'walletAutoTopUpEnabled': true,
        'walletAutoTopUpAmount': 25.0,
        'walletAutoTopUpFrequency': 'monthly',
        'walletAutoTopUpWeekday': DateTime.monday,
        'walletAutoTopUpDayOfMonth': 1,
      });

      await repo.ensureUserDocument(user: mockUser, displayName: 'Should Not Override');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      // Original values preserved
      expect(data['displayName'], 'Existing User');
      expect(data['pushkaAmount'], 99.0);
      expect(data['walletId'], '123456');
      expect(data['walletBalance'], 50.0);
      expect(data['walletAutoTopUpEnabled'], true);
      expect(data['walletAutoTopUpAmount'], 25.0);
      expect(data['walletAutoTopUpFrequency'], 'monthly');
    });

    test('patches missing walletId on existing document', () async {
      await fakeFirestore.collection('users').doc(mockUser.uid).set({
        'displayName': 'User',
        'walletId': '',  // empty — should be patched
      });

      await repo.ensureUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['walletId'], UserRepository.walletIdFromUid(mockUser.uid));
    });

    test('patches missing walletBalance on existing document', () async {
      await fakeFirestore.collection('users').doc(mockUser.uid).set({
        'displayName': 'User',
        'walletId': '123456',
        // no walletBalance
      });

      await repo.ensureUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['walletBalance'], 0.0);
    });

    test('patches walletAutoTopUpEnabled when missing', () async {
      await fakeFirestore.collection('users').doc(mockUser.uid).set({
        'walletId': '123456',
        'walletBalance': 0.0,
        // no walletAutoTopUpEnabled
      });

      await repo.ensureUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['walletAutoTopUpEnabled'], false);
    });
  });

  group('UserRepository.updateProfile', () {
    setUp(() async {
      await repo.createUserDocument(user: mockUser, displayName: null);
    });

    test('updates displayName', () async {
      await repo.updateProfile(uid: mockUser.uid, displayName: 'New Name');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['displayName'], 'New Name');
    });

    test('updates billingEmail', () async {
      await repo.updateProfile(uid: mockUser.uid, billingEmail: 'billing@example.com');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['billingEmail'], 'billing@example.com');
    });

    test('updates phoneNumber', () async {
      await repo.updateProfile(uid: mockUser.uid, phoneNumber: '+1-555-0100');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['phoneNumber'], '+1-555-0100');
    });

    test('updates mailingAddress', () async {
      await repo.updateProfile(uid: mockUser.uid, mailingAddress: '123 Main St');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['mailingAddress'], '123 Main St');
    });

    test('does not overwrite unrelated fields', () async {
      await repo.updateProfile(uid: mockUser.uid, displayName: 'Changed');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['pushkaAmount'], 0.0);
      expect(data['walletBalance'], 0.0);
    });

    test('null params are not written to document', () async {
      await repo.updateProfile(uid: mockUser.uid); // all params null

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      // Only updatedAt should be new; original displayName untouched
      expect(data['displayName'], mockUser.displayName);
    });

    test('can update multiple fields at once', () async {
      await repo.updateProfile(
        uid: mockUser.uid,
        displayName: 'Full Update',
        billingEmail: 'b@b.com',
        phoneNumber: '555',
        mailingAddress: '42 Wallaby Way',
      );

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['displayName'], 'Full Update');
      expect(data['billingEmail'], 'b@b.com');
      expect(data['phoneNumber'], '555');
      expect(data['mailingAddress'], '42 Wallaby Way');
    });
  });

  group('UserRepository.updatePushkaAmount', () {
    setUp(() async {
      await repo.createUserDocument(user: mockUser, displayName: null);
    });

    test('writes new amount', () async {
      await repo.updatePushkaAmount(uid: mockUser.uid, amount: 42.5);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['pushkaAmount'], 42.5);
    });

    test('overwrites previous amount', () async {
      await repo.updatePushkaAmount(uid: mockUser.uid, amount: 10.0);
      await repo.updatePushkaAmount(uid: mockUser.uid, amount: 99.99);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['pushkaAmount'], 99.99);
    });
  });

  group('UserRepository.updateSettings', () {
    setUp(() async {
      await repo.createUserDocument(user: mockUser, displayName: null);
    });

    test('updates pushkaGoal', () async {
      await repo.updateSettings(uid: mockUser.uid, pushkaGoal: 5000.0);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['pushkaGoal'], 5000.0);
    });

    test('updates soundEnabled', () async {
      await repo.updateSettings(uid: mockUser.uid, soundEnabled: false);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['soundEnabled'], false);
    });

    test('updates vibrationEnabled', () async {
      await repo.updateSettings(uid: mockUser.uid, vibrationEnabled: false);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['vibrationEnabled'], false);
    });

    test('updates presetAmounts list', () async {
      await repo.updateSettings(uid: mockUser.uid, presetAmounts: [5.0, 10.0, 18.0]);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['presetAmounts'], [5.0, 10.0, 18.0]);
    });

    test('updates autoEmptyFrequency', () async {
      await repo.updateSettings(uid: mockUser.uid, autoEmptyFrequency: 'weekly');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['autoEmptyFrequency'], 'weekly');
    });

    test('clears autoEmptyNextRunAt when flag is set', () async {
      await repo.updateSettings(
        uid: mockUser.uid,
        autoEmptyNextRunAt: DateTime(2026, 4, 1),
      );
      // Now clear it
      await repo.updateSettings(
        uid: mockUser.uid,
        autoEmptyClearNextRunAt: true,
      );

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['autoEmptyNextRunAt'], isNull);
    });

    test('updates walletAutoTopUpEnabled', () async {
      await repo.updateSettings(uid: mockUser.uid, walletAutoTopUpEnabled: true);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['walletAutoTopUpEnabled'], true);
    });

    test('updates walletAutoTopUpAmount', () async {
      await repo.updateSettings(uid: mockUser.uid, walletAutoTopUpAmount: 50.0);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['walletAutoTopUpAmount'], 50.0);
    });

    test('clears walletAutoTopUpNextRunAt when flag is set', () async {
      await repo.updateSettings(
        uid: mockUser.uid,
        walletAutoTopUpNextRunAt: DateTime(2026, 5, 1),
      );
      await repo.updateSettings(
        uid: mockUser.uid,
        walletAutoTopUpClearNextRunAt: true,
      );

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['walletAutoTopUpNextRunAt'], isNull);
    });

    test('null params leave existing values intact', () async {
      await repo.updateSettings(uid: mockUser.uid); // all null

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['pushkaGoal'], 3600.00);
      expect(data['soundEnabled'], true);
    });

    test('updates multiple settings at once', () async {
      await repo.updateSettings(
        uid: mockUser.uid,
        pushkaGoal: 7200.0,
        presetAmount: 18.0,
        soundEnabled: false,
        coinJingleEnabled: false,
        vibrationEnabled: true,
        partialPaymentsEnabled: true,
        currencyCountry: 'Israel',
        currencyCode: 'ILS',
        autoEmptyFrequency: 'monthly',
        autoEmptyDayOfMonth: 15,
      );

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['pushkaGoal'], 7200.0);
      expect(data['presetAmount'], 18.0);
      expect(data['soundEnabled'], false);
      expect(data['coinJingleEnabled'], false);
      expect(data['vibrationEnabled'], true);
      expect(data['partialPaymentsEnabled'], true);
      expect(data['currencyCountry'], 'Israel');
      expect(data['currencyCode'], 'ILS');
      expect(data['autoEmptyFrequency'], 'monthly');
      expect(data['autoEmptyDayOfMonth'], 15);
    });
  });

  group('UserRepository.watchUser', () {
    test('emits null initially for non-existent user', () async {
      final data = await repo.watchUser('nonexistent_uid').first;
      expect(data, isNull);
    });

    test('emits document data after creation', () async {
      await repo.createUserDocument(user: mockUser, displayName: 'Watch Test');

      final data = await repo.watchUser(mockUser.uid).first;
      expect(data, isNotNull);
      expect(data!['displayName'], 'Watch Test');
    });

    test('stream reflects updates', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);
      await repo.updateProfile(uid: mockUser.uid, displayName: 'Updated');

      final data = await repo.watchUser(mockUser.uid).first;
      expect(data!['displayName'], 'Updated');
    });

    test('users are isolated by uid', () async {
      final otherUser = MockUser(uid: 'other_uid', email: 'other@example.com');
      await repo.createUserDocument(user: mockUser, displayName: 'User A');
      await repo.createUserDocument(user: otherUser, displayName: 'User B');

      final dataA = await repo.watchUser(mockUser.uid).first;
      final dataB = await repo.watchUser(otherUser.uid).first;

      expect(dataA!['displayName'], 'User A');
      expect(dataB!['displayName'], 'User B');
    });
  });
}
