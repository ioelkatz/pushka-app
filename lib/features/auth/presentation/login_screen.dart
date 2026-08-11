import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show SignInWithAppleAuthorizationException, AuthorizationErrorCode;

import '../../../core/l10n/s.dart';
import '../providers/auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  late S _tr;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tr = S.of(context);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 10),
              Text(
                _tr.welcome,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                _tr.signInSubtitle,
                style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),

              Form(
                key: _formKey,
                child: Column(
                  children: [
                    _buildTextField(
                      controller: _emailController,
                      label: _tr.emailField,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      validator: _validateEmail,
                    ),
                    const SizedBox(height: 16),
                    _buildTextField(
                      controller: _passwordController,
                      label: _tr.passwordField,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      validator: _validatePassword,
                      suffixIcon: IconButton(
                        // Round-5 audit HIGH fix: TalkBack/VoiceOver used to
                        // announce just "Botón" — tooltip + semantic label
                        // now describe the action per current state.
                        tooltip: _obscurePassword
                            ? _tr.showPassword
                            : _tr.hidePassword,
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                          semanticLabel: _obscurePassword
                              ? _tr.showPassword
                              : _tr.hidePassword,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                      onSubmitted: (_) => _signIn(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: _isLoading ? null : _forgotPassword,
                  child: Text(_tr.forgotPassword),
                ),
              ),
              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _signIn,
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_tr.signIn),
                ),
              ),
              const SizedBox(height: 16),

              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(_tr.or_),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 16),

              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isLoading ? null : _signInWithGoogle,
                  icon: const Icon(Icons.g_mobiledata),
                  label: Text(_tr.continueGoogle),
                ),
              ),
              if (!kIsWeb) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isLoading ? null : _signInWithApple,
                    icon: const Icon(Icons.apple),
                    label: Text(_tr.continueApple),
                  ),
                ),
              ],
              const SizedBox(height: 24),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_tr.noAccount),
                  TextButton(
                    onPressed:
                        _isLoading ? null : () => context.go('/register'),
                    child: Text(_tr.createAccount),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputAction? textInputAction,
    String? Function(String?)? validator,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      textInputAction: textInputAction,
      validator: validator,
      onFieldSubmitted: onSubmitted,
      autocorrect: false,
      enableSuggestions: !obscureText,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: suffixIcon,
      ),
    );
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    // Do NOT trim the password — leading/trailing spaces are part of the user's
    // chosen password. Trimming here would silently mismatch the register validator.
    final password = _passwordController.text;

    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    setState(() => _isLoading = true);
    try {
      await ref.read(authControllerProvider).signIn(
            email: email,
            password: password,
          );
    } on FirebaseAuthException catch (e) {
      if (mounted) _showMessage(_mapAuthError(e.code));
    } on Exception catch (e) {
      if (mounted) _showMessage(_tr.signInError('$e'));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showMessage(_tr.enterEmailForReset);
      return;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      _showMessage(_tr.invalidEmail);
      return;
    }
    setState(() => _isLoading = true);
    try {
      await ref.read(authControllerProvider).sendPasswordResetEmail(email);
      if (!mounted) return;
      _showMessage(_tr.resetEmailSent);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      _showMessage(_mapAuthError(e.code));
    } on Exception catch (e) {
      if (!mounted) return;
      _showMessage(_tr.genericError('$e'));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      await ref.read(authControllerProvider).signInWithGoogle();
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        // 'sign_in_canceled' is legit (user tapped back) — silent SnackBar.
        // Anything else is a real error — show a DIALOG with the raw code
        // + message so the user (and support) can see what actually failed.
        // Previously we mapped every non-canceled code to a generic message
        // that often didn't render (SnackBar auto-dismiss + async gap made
        // it easy to miss), and the user saw "chooser → nothing" with no
        // hint what went wrong — S25 Google Sign-In loop was invisible.
        if (e.code == 'sign_in_canceled' || e.code == 'sign_in_cancelled') {
          _showMessage(_mapGoogleAuthError(e.code));
        } else {
          _showAuthErrorDialog(
            code: e.code,
            message: e.message ?? '(sin mensaje)',
            source: 'FirebaseAuthException',
          );
        }
      }
    } on PlatformException catch (e) {
      if (mounted) {
        _showAuthErrorDialog(
          code: e.code,
          message: '${e.message ?? '(sin mensaje)'} | details=${e.details}',
          source: 'PlatformException',
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        _showAuthErrorDialog(
          code: 'unknown',
          message: e.toString(),
          source: 'Exception',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showAuthErrorDialog({
    required String code,
    required String message,
    required String source,
  }) async {
    if (!mounted) return;
    final tr = S.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  tr.authErrorTitle,
                  style: Theme.of(ctx).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr.authErrorIntro, style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 8),
                        SelectableText('Source: $source',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                        SelectableText('Code:   $code',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                        const SizedBox(height: 6),
                        const Text('Message:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        SelectableText(message,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                        const SizedBox(height: 12),
                        Text(
                          tr.authErrorCopyHint,
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(tr.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _signInWithApple() async {
    setState(() => _isLoading = true);
    try {
      await ref.read(authControllerProvider).signInWithApple();
    } on SignInWithAppleAuthorizationException catch (e) {
      // Apple's typed error for the whole authorization pipeline. Cancel
      // must be silent (matches Google's sign_in_canceled path); every
      // other code is a real failure worth surfacing.
      if (!mounted) return;
      if (e.code == AuthorizationErrorCode.canceled) {
        _showMessage(_tr.signInCanceled);
      } else {
        _showMessage(_tr.appleError('${e.code.name}: ${e.message}'));
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        // 'apple_no_identity_token' carries a rich Spanish explanation from
        // the controller — surface e.message directly instead of collapsing
        // to the generic _mapAuthError bucket.
        if (e.code == 'apple_no_identity_token') {
          _showMessage(e.message ?? _mapAuthError(e.code));
        } else {
          _showMessage(_mapAuthError(e.code));
        }
      }
    } on Exception catch (e) {
      if (mounted) _showMessage(_tr.appleError('$e'));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String? _validateEmail(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return _tr.enterYourEmail;
    final isValid =
        RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text);
    if (!isValid) return _tr.invalidEmail;
    return null;
  }

  String? _validatePassword(String? value) {
    final text = value ?? '';
    if (text.isEmpty) return _tr.enterYourPassword;
    if (text.length < 6) return _tr.min6Chars;
    return null;
  }

  String _mapAuthError(String code) {
    switch (code) {
      case 'invalid-email':
        return _tr.emailNotValid;
      case 'user-disabled':
        return _tr.accountDisabled;
      case 'user-not-found':
        return _tr.noAccountWithEmail;
      case 'wrong-password':
        return _tr.wrongPassword;
      case 'too-many-requests':
        return _tr.tooManyRequests;
      case 'network-request-failed':
        return _tr.networkError;
      default:
        return _tr.signInErrorCode(code);
    }
  }

  String _mapGoogleAuthError(String code) {
    switch (code) {
      case 'sign_in_failed':
        return _tr.googlePlayError;
      case 'network_error':
        return _tr.networkError;
      case 'popup_closed_by_user':
      case 'sign_in_canceled':
      case 'sign_in_cancelled':
        return _tr.signInCanceled;
      case 'account_exists_with_different_credential':
        return _tr.emailDifferentProvider;
      case 'user-disabled':
        return _tr.accountDisabled;
      case 'user-not-found':
        return _tr.noAccountWithEmail;
      default:
        return _tr.googleError(code);
    }
  }
}
