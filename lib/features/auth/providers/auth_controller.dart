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
    // Sin try/catch, cualquier PERMISSION_DENIED de Firestore tumbaba el login
    // entero: la sesion de Auth ya estaba abierta pero la excepcion subia hasta
    // la pantalla y el usuario veia un error de credenciales que no era tal.
    // El doc se vuelve a asegurar en el proximo arranque, asi que fallar aca no
    // deja al usuario en un estado del que no pueda salir.
    try {
      await _userRepository.ensureUserDocument(
        user: credential.user,
        displayName: credential.user?.displayName,
      );
    } catch (e, st) {
      _recordNonFatal(e, st,
          op: 'signIn.ensureUserDocument', uid: credential.user?.uid);
    }
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

  /// Creates the account and returns `true` if the verification email was
  /// dispatched successfully. Returns `false` when `sendEmailVerification`
  /// fails (rate limit, SMTP hiccup, network) — callers should NOT claim
  /// "we sent you a verification email" in that case.
  Future<bool> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    // Round-5 audit MEDIUM fix: if updateDisplayName or createUserDocument
    // throws AFTER the Firebase Auth user was successfully created, we used
    // to leave an orphaned Auth account. The next signup attempt with the
    // same email would fail with 'email-already-in-use' and the user could
    // never recover. Now we rollback the Auth user on failure.
    try {
      await credential.user?.updateDisplayName(name);
      await _userRepository.createUserDocument(
        user: credential.user,
        displayName: name,
      );
    } catch (e, st) {
      _recordNonFatal(e, st, op: 'signUp.postCreate', uid: credential.user?.uid);
      // Best-effort delete of the orphaned Auth user so the email is
      // re-usable. If this itself fails there's nothing more we can do —
      // ops can clear the orphan via Auth admin console.
      try {
        await credential.user?.delete();
      } catch (_) { /* orphan will need manual cleanup */ }
      rethrow;
    }
    // Send verification email — non-blocking for account creation, but we
    // MUST track whether it actually went out so the register screen doesn't
    // lie to the user (previously the try/catch was silent and the UI always
    // said "email sent" even when Firebase rate-limited or SMTP failed).
    var emailVerificationSent = false;
    try {
      await credential.user?.sendEmailVerification();
      emailVerificationSent = credential.user != null;
    } catch (e, st) {
      _recordNonFatal(e, st, op: 'signUp.sendEmailVerification', uid: credential.user?.uid);
    }
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
    return emailVerificationSent;
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
          // v7: singleton instance instead of `GoogleSignIn()` constructor.
          // initialize() was already called from app_initializer at startup.
          await GoogleSignIn.instance.signOut();
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
      // Web strategy: try popup FIRST. Popup works in desktop browsers +
      // Chrome/Firefox Android + Safari mobile tab. It fails ONLY inside
      // installed PWA standalone mode on iOS (window.open returns null)
      // and inside in-app browsers (WhatsApp/Instagram WebView) where the
      // COOP/COEP defaults block cross-origin popups.
      //
      // Popup UX is dramatically better: user stays on the app, no full
      // page unload, no risk of losing state. We only fall back to
      // signInWithRedirect when the popup path explicitly fails with a
      // popup-related error code.
      //
      // Bug this fixes: with pure redirect, some browsers (esp. Chrome
      // desktop with third-party cookie restrictions or COEP) navigate
      // to Google but the return leg fails to hand the credential back
      // to the Firebase Auth JS SDK — user sees "returned to login page"
      // with no error. Popup keeps the credential handoff in-process.
      final provider = GoogleAuthProvider();
      try {
        final result = await _auth.signInWithPopup(provider);
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
        }
        return;
      } on FirebaseAuthException catch (e) {
        // Fall back to redirect ONLY when popup itself failed to open
        // (installed PWA on iOS, in-app browser, or user blocked popups).
        // Other errors (canceled, network, config) rethrow so the login
        // screen surfaces them properly.
        final fallbackCodes = <String>{
          'popup-blocked',
          'popup-closed-by-user', // user tapped away — try redirect instead
          'operation-not-supported-in-this-environment', // iOS PWA standalone
          'auth/popup-blocked-by-browser',
          'auth/popup-closed-by-user',
        };
        if (!fallbackCodes.contains(e.code)) rethrow;
        // Popup unavailable — try redirect. Page will navigate away.
        await _auth.signInWithRedirect(provider);
        throw FirebaseAuthException(
          code: 'redirect-did-not-fire',
          message: 'No pudimos abrir Google. Intenta de nuevo.',
        );
      }
    } else {
      // Mobile: google_sign_in v7 (Android Credential Manager on Android 14+,
      // ASWebAuthenticationSession on iOS). Completely different API from v6:
      //
      //   - `GoogleSignIn.instance` (singleton) instead of `GoogleSignIn()`
      //     constructor. All config now lives in the one-time initialize()
      //     call in app_initializer._performDeferredInit — including the
      //     serverClientId (web OAuth 2.0 client) that makes Google issue
      //     idTokens instead of just access tokens.
      //
      //   - `authenticate()` REPLACES `signIn()`. Returns a
      //     GoogleSignInAccount directly (never null) or THROWS a
      //     GoogleSignInException. The v6 "returns null after account pick"
      //     failure mode — root cause of the S25 loop Ioel hit — no longer
      //     exists: any failure now surfaces as a typed exception with
      //     a code + description we can display.
      //
      //   - `authentication` is a synchronous getter (was Future in v6) and
      //     only exposes `idToken`. For access tokens you'd have to go through
      //     the separate authorizationClient — but Firebase Auth only needs
      //     the idToken, so we ignore access tokens entirely.
      //
      // Reference: https://pub.dev/packages/google_sign_in (v7 migration guide)
      const webOAuthClientId =
          '846580817724-flf3up2e57c80cjb00u0ce8tf012ae90.apps.googleusercontent.com';

      // Sign out any cached Google session first. Same rationale as before
      // (S25 chooser loop): forces Google to run the full OAuth handshake
      // instead of silently returning a stale credential that might not
      // include a fresh idToken.
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        // signOut throws if no user was ever signed in — safe to ignore.
      }

      final GoogleSignInAccount googleUser;
      try {
        googleUser = await GoogleSignIn.instance.authenticate(
          // scopeHint (v7) is advisory only — the actual scopes granted come
          // from the OAuth consent screen config. `openid` isn't a valid
          // OAuth scope name to request explicitly in v7 (the plugin handles
          // it internally); asking for it triggers clientConfigurationError.
          scopeHint: const ['email', 'profile'],
        );
      } on GoogleSignInException catch (e, st) {
        // Typed exception with code + description. Map to FirebaseAuthException
        // so the login screen surfaces a visible error dialog with the exact
        // failure mode — no more "silent restart" mystery.
        _recordNonFatal(
          e,
          st,
          op: 'signInWithGoogle.authenticate.${e.code.name}',
          uid: null,
        );
        if (e.code == GoogleSignInExceptionCode.canceled) {
          // User dismissed the account chooser — treat as cancel. Use
          // 'sign_in_canceled' to match the code the login screen already
          // recognizes as a silent snackbar (login_screen.dart:262 + :399).
          throw FirebaseAuthException(
            code: 'sign_in_canceled',
            message: 'canceled',
          );
        }
        throw FirebaseAuthException(
          code: 'sign_in_failed',
          message:
              'Google Sign-In v7 falló: code=${e.code.name} '
              'description=${e.description ?? "(sin descripción)"} '
              'details=${e.details ?? "(sin details)"} '
              'serverClientId=$webOAuthClientId',
        );
      } catch (e, st) {
        // Non-GoogleSignInException (PlatformException from the Credential
        // Manager underneath, StateError if initialize wasn't called, etc).
        _recordNonFatal(e, st, op: 'signInWithGoogle.authenticate.other', uid: null);
        rethrow;
      }

      final googleAuth = googleUser.authentication;
      if (googleAuth.idToken == null) {
        // v7 with a valid serverClientId shouldn't hit this — the Credential
        // Manager either returns an idToken or throws providerConfigurationError.
        // If we DO land here it means the OAuth client is misconfigured on the
        // Firebase Console side (SHA-1 not registered for this signing key,
        // or the web client id in initialize() is wrong for this project).
        _recordNonFatal(
          Exception(
            'v7: googleAuth.idToken was null despite authenticate() succeeding. '
            'serverClientId=$webOAuthClientId — likely SHA-1 not registered in '
            'Firebase Console for this signing key.',
          ),
          StackTrace.current,
          op: 'signInWithGoogle.nullIdTokenV7',
          uid: null,
        );
        throw FirebaseAuthException(
          code: 'sign_in_failed',
          message: 'idToken null tras authenticate() exitoso — SHA-1 mismatch probable',
        );
      }

      // v7: accessToken is no longer available from authentication. Firebase
      // Auth accepts idToken alone for Google credentials — the accessToken
      // was only needed if we wanted to call Google APIs directly (Calendar,
      // Drive, etc), which we don't.
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );
      try {
        result = await _auth.signInWithCredential(credential);
      } catch (e, st) {
        _recordNonFatal(e, st, op: 'signInWithGoogle.signInWithCredential', uid: null);
        rethrow;
      }
    }

    // Mismo blindaje que en signIn(): el alta del doc no puede tumbar un login
    // ya exitoso. Ver el comentario de arriba.
    try {
      await _userRepository.ensureUserDocument(
        user: result.user,
        displayName: result.user?.displayName,
      );
    } catch (e, st) {
      _recordNonFatal(e, st,
          op: 'signInWithGoogle.ensureUserDocument', uid: result.user?.uid);
    }
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
      // Defensive: UI already hides the Apple button on web (login_screen
      // and settings_screen delete-account both guard with !kIsWeb). If this
      // ever fires, the caller should catch and show S.appleSignInNotAvailableOnWeb.
      throw Exception('apple_signin_not_available_on_web');
    }
    // Apple Sign-In is only available on iOS and macOS
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );

    // Apple documents identityToken as nullable — happens on entitlement
    // misconfig, revoked provider consent, or transient AppleID service
    // errors. Firebase's OAuthProvider.credential accepts null and then
    // signInWithCredential surfaces an opaque 'invalid-credential' with no
    // hint of the real cause. Detect and throw a typed error so the login
    // screen can surface something actionable (and Crashlytics records it).
    final identityToken = appleCredential.identityToken;
    if (identityToken == null) {
      final err = FirebaseAuthException(
        code: 'apple_no_identity_token',
        message:
            'Apple no devolvió identityToken. Suele indicar Sign in with Apple '
            'no habilitado en el bundle id, consentimiento del proveedor revocado, '
            'o un error transitorio del AppleID service. Intenta de nuevo desde Ajustes '
            '> Apple ID > Sign in with Apple.',
      );
      _recordNonFatal(err, StackTrace.current, op: 'signInWithApple.nullIdentityToken');
      throw err;
    }

    // Capture given/family name BEFORE calling Firebase — Apple ONLY populates
    // these on the FIRST authorization for the app. On every subsequent call
    // they're null, so if we don't grab them now the user's display name will
    // be blank forever (leaderboards, profile, tenant admin lists).
    final given = appleCredential.givenName?.trim() ?? '';
    final family = appleCredential.familyName?.trim() ?? '';
    final appleDisplayName = [given, family]
        .where((s) => s.isNotEmpty)
        .join(' ')
        .trim();

    final oauthCredential = OAuthProvider('apple.com').credential(
      idToken: identityToken,
      accessToken: appleCredential.authorizationCode,
    );

    final result = await _auth.signInWithCredential(oauthCredential);
    final user = result.user;

    // If Firebase came back with a blank displayName (typical on first Apple
    // sign-in) AND Apple gave us a name, persist it to the Firebase user and
    // Firestore. On subsequent sign-ins appleDisplayName will be empty — leave
    // whatever is already on the account.
    final firebaseDisplayName = user?.displayName?.trim() ?? '';
    final effectiveDisplayName = firebaseDisplayName.isNotEmpty
        ? firebaseDisplayName
        : appleDisplayName;
    if (user != null &&
        firebaseDisplayName.isEmpty &&
        appleDisplayName.isNotEmpty) {
      try {
        await user.updateDisplayName(appleDisplayName);
      } catch (e, st) {
        _recordNonFatal(e, st,
            op: 'signInWithApple.updateDisplayName', uid: user.uid);
      }
    }

    await _userRepository.ensureUserDocument(
      user: user,
      displayName: effectiveDisplayName.isNotEmpty ? effectiveDisplayName : null,
    );
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
