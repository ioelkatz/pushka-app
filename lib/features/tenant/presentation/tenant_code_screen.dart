import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/app_tokens.dart';
import '../data/tenant_repository.dart';
import '../domain/tenant_config.dart';

// Join code: "770-JYM". User types/pastes into 6 boxes split as [7][7][0]–[J][Y][M].
// The dash is a fixed visual separator — never typed by the user.

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
  TenantConfig? _preview;

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
    final left = _controllers.take(3).map((c) => c.text).join();
    final right = _controllers.skip(3).map((c) => c.text).join();
    return '$left-$right'.toLowerCase();
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
        _validate();
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
      _validate();
    } else {
      _focusNodes[clean.length < 6 ? clean.length : 5].requestFocus();
    }
  }

  Future<void> _validate() async {
    if (!_allFilled) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
    });
    try {
      final config = await ref.read(tenantRepositoryProvider).validateSlug(_fullCode);
      if (mounted) {
        setState(() => _preview = config);
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.code == 'not-found'
              ? 'Código no encontrado. Verificá que sea correcto.'
              : 'Error al validar. Intentá de nuevo.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Error al validar. Intentá de nuevo.');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _join() async {
    final config = _preview;
    if (config == null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(tenantRepositoryProvider);
      await repo.joinTenant(config.tenantId);
      try {
        await repo.switchTenant(config.tenantId);
      } catch (_) {}
      ref.invalidate(tenantConfigProvider);
      ref.invalidate(tenantStateProvider);
      ref.invalidate(userTenantSummariesProvider);
      invalidateTenantCache();
      if (mounted) {
        context.go('/');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'No se pudo unir. Intentá de nuevo.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE8394B),
          brightness: Brightness.light,
        ),
      ),
      child: Scaffold(
        backgroundColor: AppTokens.surface,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/jabad_campus_logo.png',
                    width: 110,
                    height: 110,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Jabad en Campus',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E293B),
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Ciudad de México',
                    style: TextStyle(
                      fontSize: 14,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 40),
                  const Text(
                    'Ingresá el código de invitación',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Tu administrador te lo compartió\npor mensaje o por link.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
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
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFE8394B),
                      ),
                    ),
                  ],
                  if (_preview != null) ...[
                    const SizedBox(height: 16),
                    _PreviewBanner(config: _preview!),
                  ],
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _loading
                          ? null
                          : _preview != null
                              ? _join
                              : _allFilled
                                  ? _validate
                                  : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE8394B),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            const Color(0xFFE8394B).withValues(alpha: 0.4),
                        disabledForegroundColor: Colors.white70,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                        ),
                        elevation: 0,
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
                              _preview != null ? 'Unirse' : 'Buscar',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
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

// ── OTP row: three boxes, dash, three boxes ──────────────────────────────────

class _OtpRow extends StatelessWidget {
  const _OtpRow({
    required this.controllers,
    required this.focusNodes,
    required this.onCharInput,
    required this.onPaste,
    required this.hasError,
  });

  final List<TextEditingController> controllers;
  final List<FocusNode> focusNodes;
  final void Function(int index, String value) onCharInput;
  final void Function(String pasted) onPaste;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _OtpBox(
          controller: controllers[0], focusNode: focusNodes[0],
          index: 0, onCharInput: onCharInput, onPaste: onPaste, hasError: hasError,
        ),
        const SizedBox(width: 8),
        _OtpBox(
          controller: controllers[1], focusNode: focusNodes[1],
          index: 1, onCharInput: onCharInput, onPaste: onPaste, hasError: hasError,
        ),
        const SizedBox(width: 8),
        _OtpBox(
          controller: controllers[2], focusNode: focusNodes[2],
          index: 2, onCharInput: onCharInput, onPaste: onPaste, hasError: hasError,
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            '—',
            style: TextStyle(
              fontSize: 22,
              color: Color(0xFF94A3B8),
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
        _OtpBox(
          controller: controllers[3], focusNode: focusNodes[3],
          index: 3, onCharInput: onCharInput, onPaste: onPaste, hasError: hasError,
        ),
        const SizedBox(width: 8),
        _OtpBox(
          controller: controllers[4], focusNode: focusNodes[4],
          index: 4, onCharInput: onCharInput, onPaste: onPaste, hasError: hasError,
        ),
        const SizedBox(width: 8),
        _OtpBox(
          controller: controllers[5], focusNode: focusNodes[5],
          index: 5, onCharInput: onCharInput, onPaste: onPaste, hasError: hasError,
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
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int index;
  final void Function(int index, String value) onCharInput;
  final void Function(String pasted) onPaste;
  final bool hasError;

  @override
  State<_OtpBox> createState() => _OtpBoxState();
}

class _OtpBoxState extends State<_OtpBox> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = widget.controller.text.isNotEmpty;
    final borderColor = widget.hasError
        ? const Color(0xFFE8394B)
        : filled
            ? const Color(0xFFE8394B)
            : const Color(0xFFCBD5E1);

    return SizedBox(
      width: 44,
      height: 54,
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
          maxLength: 1,
          keyboardType: TextInputType.visiblePassword,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
          ],
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1E293B),
          ),
          decoration: InputDecoration(
            counterText: '',
            filled: true,
            fillColor: filled
                ? const Color(0xFFE8394B).withValues(alpha: 0.07)
                : const Color(0xFFF1F5F9),
            contentPadding: EdgeInsets.zero,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: borderColor, width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: borderColor, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE8394B), width: 2),
            ),
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

// ── Preview banner shown after successful slug validation ─────────────────────

class _PreviewBanner extends StatelessWidget {
  const _PreviewBanner({required this.config});

  final TenantConfig config;

  @override
  Widget build(BuildContext context) {
    final label = config.appName.isNotEmpty ? config.appName : config.name;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE8394B).withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8394B).withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded, color: Color(0xFFE8394B), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1E293B),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
