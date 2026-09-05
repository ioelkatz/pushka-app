import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/s.dart';

/// Confirmacion del correo con un codigo de 6 digitos.
///
/// Por que un codigo y no el enlace nativo de Firebase: el enlace saca al
/// usuario de la app justo en la mitad del alta, y sobre todo no le sirve de
/// nada al que se equivoco escribiendo su direccion — que es el caso que mas
/// duele, porque el comprobante de cada donacion viaja a ese correo y el
/// donante no se entera nunca de que le llega a un buzon que no existe.
///
/// Solo la ven las cuentas de correo y contrasena creadas despues del corte
/// (ver `needsEmailVerification` en router.dart). Las de Google entran con el
/// correo ya verificado por Google y nunca pasan por aca.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  static const int _cells = 6;
  static const int _resendCooldownSeconds = 60;

  final _controllers = List.generate(_cells, (_) => TextEditingController());
  final _focusNodes = List.generate(_cells, (_) => FocusNode());

  bool _sending = false;
  bool _verifying = false;
  bool _deleting = false;
  String? _error;
  String? _info;
  int _cooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    // El primer codigo sale solo al entrar: si el usuario tuviera que pedirlo,
    // la pantalla arrancaria pidiendole algo que no sabe que existe.
    WidgetsBinding.instance.addPostFrameCallback((_) => _send(initial: true));
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  String get _code => _controllers.map((c) => c.text).join();
  bool get _allFilled => _controllers.every((c) => c.text.isNotEmpty);

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = _resendCooldownSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _send({bool initial = false}) async {
    if (_sending || (_cooldown > 0 && !initial)) return;
    setState(() {
      _sending = true;
      _error = null;
      _info = null;
    });
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('sendEmailVerificationCode')
          .call();
      final data = Map<String, dynamic>.from(res.data as Map? ?? {});
      if (!mounted) return;
      // La cuenta ya estaba verificada (por ejemplo el usuario abrio el enlace
      // viejo en otro lado). No lo dejamos mirando una pantalla sin sentido.
      if (data['alreadyVerified'] == true) {
        await _finish();
        return;
      }
      setState(() => _info = S.of(context).verifyEmailCodeSent);
      _startCooldown();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _error = _messageFor(e));
      // Si el rechazo fue por tope de envios, igual arrancamos el contador:
      // sin esto el boton queda habilitado y el usuario golpea contra el tope
      // una y otra vez sin entender por que.
      if (e.code == 'resource-exhausted') _startCooldown();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = S.of(context).errorServerUnavailable);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    if (_verifying || !_allFilled) return;
    setState(() {
      _verifying = true;
      _error = null;
      _info = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('confirmEmailVerificationCode')
          .call({'code': _code});
      await _finish();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _messageFor(e);
        for (final c in _controllers) {
          c.clear();
        }
      });
      _focusNodes.first.requestFocus();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = S.of(context).errorServerUnavailable);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  /// El servidor marco la cuenta como verificada. El claim `email_verified`
  /// viaja DENTRO del id token, asi que sin refrescarlo las funciones de pago
  /// lo seguirian viendo en false y el usuario no podria donar aunque acabe de
  /// verificar. `reload()` refresca el objeto local; `getIdToken(true)` fuerza
  /// el token nuevo.
  Future<void> _finish() async {
    try {
      await FirebaseAuth.instance.currentUser?.reload();
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
    } catch (_) {
      // Si el refresco falla igual seguimos: el router revalida en la proxima
      // pasada y, en el peor caso, el usuario ve la pantalla una vez mas.
    }
    if (!mounted) return;
    context.go('/');
  }

  /// Salida para el que se equivoco escribiendo su correo.
  ///
  /// Sin esto la cuenta queda muerta: el codigo viaja siempre al buzon
  /// inexistente y no hay ningun lugar en la app donde corregir la direccion.
  /// Como la cuenta es nueva y no esta verificada, borrarla es seguro — no
  /// tiene donaciones ni historial que perder — y ademas libera el correo mal
  /// escrito para que nadie quede con esa direccion tomada.
  Future<void> _wrongEmail() async {
    final tr = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.verifyEmailWrongTitle),
        content: Text(tr.verifyEmailWrongBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.verifyEmailWrongConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    final user = FirebaseAuth.instance.currentUser;
    try {
      await user?.delete();
    } catch (_) {
      // `delete()` exige login reciente. Si lo rechaza, cerramos sesion igual:
      // el usuario vuelve al registro y la cuenta huerfana sin verificar la
      // barre el limpiador de cuentas.
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _deleting = false);
    context.go('/register');
  }

  String _messageFor(FirebaseFunctionsException e) {
    final tr = S.of(context);
    // El backend manda mensajes accionables y ya traducidos al español para
    // estos dos codigos ("te quedan 3 intentos", "el codigo venció"). Los
    // preferimos sobre un texto generico.
    if (e.code == 'invalid-argument' || e.code == 'failed-precondition') {
      final msg = (e.message ?? '').trim();
      if (msg.isNotEmpty && msg.length <= 200) return msg;
    }
    if (e.code == 'resource-exhausted') return tr.verifyEmailTooManyRequests;
    return tr.errorServerUnavailable;
  }

  void _onCellChanged(int index, String value) {
    final digit = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digit.isEmpty) {
      _controllers[index].clear();
      setState(() => _error = null);
      if (index > 0) _focusNodes[index - 1].requestFocus();
      return;
    }
    // Pegar el codigo entero desde el correo: se reparte en las celdas en vez
    // de meter los 6 digitos en la primera.
    if (digit.length > 1) {
      for (var i = 0; i < _cells; i++) {
        _controllers[i].text = i < digit.length ? digit[i] : '';
      }
      setState(() => _error = null);
      _focusNodes[_cells - 1].requestFocus();
      if (_allFilled) _verify();
      return;
    }
    _controllers[index].text = digit;
    setState(() => _error = null);
    if (index < _cells - 1) {
      _focusNodes[index + 1].requestFocus();
    } else {
      _focusNodes[index].unfocus();
    }
    if (_allFilled) _verify();
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final busy = _verifying || _deleting;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.mark_email_unread_outlined,
                      size: 56, color: cs.primary),
                  const SizedBox(height: 20),
                  Text(
                    tr.verifyEmailTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    tr.verifyEmailSubtitle(email),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const gap = 8.0;
                      final w =
                          ((constraints.maxWidth - gap * (_cells - 1)) / _cells)
                              .clamp(38.0, 52.0);
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(_cells, (i) {
                          return Padding(
                            padding: EdgeInsets.only(
                                right: i == _cells - 1 ? 0 : gap),
                            child: SizedBox(
                              width: w,
                              height: w * 1.25,
                              child: TextField(
                                controller: _controllers[i],
                                focusNode: _focusNodes[i],
                                enabled: !busy,
                                textAlign: TextAlign.center,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                style: TextStyle(
                                  fontSize: w * 0.5,
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurface,
                                ),
                                decoration: InputDecoration(
                                  counterText: '',
                                  contentPadding: EdgeInsets.zero,
                                  filled: true,
                                  fillColor: cs.surface,
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide(
                                      color: _error != null
                                          ? cs.error
                                          : cs.outline,
                                      width: 1.5,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide:
                                        BorderSide(color: cs.primary, width: 2),
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onChanged: (v) => _onCellChanged(i, v),
                              ),
                            ),
                          );
                        }),
                      );
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: cs.error),
                    ),
                  ],
                  if (_info != null && _error == null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _info!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: cs.primary),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_verifying)
                    const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed:
                        (_sending || _cooldown > 0 || busy) ? null : _send,
                    child: Text(
                      _cooldown > 0
                          ? tr.verifyEmailResendIn(_cooldown)
                          : tr.verifyEmailResend,
                    ),
                  ),
                  TextButton(
                    onPressed: busy ? null : _wrongEmail,
                    child: Text(
                      tr.verifyEmailWrongAddress,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
