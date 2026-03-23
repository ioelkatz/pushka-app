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
import '../../../core/keyboard_safe_sheet.dart';

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
    String hint = 'Ej: 50',
  }) async {
    final controller = TextEditingController();
    String? error;
    return showKeyboardSafeSheet<double>(
      context: context,
      heightFactor: 0.55,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      const Text('Agregar fondos', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 20),
                      const Text('Ingresa monto', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTokens.mutedText)),
                      const SizedBox(height: 10),
                      TextField(
                        controller: controller,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value != null && value > 0) Navigator.pop(ctx, value);
                        },
                        decoration: InputDecoration(
                          hintText: hint, prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = 'Ingresa un monto v\u00e1lido'); return; }
                          Navigator.pop(ctx, value);
                        },
                        child: const Text('Agregar al saldo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      SizedBox(width: double.infinity, height: 44, child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                      )),
                    ]),
    );
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
        return 'Pago cancelado';
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
    return 'No se pudo procesar el pago. Intenta nuevamente.';
  }

  Future<void> _addFunds() async {
    if (_processing) return;
    final amount = await _showAmountDialog();
    if (!mounted || amount == null) return;

    final user = ref.read(currentUserProvider);
    final profile = ref.read(userProfileProvider).valueOrNull;
    if (user == null) {
      _showInfo('Inicia sesión para continuar');
      return;
    }

    setState(() => _processing = true);
    try {
      final currency = ((profile?['currencyCode'] as String?) ?? 'USD').toLowerCase();
      final amountCents = ((amount * 100) + 0.001).round();
      final minCents = _minAmountCentsForCurrency(currency);
      if (amountCents < minCents) {
        final minAmount = (minCents / 100).toStringAsFixed(2);
        _showInfo('Monto mínimo para ${currency.toUpperCase()} es \$$minAmount');
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
      _showInfo('Fondos agregados: \$${amount.toStringAsFixed(2)}');
    } catch (error) {
      _showInfo(_walletPaymentErrorMessage(error));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _copyWalletId(String walletId) async {
    await Clipboard.setData(ClipboardData(text: walletId));
    _showInfo('ID de billetera copiado: $walletId');
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final uid = ref.watch(currentUserProvider)?.uid;
    final walletId =
        (profile?['walletId'] as String?)?.trim().isNotEmpty == true
            ? (profile?['walletId'] as String).trim()
            : (uid != null ? UserRepository.walletIdFromUid(uid) : '------');
    final walletBalance = (profile?['walletBalance'] as num?)?.toDouble() ?? 0.0;
    final autoEnabled = (profile?['walletAutoTopUpEnabled'] as bool?) ?? false;
    final autoAmount = (profile?['walletAutoTopUpAmount'] as num?)?.toDouble() ?? 0.0;
    final autoFrequency = (profile?['walletAutoTopUpFrequency'] as String?) ?? 'weekly';
    final autoNextRunTs = profile?['walletAutoTopUpNextRunAt'];
    final autoNextRun =
        autoNextRunTs is Timestamp ? autoNextRunTs.toDate() : null;
    final autoLabel = autoEnabled
        ? 'ACTIVA - \$${autoAmount.toStringAsFixed(2)} '
            '${autoFrequency == 'monthly' ? 'mensual' : 'semanal'}'
        : 'RECARGA AUTOMÁTICA INACTIVA';
    final autoNextRunLabel = autoEnabled && autoNextRun != null
        ? 'Próxima: ${autoNextRun.day.toString().padLeft(2, '0')}/${autoNextRun.month.toString().padLeft(2, '0')}'
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
            'Aparta fondos ahora para vaciar tu Pushka después',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTokens.mutedText,
              fontSize: compact ? 13 : 14,
            ),
          ),
          SizedBox(height: compact ? 4 : 8),
          Text(
            'Aprender más',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTokens.primaryBlue,
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
                  color: AppTokens.cardSilver,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Tu ID de billetera',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: compact ? 4 : 6),
                    Text(
                      walletId,
                      style: TextStyle(
                        color: AppTokens.primaryBlue,
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
          const Text(
            'SALDO',
            textAlign: TextAlign.center,
            style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: compact ? 4 : 10),
          Text(
            '\$${walletBalance.toStringAsFixed(2)}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTokens.primaryBlue,
              fontSize: balanceSize,
              fontWeight: FontWeight.w800,
            ),
          ),

          SizedBox(height: sectionGap),

          // Add funds button
          OutlinedButton(
            onPressed: _processing ? null : _addFunds,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTokens.primaryBlue, width: 2),
              minimumSize: Size(0, compact ? 48 : AppTokens.buttonHeight),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              foregroundColor: AppTokens.primaryBlue,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            child: const Text('+ Agregar fondos'),
          ),

          SizedBox(height: sectionGap),

          // Cards
          _WalletCard(
            icon: Icons.swap_vert,
            iconBg: AppTokens.primaryBlue,
            title: 'Enviar / Solicitar entre billeteras',
            subtitle: 'Empodera a familia y amigos con tzedaká',
            onTap: () => context.go('/wallet/send-request'),
            compact: compact,
          ),
          SizedBox(height: walletCardGap),
          _WalletCard(
            icon: Icons.settings,
            iconBg: AppTokens.primaryBlue,
            title: 'Administrar recarga automática',
            subtitle: autoNextRunLabel,
            onTap: () => context.go('/wallet-auto-refill'),
            compact: compact,
          ),
          SizedBox(height: walletCardGap),
          _WalletCard(
            icon: Icons.receipt_long,
            iconBg: AppTokens.primaryBlue,
            title: 'Historial de transacciones',
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
            color: AppTokens.cardSilver,
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
                          color: AppTokens.mutedText,
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