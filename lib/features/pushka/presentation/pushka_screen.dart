import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_stripe/flutter_stripe.dart' hide PaymentMethod;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../analytics/analytics_service.dart';
import '../../auth/biometric_service.dart';
import '../../history/data/transaction_repository.dart';
import '../../history/domain/transaction.dart';
import '../../payments/stripe_service.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../../config/stripe_config.dart';

class PushkaScreen extends ConsumerStatefulWidget {
  const PushkaScreen({super.key});

  @override
  ConsumerState<PushkaScreen> createState() => _PushkaScreenState();
}

class _PushkaScreenState extends ConsumerState<PushkaScreen> {
  double pushkaAmount = 0;
  double pushkaGoal = 3600.00; // Meta de la pushka
  List<double> _presetAmounts = [];
  bool _loadedRemote = false;
  bool _isProcessing = false;

  Future<void> addAmount(double amount) async {
    setState(() => pushkaAmount += amount);
    await _persistPushkaAmount();
  }
  
  Future<void> emptyPushka() async {
    if (pushkaAmount <= 0 || _isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      await _addTransaction(TransactionType.pushkaEmpty, pushkaAmount);
      await AnalyticsService.instance.logPushkaEmpty(pushkaAmount);
      await _persistPushkaAmount(resetToZero: true);
      if (!mounted) return;
      setState(() => pushkaAmount = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pushka vaciada')),
      );
    } catch (error, stack) {
      debugPrint('emptyPushka error: $error');
      debugPrint('$stack');
      if (!mounted) return;
      _showError('No se pudo vaciar la Pushka');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }
  
  Future<void> _donateNow() async {
    if (pushkaAmount <= 0 || _isProcessing) return;
    final donationAmount = await _resolveDonationAmount();
    if (donationAmount == null || donationAmount <= 0) return;

    if (_biometricEnabled()) {
      final authenticated = await BiometricService.instance.authenticate(
        reason: 'Confirma tu identidad para procesar la donación',
      );
      if (!authenticated) {
        _showError('Autenticación requerida para donar');
        return;
      }
    }

    if (_additionalPaymentOptionsEnabled()) {
      final method = await _showPaymentMethodSelector();
      if (method == null || !mounted) return;
      if (method == PaymentMethod.card) {
        await _processCardPayment(donationAmount);
      } else {
        await _processAlternativePayment(donationAmount, method);
      }
    } else {
      await _processCardPayment(donationAmount);
    }
  }

  Future<void> _processCardPayment(double donationAmount) async {
    setState(() => _isProcessing = true);
    try {
      if (StripeConfig.publishableKey.isEmpty) {
        throw Exception('Stripe no está configurado');
      }

      final amountCents = (donationAmount * 100).round();
      final currency = _currencyCodeFromProfile();
      final minCents = _minAmountCentsForCurrency(currency);
      if (amountCents < minCents) {
        if (!mounted) return;
        _showMinAmountDialog(currency, minCents, donationAmount);
        return;
      }
      await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: ref.read(currentUserProvider)?.email,
        purpose: 'donation',
      );

      await AnalyticsService.instance.logDonation(donationAmount, currency);
      final remaining = (pushkaAmount - donationAmount).clamp(0.0, double.infinity);
      if (mounted) {
        setState(() => pushkaAmount = remaining);
      }
      await _persistPushkaAmount(resetToZero: remaining <= 0);

      final user = ref.read(currentUserProvider);
      if (user != null) {
        await ref.read(transactionRepositoryProvider).addTransaction(
          uid: user.uid,
          type: TransactionType.tzedaka,
          amount: donationAmount,
          description: 'Donación con tarjeta',
          paymentMethod: PaymentMethod.card,
          status: PaymentStatus.completed,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              remaining > 0
                  ? 'Pago procesado. Quedaron \$${remaining.toStringAsFixed(2)} en la Pushka.'
                  : 'Pago procesado. Se reflejará en el historial pronto.',
            ),
          ),
        );
      }
    } catch (error) {
      debugPrint('Card payment error: $error');
      if (!mounted) return;
      _showError(_donationErrorMessage(error));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _processAlternativePayment(double amount, PaymentMethod method) async {
    final confirmed = await _showPaymentInstructions(method, amount);
    if (confirmed != true) return;

    setState(() => _isProcessing = true);
    try {
      final remaining = (pushkaAmount - amount).clamp(0.0, double.infinity);
      if (mounted) setState(() => pushkaAmount = remaining);
      await _persistPushkaAmount(resetToZero: remaining <= 0);

      final user = ref.read(currentUserProvider);
      if (user != null) {
        final methodLabels = {
          PaymentMethod.check: 'cheque',
          PaymentMethod.transfer: 'transferencia bancaria',
          PaymentMethod.daf: 'DAF (Donor Advised Fund)',
        };
        await ref.read(transactionRepositoryProvider).addTransaction(
          uid: user.uid,
          type: TransactionType.tzedaka,
          amount: amount,
          description: 'Donación vía ${methodLabels[method] ?? method.name}',
          paymentMethod: method,
          status: PaymentStatus.pending,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Donación de \$${amount.toStringAsFixed(2)} registrada como pendiente. '
              'Completa el pago según las instrucciones.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (error) {
      if (mounted) _showError('No se pudo registrar la donación');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  double get fillPercentage {
    if (pushkaGoal <= 0) return 0;
    final percentage = (pushkaAmount / pushkaGoal).clamp(0.0, 1.0);
    return percentage;
  }

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE05A4F);
    const blue = Color(0xFF2F60C5);
    const lightBlue = Color(0xFFE3F2FD);

    final userProfile = ref.watch(userProfileProvider).valueOrNull;
    final remoteGoal = userProfile?['pushkaGoal'];
    final remoteAmount = userProfile?['pushkaAmount'];
    final remotePresets = userProfile?['presetAmounts'];

    if (!_loadedRemote && userProfile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          if (remoteGoal is num) pushkaGoal = remoteGoal.toDouble();
          if (remoteAmount is num) pushkaAmount = remoteAmount.toDouble();
          if (remotePresets is List && remotePresets.length == 3) {
            _presetAmounts = remotePresets.map((e) => (e as num).toDouble()).toList();
          }
          _loadedRemote = true;
        });
      });
    }

    final quickAmounts = _buildQuickAmounts();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxHeight < 560;
            final imageHeight = isCompact ? 250.0 : 450.0;
            final topGap = isCompact ? 10.0 : 16.0;
            final titleSize = isCompact ? 23.0 : 28.0;
            final subtitleSize = isCompact ? 14.0 : 16.0;
            final titleBottomGap = isCompact ? 14.0 : 24.0;
            final actionsTopGap = isCompact ? 12.0 : 16.0;

            Widget pushkaStack() {
              return Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    height: imageHeight,
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        Image.asset(
                          'assets/images/pushka.png',
                          height: imageHeight,
                          fit: BoxFit.contain,
                        ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: ClipRect(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              heightFactor: fillPercentage,
                              child: Container(
                                height: imageHeight,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      lightBlue.withValues(alpha: 0.6),
                                      lightBlue.withValues(alpha: 0.3),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: isCompact ? 8 : 20,
                    left: 0,
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: blue,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "\$${pushkaGoal.toStringAsFixed(2)}",
                          style: TextStyle(
                            color: blue,
                            fontSize: isCompact ? 14 : 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: isCompact ? 8 : 20,
                    right: 0,
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: blue,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "\$${pushkaAmount.toStringAsFixed(2)}",
                          style: TextStyle(
                            color: blue,
                            fontSize: isCompact ? 14 : 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }

            final content = Column(
              mainAxisSize: isCompact ? MainAxisSize.min : MainAxisSize.max,
              children: [
            // Banner de Streak
            _buildStreakBanner(lightBlue, blue),
            
            SizedBox(height: topGap),

            // Títulos
            Text(
              "¡Llénala!",
              style: TextStyle(
                fontSize: titleSize,
                fontWeight: FontWeight.w700,
                color: blue,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "Sigamos adelante",
              style: TextStyle(color: Colors.black54, fontSize: subtitleSize),
            ),
            SizedBox(height: titleBottomGap),

            // Pushka con efecto de llenado
            if (isCompact)
              Center(child: pushkaStack())
            else
              Expanded(
                child: Center(child: pushkaStack()),
              ),

            SizedBox(height: actionsTopGap),

            // Botones de monto
            Row(
              children: [
                _moneyBtn(
                  _formatQuickAmount(quickAmounts[0]),
                  red,
                  () => addAmount(quickAmounts[0]),
                ),
                const SizedBox(width: 10),
                _moneyBtn(
                  _formatQuickAmount(quickAmounts[1]),
                  red,
                  () => addAmount(quickAmounts[1]),
                ),
                const SizedBox(width: 10),
                _moneyBtn(
                  _formatQuickAmount(quickAmounts[2]),
                  red,
                  () => addAmount(quickAmounts[2]),
                ),
                const SizedBox(width: 10),
                _moneyBtn('OTRO', red, _otherAmount),
              ],
            ),

            const SizedBox(height: 18),

            // Botones de acción
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _donateNow,
                  child: const Text(
                    'DONAR AHORA',
                    style: TextStyle(color: red, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: emptyPushka,
                  child: const Text(
                    'VACIAR PUSHKA',
                    style: TextStyle(color: red, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.grey),
                  onPressed: _showTzedakahSettingsDialog,
                ),
              ],
            ),
              ],
            );

            if (isCompact) {
              return SingleChildScrollView(
                child: content,
              );
            }
            return content;
          },
        ),
      ),
    );
  }

  Widget _buildStreakBanner(Color lightBlue, Color blue) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: blue,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          // Hexágono con número
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: lightBlue,
              borderRadius: BorderRadius.circular(6),
            ),
            margin: const EdgeInsets.all(4),
            child: Center(
              child: Text(
                '1',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: blue,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Racha de Días de Semana',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Expanded _moneyBtn(String label, Color border, VoidCallback onTap) {
    return Expanded(
      child: SizedBox(
        height: 44,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: border, width: 2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            foregroundColor: border,
            textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _otherAmount() async {
    final controller = TextEditingController();
    String? error;

    final result = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                    const Text('Otro monto', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 14),
                    TextField(
                      controller: controller,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        hintText: 'Ej: 12.50', prefixText: '\$ ', errorText: error,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6)),
                      ),
                      onChanged: (_) { if (error != null) setSheetState(() => error = null); },
                    ),
                    const SizedBox(height: 16),
                    SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      onPressed: () {
                        final value = double.tryParse(controller.text.replaceAll(',', '.'));
                        if (value == null || value <= 0) { setSheetState(() => error = 'Ingresa un monto válido'); return; }
                        Navigator.pop(ctx, value);
                      },
                      child: const Text('Agregar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    )),
                    const SizedBox(height: 8),
                    SizedBox(width: double.infinity, height: 44, child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                    )),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    controller.dispose();
    if (result != null) await addAmount(result);
  }

  Future<void> _addTransaction(TransactionType type, double amount) async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showError('Inicia sesión para continuar');
      return;
    }
    await ref.read(transactionRepositoryProvider).addTransaction(
          uid: user.uid,
          type: type,
          amount: amount,
        );
  }

  Future<void> _persistPushkaAmount({bool resetToZero = false}) async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showError('Inicia sesión para continuar');
      return;
    }
    final amount = resetToZero ? 0.0 : pushkaAmount;
    await ref.read(userRepositoryProvider).updatePushkaAmount(
          uid: user.uid,
          amount: amount,
        );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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

  void _showMinAmountDialog(String currency, int minCents, double attempted) {
    final symbol = _currencySymbol(currency);
    final minAmount = _formatAmountFromCents(minCents);
    final code = currency.toUpperCase();

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.info_outline_rounded, color: Color(0xFFFF9500), size: 30),
            ),
            const SizedBox(height: 16),
            const Text(
              'Monto mínimo',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              'Para procesar pagos en $code, el monto mínimo es de $symbol$minAmount.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700, height: 1.4),
            ),
            const SizedBox(height: 6),
            Text(
              'Puedes aumentar el monto o cambiar la moneda en Configuración.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500, height: 1.4),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE05A4F),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Entendido', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  String _donationErrorMessage(Object error) {
    if (error is FirebaseFunctionsException) {
      return switch (error.code) {
        'unauthenticated' =>
          'Tu sesión no es válida. Cierra sesión e inicia de nuevo.',
        'failed-precondition' =>
          'Verificación de seguridad fallida. Intenta de nuevo.',
        'permission-denied' =>
          'Acceso denegado por seguridad. Intenta de nuevo.',
        'internal' =>
          'Error del servidor de pagos. Verifica tu conexión e intenta de nuevo.',
        'unavailable' =>
          'El servidor de pagos no está disponible. Intenta más tarde.',
        _ => error.message ?? 'No se pudo iniciar el pago',
      };
    }
    if (error is StripeException) {
      if (error.error.code == FailureCode.Canceled) {
        return 'Pago cancelado';
      }
      final msg = error.error.localizedMessage ?? error.error.message;
      if (msg != null && msg.trim().isNotEmpty) {
        return 'No se pudo completar el pago: $msg';
      }
    }
    if (error is Exception) {
      final msg = error.toString().replaceFirst('Exception: ', '');
      if (msg.isNotEmpty && msg != 'null') {
        return msg;
      }
    }
    return 'No se pudo completar la donación';
  }

  String _currencyCodeFromProfile() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    final code = profile?['currencyCode'] as String?;
    if (code != null && code.trim().isNotEmpty) {
      return code;
    }
    return 'usd';
  }

  bool _partialPaymentsEnabled() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    return (profile?['partialPaymentsEnabled'] as bool?) ?? false;
  }

  bool _additionalPaymentOptionsEnabled() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    return (profile?['additionalPaymentOptionsEnabled'] as bool?) ?? false;
  }

  bool _biometricEnabled() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    return (profile?['biometricAuthenticationEnabled'] as bool?) ?? false;
  }

  Future<double?> _resolveDonationAmount() async {
    if (!_partialPaymentsEnabled()) return pushkaAmount;
    return _showPartialDonationDialog();
  }

  Future<PaymentMethod?> _showPaymentMethodSelector() async {
    return showDialog<PaymentMethod>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Método de pago', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Selecciona cómo deseas realizar tu donación', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            const SizedBox(height: 18),
            _paymentMethodTile(ctx, PaymentMethod.card, Icons.credit_card, 'Tarjeta de crédito/débito', 'Pago inmediato vía Stripe'),
            const SizedBox(height: 10),
            _paymentMethodTile(ctx, PaymentMethod.check, Icons.mail_outline, 'Cheque', 'Envía un cheque por correo'),
            const SizedBox(height: 10),
            _paymentMethodTile(ctx, PaymentMethod.transfer, Icons.account_balance, 'Transferencia bancaria', 'Transferencia electrónica'),
            const SizedBox(height: 10),
            _paymentMethodTile(ctx, PaymentMethod.daf, Icons.volunteer_activism, 'DAF', 'Donor Advised Fund'),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, height: 44, child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
            )),
          ]),
        ),
      ),
    );
  }

  Widget _paymentMethodTile(BuildContext ctx, PaymentMethod method, IconData icon, String title, String subtitle) {
    const red = Color(0xFFE05A4F);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.pop(ctx, method),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: red, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ])),
          Icon(Icons.chevron_right, color: Colors.grey.shade400),
        ]),
      ),
    );
  }

  Future<bool?> _showPaymentInstructions(PaymentMethod method, double amount) async {
    if (method == PaymentMethod.card) return null;

    final String title;
    final String instructionText;
    final IconData icon;

    switch (method) {
      case PaymentMethod.check:
        title = 'Pago con Cheque';
        icon = Icons.mail_outline;
        instructionText =
            'Envía un cheque por el monto de \$${amount.toStringAsFixed(2)} a:\n\n'
            'Nombre: [Nombre de la Organización]\n'
            'Dirección: [Dirección postal]\n'
            'Ciudad, Estado, ZIP: [Ciudad, ST 00000]\n\n'
            'Referencia: Incluye tu email o ID de usuario en el memo del cheque.\n\n'
            'Una vez recibido y procesado, la donación se marcará como confirmada en tu historial.';
      case PaymentMethod.transfer:
        title = 'Transferencia Bancaria';
        icon = Icons.account_balance;
        instructionText =
            'Transfiere \$${amount.toStringAsFixed(2)} a la siguiente cuenta:\n\n'
            'Banco: [Nombre del Banco]\n'
            'Número de cuenta: [XXXX-XXXX-XXXX]\n'
            'Routing / ABA: [XXXXXXXXX]\n'
            'Beneficiario: [Nombre de la Organización]\n\n'
            'Referencia: Usa tu email como referencia de la transferencia.\n\n'
            'El pago se confirmará automáticamente en 2-3 días hábiles.';
      case PaymentMethod.daf:
        title = 'Donor Advised Fund (DAF)';
        icon = Icons.volunteer_activism;
        instructionText =
            'Realiza una donación de \$${amount.toStringAsFixed(2)} desde tu DAF a:\n\n'
            'Organización: [Nombre Legal de la Organización]\n'
            'EIN: [XX-XXXXXXX]\n'
            'Dirección: [Dirección de la Organización]\n\n'
            'Indica tu email en el campo de notas del grant.\n\n'
            'Proveedores comunes: Fidelity Charitable, Schwab Charitable, DAF Direct.\n\n'
            'Una vez procesado el grant, la donación se confirmará en tu historial.';
      case PaymentMethod.card:
        return null;
    }

    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Column(children: [
                  Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                  Icon(icon, size: 40, color: const Color(0xFFE05A4F)),
                  const SizedBox(height: 10),
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(color: const Color(0xFFE05A4F).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                    child: Text('\$${amount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFFE05A4F))),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Flexible(child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: const Color(0xFFF8F8F8), borderRadius: BorderRadius.circular(12)),
                  child: Text(instructionText, style: const TextStyle(fontSize: 14, height: 1.55, color: Color(0xFF3A3A3A))),
                ),
              )),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Column(children: [
                  SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Confirmar donación', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  )),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, height: 44, child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                  )),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<double?> _showPartialDonationDialog() async {
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PartialDonationSheet(available: pushkaAmount),
    );
  }

  int _minAmountCentsForCurrency(String currency) {
    switch (currency.toLowerCase()) {
      case 'ars':
        return 100000; // 1000 ARS (~$0.80 USD)
      case 'mxn':
        return 1000; // 10 MXN (~$0.50 USD)
      case 'brl':
        return 100; // 1.00 BRL (~$0.20 USD)
      case 'clp':
        return 50000; // 500 CLP (~$0.55 USD, zero-decimal)
      case 'cop':
        return 200000; // 2000 COP (~$0.50 USD)
      case 'ils':
        return 200; // 2.00 ILS (~$0.55 USD)
      case 'gbp':
        return 30; // 0.30 GBP (Stripe's actual min)
      case 'usd':
      case 'eur':
      case 'cad':
        return 50; // 0.50
      default:
        return 100; // 1.00 safe default
    }
  }

  String _formatAmountFromCents(int cents) {
    final value = cents / 100;
    if (value == value.roundToDouble() && value >= 1) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }

  List<double> _presetsForCurrency(String currency) {
    switch (currency.toLowerCase()) {
      case 'mxn':
        return [20, 100, 200];
      case 'ars':
        return [1000, 5000, 10000];
      case 'brl':
        return [5, 25, 50];
      case 'clp':
        return [1000, 5000, 10000];
      case 'cop':
        return [5000, 20000, 50000];
      case 'ils':
        return [5, 20, 40];
      case 'eur':
        return [1, 5, 10];
      case 'gbp':
        return [1, 5, 10];
      case 'cad':
        return [1, 5, 10];
      case 'usd':
      default:
        return [1, 5, 10];
    }
  }

  String _shortSymbol(String code) {
    const symbols = {
      'usd': '\$', 'eur': '€', 'gbp': '£', 'cad': 'C\$',
      'mxn': '\$', 'ars': '\$', 'brl': 'R\$', 'ils': '₪',
      'clp': '\$', 'cop': '\$',
    };
    return symbols[code.toLowerCase()] ?? '\$';
  }

  String _formatPresetValue(double amount) {
    if (amount == amount.roundToDouble()) return amount.toInt().toString();
    return amount.toStringAsFixed(2);
  }

  String _formatQuickAmount(double amount) {
    final currency = _currencyCodeFromProfile();
    final symbol = _shortSymbol(currency);
    if (amount == amount.roundToDouble()) {
      return '$symbol${amount.toInt()}';
    }
    return '$symbol${amount.toStringAsFixed(2)}';
  }

  List<double> _buildQuickAmounts() {
    if (_presetAmounts.length == 3 && _presetAmounts.every((v) => v > 0)) {
      return _presetAmounts;
    }
    final currency = _currencyCodeFromProfile();
    return _presetsForCurrency(currency);
  }

  Future<void> _syncTzedakahSettings({
    required String uid,
    required double goal,
    required List<double> presets,
  }) async {
    try {
      await ref
          .read(userRepositoryProvider)
          .updateSettings(
            uid: uid,
            pushkaGoal: goal,
            presetAmounts: presets,
          )
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      if (!mounted) return;
      _showError(
        'Sin conexión estable. Guardamos localmente y se sincronizará al reconectar.',
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      if (e.code == 'unavailable') {
        _showError(
          'No hay conexión con Firestore. Revisa internet y vuelve a intentar.',
        );
      } else {
        _showError('No se pudo sincronizar la configuración. Intenta nuevamente.');
      }
    } catch (_) {
      if (!mounted) return;
      _showError('No se pudo sincronizar la configuración. Intenta nuevamente.');
    }
  }

  Future<void> _showTzedakahSettingsDialog() async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showError('Inicia sesión para continuar');
      return;
    }

    final goalOptions = <double>[36, 60, 90, 180, 360, 600, 900, 1200, 1800, 3600];
    if (!goalOptions.any((v) => (v - pushkaGoal).abs() < 0.001)) {
      goalOptions.add(pushkaGoal);
      goalOptions.sort();
    }

    final currency = _currencyCodeFromProfile();
    final defaults = _presetsForCurrency(currency);
    final currentPresets = (_presetAmounts.length == 3 && _presetAmounts.every((v) => v > 0))
        ? _presetAmounts
        : defaults;
    final symbol = _shortSymbol(currency);

    final ctrl1 = TextEditingController(text: _formatPresetValue(currentPresets[0]));
    final ctrl2 = TextEditingController(text: _formatPresetValue(currentPresets[1]));
    final ctrl3 = TextEditingController(text: _formatPresetValue(currentPresets[2]));

    double selectedGoal = pushkaGoal;
    bool isSaving = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          insetPadding: EdgeInsets.fromLTRB(
            16,
            20,
            16,
            MediaQuery.of(dialogContext).viewInsets.bottom + 14,
          ),
          contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 360,
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.82,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                const Center(
                  child: Text(
                    'Configuración de Tzedaká',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'META DE PUSHKA',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<double>(
                  initialValue: selectedGoal,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  isExpanded: true,
                  menuMaxHeight: 620,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  itemHeight: 52,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                  items: goalOptions.map((value) {
                    return DropdownMenuItem<double>(
                      value: value,
                      child: Text(
                        '\$${value.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    );
                  }).toList()
                    ..add(
                      const DropdownMenuItem<double>(
                        value: -1,
                        child: Text(
                          'OTRO',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  onChanged: (value) async {
                    if (value == null) return;
                    if (value == -1) {
                      final custom = await _showCustomGoalDialog();
                      if (custom != null) {
                        setDialogState(() => selectedGoal = custom);
                      }
                      return;
                    }
                    setDialogState(() => selectedGoal = value);
                  },
                ),
                const SizedBox(height: 18),
                Text(
                  'MONTOS PREDEFINIDOS',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Edita los montos que aparecen como botones rápidos',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [ctrl1, ctrl2, ctrl3].asMap().entries.map((entry) {
                    final idx = entry.key;
                    final ctrl = entry.value;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: idx < 2 ? 8 : 0),
                        child: TextField(
                          controller: ctrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Color(0xFF2F60C5),
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            prefixText: symbol,
                            prefixStyle: TextStyle(
                              fontSize: 15,
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.w600,
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(color: Colors.grey.shade300, width: 1.2),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(color: Colors.grey.shade300, width: 1.2),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(color: Color(0xFF2F60C5), width: 2),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE05A4F),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: isSaving
                        ? null
                        : () async {
                            final p1 = double.tryParse(ctrl1.text.replaceAll(',', '.')) ?? 0;
                            final p2 = double.tryParse(ctrl2.text.replaceAll(',', '.')) ?? 0;
                            final p3 = double.tryParse(ctrl3.text.replaceAll(',', '.')) ?? 0;
                            if (p1 <= 0 || p2 <= 0 || p3 <= 0) {
                              _showError('Todos los montos deben ser mayores a 0');
                              return;
                            }
                            final newPresets = [p1, p2, p3];
                            setDialogState(() => isSaving = true);
                            if (!mounted) return;
                            setState(() {
                              pushkaGoal = selectedGoal;
                              _presetAmounts = newPresets;
                            });
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop(true);
                            }
                            unawaited(
                              _syncTzedakahSettings(
                                uid: user.uid,
                                goal: selectedGoal,
                                presets: newPresets,
                              ),
                            );
                          },
                    child: isSaving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'GUARDAR',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE05A4F),
                      side: const BorderSide(color: Color(0xFFE05A4F), width: 2),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: isSaving
                        ? null
                        : () => Navigator.of(dialogContext).pop(false),
                    child: const Text(
                      'CANCELAR',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    ctrl1.dispose();
    ctrl2.dispose();
    ctrl3.dispose();

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuración aplicada')),
      );
    }
  }

  Future<double?> _showCustomGoalDialog() async {
    final controller = TextEditingController();
    String? error;
    final result = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
            child: SafeArea(top: false, child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                const Text('Meta personalizada', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: 'Ej: 4500', prefixText: '\$ ', errorText: error,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6)),
                  ),
                  onChanged: (_) { if (error != null) setSheetState(() => error = null); },
                ),
                const SizedBox(height: 16),
                SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: () {
                    final value = double.tryParse(controller.text.replaceAll(',', '.'));
                    if (value == null || value <= 0) { setSheetState(() => error = 'Ingresa un monto válido'); return; }
                    Navigator.pop(ctx, value);
                  },
                  child: const Text('Aceptar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                )),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, height: 44, child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                )),
              ]),
            )),
          ),
        ),
      ),
    );
    controller.dispose();
    return result;
  }
}

