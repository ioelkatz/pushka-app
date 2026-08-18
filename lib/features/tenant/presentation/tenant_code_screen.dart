import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../data/tenant_repository.dart';
import 'tenant_switch_reset.dart';
// Join code: "770-JYM". 6 OTP boxes split [7][7][0]–[J][Y][M].
// Dash is a fixed visual separator. One-tap flow: validate → auto-join.

const _kRed = Color(0xFFf82c4a);

/// Cuanto se sube el caracter dentro de su celda OTP, como fraccion del
/// fontSize.
///
/// Flutter centra la *line box* de la fuente (ascent + descent), no el glifo.
/// El codigo de invitacion es solo mayusculas y digitos, que no tienen
/// descendentes: el hueco reservado bajo la linea base queda vacio y la letra
/// se ve caida. Con el strut forzado a height 1.0 la linea base cae a ~0.79em
/// y sobra ~0.21em abajo contra ~0.08em arriba, asi que hay que compensar
/// ~0.13em recortando desde abajo.
///
/// Es el unico numero a tocar si el caracter queda alto o bajo: subirlo lo
/// sube, bajarlo lo baja.
const double _kGlyphLift = 0.13;

class TenantCodeScreen extends ConsumerStatefulWidget {
  const TenantCodeScreen({super.key});

  @override
  ConsumerState<TenantCodeScreen> createState() => _TenantCodeScreenState();
}

class _TenantCodeScreenState extends ConsumerState<TenantCodeScreen> {
  final _controllers = List.generate(6, (_) => TextEditingController());
  final _focusNodes = List.generate(6, (_) => FocusNode());

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  String get _fullCode {
    // CF normalizeSlug strips dashes — send without dash so it matches stored slug
    return _controllers.map((c) => c.text).join().toLowerCase();
  }

  bool get _allFilled => _controllers.every((c) => c.text.isNotEmpty);

  void _onCharInput(int index, String value) {
    final char = value.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (char.isEmpty) {
      _controllers[index].clear();
      setState(() => _error = null);
      if (index > 0) {
        _focusNodes[index - 1].requestFocus();
      }
      return;
    }
    _controllers[index].text = char[0].toUpperCase();
    _controllers[index].selection = const TextSelection.collapsed(offset: 1);
    setState(() => _error = null);
    if (index < 5) {
      _focusNodes[index + 1].requestFocus();
    } else {
      _focusNodes[index].unfocus();
      if (_allFilled) {
        _joinWithCode();
      }
    }
  }

  void _onPaste(String pasted) {
    final clean = pasted.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    if (clean.isEmpty) {
      return;
    }
    for (int i = 0; i < 6 && i < clean.length; i++) {
      _controllers[i].text = clean[i];
    }
    setState(() => _error = null);
    if (clean.length >= 6) {
      _focusNodes[5].unfocus();
      _joinWithCode();
    } else {
      _focusNodes[clean.length < 6 ? clean.length : 5].requestFocus();
    }
  }

