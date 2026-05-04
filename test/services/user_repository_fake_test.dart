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
      expect(data['pushkaAmount'], 0.0);
      expect(data['pushkaGoal'], 180.0); // defaultGoalForCurrency('USD')
      expect(data['presetAmount'], 1.00);
      expect(data['streakCount'], 0);
    });

    test('sets default boolean fields', () async {
      await repo.createUserDocument(user: mockUser, displayName: null);

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['soundEnabled'], true);
      expect(data['coinJingleEnabled'], true);
      expect(data['vibrationEnabled'], true);
      expect(data['partialPaymentsEnabled'], false);
      expect(data['biometricAuthenticationEnabled'], false);
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
      await fakeFirestore.collection('users').doc(mockUser.uid).set({
        'displayName': 'Existing User',
        'pushkaAmount': 99.0,
      });

      await repo.ensureUserDocument(user: mockUser, displayName: 'Should Not Override');

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['displayName'], 'Existing User');
      expect(data['pushkaAmount'], 99.0);
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
    const tenantId = 'tenant123';

    setUp(() async {
      await repo.createUserDocument(user: mockUser, displayName: null);
    });

    test('writes new amount to tenantState', () async {
      await repo.updatePushkaAmount(uid: mockUser.uid, tenantId: tenantId, amount: 42.5);

      final data = (await fakeFirestore
          .collection('users').doc(mockUser.uid)
          .collection('tenantState').doc(tenantId).get()).data()!;
      expect(data['pushkaAmount'], 42.5);
    });

    test('overwrites previous amount in tenantState', () async {
      await repo.updatePushkaAmount(uid: mockUser.uid, tenantId: tenantId, amount: 10.0);
      await repo.updatePushkaAmount(uid: mockUser.uid, tenantId: tenantId, amount: 99.99);

      final data = (await fakeFirestore
          .collection('users').doc(mockUser.uid)
          .collection('tenantState').doc(tenantId).get()).data()!;
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

    test('null params leave existing values intact', () async {
      await repo.updateSettings(uid: mockUser.uid); // all null

      final data = (await fakeFirestore.collection('users').doc(mockUser.uid).get()).data()!;
      expect(data['pushkaGoal'], 180.0); // defaultGoalForCurrency('USD')
      expect(data['soundEnabled'], true);
    });

    test('updates multiple settings at once', () async {
      await repo.updateSettings(
        uid: mockUser.uid,
        pushkaGoal: 7200.0,
        presetAmount: 18.0,
        soundEnabled: false,
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
