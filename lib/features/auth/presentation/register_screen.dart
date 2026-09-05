import 'package:flutter/gestures.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/s.dart';
import '../providers/auth_controller.dart';
import '../../legal/presentation/legal_screen.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
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
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_tr.createAccountTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _tr.createYourAccount,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                _tr.completeData,
                style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),

              Form(
                key: _formKey,
                child: Column(
                  children: [
                    _buildTextField(
                      controller: _nameController,
                      label: _tr.fullName,
                      textInputAction: TextInputAction.next,
                      validator: _validateName,
                    ),
                    const SizedBox(height: 16),
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
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                      onSubmitted: (_) => _signUp(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _signUp,
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_tr.createAccount),
                ),
              ),

              // Los Terminos afirman que al registrarte los aceptaste, pero
              // hasta el 2026-09-04 esta pantalla no los mostraba ni los
              // enlazaba: el donante entregaba nombre, correo y despues una
              // tarjeta sin haber tenido delante que se hace con sus datos,
              // quien cobra, ni que hay comision. Audit de producto.
              const SizedBox(height: 18),
              _LegalNotice(tr: _tr),
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

  Future<void> _signUp() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim().toLowerCase();
    // Do NOT trim the password — leading/trailing spaces are part of the user's
    // chosen password and trimming would silently mismatch the login validator.
    final password = _passwordController.text;

    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    setState(() => _isLoading = true);
    try {
      await ref.read(authControllerProvider).signUp(
            name: name,
            email: email,
            password: password,
          );
      // Ya no se muestra ningun aviso de "te mandamos un correo": el router
      // manda solo a VerifyEmailScreen, que pide el codigo al abrirse y
      // reporta ahi mismo si salio o no. Prometerlo desde aca era justamente
      // lo que dejaba al usuario esperando un correo que a veces no llegaba.
      if (mounted) {
        Navigator.pop(context);
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) _showMessage(_mapAuthError(e.code));
    } on Exception catch (e) {
      if (mounted) _showMessage(_tr.createAccountError('$e'));
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

  String? _validateName(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return _tr.enterYourName;
    if (text.length < 2) return _tr.nameTooShort;
    return null;
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
    if (text.length < 8) return _tr.passwordTooShort;
    if (!RegExp(r'[0-9]').hasMatch(text)) return _tr.passwordNeedsNumber;
    if (!RegExp(r'[A-Z]').hasMatch(text)) return _tr.passwordNeedsUppercase;
    return null;
  }

  String _mapAuthError(String code) {
    switch (code) {
      case 'invalid-email':
        return _tr.emailNotValid;
      case 'email-already-in-use':
        return _tr.emailInUse;
      case 'weak-password':
        return _tr.weakPassword;
      case 'operation-not-allowed':
        return _tr.registrationNotAllowed;
      case 'network-request-failed':
        return _tr.networkError;
      default:
        return _tr.createAccountErrorCode(code);
    }
  }
}

/// Aviso de aceptacion con los dos documentos enlazados y abribles ANTES de
/// crear la cuenta. Se abren con el navegador raiz para que la pantalla legal
/// se monte con su propio AppBar por encima del registro.
class _LegalNotice extends StatelessWidget {
  const _LegalNotice({required this.tr});

  final S tr;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    final link = base.copyWith(
      color: cs.primary,
      decoration: TextDecoration.underline,
      decorationColor: cs.primary,
    );
    void open(LegalSectionTarget section) {
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => LegalScreen(section: section)),
      );
    }

    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: tr.registerLegalPrefix),
          TextSpan(
            text: tr.termsOfService,
            style: link,
            recognizer: TapGestureRecognizer()
              ..onTap = () => open(LegalSectionTarget.terms),
          ),
          TextSpan(text: tr.registerLegalAnd),
          TextSpan(
            text: tr.privacyPolicy,
            style: link,
            recognizer: TapGestureRecognizer()
              ..onTap = () => open(LegalSectionTarget.privacy),
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
