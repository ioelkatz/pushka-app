import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import '../../payments/stripe_service.dart';
import '../../../core/l10n/s.dart';

class SavedCardsScreen extends ConsumerStatefulWidget {
  const SavedCardsScreen({super.key});

  @override
  ConsumerState<SavedCardsScreen> createState() => _SavedCardsScreenState();
}

class _SavedCardsScreenState extends ConsumerState<SavedCardsScreen> {
  bool _loading = true;
  bool _processing = false;
  String? _error;
  List<Map<String, dynamic>> _cards = [];
  String? _defaultPaymentMethodId;

  @override
  void initState() {
    super.initState();
    _loadCards();
  }

  Future<void> _loadCards({bool autoSetDefault = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('listSavedCards');
      final result = await callable.call({});
      if (!mounted) return;
      final data = result.data as Map<dynamic, dynamic>;
      final rawCards = data['cards'] as List<dynamic>? ?? [];
      final cards = rawCards.map((c) => Map<String, dynamic>.from(c as Map)).toList();
      final defaultId = data['defaultPaymentMethodId'] as String?;

      setState(() {
        _cards = cards;
        _defaultPaymentMethodId = defaultId;
        _loading = false;
      });

      // Auto-set the only card as default when there is none yet
      if (autoSetDefault && defaultId == null && cards.isNotEmpty && mounted) {
        await _setDefault(cards.first['id'] as String);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addCard() async {
    if (_processing) return;
    final tr = S.of(context);
    setState(() => _processing = true);
    try {
      await StripeService.instance.setupCard();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.cardAdded)),
      );
      await _loadCards(autoSetDefault: true);
    } on StripeException catch (e) {
      if (!mounted) return;
      if (e.error.code == FailureCode.Canceled) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.error.localizedMessage ?? e.error.message ?? tr.errorLoadingCards)),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? tr.errorLoadingCards)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.errorLoadingCards)),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _setDefault(String pmId) async {
    if (_processing) return;
    if (!mounted) return;
    final tr = S.of(context);
    setState(() => _processing = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('setDefaultPaymentMethod');
      await callable.call({'paymentMethodId': pmId});
      if (!mounted) return;
      setState(() => _defaultPaymentMethodId = pmId);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.cardSetAsDefault)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.errorLoadingCards)),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _deleteCard(String pmId) async {
    if (_processing) return;
    final tr = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(tr.confirmDeleteCard),
        content: Text(tr.confirmDeleteCardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancelBtn),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE05A4F),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(tr.deleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _processing = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('deletePaymentMethod');
      await callable.call({'paymentMethodId': pmId});
      if (!mounted) return;
      await _loadCards();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.cardDeleted)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.errorLoadingCards)),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  String _brandLabel(String brand) {
    const labels = {
      'visa': 'Visa',
      'mastercard': 'Mastercard',
      'amex': 'Amex',
      'discover': 'Discover',
      'jcb': 'JCB',
      'unionpay': 'UnionPay',
      'dinersclub': 'Diners',
    };
    return labels[brand.toLowerCase()] ?? brand;
  }

  IconData _brandIcon(String brand) {
    switch (brand.toLowerCase()) {
      case 'amex':
        return Icons.credit_card_outlined;
      default:
        return Icons.credit_card;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    const red = Color(0xFFE05A4F);
    const blue = Color(0xFF2F60C5);

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr.errorLoadingCards, style: const TextStyle(color: Colors.red)),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _loadCards,
                          child: Text(tr.retry),
                        ),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _cards.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 32),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.credit_card_off_outlined,
                                        size: 56,
                                        color: Colors.grey.shade400,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        tr.noSavedCards,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 15,
                                          color: Colors.grey.shade600,
                                          height: 1.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                                itemCount: _cards.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final card = _cards[index];
                                  final pmId = card['id'] as String;
                                  final brand = card['brand'] as String? ?? 'card';
                                  final last4 = card['last4'] as String? ?? '****';
                                  final expMonth = (card['expMonth'] as num?)?.toInt() ?? 0;
                                  final expYear = (card['expYear'] as num?)?.toInt() ?? 0;
                                  final isDefault = pmId == _defaultPaymentMethodId;

                                  return Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isDefault ? blue : Colors.grey.shade200,
                                        width: isDefault ? 1.5 : 1,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.04),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                                      child: Row(
                                        children: [
                                          Icon(_brandIcon(brand), size: 32, color: blue),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Text(
                                                      '${_brandLabel(brand)}  ${tr.cardEndingIn(last4)}',
                                                      style: const TextStyle(
                                                        fontSize: 15,
                                                        fontWeight: FontWeight.w600,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  tr.cardExpiry(
                                                    expMonth.toString().padLeft(2, '0'),
                                                    expYear.toString(),
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: Colors.grey.shade600,
                                                  ),
                                                ),
                                                if (isDefault) ...[
                                                  const SizedBox(height: 4),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: blue.withValues(alpha: 0.10),
                                                      borderRadius: BorderRadius.circular(4),
                                                    ),
                                                    child: Text(
                                                      tr.cardDefault,
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w600,
                                                        color: blue,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            onSelected: (value) {
                                              if (value == 'default') _setDefault(pmId);
                                              if (value == 'delete') _deleteCard(pmId);
                                            },
                                            itemBuilder: (_) => [
                                              if (!isDefault)
                                                PopupMenuItem(
                                                  value: 'default',
                                                  child: Row(
                                                    children: [
                                                      const Icon(Icons.star_outline, size: 18),
                                                      const SizedBox(width: 8),
                                                      Text(tr.setAsDefault),
                                                    ],
                                                  ),
                                                ),
                                              PopupMenuItem(
                                                value: 'delete',
                                                child: Row(
                                                  children: [
                                                    const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                                    const SizedBox(width: 8),
                                                    Text(tr.deleteCard, style: const TextStyle(color: Colors.red)),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                        child: SizedBox(
                          height: 50,
                          child: ElevatedButton.icon(
                            onPressed: _processing ? null : _addCard,
                            icon: _processing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.add_card_outlined),
                            label: Text(
                              tr.addCard,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: red,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
