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
    // Snapshot count BEFORE the SetupIntent so we can detect a fingerprint
    // collision after the reload. listSavedCards dedupes server-side at list
    // time (matching `card.fingerprint` → detach the newly-attached PM and
    // keep the older / default one), so if the post-add count is unchanged
    // OR the collision flag came back, the user's "new" card was actually
    // a re-save of one they already had.
    final cardCountBefore = _cards.length;
    try {
      await StripeService.instance.setupCard(
        merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
      );
      if (!mounted) return;
      await _loadCards(autoSetDefault: true);
      if (!mounted) return;
      final isDuplicate = _cards.length <= cardCountBefore;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isDuplicate ? tr.cardAlreadySaved : tr.cardAdded),
        ),
      );
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
  // Visa wordmark — public path-data representation of the Visa logo
  // (single-color white, italic, V-I-S-A). The path comes from a clean
  // single-path rendering of the wordmark; scales perfectly and reads
  // as the real Visa mark.
  static const _svgVisa = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path fill="#FFFFFF" d="M9.112 8.262L5.97 15.758H3.92L2.374 9.775c-.094-.368-.175-.503-.461-.658C1.447 8.864.677 8.627 0 8.479l.046-.217h3.3a.904.904 0 01.894.764l.817 4.338 2.018-5.102zm8.033 5.049c.008-1.979-2.736-2.088-2.717-2.972.006-.269.262-.555.822-.628a3.66 3.66 0 011.913.336l.34-1.59a5.207 5.207 0 00-1.814-.333c-1.917 0-3.266 1.02-3.278 2.479-.012 1.079.963 1.68 1.698 2.04.756.367 1.01.603 1.006.931-.005.504-.602.725-1.16.734-.975.015-1.54-.263-1.992-.473l-.351 1.642c.453.208 1.289.39 2.156.398 2.037 0 3.37-1.006 3.377-2.564m5.061 2.447H24l-1.565-7.496h-1.656a.883.883 0 00-.826.55l-2.909 6.946h2.036l.405-1.12h2.488zm-2.163-2.656l1.02-2.815.588 2.815zm-8.16-4.84l-1.603 7.496H8.34l1.605-7.496z"/>
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
        return SvgPicture.string(_svgVisa, width: 34, height: 22);
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

    return InkWell(
      onTap: () => _showCardActionsSheet(pmId, brand, last4, isDefault, tr),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
          Padding(
            padding: const EdgeInsets.only(right: 4, left: 8),
            child: Icon(
              Icons.chevron_right_rounded,
              color: cs.onSurfaceVariant,
              size: 22,
            ),
          ),
        ],
      ),
    ),
    );
  }

  // Bottom sheet with card actions (set as default + delete). Replaces
  // the old kebab popup so the row tap surface is bigger and the chevron
  // pattern matches the wallet-style reference.
  void _showCardActionsSheet(
    String pmId,
    String brand,
    String last4,
    bool isDefault,
    S tr,
  ) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  Text(
                    '${_brandLabel(brand)}  ···· $last4',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (!isDefault)
              ListTile(
                leading: Icon(Icons.star_outline, color: cs.primary),
                title: Text(tr.setAsDefault),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _setDefault(pmId);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(
                tr.deleteCard,
                style: const TextStyle(color: Colors.red),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                _deleteCard(pmId);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
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
                          // Lighter divider + more vertical breathing room
                          // between cards per the wallet reference.
                          separatorBuilder: (_, _) => Divider(
                            height: 18,
                            thickness: 1,
                            color: Theme.of(context).brightness == Brightness.dark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.grey.shade200,
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
