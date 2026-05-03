import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
  // Inline SVGs of the iconic brand marks. Stored as Dart strings so we
  // don't need a separate assets/ folder for 6 small files. Each brand
  // pairs with a bg color so the logo box matches the visual identity
  // (Mastercard black, Visa navy, etc.) — see _brandBg().
  //
  // Visa wordmark — path data approximating the official typeface
  // (italic V-I-S-A with the characteristic curves). White fill so it
  // sits on the navy box bg.
  static const _svgVisa = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 64" preserveAspectRatio="xMidYMid meet">
  <g fill="#FFFFFF">
    <path d="M67.4 8.1L42.5 56.3H30.6L18.4 16.7c-0.7-2.9-1.4-3.9-3.6-5.1C11.1 9.7 5.0 7.9 0 6.8L0.3 5.1H25.5c3.2 0 6.1 2.2 6.9 5.9L38.7 44.1 53.2 8.1H67.4z"/>
    <path d="M114.4 56.3H102.3L110 8.1H122.1L114.4 56.3z"/>
    <path d="M168.2 9.4C165.6 8.4 161.4 7.4 156.2 7.4c-13.7 0-23.3 7.3-23.4 17.7-0.1 7.7 6.9 12 12.1 14.6 5.4 2.6 7.2 4.3 7.2 6.6 -0.0 3.6-4.3 5.2-8.3 5.2 -5.5 0-8.5-0.8-13.0-2.8L129 47.4l-1.9 11.7C130.0 60.5 135.2 61.6 140.4 61.7c14.5 0 24.0-7.2 24.1-18.4 0.0-6.1-3.6-10.8-11.7-14.6 -4.9-2.5-7.9-4.1-7.9-6.6 0.0-2.2 2.5-4.6 8.0-4.6 4.6-0.1 7.9 1.0 10.5 2.1l1.3 0.6L168.2 9.4z"/>
    <path d="M180.5 39.2c1.0-2.7 4.8-13.0 4.8-13.0 -0.1 0.1 1.0-2.7 1.6-4.4l0.8 4.0c0.0 0 2.3 11.0 2.8 13.4H180.5zM195.4 8.1H186.0c-2.9 0-5.1 0.8-6.4 3.9L161.4 56.3H174c0.0 0 2.1-5.7 2.6-6.9 1.4 0 13.5 0 15.3 0 0.4 1.6 1.5 6.9 1.5 6.9H205L195.4 8.1z"/>
  </g>
</svg>''';
  static const _svgMastercard = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 152 96">
  <circle cx="58" cy="48" r="40" fill="#EB001B"/>
  <circle cx="94" cy="48" r="40" fill="#F79E1B"/>
  <path d="M76,16.5 a40 40 0 0 1 0 63 a40 40 0 0 1 0 -63" fill="#FF5F00"/>
</svg>''';
  static const _svgAmex = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 36">
  <text x="50" y="25" text-anchor="middle" fill="#FFFFFF"
        font-family="Helvetica, Arial, sans-serif" font-weight="900"
        font-size="20" letter-spacing="1">AMEX</text>
</svg>''';
  static const _svgDiscover = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 130 30">
  <text x="65" y="22" text-anchor="middle" fill="#FFFFFF"
        font-family="Helvetica, Arial, sans-serif" font-weight="800"
        font-size="18" letter-spacing="1">DISCOVER</text>
</svg>''';
  static const _svgJcb = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 30">
  <text x="30" y="22" text-anchor="middle" fill="#FFFFFF"
        font-family="Helvetica, Arial, sans-serif" font-weight="900"
        font-size="20" letter-spacing="0.5">JCB</text>
</svg>''';
  static const _svgDinersClub = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 90 30">
  <text x="45" y="22" text-anchor="middle" fill="#FFFFFF"
        font-family="Helvetica, Arial, sans-serif" font-weight="800"
        font-size="16" letter-spacing="0.5">DINERS</text>
</svg>''';

  // Background color for the brand box — matches each brand's primary
  // identity (Visa = navy, Mastercard = black, Amex = blue, etc.).
  Color _brandBg(String brand) {
    switch (brand.toLowerCase()) {
      case 'visa':
        return const Color(0xFF1A1F71);
      case 'mastercard':
        return const Color(0xFF111827);
      case 'amex':
        return const Color(0xFF016FD0);
      case 'discover':
        return const Color(0xFFFF6000);
      case 'jcb':
        return const Color(0xFF0E4C92);
      case 'dinersclub':
        return const Color(0xFF0079BE);
      default:
        return const Color(0xFF374151);
    }
  }

  // Renders the brand mark inside the box. Visa is a custom Text widget
  // (its iconic italic wordmark looks better in real text than as a
  // text-rendered SVG). Mastercard is the iconic two-circle logo via
  // inline SVG. Other brands use simplified white wordmark SVGs.
  Widget _brandLogoFor(String brand) {
    switch (brand.toLowerCase()) {
      case 'visa':
        return SvgPicture.string(_svgVisa, width: 30, height: 12);
      case 'mastercard':
        return SvgPicture.string(_svgMastercard, width: 24, height: 16);
      case 'amex':
        return SvgPicture.string(_svgAmex, width: 28, height: 12);
      case 'discover':
        return SvgPicture.string(_svgDiscover, width: 32, height: 10);
      case 'jcb':
        return SvgPicture.string(_svgJcb, width: 22, height: 12);
      case 'dinersclub':
        return SvgPicture.string(_svgDinersClub, width: 28, height: 10);
      default:
        return const Icon(Icons.credit_card, color: Colors.white, size: 18);
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
    final mm = expMonth.toString().padLeft(2, '0');
    final yy = expYear.toString().padLeft(4, '0').substring(2);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // Brand logo box — bg matches the brand identity (Visa navy,
          // Mastercard black, etc.) with the iconic mark inside. The
          // border uses white-with-alpha so it's clearly visible in
          // dark mode against Mastercard/JCB's near-black bg, while
          // staying subtle in light mode (white scrim over a dark box
          // reads as a soft halo, not an outline).
          Container(
            width: 40,
            height: 28,
            decoration: BoxDecoration(
              color: _brandBg(brand),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: _brandLogoFor(brand),
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
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
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
