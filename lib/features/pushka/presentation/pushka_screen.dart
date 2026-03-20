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
  double _presetAmount = 1.00;
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
      setState(() => pushkaAmount = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pushka vaciada')),
      );
    } catch (_) {
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
      if (method == null) return;
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
        final minLabel = _formatAmountFromCents(minCents);
        _showError('Monto mínimo para ${currency.toUpperCase()} es $minLabel');
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
      _showError('No se pudo registrar la donación');
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
    final remotePreset = userProfile?['presetAmount'];

    if (!_loadedRemote && userProfile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          if (remoteGoal is num) pushkaGoal = remoteGoal.toDouble();
          if (remoteAmount is num) pushkaAmount = remoteAmount.toDouble();
          if (remotePreset is num) _presetAmount = remotePreset.toDouble();
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
                                      lightBlue.withOpacity(0.6),
                                      lightBlue.withOpacity(0.3),
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
                  '\$${quickAmounts[0].toStringAsFixed(2)}',
                  red,
                  () => addAmount(quickAmounts[0]),
                ),
                const SizedBox(width: 10),
                _moneyBtn(
                  '\$${quickAmounts[1].toStringAsFixed(2)}',
                  red,
                  () => addAmount(quickAmounts[1]),
                ),
                const SizedBox(width: 10),
                _moneyBtn(
                  '\$${quickAmounts[2].toStringAsFixed(2)}',
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

  String _donationErrorMessage(Object error) {
    if (error is FirebaseFunctionsException) {
      final msg = error.message ?? error.code;
      return 'Error de pago: $msg';
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
    return showModalBottomSheet<PaymentMethod>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
              const Text('Método de pago', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('Selecciona cómo deseas realizar tu donación', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
              const SizedBox(height: 18),
              _paymentMethodTile(ctx, PaymentMethod.card, Icons.credit_card, 'Tarjeta de crédito/débito', 'Pago inmediato vía Stripe'),
              const SizedBox(height: 10),
              _paymentMethodTile(ctx, PaymentMethod.check, Icons.mail_outline, 'Cheque', 'Envía un cheque por correo'),
              const SizedBox(height: 10),
              _paymentMethodTile(ctx, PaymentMethod.transfer, Icons.account_balance, 'Transferencia bancaria', 'Transferencia o wire'),
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
      case 'mxn':
        return 1000; // 10.00 MXN
      case 'usd':
      case 'eur':
      case 'gbp':
      default:
        return 50; // 0.50 in minor units
    }
  }

  String _formatAmountFromCents(int cents) {
    final value = cents / 100;
    return value.toStringAsFixed(2);
  }

  List<double> _buildQuickAmounts() {
    final base = _presetAmount > 0 ? _presetAmount : 1.0;
    const candidates = <double>[1, 5, 10, 18, 36, 50];
    final values = <double>[base];
    for (final candidate in candidates) {
      final exists = values.any((v) => (v - candidate).abs() < 0.001);
      if (!exists) values.add(candidate);
      if (values.length == 3) break;
    }
    while (values.length < 3) {
      values.add(1);
    }
    return values;
  }

  Future<void> _syncTzedakahSettings({
    required String uid,
    required double goal,
    required double preset,
  }) async {
    try {
      await ref
          .read(userRepositoryProvider)
          .updateSettings(
            uid: uid,
            pushkaGoal: goal,
            presetAmount: preset,
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

    double selectedGoal = pushkaGoal;
    double selectedPreset = _presetAmount > 0 ? _presetAmount : 1.0;
    bool isSaving = false;
    const presetOptions = <double>[1, 5, 10];

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
                  value: selectedGoal,
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
                const SizedBox(height: 10),
                Row(
                  children: presetOptions.map((value) {
                    final isPrimary = (selectedPreset - value).abs() < 0.001;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: value == presetOptions.last ? 0 : 8,
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setDialogState(() => selectedPreset = value),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: isPrimary
                                      ? const Color(0xFF2F60C5).withOpacity(0.06)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isPrimary
                                        ? const Color(0xFF2F60C5)
                                        : Colors.grey.shade300,
                                    width: isPrimary ? 2 : 1.2,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '\$${value.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Color(0xFF2F60C5),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (isPrimary)
                                Positioned(
                                  top: -9,
                                  left: 10,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2F60C5),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'Principal',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
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
                            setDialogState(() => isSaving = true);
                            if (!mounted) return;
                            setState(() {
                              pushkaGoal = selectedGoal;
                              _presetAmount = selectedPreset;
                            });
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop(true);
                            }
                            unawaited(
                              _syncTzedakahSettings(
                                uid: user.uid,
                                goal: selectedGoal,
                                preset: selectedPreset,
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

    if (saved == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuración aplicada')),
      );
    }
  }

  Future<double?> _showCustomGoalDialog() async {
    final controller = TextEditingController();
    String? error;
    return showModalBottomSheet<double>(
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
