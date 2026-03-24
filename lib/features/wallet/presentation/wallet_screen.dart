import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../analytics/analytics_service.dart';
import '../../payments/stripe_service.dart';
import '../data/wallet_service.dart';
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

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<double?> _showAmountDialog({
    String? hint,
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
            contentPadding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr.addFunds, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
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
                  hintText: hintText, prefixText: '\$ ', errorText: error,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6)),
                ),
              ),
            ]),
            actions: [
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: () {
                  final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                  if (value == null || value <= 0) { setDialogState(() => error = tr.enterValidAmount); return; }
                  Navigator.pop(ctx, value);
                },
                child: Text(tr.addToBalance, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
    if (error is StripeException) {
      if (error.error.code == FailureCode.Canceled) {
        return S.of(context).paymentCanceled;
      }
      final message = error.error.localizedMessage ?? error.error.message;
      if (message != null && message.trim().isNotEmpty) {
        return message;
      }
    }
    final raw = error.toString();
    if (raw.startsWith('Exception: ')) {
      return raw.replaceFirst('Exception: ', '');
    }
    return S.of(context).paymentCouldNotProcess;
  }

  Future<void> _addFunds() async {
    if (_processing) return;
    final amount = await _showAmountDialog();
    if (!mounted || amount == null) return;

    final user = ref.read(currentUserProvider);
    final profile = ref.read(userProfileProvider).valueOrNull;
    if (user == null) {
      _showInfo(S.of(context).signInToContinue);
      return;
    }

    setState(() => _processing = true);
    try {
      final currency = ((profile?['currencyCode'] as String?) ?? 'USD').toLowerCase();
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

      await WalletService.instance.confirmTopUpFromPaymentIntent(paymentIntentId);
      await AnalyticsService.instance.logWalletFill(amount);
      if (!mounted) return;
      _showInfo(S.of(context).fundsAdded(formatMoney(amount, symbol: _currencySymbol(currency))));
    } catch (error) {
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
    const red = Color(0xFFE05A4F);
    const blue = Color(0xFF2F60C5);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final uid = ref.watch(currentUserProvider)?.uid;
    final walletId =
        (profile?['walletId'] as String?)?.trim().isNotEmpty == true
            ? (profile?['walletId'] as String).trim()
            : (uid != null ? UserRepository.walletIdFromUid(uid) : '------');
    final walletBalance = (profile?['walletBalance'] as num?)?.toDouble() ?? 0.0;
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
              color: Colors.black.withValues(alpha: 0.62),
              fontSize: compact ? 13 : 14,
            ),
          ),
          SizedBox(height: compact ? 4 : 8),
          Text(
            tr.learnMore,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: blue,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationThickness: 1.2,
            ),
          ),

          SizedBox(height: sectionGap),

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
                  color: const Color(0xFFF0F0F0),
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
                        color: blue,
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

          SizedBox(height: sectionGap),

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
              color: blue,
              fontSize: balanceSize,
              fontWeight: FontWeight.w800,
            ),
          ),

          SizedBox(height: sectionGap),

          // Add funds button
          OutlinedButton(
            onPressed: _processing ? null : _addFunds,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: red, width: 2),
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

  const _WalletCard({
    required this.icon,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.compact = false,
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
            color: const Color(0xFFF3F3F3),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
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
                          color: Colors.black.withValues(alpha: 0.55),
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
