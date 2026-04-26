import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../users/presentation/user_profile_provider.dart';
import '../data/wallet_service.dart';
import '../../../core/format_utils.dart';
import '../../../core/l10n/s.dart';
import '../../../core/widgets/empty_state.dart';

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
    final value = raw.trim().replaceAll(RegExp(r'\s'), '');
    if (value.isEmpty) return '';
    // Wallet IDs are always exactly 8 numeric digits
    if (RegExp(r'^\d{8}$').hasMatch(value)) return value;
    return '';
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _walletError(Object e, String defaultMsg) {
    final tr = S.of(context);
    if (e is FirebaseFunctionsException) {
      return switch (e.code) {
        'not-found' => tr.walletUserNotFound,
        'failed-precondition' => tr.insufficientFunds,
        'invalid-argument' => tr.invalidWalletId,
        _ => defaultMsg,
      };
    }
    return defaultMsg;
  }

  String _currencySymbol() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    final code = ((profile?['currencyCode'] as String?) ?? 'USD').toLowerCase();
    const symbols = {
      'usd': 'US\$', 'eur': '€', 'gbp': '£', 'cad': 'CA\$',
      'mxn': 'MX\$', 'ars': 'ARS\$', 'brl': 'R\$', 'ils': '₪',
      'clp': 'CL\$', 'cop': 'CO\$',
    };
    return symbols[code] ?? '\$';
  }

  Future<double?> _showAmountDialog(String title) async {
    final tr = S.of(context);
    final currencySymbol = _currencySymbol();
    return showDialog<double>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final controller = TextEditingController();
        String? error;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            scrollable: true,
            contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
            actionsPadding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 20),
              Text(tr.enterAmount, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF5A5A5A))),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                  if (value != null && value > 0) Navigator.pop(ctx, value);
                },
                decoration: InputDecoration(
                  hintText: tr.amountHint,
                  prefixText: '$currencySymbol ',
                  errorText: error,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE84324), width: 1.6)),
                ),
              ),
            ]),
            actions: [
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE84324), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: () {
                  final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                  if (value == null || value <= 0) { setDialogState(() => error = tr.enterValidAmount); return; }
                  Navigator.pop(ctx, value);
                },
                child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              )),
              SizedBox(width: double.infinity, height: 44, child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr.cancel, style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
              )),
            ],
          ),
        );
      },
    );
  }

  Future<void> _executeAction() async {
    final contactId = _selectedContactWalletId;
    if (contactId == null) { _showSelectContactBanner(); return; }
    if (_saving) return;

    final tr = S.of(context);
    final title = _sendSelected ? tr.send : tr.request;
    final amount = await _showAmountDialog(title);
    if (!mounted || amount == null) return;

    final isSend = _sendSelected;
    setState(() => _saving = true);
    try {
      if (isSend) {
        await WalletService.instance.transfer(targetWalletId: contactId, amount: amount);
        if (!mounted) return;
        _showInfo(tr.sent(formatMoney(amount), contactId));
      } else {
        await WalletService.instance.requestTransfer(fromWalletId: contactId, amount: amount);
        if (!mounted) return;
        _showInfo(tr.requestSent(formatMoney(amount)));
      }
      if (mounted) setState(() => _selectedContactWalletId = null);
    } catch (e) {
      if (!mounted) return;
      _showInfo(_walletError(e, isSend ? S.of(context).couldNotTransfer : S.of(context).couldNotSendRequest));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSelectContactBanner() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          S.of(context).selectContactBanner,
          textAlign: TextAlign.center,
          style: const TextStyle(
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
    final tr = S.of(context);
    final normalized = _normalizeWalletId(walletId);
    if (normalized.isEmpty) {
      _showInfo(tr.invalidWalletId);
      return;
    }
    // Prevent adding own wallet ID as a contact.
    final ownProfile = ref.read(userProfileProvider).valueOrNull;
    final ownWalletId = ownProfile?['walletId'] as String?;
    if (ownWalletId != null && ownWalletId.trim() == normalized) {
      _showInfo(tr.cannotAddSelf);
      return;
    }
    if (_saving) return;

    setState(() => _saving = true);
    try {
      await WalletService.instance.addContact(normalized);
      if (!mounted) return;
      _showInfo(tr.contactAdded);
    } catch (e) {
      if (!mounted) return;
      _showInfo(_walletError(e, S.of(context).couldNotAddContact));
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
    final tr = S.of(context);
    bool showManualEntry = false;
    String? error;

    final manualWalletId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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
                      Text(S.of(ctx).verification, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 14),
                      Text(
                        S.of(ctx).verificationBody,
                        style: const TextStyle(fontSize: 14, height: 1.45, color: Color(0xFF5A5A5A)),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(height: 52, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Theme.of(ctx).brightness == Brightness.dark ? Theme.of(ctx).colorScheme.primary : const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () => Navigator.of(ctx).pop(''),
                        child: Text(S.of(ctx).scanWalletId, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      const SizedBox(height: 10),
                      Text(S.of(ctx).or_, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Color(0xFF5A5A5A))),
                      const SizedBox(height: 6),
                      if (!showManualEntry)
                        SizedBox(height: 52, child: OutlinedButton(
                          style: OutlinedButton.styleFrom(foregroundColor: Theme.of(ctx).brightness == Brightness.dark ? Theme.of(ctx).colorScheme.primary : const Color(0xFFE05A4F), side: const BorderSide(color: Color(0xFFE05A4F), width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          onPressed: () { setSheetState(() { showManualEntry = true; error = null; }); },
                          child: Text(S.of(ctx).enterWalletId, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        )),
                      if (showManualEntry) ...[
                        TextField(
                          autofocus: true,
                          textCapitalization: TextCapitalization.characters,
                          textInputAction: TextInputAction.done,
                          onChanged: (value) { if (error != null) setSheetState(() => error = null); },
                          onSubmitted: (value) {
                            final normalized = _normalizeWalletId(value);
                            if (normalized.isEmpty) { setSheetState(() => error = S.of(ctx).enterValidId); return; }
                            Navigator.of(ctx).pop(normalized);
                          },
                          decoration: InputDecoration(
                            hintText: S.of(ctx).writeWalletId, errorText: error,
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
    final normalizedManual = _normalizeWalletId(manualWalletId);
    if (manualWalletId.isNotEmpty && normalizedManual.isEmpty) {
      _showInfo(tr.invalidWalletId);
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
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    const red = Color(0xFFE84324);
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
                    child: Text(
                      tr.addNewContact,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  tr.yourContacts,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.6,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: uid == null
                      ? Center(
                          child: Text(
                            tr.signInForContacts,
                            style: const TextStyle(fontSize: 16),
                          ),
                        )
                      : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _contactsStream(uid),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Center(child: Text(tr.errorLoadingContacts));
                            }
                            if (!snapshot.hasData) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            final docs = snapshot.data!.docs;
                            if (docs.isEmpty) {
                              return EmptyState(
                                icon: Icons.people_outline_rounded,
                                iconColor: const Color(0xFF7C3AED),
                                title: tr.noContacts,
                                subtitle: tr.noContactsSubtitle,
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
                                        : tr.defaultContact;
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
                                        color: cs.surfaceContainer,
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
                                                  tr.idPrefix(walletId),
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: cs.onSurfaceVariant,
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
                    onPressed: _saving ? null : () {
                      setState(() => _sendSelected = true);
                      _executeAction();
                    },
                    child: Text(
                      tr.send,
                      style: const TextStyle(
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
                      backgroundColor: cs.onSurface,
                      foregroundColor: cs.surface,
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: _sendSelected ? 1.5 : 0,
                    ),
                    onPressed: _saving ? null : () {
                      setState(() => _sendSelected = false);
                      _executeAction();
                    },
                    child: Text(
                      tr.request,
                      style: const TextStyle(
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
  late final MobileScannerController _scanController;

  @override
  void initState() {
    super.initState();
    _scanController = MobileScannerController();
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  String _normalizeWalletId(String raw) {
    // Extract exactly an 8-digit numeric sequence from the scanned data.
    // This is consistent with the wallet-ID format defined in UserRepository.
    final value = raw.trim();
    final match = RegExp(r'\d{8}').firstMatch(value);
    return match?.group(0) ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of(context).scanQrCode),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scanController,
            onDetect: (capture) {
              if (_handled || !mounted) return;
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
              onPressed: () => _scanController.toggleTorch(),
              iconSize: 28,
              icon: ValueListenableBuilder(
                valueListenable: _scanController,
                builder: (_, value, _) => Icon(
                  value.torchState == TorchState.on
                      ? Icons.flash_on_rounded
                      : Icons.flash_off_rounded,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
