import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../analytics/analytics_service.dart';
import '../../users/data/user_repository.dart';
import '../../notifications/notification_service.dart';
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
      await AnalyticsService.instance.setUserId(user.uid);
      await AnalyticsService.instance.logLogin('email');
      await NotificationService.instance.syncFcmToken(user.uid);
      NotificationService.instance.listenForTokenRefresh(user.uid);
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
    final user = credential.user;
    if (user != null) {
      await AnalyticsService.instance.setUserId(user.uid);
      await AnalyticsService.instance.logSignUp('email');
      await NotificationService.instance.syncFcmToken(user.uid);
      NotificationService.instance.listenForTokenRefresh(user.uid);
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
    await AnalyticsService.instance.setUserId(null);
    await NotificationService.instance.stopTokenRefresh();
  }

  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  Future<void> signInWithGoogle() async {
    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) {
      throw Exception('Inicio de sesión cancelado');
    }

    final googleAuth = await googleUser.authentication;
    if (googleAuth.idToken == null) {
      throw Exception('No se recibió idToken de Google');
    }
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final result = await _auth.signInWithCredential(credential);
    await _userRepository.ensureUserDocument(
      user: result.user,
      displayName: result.user?.displayName,
    );
    final user = result.user;
    if (user != null) {
      await AnalyticsService.instance.setUserId(user.uid);
      await AnalyticsService.instance.logLogin('google');
      await NotificationService.instance.syncFcmToken(user.uid);
      NotificationService.instance.listenForTokenRefresh(user.uid);
    }
  }

  Future<void> signInWithApple() async {
    if (!Platform.isIOS) {
      throw Exception('Inicio de sesión con Apple solo está disponible en iOS');
    }

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
      await AnalyticsService.instance.setUserId(user.uid);
      await AnalyticsService.instance.logLogin('apple');
      await NotificationService.instance.syncFcmToken(user.uid);
      NotificationService.instance.listenForTokenRefresh(user.uid);
    }
  }
}

final authControllerProvider = Provider<AuthController>((ref) {
  return AuthController(ref);
});
