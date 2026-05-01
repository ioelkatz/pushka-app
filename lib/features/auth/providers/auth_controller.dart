import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../analytics/analytics_service.dart';
import '../../users/data/user_repository.dart';
import '../../notifications/notification_service.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../../app/router.dart' show invalidateTenantCache;
import '../../../core/hive_cache.dart';
import 'auth_state_provider.dart';

class AuthController {
  AuthController(this._ref);

  final Ref _ref;

  FirebaseAuth get _auth => _ref.read(firebaseAuthProvider);
  UserRepository get _userRepository => _ref.read(userRepositoryProvider);

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    await _userRepository.ensureUserDocument(
      user: credential.user,
      displayName: credential.user?.displayName,
    );
    final user = credential.user;
    if (user != null) {
      try {
        await AnalyticsService.instance.setUserId(user.uid);
        await AnalyticsService.instance.logLogin('email');
      } catch (_) {}
      if (!kIsWeb) {
        try {
          await NotificationService.instance.syncFcmToken(user.uid);
          NotificationService.instance.listenForTokenRefresh(user.uid);
        } catch (e) {
          debugPrint('AuthController.signIn: notification sync failed: $e');
        }
      }
    }
  }

  Future<void> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await credential.user?.updateDisplayName(name);
    await _userRepository.createUserDocument(
      user: credential.user,
      displayName: name,
    );
    // Send verification email — non-blocking so the user can continue.
    try { await credential.user?.sendEmailVerification(); } catch (_) {}
    final user = credential.user;
    if (user != null) {
      try {
        await AnalyticsService.instance.setUserId(user.uid);
        await AnalyticsService.instance.logSignUp('email');
      } catch (_) {}
      if (!kIsWeb) {
        try {
          await NotificationService.instance.syncFcmToken(user.uid);
          NotificationService.instance.listenForTokenRefresh(user.uid);
        } catch (e) {
          debugPrint('AuthController.signUp: notification sync failed: $e');
        }
      }
    }
  }

  Future<void> signOut() async {
    final uid = _auth.currentUser?.uid;
    try {
      if (!kIsWeb) {
        try {
          await GoogleSignIn().signOut();
        } catch (_) {}
      }
      await _auth.signOut();
      try {
        await AnalyticsService.instance.setUserId(null);
      } catch (_) {}
      if (!kIsWeb) {
        try {
          await NotificationService.instance.stopTokenRefresh();
        } catch (_) {}
      }
    } finally {
      // Always clear caches that key off the previous uid, even if other
      // sign-out steps failed. Without this, signing in as a different user
      // briefly serves the previous tenant's branding/route decisions.
      if (uid != null) {
        await HiveCache.instance.clearUser(uid);
      }
      invalidateTenantCache();
      _ref.invalidate(tenantConfigProvider);
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  Future<void> signInWithGoogle() async {
    UserCredential result;

    if (kIsWeb) {
      // Web: use Firebase Auth popup — no extra client ID needed
      final provider = GoogleAuthProvider();
      result = await _auth.signInWithPopup(provider);
    } else {
      // Mobile: use google_sign_in package
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        // User dismissed the Google sign-in dialog — treat like a cancellation.
        throw FirebaseAuthException(code: 'sign_in_canceled');
      }
      final googleAuth = await googleUser.authentication;
      if (googleAuth.idToken == null) {
        throw FirebaseAuthException(code: 'sign_in_failed');
      }
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      result = await _auth.signInWithCredential(credential);
    }

    await _userRepository.ensureUserDocument(
      user: result.user,
      displayName: result.user?.displayName,
    );
    final user = result.user;
    if (user != null) {
      try {
        await AnalyticsService.instance.setUserId(user.uid);
        await AnalyticsService.instance.logLogin('google');
      } catch (_) {}
      if (!kIsWeb) {
        try {
          await NotificationService.instance.syncFcmToken(user.uid);
          NotificationService.instance.listenForTokenRefresh(user.uid);
        } catch (e) {
          debugPrint('AuthController.signInWithGoogle: notification sync failed: $e');
        }
      }
    }
  }

  Future<void> signInWithApple() async {
    if (kIsWeb) {
      throw Exception('Apple Sign-In is not available on web');
    }
    // Apple Sign-In is only available on iOS and macOS
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );

    final oauthCredential = OAuthProvider('apple.com').credential(
      idToken: appleCredential.identityToken,
      accessToken: appleCredential.authorizationCode,
    );

    final result = await _auth.signInWithCredential(oauthCredential);
    await _userRepository.ensureUserDocument(
      user: result.user,
      displayName: result.user?.displayName,
    );
    final user = result.user;
    if (user != null) {
      try {
        await AnalyticsService.instance.setUserId(user.uid);
        await AnalyticsService.instance.logLogin('apple');
      } catch (_) {}
      try {
        await NotificationService.instance.syncFcmToken(user.uid);
        NotificationService.instance.listenForTokenRefresh(user.uid);
      } catch (e) {
        debugPrint('AuthController.signInWithApple: notification sync failed: $e');
      }
    }
  }
}

final authControllerProvider = Provider<AuthController>((ref) {
  return AuthController(ref);
});
