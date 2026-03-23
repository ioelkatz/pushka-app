import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../users/presentation/user_profile_provider.dart';
import '../data/wallet_service.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../core/keyboard_safe_sheet.dart';

class WalletSendRequestScreen extends ConsumerStatefulWidget {
  const WalletSendRequestScreen({super.key});

  @override
  ConsumerState<WalletSendRequestScreen> createState() =>
      _WalletSendRequestScreenState();
}

class _WalletSendRequestScreenState
    extends ConsumerState<WalletSendRequestScreen> {
  bool _sendSelected = true;
  bool _saving = false;
  String? _selectedContactWalletId;

  Stream<QuerySnapshot<Map<String, dynamic>>> _contactsStream(String uid) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('walletContacts')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  String _normalizeWalletId(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final match = RegExp(r'[A-Za-z0-9-]{4,20}').firstMatch(value);
    return (match?.group(0) ?? value).trim();
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showSelectContactBanner() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'Selecciona un contacto para enviar o solicitar dinero.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            height: 1.3,
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTokens.mutedText,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(36, 0, 36, 94),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _addContact(String walletId) async {
    final normalized = _normalizeWalletId(walletId);
    if (normalized.isEmpty) {
      _showInfo('Ingresa un ID de billetera válido');
      return;
    }
    if (_saving) return;

    setState(() => _saving = true);
    try {
      await WalletService.instance.addContact(normalized);
      _showInfo('Contacto agregado');
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _showInfo(msg);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openScanFlow() async {
    final result = await Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(builder: (_) => const _WalletScannerScreen()),
    );
    if (result == null || result.isEmpty || !mounted) return;
    await _addContact(result);
  }

  Future<void> _showVerificationDialog() async {
    bool showManualEntry = false;
    String manualValue = '';
    String? error;

    final manualWalletId = await showKeyboardSafeSheet<String>(
      context: context,
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      builder: (ctx, setSheetState) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      const Text('Verificación', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 14),
                      const Text(
                        'Para enviar o solicitar tzedaká, primero verifica el contacto:\n'
                        '• Escanea su ID de billetera (arriba a la derecha en esta pantalla), o\n'
                        '• Escribe el código de 6 dígitos que te comparta.',
                        style: TextStyle(fontSize: 14, height: 1.45, color: AppTokens.mutedText),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(height: 52, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () => Navigator.of(ctx).pop(''),
                        child: const Text('Escanear ID de billetera', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      const SizedBox(height: 10),
                      const Text('o', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: AppTokens.mutedText)),
                      const SizedBox(height: 6),
                      if (!showManualEntry)
                        SizedBox(height: 52, child: OutlinedButton(
                          style: OutlinedButton.styleFrom(foregroundColor: AppTokens.primaryBlue, side: const BorderSide(color: AppTokens.primaryBlue, width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          onPressed: () { setSheetState(() { showManualEntry = true; error = null; }); },
                          child: const Text('Ingresar ID de billetera', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        )),
                      if (showManualEntry) ...[
                        TextField(
                            textCapitalization: TextCapitalization.characters,
                          textInputAction: TextInputAction.done,
                          onChanged: (value) { manualValue = value; if (error != null) setSheetState(() => error = null); },
                          onSubmitted: (value) {
                            final normalized = _normalizeWalletId(value);
                            if (normalized.isEmpty) { setSheetState(() => error = 'Ingresa un ID válido'); return; }
                            Navigator.of(ctx).pop(value);
                          },
                          decoration: InputDecoration(
                            hintText: 'Escribe ID de billetera', errorText: error,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                          ),
                        ),
                      ],
                    ],
                  ),
    );

    if (manualWalletId == null) return;
    final normalizedManual = _normalizeWalletId(manualWalletId.isEmpty ? manualValue : manualWalletId);
    if (manualWalletId.isNotEmpty && normalizedManual.isEmpty) {
      _showInfo('Ingresa un ID de billetera válido');
      return;
    }
    if (manualWalletId.isEmpty) {
      await _openScanFlow();
      return;
    }
    await _addContact(normalizedManual);
  }


  Future<double?> _showAmountDialog(String actionLabel) async {
    final controller = TextEditingController();
    String? error;
    return showKeyboardSafeSheet<double>(
      context: context,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      Text(actionLabel, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                        'Contacto: $_selectedContactWalletId',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: controller,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value != null && value > 0) Navigator.pop(ctx, value);
                        },
                        decoration: InputDecoration(
                          hintText: 'Ej: 50', prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      const SizedBox(height: 16),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = 'Ingresa un monto v\u00e1lido'); return; }
                          Navigator.pop(ctx, value);
                        },
                        child: Text(actionLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      SizedBox(width: double.infinity, height: 44, child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                      )),
                    ]),
    );
  }

  Future<void> _executeSend() async {
    if (_selectedContactWalletId == null) {
      _showSelectContactBanner();
      return;
    }
    final amount = await _showAmountDialog('Enviar');
    if (!mounted || amount == null) return;

    setState(() => _saving = true);
    try {
      await WalletService.instance.transfer(
        targetWalletId: _selectedContactWalletId!,
        amount: amount,
      );
      if (!mounted) return;
      _showInfo('Enviado \$${amount.toStringAsFixed(2)} a $_selectedContactWalletId');
    } catch (e) {
      if (!mounted) return;
      _showInfo(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _executeRequest() async {
    if (_selectedContactWalletId == null) {
      _showSelectContactBanner();
      return;
    }
    final amount = await _showAmountDialog('Solicitar');
    if (!mounted || amount == null) return;

    setState(() => _saving = true);
    try {
      await WalletService.instance.requestTransfer(
        fromWalletId: _selectedContactWalletId!,
        amount: amount,
      );
      if (!mounted) return;
      _showInfo('Solicitud de \$${amount.toStringAsFixed(2)} enviada');
    } catch (e) {
      if (!mounted) return;
      _showInfo(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(currentUserProvider)?.uid;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTokens.primaryBlue,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 42),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                    onPressed: _saving ? null : _showVerificationDialog,
                    child: const Text(
                      '+ AGREGAR NUEVO CONTACTO',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'TUS CONTACTOS',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.6,
                    color: AppTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: uid == null
                      ? const Center(
                          child: Text(
                            'Inicia sesión para ver tus contactos',
                            style: TextStyle(fontSize: 16),
                          ),
                        )
                      : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _contactsStream(uid),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return const Center(child: Text('Error cargando contactos'));
                            }
                            if (!snapshot.hasData) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            final docs = snapshot.data!.docs;
                            if (docs.isEmpty) {
                              return const Center(
                                child: Text(
                                  'Sin contactos',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w400,
                                    color: AppTokens.textPrimary,
                                  ),
                                ),
                              );
                            }

                            return ListView.separated(
                              itemCount: docs.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final data = docs[index].data();
                                final name =
                                    (data['displayName'] as String?)?.trim().isNotEmpty == true
                                        ? data['displayName'] as String
                                        : 'Contacto';
                                final walletId = (data['walletId'] as String?) ?? docs[index].id;
                                final isSelected = _selectedContactWalletId == walletId;
                                return Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () {
                                      setState(() => _selectedContactWalletId = walletId);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 12,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTokens.cardSilver,
                                        borderRadius: BorderRadius.circular(14),
                                        border: isSelected
                                            ? Border.all(color: AppTokens.primaryBlue, width: 1.8)
                                            : null,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 36,
                                            height: 36,
                                            decoration: BoxDecoration(
                                              color: AppTokens.primaryBlue.withValues(alpha: 0.14),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: const Icon(
                                              Icons.person_outline_rounded,
                                              color: AppTokens.primaryBlue,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  name,
                                                  style: const TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  'ID: $walletId',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: AppTokens.mutedText,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTokens.primaryBlue,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: _sendSelected ? 0 : 1.5,
                    ),
                    onPressed: _saving ? null : () {
                      setState(() => _sendSelected = true);
                      _executeSend();
                    },
                    child: const Text(
                      'ENVIAR',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTokens.textPrimary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: _sendSelected ? 1.5 : 0,
                    ),
                    onPressed: _saving ? null : () {
                      setState(() => _sendSelected = false);
                      _executeRequest();
                    },
                    child: const Text(
                      'SOLICITAR',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _WalletScannerScreen extends StatefulWidget {
  const _WalletScannerScreen();

  @override
  State<_WalletScannerScreen> createState() => _WalletScannerScreenState();
}

class _WalletScannerScreenState extends State<_WalletScannerScreen> {
  bool _handled = false;
  bool _torchEnabled = false;

  String _normalizeWalletId(String raw) {
    final value = raw.trim();
    final match = RegExp(r'[A-Za-z0-9-]{4,20}').firstMatch(value);
    return (match?.group(0) ?? value).trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear código QR'),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: MobileScannerController(
              torchEnabled: _torchEnabled,
            ),
            onDetect: (capture) {
              if (_handled) return;
              final value = capture.barcodes.isNotEmpty
                  ? capture.barcodes.first.rawValue
                  : null;
              if (value == null || value.trim().isEmpty) return;
              final normalized = _normalizeWalletId(value);
              if (normalized.isEmpty) return;
              _handled = true;
              Navigator.pop(context, normalized);
            },
          ),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
          Positioned.fill(
            child: Center(
              child: Container(
                width: 260,
                height: 2,
                color: AppTokens.primaryBlue,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: IconButton(
              onPressed: () {
                setState(() => _torchEnabled = !_torchEnabled);
              },
              iconSize: 28,
              icon: Icon(
                _torchEnabled ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}