import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../analytics/analytics_service.dart';
import '../../payments/stripe_service.dart';
import '../data/wallet_service.dart';
import 'wallet_requests_screen.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../core/format_utils.dart';
import '../../../core/l10n/s.dart';

class WalletScreen extends ConsumerStatefulWidget {
  const WalletScreen({super.key});

  @override
  ConsumerState<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends ConsumerState<WalletScreen> {
  bool _processing = false;

  @override
  void initState() {
    super.initState();
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<double?> _showAmountDialog({
    String? hint,
    String currencySymbol = '\$',
  }) async {
    final tr = S.of(context);
    final hintText = hint ?? tr.amountHint;
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
              Text(tr.addFunds, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 20),
              Text(tr.enterAmount, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                  if (value != null && value > 0) {
                    Navigator.pop(ctx, value);
                  } else {
                    setDialogState(() => error = tr.enterValidAmount);
                  }
                },
                decoration: InputDecoration(
                  hintText: hintText, prefixText: '$currencySymbol ', errorText: error,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ]),
            actions: [
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Theme.of(ctx).brightness == Brightness.dark ? Theme.of(ctx).colorScheme.primary : const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: () {
                  final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                  if (value == null || value <= 0) { setDialogState(() => error = tr.enterValidAmount); return; }
                  Navigator.pop(ctx, value);
                },
                child: Text(tr.addToBalance, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              )),
              SizedBox(width: double.infinity, height: 44, child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr.cancel, style: const TextStyle(fontWeight: FontWeight.w500)),
              )),
            ],
          ),
        );
      },
    );
  }

  String _currencySymbol(String code) {
    const symbols = {
      'usd': 'US\$', 'eur': '€', 'gbp': '£', 'cad': 'CA\$',
      'mxn': 'MX\$', 'ars': 'ARS\$', 'brl': 'R\$', 'ils': '₪',
      'clp': 'CL\$', 'cop': 'CO\$',
    };
    return symbols[code.toLowerCase()] ?? '\$';
  }

  int _minAmountCentsForCurrency(String currency) {
    switch (currency.toLowerCase()) {
      case 'ars':
        return 100000;
      case 'mxn':
        return 1000;
      case 'brl':
        return 100;
      case 'clp':
        return 50000;
      case 'cop':
        return 200000;
      case 'ils':
        return 200;
      case 'gbp':
        return 30;
      case 'usd':
      case 'eur':
      case 'cad':
        return 50;
      default:
        return 100;
    }
  }

  String _walletPaymentErrorMessage(Object error) {
    final tr = S.of(context);
    if (error is StripeServiceException) {
      if (error.code.toLowerCase() == 'canceled') return tr.paymentCanceled;
      return tr.couldNotStartPayment;
    }
    if (error is FirebaseFunctionsException) {
      return switch (error.code) {
        'not-found' => tr.walletNotFound,
        'failed-precondition' => tr.insufficientFunds,
        'invalid-argument' => tr.invalidWalletId,
        _ => tr.couldNotConfirmTopUp,
      };
    }
    return tr.paymentCouldNotProcess;
  }

  Future<void> _addFunds() async {
    if (_processing) return;
    final user = ref.read(currentUserProvider);
    final profile = ref.read(userProfileProvider).valueOrNull;
    if (user == null) {
      _showInfo(S.of(context).signInToContinue);
      return;
    }

    final currency = ((profile?['currencyCode'] as String?) ?? 'USD').toLowerCase();
    final amount = await _showAmountDialog(currencySymbol: _currencySymbol(currency));
    if (!mounted || amount == null) return;

    setState(() => _processing = true);
    try {
      final amountCents = (amount * 100).round();
      final minCents = _minAmountCentsForCurrency(currency);
      if (amountCents < minCents) {
        final minAmountDouble = minCents / 100;
        _showInfo(S.of(context).minAmountCurrency(currency.toUpperCase(), formatMoney(minAmountDouble, symbol: _currencySymbol(currency))));
        return;
      }

      final paymentIntentId = await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: user.email,
        purpose: 'wallet_topup',
      );

      if (!mounted) return;
      await WalletService.instance.confirmTopUpFromPaymentIntent(paymentIntentId);
      await AnalyticsService.instance.logWalletFill(amount);
      if (!mounted) return;
      ref.invalidate(userProfileProvider);
      _showInfo(S.of(context).fundsAdded(formatMoney(amount, symbol: _currencySymbol(currency))));
    } catch (error) {
      if (!mounted) return;
      _showInfo(_walletPaymentErrorMessage(error));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _copyWalletId(String walletId) async {
    await Clipboard.setData(ClipboardData(text: walletId));
    if (!mounted) return;
    _showInfo(S.of(context).walletIdCopied(walletId));
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final red = Theme.of(context).brightness == Brightness.dark ? cs.primary : const Color(0xFFE05A4F);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final uid = ref.watch(currentUserProvider)?.uid;
    final pendingRequests = ref.watch(pendingWalletRequestsProvider).valueOrNull ?? 0;
    final walletId =
        (profile?['walletId'] as String?)?.trim().isNotEmpty == true
            ? (profile?['walletId'] as String).trim()
            : (uid != null ? UserRepository.walletIdFromUid(uid) : '------');
    final walletBalance = ((profile?['walletBalance'] as num?)?.toDouble() ?? 0.0).clamp(0.0, double.infinity);
    final currencyCode = ((profile?['currencyCode'] as String?) ?? 'USD').toLowerCase();
    final autoEnabled = (profile?['walletAutoTopUpEnabled'] as bool?) ?? false;
    final autoAmount = (profile?['walletAutoTopUpAmount'] as num?)?.toDouble() ?? 0.0;
    final autoFrequency = (profile?['walletAutoTopUpFrequency'] as String?) ?? 'weekly';
    final autoNextRunTs = profile?['walletAutoTopUpNextRunAt'];
    final autoNextRun =
        autoNextRunTs is Timestamp ? autoNextRunTs.toDate() : null;
    final autoLabel = autoEnabled
        ? tr.autoRefillActive(formatMoney(autoAmount, symbol: _currencySymbol(currencyCode)), autoFrequency == 'monthly' ? tr.monthly : tr.weekly)
        : tr.autoRefillInactive;
    final autoNextRunLabel = autoEnabled && autoNextRun != null
        ? tr.nextRun('${autoNextRun.day.toString().padLeft(2, '0')}/${autoNextRun.month.toString().padLeft(2, '0')}')
        : autoLabel;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 760;
        final topPadding = compact ? 8.0 : 14.0;
        final sectionGap = compact ? 12.0 : 20.0;
        final walletCardGap = compact ? 10.0 : 14.0;
        final balanceSize = compact ? 46.0 : 54.0;
        final walletIdSize = compact ? 24.0 : 28.0;

        final content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          // texto superior
          Text(
            tr.setFundsSubtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: compact ? 13 : 14,
            ),
          ),
          SizedBox(height: compact ? 4 : 8),
          GestureDetector(
            onTap: () {
              showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  title: Text(tr.walletInfoTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
                  content: Text(tr.walletInfoBody, style: const TextStyle(height: 1.6)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            },
            child: Text(
              tr.learnMore,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          SizedBox(height: compact ? 24.0 : 32.0),

          // Wallet ID pill
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _copyWalletId(walletId),
              child: Container(
                padding: EdgeInsets.symmetric(
                  vertical: compact ? 14 : 18,
                  horizontal: 18,
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    Text(
                      tr.yourWalletId,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: compact ? 4 : 6),
                    Text(
                      walletId,
                      style: TextStyle(
                        color: cs.primary,
                        fontSize: walletIdSize,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          SizedBox(height: compact ? 24.0 : 32.0),

          // Balance
          Text(
            tr.balanceLabel,
            textAlign: TextAlign.center,
            style: const TextStyle(letterSpacing: 2, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: compact ? 4 : 10),
          Text(
            formatMoney(walletBalance, symbol: _currencySymbol(currencyCode)),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: cs.primary,
              fontSize: balanceSize,
              fontWeight: FontWeight.w800,
            ),
          ),

          SizedBox(height: compact ? 24.0 : 32.0),

          // Add funds button
          OutlinedButton(
            onPressed: _processing ? null : _addFunds,
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: red, width: 2),
              minimumSize: Size(0, compact ? 48 : AppTokens.buttonHeight),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              foregroundColor: red,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            child: Text(tr.addFundsBtn),
          ),

          SizedBox(height: sectionGap),

          // Cards
          if (pendingRequests > 0) ...[
            _WalletCard(
              icon: Icons.mark_email_unread_outlined,
              iconBg: cs.primary,
              title: tr.pendingRequests,
              subtitle: '$pendingRequests ${tr.pendingRequestsBadge}',
              onTap: () => context.go('/wallet/requests'),
              compact: compact,
              badgeCount: pendingRequests,
            ),
            SizedBox(height: walletCardGap),
          ],
          _WalletCard(
            icon: Icons.swap_vert,
            iconBg: red,
            title: tr.sendRequest,
            subtitle: tr.sendRequestSub,
            onTap: () => context.go('/wallet/send-request'),
            compact: compact,
          ),
          SizedBox(height: walletCardGap),
          _WalletCard(
            icon: Icons.settings,
            iconBg: red,
            title: tr.manageAutoRefill,
            subtitle: autoNextRunLabel,
            onTap: () => context.go('/wallet-auto-refill'),
            compact: compact,
          ),
          SizedBox(height: walletCardGap),
          _WalletCard(
            icon: Icons.receipt_long,
            iconBg: red,
            title: tr.transactionHistory,
            subtitle: '',
            onTap: () => context.go('/history'),
            compact: compact,
          ),
          ],
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(18, topPadding, 18, compact ? 14 : 20),
          child: LayoutBuilder(
            builder: (context, innerConstraints) {
              return SizedBox(
                width: innerConstraints.maxWidth,
                height: innerConstraints.maxHeight,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: innerConstraints.maxWidth,
                      child: content,
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _WalletCard extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool compact;
  final int badgeCount;

  const _WalletCard({
    required this.icon,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.compact = false,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.all(compact ? 11 : 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: compact ? 46 : 54,
                    height: compact ? 46 : 54,
                    decoration: BoxDecoration(
                      color: iconBg,
                      borderRadius: BorderRadius.circular(compact ? 13 : 16),
                    ),
                    child: Icon(icon, color: Colors.white, size: compact ? 22 : 24),
                  ),
                  if (badgeCount > 0)
                    PositionedDirectional(
                      end: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).colorScheme.primary : const Color(0xFFE05A4F),
                          borderRadius: const BorderRadius.all(Radius.circular(10)),
                        ),
                        child: Text(
                          '$badgeCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(width: compact ? 10 : 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: compact ? 14 : 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      SizedBox(height: compact ? 2 : 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: compact ? 13 : 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: compact ? 4 : 6),
              Icon(
                Icons.chevron_right_rounded,
                size: compact ? 22 : 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