  // Single-step flow: validate slug then immediately join.
  Future<void> _joinWithCode() async {
    if (!_allFilled || _loading) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    // Snapshot container + uid + outgoing tenantId BEFORE the first await
    // so we don't cross a BuildContext over async gaps. ProviderContainer is
    // owned by the root ProviderScope and survives even if this widget
    // disposes mid-flow. outgoingTenantId may be null on first onboarding.
    final container = ProviderScope.containerOf(context);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final outgoingTenantId =
        container.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    try {
      final repo = ref.read(tenantRepositoryProvider);
      final config = await repo.validateSlug(_fullCode);
      await repo.joinTenant(config.tenantId);
      // Round-7 regression fix: switchTenant errors used to be swallowed
      // silently — the flow would continue as if the switch succeeded
      // (invalidating providers, redirecting home) while the user's
      // active tenantId stayed at the old value. Now surface the failure
      // so the user knows to retry.
      await repo.switchTenant(config.tenantId);
      // Round-2 audit fix: use the shared helper so this flow invalidates
      // the same providers as account_switcher_sheet — otherwise the
      // History tab briefly shows the old tenant's transactions.
      await resetTenantScopedState(
        container,
        uid: uid,
        outgoingTenantId: outgoingTenantId,
      );
      invalidateTenantCache();
      if (mounted) {
        context.go('/');
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _humanError(e, S.of(context));
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = S.of(context).tenantCodeErrorGeneric;
        });
      }
    }
  }

  // Fallback para usuarios que perdieron el código: abre un mail a Ioel
  // (super_admin) que puede guiarlos manualmente. Hardcoded porque en esta
  // pantalla todavía no hay tenantId asociado al user.
  Future<void> _contactSupport() async {
    final tr = S.of(context);
    final uri = Uri(
      scheme: 'mailto',
      path: 'ioelkatz@gmail.com',
      queryParameters: {'subject': tr.tenantCodeMailSubject},
    );
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr.tenantCodeMailOpenFailed);
      }
    }
  }

  // Escape hatch: user firmado pero sin código válido puede salir y volver.
  // El router (authStateChanges listener) redirige a /login automáticamente.
  Future<void> _signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
  }

  // Mensajes específicos por código de error. Antes el catch mostraba
  // "Código no encontrado" para CUALQUIER `not-found` — pero ese código
  // también lo tira joinTenant cuando el user doc Firestore no existe,
  // engañando al usuario ("el código está bien, ¿por qué dice eso?").
  // Idem `resource-exhausted` mostraba "Error al validar" sin pista de
  // que era rate limit.
  String _humanError(FirebaseFunctionsException e, S tr) {
    switch (e.code) {
      case 'not-found':
        return tr.tenantCodeErrorNotFound;
      case 'resource-exhausted':
        final match = RegExp(r'(\d+)\s*segundos').firstMatch(e.message ?? '');
        if (match != null) {
          final secs = int.tryParse(match.group(1) ?? '') ?? 0;
          final mins = (secs / 60).ceil();
          if (mins <= 1) return tr.tenantCodeErrorRateLimitOne;
          return tr.tenantCodeErrorRateLimitMins(mins);
        }
        return tr.tenantCodeErrorRateLimitGeneric;
      case 'unauthenticated':
        return tr.tenantCodeErrorSessionExpired;
      case 'failed-precondition':
        return tr.tenantCodeErrorUnavailable;
      default:
        return tr.tenantCodeErrorGeneric;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    // Esta pantalla es SIEMPRE clara, sin importar el tema del sistema.
    //
    // El Round-5 audit la hizo seguir el brillo del sistema, pero solo cambio
    // el color de fondo: todos los textos de abajo estan hardcodeados en
    // oscuro (0xFF1E293B titulo, 0xFF64748B subtitulo, 0xFF94A3B8 cerrar
    // sesion) igual que las cajas OTP y la imagen del edificio. Resultado:
    // un usuario con el celular en modo oscuro veia fondo #0F172A con texto
    // #1E293B encima — ilegible. Reportado por el cliente en prod.
    //
    // Si algun dia se quiere soportar dark aca, no alcanza con tocar el
    // Scaffold: hay que tematizar tambien los textos, los _OtpBox (fondo
    // Colors.white fijo) y el asset del edificio.
    return Theme(
      data: ThemeData.light().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _kRed,
          brightness: Brightness.light,
        ),
      ),
      // Fondo claro forzado => la status bar necesita iconos oscuros, si no
      // el usuario en modo oscuro los ve blancos sobre blanco.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Stack(
            children: [
              // Building image: hidden when keyboard is open to avoid layout jump
              if (MediaQuery.of(context).viewInsets.bottom == 0)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Image.asset(
                    'assets/images/jabad_campus_building.png',
                    height: MediaQuery.of(context).size.height * 0.30,
                    fit: BoxFit.fitHeight,
                  ),
                ),
              // Main content
              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 34, 28, 24),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final availableWidth = constraints.maxWidth;
                        // Same formula as _OtpRow to compute box width
                        final boxWidth = ((availableWidth - 5 * 8 - 44) / 6)
                            .clamp(36.0, 52.0);
                        // Approximate OTP row visual width:
                        // 6 boxes + 4 small gaps (×0.18) + 2 wide gaps (×0.3) + dash (~×0.45)
                        final otpRowWidth = boxWidth * 7.62;

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // BUG-063 fix: this screen is pre-tenant-join (no
                            // tenantConfig available yet), so we show the
                            // generic Pushka brand instead of hardcoding the
                            // first launch tenant ("Jabad en Campus"). Any
                            // donor of any future tenant lands here when
                            // entering an invite code.
                            const Text(
                              'Pushka',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1E293B),
                                letterSpacing: -0.4,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Image.asset(
                              'assets/images/logo.png',
                              width: 90,
                              height: 90,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(height: 32),
                            Text(
                              tr.tenantCodeTitle,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1E293B),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              tr.tenantCodeSubtitle,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF64748B),
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 28),
                            _OtpRow(
                              controllers: _controllers,
                              focusNodes: _focusNodes,
                              onCharInput: _onCharInput,
                              onPaste: _onPaste,
                              hasError: _error != null,
                              availableWidth: availableWidth,
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: _kRed,
                                ),
                              ),
                            ],
                            const SizedBox(height: 24),
                            // Button aligned to OTP row width
                            SizedBox(
                              width: otpRowWidth,
                              height: 52,
                              child: ElevatedButton(
                                onPressed: (_loading || !_allFilled)
                                    ? null
                                    : _joinWithCode,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _kRed,
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor: _kRed.withValues(
                                    alpha: 0.4,
                                  ),
                                  disabledForegroundColor: Colors.white70,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppTokens.radiusMd,
                                    ),
                                  ),
                                  elevation: 6,
                                  shadowColor: _kRed.withValues(alpha: 0.45),
                                ),
                                child: _loading
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Text(
                                        tr.tenantCodeJoinButton,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            // Fallback discreto: usuario que perdió el código
                            // puede contactar soporte o cerrar sesión sin
                            // quedar bloqueado en esta pantalla.
                            TextButton(
                              onPressed: _contactSupport,
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF64748B),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                tr.tenantCodeLostCode,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            TextButton(
                              onPressed: _signOut,
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF94A3B8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                tr.tenantCodeSignOut,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                            // Reserve space so building image doesn't overlap content
                            const SizedBox(height: 220),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── OTP row ──────────────────────────────────────────────────────────────────

class _OtpRow extends StatelessWidget {
  const _OtpRow({
    required this.controllers,
    required this.focusNodes,
    required this.onCharInput,
    required this.onPaste,
    required this.hasError,
    required this.availableWidth,
  });

  final List<TextEditingController> controllers;
  final List<FocusNode> focusNodes;
  final void Function(int index, String value) onCharInput;
  final void Function(String pasted) onPaste;
  final bool hasError;
  final double availableWidth;

  @override
  Widget build(BuildContext context) {
    // Available width shared between 6 boxes + 5 gaps (8px each) + dash area (44px)
    final boxWidth = ((availableWidth - 5 * 8 - 44) / 6).clamp(36.0, 52.0);
    final boxHeight = boxWidth * 1.22;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _OtpBox(
          controller: controllers[0],
          focusNode: focusNodes[0],
          index: 0,
          onCharInput: onCharInput,
          onPaste: onPaste,
          hasError: hasError,
          width: boxWidth,
          height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.18),
        _OtpBox(
          controller: controllers[1],
          focusNode: focusNodes[1],
          index: 1,
          onCharInput: onCharInput,
          onPaste: onPaste,
          hasError: hasError,
          width: boxWidth,
          height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.18),
        _OtpBox(
          controller: controllers[2],
          focusNode: focusNodes[2],
          index: 2,
          onCharInput: onCharInput,
          onPaste: onPaste,
          hasError: hasError,
          width: boxWidth,
          height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.3),
        Text(
          '—',
          style: TextStyle(
            fontSize: boxWidth * 0.45,
            color: const Color(0xFF94A3B8),
            fontWeight: FontWeight.w300,
          ),
        ),
        SizedBox(width: boxWidth * 0.3),
        _OtpBox(
          controller: controllers[3],
          focusNode: focusNodes[3],
          index: 3,
          onCharInput: onCharInput,
          onPaste: onPaste,
          hasError: hasError,
          width: boxWidth,
          height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.18),
        _OtpBox(
          controller: controllers[4],
          focusNode: focusNodes[4],
          index: 4,
          onCharInput: onCharInput,
          onPaste: onPaste,
          hasError: hasError,
          width: boxWidth,
          height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.18),
        _OtpBox(
          controller: controllers[5],
          focusNode: focusNodes[5],
          index: 5,
          onCharInput: onCharInput,
          onPaste: onPaste,
          hasError: hasError,
          width: boxWidth,
          height: boxHeight,
        ),
      ],
    );
  }
}

