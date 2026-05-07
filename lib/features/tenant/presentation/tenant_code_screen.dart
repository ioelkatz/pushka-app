import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/app_tokens.dart';
import '../data/tenant_repository.dart';
// Join code: "770-JYM". 6 OTP boxes split [7][7][0]–[J][Y][M].
// Dash is a fixed visual separator. One-tap flow: validate → auto-join.

const _kRed = Color(0xFFf82c4a);

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
    try {
      final repo = ref.read(tenantRepositoryProvider);
      final config = await repo.validateSlug(_fullCode);
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
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.code == 'not-found'
              ? 'Código no encontrado. Verificá que sea correcto.'
              : 'Error al validar. Intentá de nuevo.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Error al unirse. Intentá de nuevo.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _kRed,
          brightness: Brightness.light,
        ),
      ),
      child: Scaffold(
        backgroundColor: AppTokens.surface,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Jabad en Campus',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E293B),
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Image.asset(
                    'assets/images/jabad_campus_logo.png',
                    width: 100,
                    height: 100,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 36),
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
                    'Tu rabino te lo compartió por mensaje.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 28),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return _OtpRow(
                        controllers: _controllers,
                        focusNodes: _focusNodes,
                        onCharInput: _onCharInput,
                        onPaste: _onPaste,
                        hasError: _error != null,
                        availableWidth: constraints.maxWidth,
                      );
                    },
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
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: (_loading || !_allFilled) ? null : _joinWithCode,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kRed,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: _kRed.withValues(alpha: 0.4),
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
                          : const Text(
                              'Unirse',
                              style: TextStyle(
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
          controller: controllers[0], focusNode: focusNodes[0],
          index: 0, onCharInput: onCharInput, onPaste: onPaste,
          hasError: hasError, width: boxWidth, height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.18),
        _OtpBox(
          controller: controllers[1], focusNode: focusNodes[1],
          index: 1, onCharInput: onCharInput, onPaste: onPaste,
          hasError: hasError, width: boxWidth, height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.18),
        _OtpBox(
          controller: controllers[2], focusNode: focusNodes[2],
          index: 2, onCharInput: onCharInput, onPaste: onPaste,
          hasError: hasError, width: boxWidth, height: boxHeight,
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
          controller: controllers[3], focusNode: focusNodes[3],
          index: 3, onCharInput: onCharInput, onPaste: onPaste,
          hasError: hasError, width: boxWidth, height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.18),
        _OtpBox(
          controller: controllers[4], focusNode: focusNodes[4],
          index: 4, onCharInput: onCharInput, onPaste: onPaste,
          hasError: hasError, width: boxWidth, height: boxHeight,
        ),
        SizedBox(width: boxWidth * 0.18),
        _OtpBox(
          controller: controllers[5], focusNode: focusNodes[5],
          index: 5, onCharInput: onCharInput, onPaste: onPaste,
          hasError: hasError, width: boxWidth, height: boxHeight,
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
        ? _kRed
        : filled
            ? _kRed
            : const Color(0xFFCBD5E1);

    return SizedBox(
      width: widget.width,
      height: widget.height,
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
          style: TextStyle(
            fontSize: widget.width * 0.44,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF1E293B),
          ),
          decoration: InputDecoration(
            counterText: '',
            filled: true,
            fillColor: filled
                ? _kRed.withValues(alpha: 0.07)
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
              borderSide: const BorderSide(color: _kRed, width: 2),
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
