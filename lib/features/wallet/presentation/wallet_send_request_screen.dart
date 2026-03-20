import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../users/presentation/user_profile_provider.dart';
import '../data/wallet_service.dart';

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
        backgroundColor: const Color(0xFF777777),
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
    if (result == null || result.isEmpty) return;
    await _addContact(result);
  }

  Future<void> _showVerificationDialog() async {
    bool showManualEntry = false;
    String manualValue = '';
    String? error;

    final manualWalletId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                child: SafeArea(top: false, child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Column(
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
                        style: TextStyle(fontSize: 14, height: 1.45, color: Color(0xFF5A5A5A)),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(height: 52, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () => Navigator.of(ctx).pop(''),
                        child: const Text('Escanear ID de billetera', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      const SizedBox(height: 10),
                      const Text('o', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Color(0xFF5A5A5A))),
                      const SizedBox(height: 6),
                      if (!showManualEntry)
                        SizedBox(height: 52, child: OutlinedButton(
                          style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFE05A4F), side: const BorderSide(color: Color(0xFFE05A4F), width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          onPressed: () { setSheetState(() { showManualEntry = true; error = null; }); },
                          child: const Text('Ingresar ID de billetera', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        )),
                      if (showManualEntry) ...[
                        TextField(
                          autofocus: true,
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
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6)),
                          ),
                        ),
                      ],
                    ],
                  ),
                )),
              ),
            );
          },
        );
      },
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

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE84324);
    const navy = Color(0xFF1F233A);
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
                      backgroundColor: red,
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
                    color: Color(0xFF2D2D2D),
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
                                    color: Color(0xFF2D2D2D),
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
                                        color: const Color(0xFFF4F4F4),
                                        borderRadius: BorderRadius.circular(14),
                                        border: isSelected
                                            ? Border.all(color: red, width: 1.8)
                                            : null,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 36,
                                            height: 36,
                                            decoration: BoxDecoration(
                                              color: red.withValues(alpha: 0.14),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: const Icon(
                                              Icons.person_outline_rounded,
                                              color: red,
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
                                                    color: Colors.black.withValues(alpha: 0.55),
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
                      backgroundColor: red,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: _sendSelected ? 0 : 1.5,
                    ),
                    onPressed: () {
                      setState(() => _sendSelected = true);
                      if (_selectedContactWalletId == null) {
                        _showSelectContactBanner();
                      }
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
                      backgroundColor: navy,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: _sendSelected ? 1.5 : 0,
                    ),
                    onPressed: () {
                      setState(() => _sendSelected = false);
                      if (_selectedContactWalletId == null) {
                        _showSelectContactBanner();
                      }
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
                color: const Color(0xFFE84324),
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