class _PartialDonationSheet extends StatefulWidget {
  const _PartialDonationSheet({required this.available});

  final double available;

  @override
  State<_PartialDonationSheet> createState() => _PartialDonationSheetState();
}

class _PartialDonationSheetState extends State<_PartialDonationSheet> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.available.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _amountFromPercent(int percent) {
    return double.parse(
      ((widget.available * percent) / 100).toStringAsFixed(2),
    );
  }

  int? _selectedPercent() {
    final current = double.tryParse(_controller.text.replaceAll(',', '.'));
    if (current == null) return null;
    for (final percent in const [25, 50, 75, 100]) {
      final target = _amountFromPercent(percent);
      if ((current - target).abs() < 0.01) return percent;
    }
    return null;
  }

  void _applyPercent(int percent) {
    setState(() {
      _controller.text = _amountFromPercent(percent).toStringAsFixed(2);
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
      _error = null;
    });
  }

  void _submit() {
    final parsed = double.tryParse(_controller.text.replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) {
      setState(() => _error = 'Ingresa un monto válido');
      return;
    }
    if (parsed > widget.available) {
      setState(() => _error = 'No puede ser mayor al saldo de tu Pushka');
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  'Donación parcial',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  'Disponible en Pushka: \$${widget.available.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  'Selecciona rápido',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _percentButton(25)),
                    const SizedBox(width: 8),
                    Expanded(child: _percentButton(50)),
                    const SizedBox(width: 8),
                    Expanded(child: _percentButton(75)),
                    const SizedBox(width: 8),
                    Expanded(child: _percentButton(100)),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.done,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Monto a donar ahora',
                    prefixText: '\$ ',
                    errorText: _error,
                    hintText: 'Ej: 5.00',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6),
                    ),
                  ),
                  onChanged: (_) {
                    if (_error != null) {
                      setState(() => _error = null);
                    }
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE05A4F),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _submit,
                    child: const Text(
                      'Donar',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Cancelar',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _percentButton(int percent) {
    final isSelected = _selectedPercent() == percent;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _applyPercent(percent),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFE05A4F).withValues(alpha: 0.12)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFFE05A4F) : Colors.grey.shade300,
            width: isSelected ? 1.8 : 1.2,
          ),
        ),
        child: Text(
          '$percent%',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: isSelected ? const Color(0xFFE05A4F) : const Color(0xFF2A2A2A),
          ),
        ),
      ),
    );
  }
}
