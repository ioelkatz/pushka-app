import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../payments/stripe_service.dart';
import '../../tenant/data/tenant_repository.dart';
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
    // autoSetDefault on initial load: cards added via the Stripe Payment
    // Sheet during a payment (Vaciar Pushka) get attached to the customer
    // but don't auto-set as default — so the user doc lacks
    // stripeDefaultPaymentMethodLast4/Brand and the Settings entry shows
    // "no cards" even though there is one. First open of this screen
    // promotes the first card to default and back-fills those fields.
    _loadCards(autoSetDefault: true);
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

      if (autoSetDefault && defaultId == null && cards.isNotEmpty && mounted) {
        await _setDefault(cards.first['id'] as String);
      }
    } catch (e) {
      if (!mounted) return;
      // Treat load errors as empty state — user can still add a card.
      // Keep _error set so a subtle retry banner shows, but don't block the UI.
      setState(() {
        _cards = [];
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
      await StripeService.instance.setupCard(
        merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
      );
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
    } on StripeServiceException catch (e) {
      if (!mounted) return;
      if (e.code == 'canceled') return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.errorLoadingCards)),
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

  // Brand-tinted gradient stops so each card visually matches its issuer
  // (Visa = navy/blue, Mastercard = red→orange, Amex = teal, etc.).
  // Returns (top-left color, bottom-right color).
  // FontAwesome brand icon for the small logo box (null for unrecognized
  // brands → falls back to a plain credit card icon).
  IconData _brandFaIcon(String brand) {
    switch (brand.toLowerCase()) {
      case 'visa':
        return FontAwesomeIcons.ccVisa;
      case 'mastercard':
        return FontAwesomeIcons.ccMastercard;
      case 'amex':
        return FontAwesomeIcons.ccAmex;
      case 'discover':
        return FontAwesomeIcons.ccDiscover;
      case 'jcb':
        return FontAwesomeIcons.ccJcb;
      case 'dinersclub':
        return FontAwesomeIcons.ccDinersClub;
      default:
        return FontAwesomeIcons.creditCard;
    }
  }

  (Color, Color) _brandGradient(String brand) {
    switch (brand.toLowerCase()) {
      case 'visa':
        return (const Color(0xFF1A1F71), const Color(0xFF2B3A9C));
      case 'mastercard':
        return (const Color(0xFFEB001B), const Color(0xFFF79E1B));
      case 'amex':
        return (const Color(0xFF016FD0), const Color(0xFF26A6E2));
      case 'discover':
        return (const Color(0xFFFF6000), const Color(0xFFFFA040));
      case 'jcb':
        return (const Color(0xFF0E4C92), const Color(0xFF7E1F23));
      case 'unionpay':
        return (const Color(0xFFD32027), const Color(0xFF005B9A));
      case 'dinersclub':
        return (const Color(0xFF0079BE), const Color(0xFF003B6F));
      default:
        return (const Color(0xFF374151), const Color(0xFF6B7280));
    }
  }

  Widget _buildCardTile({
    required String pmId,
    required String brand,
    required String last4,
    required int expMonth,
    required int expYear,
    required bool isDefault,
    required S tr,
  }) {
    final cs = Theme.of(context).colorScheme;
    final accent = _brandGradient(brand).$1;
    final mm = expMonth.toString().padLeft(2, '0');
    final yy = expYear.toString().padLeft(4, '0').substring(2);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Brand logo box — white background with the actual brand logo
          // (FontAwesome cc* icons). Falls back to a generic credit card
          // for unrecognized brands.
          Container(
            width: 44,
            height: 30,
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: cs.outlineVariant, width: 1),
            ),
            alignment: Alignment.center,
            child: FaIcon(
              _brandFaIcon(brand),
              size: 22,
              color: accent,
            ),
          ),
          const SizedBox(width: 12),
          // Title + subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                    children: [
                      TextSpan(text: _brandLabel(brand)),
                      const TextSpan(text: '  ····'),
                      TextSpan(
                        text: last4,
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isDefault ? '${tr.cardDefault}  ·  $mm/$yy' : '$mm/$yy',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: isDefault ? accent : cs.onSurfaceVariant,
                    fontWeight: isDefault ? FontWeight.w500 : FontWeight.w400,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: cs.onSurfaceVariant),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    const red = Color(0xFFE05A4F);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blue = Theme.of(context).colorScheme.primary;
    final actionColor = isDark ? blue : red;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Error banner — shown only when load failed, non-blocking
            if (!_loading && _error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 18, color: Colors.red.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tr.errorLoadingCards,
                          style: TextStyle(fontSize: 13, color: Colors.red.shade700),
                        ),
                      ),
                      TextButton(
                        onPressed: _loadCards,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(tr.retry, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ),

            // Card list / loading / empty state
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _cards.isEmpty
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
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          itemCount: _cards.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            thickness: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          itemBuilder: (context, index) {
                            final card = _cards[index];
                            final pmId = card['id'] as String;
                            final brand = card['brand'] as String? ?? 'card';
                            final last4 = card['last4'] as String? ?? '****';
                            final expMonth = (card['expMonth'] as num?)?.toInt() ?? 0;
                            final expYear = (card['expYear'] as num?)?.toInt() ?? 0;
                            final isDefault = pmId == _defaultPaymentMethodId;
                            return _buildCardTile(
                              pmId: pmId,
                              brand: brand,
                              last4: last4,
                              expMonth: expMonth,
                              expYear: expYear,
                              isDefault: isDefault,
                              tr: tr,
                            );
                          },
                        ),
            ),

            // Add card button — always visible
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: (_processing || _loading) ? null : _addCard,
                  icon: _processing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.add_card_outlined),
                  label: Text(
                    tr.addCard,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: actionColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