// ── Single OTP box ────────────────────────────────────────────────────────────

class _OtpBox extends StatefulWidget {
  const _OtpBox({
    required this.controller,
    required this.focusNode,
    required this.index,
    required this.onCharInput,
    required this.onPaste,
    required this.hasError,
    required this.width,
    required this.height,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int index;
  final void Function(int index, String value) onCharInput;
  final void Function(String pasted) onPaste;
  final bool hasError;
  final double width;
  final double height;

  @override
  State<_OtpBox> createState() => _OtpBoxState();
}

class _OtpBoxState extends State<_OtpBox> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
    widget.focusNode.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    widget.focusNode.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = widget.controller.text.isNotEmpty;
    final focused = widget.focusNode.hasFocus;
    final fontSize = widget.width * 0.44;

    final borderColor = widget.hasError
        ? _kRed
        : focused
        ? _kRed
        : filled
        ? _kRed
        : const Color(0xFFE2E8F0);

    final borderWidth = focused ? 2.0 : 1.5;

    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        // La celda queda SIEMPRE blanca y plana, vacia o llena. Antes el
        // relleno rosado al 6% mas un boxShadow negro al 18% hacian que,
        // apenas escribias, la casilla se viera gris y hundida. Lo unico
        // que cambia al escribir es el borde (gris -> rojo) y la letra.
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.backspace &&
              widget.controller.text.isEmpty &&
              widget.index > 0) {
            widget.onCharInput(widget.index, '');
          }
        },
        child: TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          textAlign: TextAlign.center,
          textAlignVertical: TextAlignVertical.center,
          // Un StrutStyle forzado a height 1.0 fija la line box en exactamente
          // fontSize. Sin esto la caja mide ascent + descent (~1.17em en
          // Roboto) y el centrado arrastra ese sobrante.
          strutStyle: StrutStyle(
            fontSize: fontSize,
            height: 1.0,
            forceStrutHeight: true,
            leading: 0,
          ),
          maxLength: 1,
          keyboardType: TextInputType.visiblePassword,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
          ],
          style: TextStyle(
            fontSize: fontSize,
            height: 1.0,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1E293B),
          ),
          decoration: InputDecoration(
            counterText: '',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            filled: false,
            // Recorta desde abajo el hueco de los descendentes, asi el
            // centrado cae sobre la banda del glifo. Ver _kGlyphLift.
            contentPadding: EdgeInsets.only(bottom: fontSize * _kGlyphLift),
          ),
          onChanged: (value) {
            if (value.length > 1) {
              widget.onPaste(value);
              return;
            }
            widget.onCharInput(widget.index, value);
          },
        ),
      ),
    );
  }
}
