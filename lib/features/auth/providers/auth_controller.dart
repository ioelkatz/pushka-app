import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
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

  void _recordNonFatal(Object e, StackTrace st, {required String op, String? uid}) {
    try {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'auth_controller:$op',
        information: [if (uid != null) 'uid=$uid'],
        fatal: false,
      );
    } catch (_) {}
  }

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
      // CRITICAL: revoke this device's FCM token from Firestore *before*
      // FirebaseAuth.signOut(). After signOut() the auth context is gone and
      // Firestore rules reject the delete (`isOwner(uid)` fails), leaving a
      // stale token doc that keeps pushing to this device for the prev user.
      if (!kIsWeb && uid != null) {
        try {
          await NotificationService.instance.revokeFcmTokenForUser(uid);
        } catch (e, st) {
          debugPrint('AuthController.signOut: FCM revoke failed: $e');
          _recordNonFatal(e, st, op: 'signOut.revokeFcmToken', uid: uid);
        }
      }
      if (!kIsWeb) {
        try {
          await GoogleSignIn().signOut();
        } catch (e, st) {
          _recordNonFatal(e, st, op: 'signOut.googleSignOut', uid: uid);
        }
      }
      await _auth.signOut();
      try {
        await AnalyticsService.instance.setUserId(null);
      } catch (e, st) {
        _recordNonFatal(e, st, op: 'signOut.clearAnalyticsUid', uid: uid);
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
      // Web: use signInWithRedirect INSTEAD of signInWithPopup because iOS
      // Safari in installed PWA standalone mode BLOCKS popups entirely —
      // window.open() returns null and the sign-in silently fails. Popup
      // works in a regular browser tab but breaks the moment the user
      // installs the PWA to home screen (which is exactly what we want them
      // to do for the 500-user launch).
      //
      // Redirect works everywhere: desktop, Safari, iOS PWA, Android PWA.
      // Trade-off: full-page navigation instead of a popup. UX-wise it's
      // slightly worse on desktop but identical on mobile.
      //
      // Flow: signInWithRedirect navigates the browser to Google → user
      // approves → Google redirects back to our origin with the credential
      // in the URL fragment → Firebase Auth JS SDK auto-detects on page
      // load and fires authStateChanges. The router (router.dart:57
      // GoRouterRefreshStream on authStateChanges) picks it up and
      // navigates to /home. This function's future NEVER completes
      // because the page unloads before signInWithRedirect resolves —
      // that's expected. The caller's `await` is discarded when the
      // page unloads; the auth flow completes across page loads.
      final provider = GoogleAuthProvider();
      await _auth.signInWithRedirect(provider);
      // Execution effectively ends here on web — page navigates to Google.
      // The line below is only reached if signInWithRedirect returns
      // synchronously with an error (rare — bad config, provider not
      // enabled). Throw a friendly error so the login screen catches it.
      throw FirebaseAuthException(
        code: 'redirect-did-not-fire',
        message: 'No pudimos abrir Google. Reintentá.',
      );
    } else {
      // Mobile: use google_sign_in package. Pass serverClientId EXPLICITLY
      // (the Web OAuth 2.0 client) so the plugin doesn't rely on auto-discovery
      // from google-services.json — that fails intermittently on newer Android
      // (14+) and on APKs distributed outside Play Store where the manifest
      // metadata reading order can differ. Without the correct web client id
      // Google returns a valid access token but a NULL idToken, and Firebase
      // Auth rejects the credential with 'invalid-credential'.
      //
      // This is the Web (client_type: 3) OAuth 2.0 client ID from Google
      // Cloud Console for the pushka-app-ioel project — same value that lives
      // in android/app/src/prod/google-services.json.
      const webOAuthClientId =
          '846580817724-flf3up2e57c80cjb00u0ce8tf012ae90.apps.googleusercontent.com';
      final GoogleSignIn googleSignIn = GoogleSignIn(
        serverClientId: webOAuthClientId,
      );

      GoogleSignInAccount? googleUser;
      try {
        googleUser = await googleSignIn.signIn();
      } catch (e, st) {
        // Log the raw plugin error to Crashlytics so we can see the exact
        // failure mode (ApiException 10 = DEVELOPER_ERROR = SHA-1 mismatch;
        // ApiException 12500 = SIGN_IN_FAILED; etc). Otherwise we'd only see
        // a generic FirebaseAuthException upstream.
        _recordNonFatal(e, st, op: 'signInWithGoogle.plugin', uid: null);
        rethrow;
      }
      if (googleUser == null) {
        // User dismissed the Google sign-in dialog — treat like a cancellation.
        throw FirebaseAuthException(code: 'sign_in_canceled');
      }
      final googleAuth = await googleUser.authentication;
      if (googleAuth.idToken == null) {
        // Null idToken usually means the serverClientId (web OAuth client) is
        // wrong or the SHA-1 of the signing key isn't registered in Firebase.
        // Log both to Crashlytics for triage.
        _recordNonFatal(
          Exception(
            'googleAuth.idToken was null. serverClientId=$webOAuthClientId '
            'accessTokenPresent=${googleAuth.accessToken != null} — '
            'likely SHA-1 or web OAuth client id mismatch',
          ),
          StackTrace.current,
          op: 'signInWithGoogle.nullIdToken',
          uid: null,
        );
        throw FirebaseAuthException(code: 'sign_in_failed');
      }
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      try {
        result = await _auth.signInWithCredential(credential);
      } catch (e, st) {
        _recordNonFatal(e, st, op: 'signInWithGoogle.signInWithCredential', uid: null);
        rethrow;
      }
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
