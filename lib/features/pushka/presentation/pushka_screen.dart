import 'dart:async';
import 'dart:math' as math;
import '../../../core/format_utils.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../core/keyboard_safe_sheet.dart';
import 'pushka_3d_widget.dart';

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
import '../../feedback/feedback_service.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../../config/stripe_config.dart';

class PushkaScreen extends ConsumerStatefulWidget {
  const PushkaScreen({super.key});

  @override
  ConsumerState<PushkaScreen> createState() => _PushkaScreenState();
}

class _PushkaScreenState extends ConsumerState<PushkaScreen> {
  final _pushkaKey = GlobalKey<Pushka3DWidgetState>();
  double pushkaAmount = 0;
  double pushkaGoal = 3600.00; // Meta de la pushka
  List<double> _presetAmounts = [];
  bool _loadedRemote = false;
  bool _isProcessing = false;
  int _streakCount = 0;
  bool _showCelebration = false;


  void _triggerCelebration() {
    setState(() => _showCelebration = true);
    FeedbackService.instance.playSuccess();
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showCelebration = false);
    });
  }

  Future<void> _updateStreak() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    final profile = ref.read(userProfileProvider).valueOrNull;
    if (profile == null) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastDateRaw = profile['lastStreakDate'];
    DateTime? lastDate;
    if (lastDateRaw is Timestamp) {
      lastDate = lastDateRaw.toDate();
    }

    if (lastDate != null) {
      final lastDay = DateTime(lastDate.year, lastDate.month, lastDate.day);
      if (lastDay == today) return;

      DateTime prevWeekday = today.subtract(const Duration(days: 1));
      while (prevWeekday.weekday == DateTime.saturday || prevWeekday.weekday == DateTime.sunday) {
        prevWeekday = prevWeekday.subtract(const Duration(days: 1));
      }

      if (lastDay == prevWeekday || lastDay.isAfter(prevWeekday)) {
        _streakCount = (_streakCount > 0 ? _streakCount : 1) + 1;
      } else {
        _streakCount = 1;
      }
    } else {
      _streakCount = 1;
    }

    if (mounted) setState(() {});
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'streakCount': _streakCount,
        'lastStreakDate': Timestamp.fromDate(today),
      });
    } catch (_) {}
  }
  Future<void> addAmount(double amount) async {
    final wasFull = pushkaGoal > 0 && pushkaAmount >= pushkaGoal;
    setState(() => pushkaAmount += amount);
    final nowFull = pushkaGoal > 0 && pushkaAmount >= pushkaGoal;
    if (!wasFull && nowFull) _triggerCelebration();
    _pushkaKey.currentState?.triggerCoinDrop();
    FeedbackService.instance.playCoinDrop();
    await _persistPushkaAmount();
    _updateStreak();
  }
  
  Future<void> emptyPushka() async {
    if (pushkaAmount <= 0 || _isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      if (StripeConfig.publishableKey.isEmpty) {
        throw Exception('Stripe no está configurado');
      }

      final amountToEmpty = pushkaAmount;
      final currency = _currencyCodeFromProfile();
      final amountCents = ((amountToEmpty * 100) + 0.001).round();
      final minCents = _minAmountCentsForCurrency(currency);

      if (amountCents < minCents) {
        if (!mounted) return;
        _showMinAmountDialog(currency, minCents, amountToEmpty);
        return;
      }

      if (_biometricEnabled()) {
        final authenticated = await BiometricService.instance.authenticate(
          reason: 'Confirma tu identidad para vaciar la Pushka',
        );
        if (!authenticated) {
          _showError('Autenticación requerida para vaciar la Pushka');
          return;
        }
      }

      final paymentIntentId = await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: ref.read(currentUserProvider)?.email,
        purpose: 'pushka_empty',
      );

      await AnalyticsService.instance.logPushkaEmpty(amountToEmpty);

      final user = ref.read(currentUserProvider);
      if (user != null) {
        await ref.read(transactionRepositoryProvider).addTransaction(
          uid: user.uid,
          type: TransactionType.pushkaEmpty,
          amount: amountToEmpty,
          description: 'Pushka vaciada - pago con tarjeta',
          paymentMethod: PaymentMethod.card,
          status: PaymentStatus.completed,
          docId: paymentIntentId,
        );
      }

      await _persistPushkaAmount(resetToZero: true);
      if (!mounted) return;
      setState(() => pushkaAmount = 0);
      FeedbackService.instance.playSuccess();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pushka vaciada. El pago fue procesado.')),
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
    if (_isProcessing) return;
    final amountCtrl = TextEditingController();
    final messageCtrl = TextEditingController();
    Map<String, dynamic>? result;
    String? error;
    result = await showKeyboardSafeSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      const Center(child: Text('Donar Ahora', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
                      const SizedBox(height: 16),
                      TextField(
                        controller: amountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: 'Monto', hintText: '0', prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: messageCtrl,
                        decoration: InputDecoration(
                          labelText: 'Mensaje personal (opcional)',
                          hintText: 'Escribe un mensaje...',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('Donaci\u00f3n instant\u00e1nea. No reduce ni afecta el balance de tu Pushka.', style: TextStyle(color: Color(0xFF888888), fontSize: 12), textAlign: TextAlign.center),
                      const SizedBox(height: 14),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(amountCtrl.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = 'Ingresa un monto v\u00e1lido'); return; }
                          Navigator.pop(ctx, {'amount': value, 'message': messageCtrl.text.trim()});
                        },
                        child: const Text('DONAR AHORA', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      )),
                    ]),
    );
    if (result == null || !mounted) return;
    final donationAmount = result['amount'] as double;

    setState(() => _isProcessing = true);
    try {
      if (_biometricEnabled()) {
        final authenticated = await BiometricService.instance.authenticate(
          reason: 'Confirma tu identidad para procesar la donaci\u00f3n',
        );
        if (!authenticated) {
          _showError('Autenticaci\u00f3n requerida para donar');
          return;
        }
      }
      if (!mounted) return;

      if (StripeConfig.publishableKey.isEmpty) {
        throw Exception('Stripe no est\u00e1 configurado');
      }

      final currency = _currencyCodeFromProfile();
      final amountCents = ((donationAmount * 100) + 0.001).round();
      final minCents = _minAmountCentsForCurrency(currency);
      if (amountCents < minCents) {
        if (!mounted) return;
        _showMinAmountDialog(currency, minCents, donationAmount);
        return;
      }

      final paymentIntentId = await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: ref.read(currentUserProvider)?.email,
        purpose: 'donation',
      );

      await AnalyticsService.instance.logDonation(donationAmount, currency);

      final user = ref.read(currentUserProvider);
      if (user != null) {
        await ref.read(transactionRepositoryProvider).addTransaction(
          uid: user.uid,
          type: TransactionType.tzedaka,
          amount: donationAmount,
          description: result['message']?.toString().isNotEmpty == true
              ? result['message'] as String
              : 'Donaci\u00f3n instant\u00e1nea',
          paymentMethod: PaymentMethod.card,
          status: PaymentStatus.completed,
          docId: paymentIntentId,
        );
      }

      FeedbackService.instance.playSuccess();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Donaci\u00f3n de ${formatMoney(donationAmount)} procesada exitosamente')),
        );
      }
    } catch (error) {
      debugPrint('Instant donation error: $error');
      if (!mounted) return;
      _showError(_donationErrorMessage(error));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _processCardPayment(double donationAmount) async {
    if (!mounted) return;
    setState(() => _isProcessing = true);
    try {
      if (StripeConfig.publishableKey.isEmpty) {
        throw Exception('Stripe no está configurado');
      }

      final amountCents = ((donationAmount * 100) + 0.001).round();
      final currency = _currencyCodeFromProfile();
      final minCents = _minAmountCentsForCurrency(currency);
      if (amountCents < minCents) {
        if (!mounted) return;
        _showMinAmountDialog(currency, minCents, donationAmount);
        return;
      }
      final paymentIntentId = await StripeService.instance.pay(
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
          docId: paymentIntentId,
        );
      }

      FeedbackService.instance.playSuccess();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              remaining > 0
                  ? 'Pago procesado. Quedaron ${formatMoney(remaining)} en la Pushka.'
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

    if (!mounted) return;
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
              'Donación de ${formatMoney(amount)} registrada como pendiente. '
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

  Future<void> _processDirectDonation(double amount) async {
    if (amount <= 0 || _isProcessing) return;

    if (_biometricEnabled()) {
      final authenticated = await BiometricService.instance.authenticate(
        reason: 'Confirma tu identidad para procesar la donaci\u00f3n',
      );
      if (!authenticated) {
        _showError('Autenticaci\u00f3n requerida para donar');
        return;
      }
    }
    if (!mounted) return;

    if (_additionalPaymentOptionsEnabled()) {
      final method = await _showPaymentMethodSelector();
      if (method == null || !mounted) return;
      if (method == PaymentMethod.card) {
        await _processCardPayment(amount);
      } else {
        await _processAlternativePayment(amount, method);
      }
    } else {
      await _processCardPayment(amount);
    }
  }
    double get fillPercentage {
    if (pushkaGoal <= 0) return 0;
    final percentage = (pushkaAmount / pushkaGoal).clamp(0.0, 1.0);
    return percentage;
  }

  @override
  Widget build(BuildContext context) {


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
            try {
              _presetAmounts = remotePresets.whereType<num>().map((e) => e.toDouble()).toList();
              if (_presetAmounts.length != 3) _presetAmounts = [];
            } catch (_) {
              _presetAmounts = [];
            }
          }
          _loadedRemote = true;
          _streakCount = (userProfile['streakCount'] as int?) ?? 0;
          FeedbackService.instance.updatePreferences(
            sound: (userProfile['soundEnabled'] as bool?) ?? true,
            coinJingle: (userProfile['coinJingleEnabled'] as bool?) ?? true,
            vibration: (userProfile['vibrationEnabled'] as bool?) ?? true,
          );
        });
      });
    }

    final quickAmounts = _buildQuickAmounts();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxHeight < 560;
            final availableForImage = constraints.maxHeight - 260;
            final imageHeight = availableForImage.clamp(220.0, 440.0);
            final topGap = isCompact ? 4.0 : 8.0;
            final titleSize = isCompact ? 20.0 : 24.0;
            final subtitleSize = isCompact ? 14.0 : 16.0;
            final titleBottomGap = isCompact ? 6.0 : 10.0;
            final actionsTopGap = isCompact ? 6.0 : 10.0;

                        final activeHoliday = _HolidayInfo.getActiveHoliday();
            final bool isFull = pushkaGoal > 0 && pushkaAmount >= pushkaGoal;

            final content = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            Center(child: _buildStreakBanner(AppTokens.cardSilver, AppTokens.primaryBlue)),
            if (activeHoliday != null) Center(child: _buildHolidayBanner(activeHoliday)),

            SizedBox(height: topGap),

            if (isFull) ...[
              Text(
                "Tu Pushka est\u00e1 llena",
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w700,
                  color: AppTokens.primaryBlue,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                "\u00a1Alcanzaste tu Meta de Donaci\u00f3n!",
                style: TextStyle(color: AppTokens.mutedText, fontSize: subtitleSize),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: titleBottomGap),

              RepaintBoundary(
                child: SizedBox(
                  height: imageHeight,
                  child: Pushka3DWidget(
                    key: _pushkaKey,
                    fillPercentage: fillPercentage,
                    goal: pushkaGoal,
                    amount: pushkaAmount,
                    currencySymbol: _currencySymbol(_currencyCodeFromProfile()),
                  ),
                ),
              ),

              SizedBox(height: actionsTopGap),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: emptyPushka,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTokens.primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('VACIAR PUSHKA', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _showTzedakahSettingsDialog,
                child: Text(
                  'CAMBIAR META DE PUSHKA',
                  style: TextStyle(color: AppTokens.primaryBlue, fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ] else ...[
              Text(
                "\u00a1Ll\u00e9nala!",
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w700,
                  color: AppTokens.primaryBlue,
                ),
              ),
              SizedBox(height: titleBottomGap),

              RepaintBoundary(
                child: SizedBox(
                  height: imageHeight,
                  child: Pushka3DWidget(
                    key: _pushkaKey,
                    fillPercentage: fillPercentage,
                    goal: pushkaGoal,
                    amount: pushkaAmount,
                    currencySymbol: _currencySymbol(_currencyCodeFromProfile()),
                  ),
                ),
              ),

              SizedBox(height: actionsTopGap),

              Row(
                children: [
                  _moneyBtn(
                    _formatQuickAmount(quickAmounts[0]),
                    AppTokens.primaryBlue,
                    () => addAmount(quickAmounts[0]),
                  ),
                  const SizedBox(width: 10),
                  _moneyBtn(
                    _formatQuickAmount(quickAmounts[1]),
                    AppTokens.primaryBlue,
                    () => addAmount(quickAmounts[1]),
                  ),
                  const SizedBox(width: 10),
                  _moneyBtn(
                    _formatQuickAmount(quickAmounts[2]),
                    AppTokens.primaryBlue,
                    () => addAmount(quickAmounts[2]),
                  ),
                  const SizedBox(width: 10),
                  _moneyBtn('OTRO', AppTokens.primaryBlue, _otherAmount),
                ],
              ),

              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _donateNow,
                    child: const Text(
                      'DONAR AHORA',
                      style: TextStyle(color: AppTokens.primaryBlue, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(
                    onPressed: emptyPushka,
                    child: const Text(
                      'VACIAR PUSHKA',
                      style: TextStyle(color: AppTokens.primaryBlue, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings, color: Colors.grey),
                    onPressed: _showTzedakahSettingsDialog,
                  ),
                ],
              ),
            ],
              ],
            );
            return Stack(
              children: [
                SingleChildScrollView(child: content),
                if (_showCelebration) const Positioned.fill(
                  child: IgnorePointer(child: _CelebrationOverlay()),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildStreakBanner(Color bgColor, Color brandBlue) {
    if (_streakCount <= 0) return const SizedBox.shrink();

    final colors = _streakColors(_streakCount);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            margin: const EdgeInsets.only(left: 18),
            padding: const EdgeInsets.fromLTRB(28, 8, 16, 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [colors.$1, colors.$2],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(20),
                bottomRight: Radius.circular(20),
                topLeft: Radius.circular(4),
                bottomLeft: Radius.circular(4),
              ),
              boxShadow: [
                BoxShadow(
                  color: colors.$2.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Racha de D\u00edas',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    shadows: [
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.local_fire_department, color: Colors.white, size: 16),
              ],
            ),
          ),
          Positioned(
            left: 0,
            top: -2,
            child: _HexBadge(count: _streakCount, color1: colors.$1, color2: colors.$2),
          ),
        ],
      ),
    );
  }

  (Color, Color) _streakColors(int count) {
    final day = ((count - 1) % 7) + 1;
    return switch (day) {
      1 => (const Color(0xFFFFD54F), const Color(0xFFFFC107)),
      2 => (const Color(0xFFFF7043), const Color(0xFFE53935)),
      3 => (const Color(0xFF42A5F5), const Color(0xFF1E88E5)),
      4 => (const Color(0xFF66BB6A), const Color(0xFF43A047)),
      5 => (const Color(0xFFAB47BC), const Color(0xFF8E24AA)),
      6 => (const Color(0xFF26C6DA), const Color(0xFF00ACC1)),
      _ => (const Color(0xFF5C6BC0), const Color(0xFF3949AB)),
    };
  }
  String _holidayEmoji(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('pesaj') || lower.contains('jitim') || lower.contains('ma\u0027ot')) return '\uD83E\uDED3\uD83E\uDED3';
    if (lower.contains('shavuot')) return '\uD83C\uDF3E';
    if (lower.contains('rosh')) return '\uD83C\uDF4E\uD83C\uDF6F';
    if (lower.contains('kipur')) return '\uD83D\uDD4A\uFE0F';
    if (lower.contains('sucot')) return '\uD83C\uDF34';
    if (lower.contains('januc')) return '\uD83D\uDD6F\uFE0F';
    if (lower.contains('purim')) return '\uD83C\uDF89';
    return '\u2728';
  }

  Widget _buildHolidayBanner(_HolidayInfo holiday) {
    final emoji = _holidayEmoji(holiday.nameEs);
    return GestureDetector(
      onTap: () { if (_isProcessing) return; _showHolidayDonationDialog(holiday); },
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFE8912D), Color(0xFFD4790A)],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFE8912D).withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                holiday.nameEs,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Colors.white, size: 18),
          ],
        ),
      ),
    );
  }
  Future<void> _showHolidayDonationDialog(_HolidayInfo holiday) async {
    final amountCtrl = TextEditingController();
    Map<String, dynamic>? result;
    double? selectedPreset;
    result = await showKeyboardSafeSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx, setDialogState) {
            double currentAmount() {
              if (selectedPreset != null) return selectedPreset!;
              final parsed = double.tryParse(amountCtrl.text.trim().replaceAll(',', '.'));
              return parsed ?? 0;
            }
            return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 8), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                        Text(
                          holiday.nameEs,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFFE8912D)),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          holiday.descriptionEs,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppTokens.mutedText, fontSize: 14),
                        ),
                        const SizedBox(height: 18),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('Elige un monto', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: holiday.presetAmounts.map((amt) {
                            final isSelected = selectedPreset == amt;
                            return OutlinedButton(
                              onPressed: () {
                                setDialogState(() {
                                  selectedPreset = isSelected ? null : amt;
                                  if (!isSelected) amountCtrl.clear();
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                backgroundColor: isSelected ? const Color(0xFFE8912D) : null,
                                foregroundColor: isSelected ? Colors.white : const Color(0xFFE8912D),
                                side: const BorderSide(color: Color(0xFFE8912D), width: 2),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text('${_shortSymbol(_currencyCodeFromProfile())}${amt.toInt()}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 16),
                        GestureDetector(
                          onTap: () => setDialogState(() => selectedPreset = null),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: amountCtrl,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      hintText: '0',
                                      hintStyle: TextStyle(color: Colors.grey),
                                    ),
                                    onChanged: (_) => setDialogState(() => selectedPreset = null),
                                  ),
                                ),
                                const Icon(Icons.edit, color: Colors.grey, size: 18),
                              ],
                            ),
                          ),
                        ),
                        const Text('Toca para editar el monto', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              final amt = currentAmount();
                              if (amt > 0) Navigator.pop(ctx, {'action': 'donate', 'amount': amt});
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTokens.primaryBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('DONAR AHORA', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () {
                              final amt = currentAmount();
                              if (amt > 0) Navigator.pop(ctx, {'action': 'pushka', 'amount': amt});
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTokens.primaryBlue,
                              side: const BorderSide(color: AppTokens.primaryBlue, width: 2),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('AGREGAR A PUSHKA', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          ),
                        ),
                      ],
                    );
      },
    );

    if (result == null || !mounted) return;
    final amount = result['amount'] as double;
    if (result['action'] == 'pushka') {
      await addAmount(amount);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${formatMoney(amount)} agregado a tu Pushka')),
        );
      }
    } else {
      await _processDirectDonation(amount);
    }
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
    double? result;
    result = await showKeyboardSafeSheet<double>(
      context: context,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      const Text('Otro monto', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 14),
                      TextField(
                        controller: controller,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value != null && value > 0) Navigator.pop(ctx, value);
                        },
                        decoration: InputDecoration(
                          hintText: 'Ej: 12.50', prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      const SizedBox(height: 16),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = 'Ingresa un monto v\u00e1lido'); return; }
                          Navigator.pop(ctx, value);
                        },
                        child: const Text('Agregar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      SizedBox(width: double.infinity, height: 44, child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                      )),
                    ]),
    );

    if (!mounted || result == null) return;
    await addAmount(result);
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
    if (!mounted) return;
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
                  backgroundColor: AppTokens.primaryBlue,
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
            decoration: BoxDecoration(color: AppTokens.primaryBlue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: AppTokens.primaryBlue, size: 22),
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
            'Envía un cheque por el monto de ${formatMoney(amount)} a:\n\n'
            'Nombre: [Nombre de la Organización]\n'
            'Dirección: [Dirección postal]\n'
            'Ciudad, Estado, ZIP: [Ciudad, ST 00000]\n\n'
            'Referencia: Incluye tu email o ID de usuario en el memo del cheque.\n\n'
            'Una vez recibido y procesado, la donación se marcará como confirmada en tu historial.';
      case PaymentMethod.transfer:
        title = 'Transferencia Bancaria';
        icon = Icons.account_balance;
        instructionText =
            'Transfiere ${formatMoney(amount)} a la siguiente cuenta:\n\n'
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
            'Realiza una donación de ${formatMoney(amount)} desde tu DAF a:\n\n'
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
                  Icon(icon, size: 40, color: AppTokens.primaryBlue),
                  const SizedBox(height: 10),
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(color: AppTokens.primaryBlue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                    child: Text(formatMoney(amount), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTokens.primaryBlue)),
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
                    style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
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
      _showError('Inicia sesi\u00f3n para continuar');
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

    double selectedGoal = pushkaGoal;
    bool isSaving = false;

    final ctrl1 = TextEditingController(text: _formatPresetValue(currentPresets[0]));
    final ctrl2 = TextEditingController(text: _formatPresetValue(currentPresets[1]));
    final ctrl3 = TextEditingController(text: _formatPresetValue(currentPresets[2]));
    bool? saved;
    saved = await showKeyboardSafeSheet<bool>(
      context: context,
      builder: (ctx, setDialogState) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                  const Center(
                    child: Text(
                      'Configuraci\u00f3n de Tzedak\u00e1',
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
                    initialValue: goalOptions.contains(selectedGoal) ? selectedGoal : null,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    isExpanded: true,
                    menuMaxHeight: 620,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    itemHeight: 52,
                    decoration: InputDecoration(
                      hintText: formatMoney(selectedGoal),
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
                          formatMoney(value),
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
                        if (custom != null && ctx.mounted) {
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
                    'Edita los montos que aparecen como botones r\u00e1pidos',
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
                        backgroundColor: AppTokens.primaryBlue,
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
                              if (ctx.mounted) {
                                Navigator.of(ctx).pop(true);
                              }
                              if (!mounted) return;
                              setState(() {
                                pushkaGoal = selectedGoal;
                                _presetAmounts = newPresets;
                              });
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
                        foregroundColor: AppTokens.primaryBlue,
                        side: const BorderSide(color: AppTokens.primaryBlue, width: 2),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: isSaving
                          ? null
                          : () => Navigator.of(ctx).pop(false),
                      child: const Text(
                        'CANCELAR',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                      ],
                    ),
    );

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuraci\u00f3n aplicada')),
      );
    }
  }

  Future<double?> _showCustomGoalDialog() async {
    final controller = TextEditingController();
    String? error;
    double? result;
    result = await showKeyboardSafeSheet<double>(
      context: context,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      const Text('Meta personalizada', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 14),
                      TextField(
                        controller: controller,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value != null && value > 0) Navigator.pop(ctx, value);
                        },
                        decoration: InputDecoration(
                          hintText: 'Ej: 4500', prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      const SizedBox(height: 16),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = 'Ingresa un monto v\u00e1lido'); return; }
                          Navigator.pop(ctx, value);
                        },
                        child: const Text('Aceptar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      SizedBox(width: double.infinity, height: 44, child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                      )),
                    ]),
    );
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
    return Container(
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
                  'Disponible en Pushka: ${formatMoney(widget.available)}',
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
                      borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6),
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
                      backgroundColor: AppTokens.primaryBlue,
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
              ? AppTokens.primaryBlue.withValues(alpha: 0.12)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppTokens.primaryBlue : Colors.grey.shade300,
            width: isSelected ? 1.8 : 1.2,
          ),
        ),
        child: Text(
          '$percent%',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: isSelected ? AppTokens.primaryBlue : AppTokens.textPrimary,
          ),
        ),
      ),
    );
  }
}


class _HolidayInfo {
  final String nameEs;
  final String descriptionEs;
  final List<double> presetAmounts;
  final DateTime startDate;
  final int showDaysBefore;
  final int durationDays;
  final String? iconAsset;

  const _HolidayInfo({
    required this.nameEs,
    required this.descriptionEs,
    required this.presetAmounts,
    required this.startDate,
    required this.showDaysBefore,
    this.durationDays = 1,
    this.iconAsset,
  });

  bool get isActive {
    final now = DateTime.now();
    final showFrom = startDate.subtract(Duration(days: showDaysBefore));
    final hideAfter = startDate.add(Duration(days: durationDays));
    return now.isAfter(showFrom) && now.isBefore(hideAfter);
  }

  static _HolidayInfo? getActiveHoliday() {
    for (final h in _holidays) {
      if (h.isActive) return h;
    }
    return null;
  }

  static final List<_HolidayInfo> _holidays = [
    // 5786 (2025-2026)
    _HolidayInfo(
      nameEs: 'Ma\u0027ot Jitim',
      descriptionEs: 'Fondos para los necesitados de Israel para sus necesidades de P\u00e9saj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2026, 4, 2),
      showDaysBefore: 30,
      durationDays: 8,
    ),
    _HolidayInfo(
      nameEs: 'Shavuot',
      descriptionEs: 'Celebramos la entrega de la Tor\u00e1. Dona tzedak\u00e1 en honor a esta festividad',
      presetAmounts: [18, 36, 180],
      startDate: DateTime(2026, 5, 22),
      showDaysBefore: 21,
      durationDays: 2,
    ),
    // 5787 (2026-2027)
    _HolidayInfo(
      nameEs: 'Rosh Hashan\u00e1',
      descriptionEs: 'A\u00f1o Nuevo jud\u00edo. Comienza el a\u00f1o con tzedak\u00e1 y buenas acciones',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2026, 9, 12),
      showDaysBefore: 30,
      durationDays: 2,
    ),
    _HolidayInfo(
      nameEs: 'Yom Kippur',
      descriptionEs: 'D\u00eda de la Expiaci\u00f3n. La tzedak\u00e1 es un m\u00e9rito especial antes de Yom Kippur',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2026, 9, 21),
      showDaysBefore: 14,
    ),
    _HolidayInfo(
      nameEs: 'Sucot',
      descriptionEs: 'Fiesta de las Caba\u00f1as. Comparte alegr\u00eda con quienes m\u00e1s lo necesitan',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2026, 9, 26),
      showDaysBefore: 14,
      durationDays: 7,
    ),
    _HolidayInfo(
      nameEs: 'Januc\u00e1',
      descriptionEs: 'Festival de las Luces. Ilumina vidas con tu donaci\u00f3n de tzedak\u00e1',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2026, 12, 5),
      showDaysBefore: 21,
      durationDays: 8,
    ),
    _HolidayInfo(
      nameEs: 'Purim',
      descriptionEs: "Matanot la'Evionim: regalos a los necesitados, una mitzv\u00e1 central de Purim",
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2027, 3, 23),
      showDaysBefore: 21,
    ),
    _HolidayInfo(
      nameEs: 'Ma\u0027ot Jitim',
      descriptionEs: 'Fondos para los necesitados de Israel para sus necesidades de P\u00e9saj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2027, 4, 22),
      showDaysBefore: 30,
      durationDays: 8,
    ),
  ];
}
class _CelebrationOverlay extends StatefulWidget {
  const _CelebrationOverlay();

  @override
  State<_CelebrationOverlay> createState() => _CelebrationOverlayState();
}

class _CelebrationOverlayState extends State<_CelebrationOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return CustomPaint(
          painter: _ConfettiPainter(progress: _ctrl.value),
        );
      },
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final double progress;
  _ConfettiPainter({required this.progress});

  static const _colors = [
    Color(0xFFFFD700), Color(0xFFFF6B35), Color(0xFF2563EB),
    Color(0xFF60A5FA), Color(0xFF10B981), Color(0xFFE040FB),
    Color(0xFFFF1744), Color(0xFF00E5FF), Color(0xFFFFC107),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rng = _SeededRandom(77);
    const count = 120;
    final fadeOut = progress > 0.65 ? (1.0 - (progress - 0.65) / 0.35) : 1.0;

    for (int i = 0; i < count; i++) {
      final startX = rng.next() * size.width;
      final startY = -30.0 - rng.next() * 120;
      final speed = 0.3 + rng.next() * 0.7;
      final drift = (rng.next() - 0.5) * 160;
      final wobble = (rng.next() - 0.5) * 40 * (0.5 + 0.5 * rng.next());
      final pSize = 3.0 + rng.next() * 10.0;
      final delay = rng.next() * 0.2;
      final p = ((progress - delay) / (1.0 - delay)).clamp(0.0, 1.0);

      final x = startX + drift * p + wobble * (p * 3.14).clamp(0.0, 3.14);
      final y = startY + size.height * 1.2 * p * speed;

      if (y < -30 || y > size.height + 30 || p <= 0) continue;

      final paint = Paint()
        ..color = _colors[i % _colors.length].withValues(alpha: fadeOut * 0.9)
        ..style = PaintingStyle.fill;

      final shape = i % 4;
      if (shape == 0) {
        canvas.drawCircle(Offset(x, y), pSize / 2, paint);
      } else if (shape == 1) {
        canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: pSize, height: pSize * 0.5), paint);
      } else if (shape == 2) {
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(p * 8.0 * (0.5 + rng.next()));
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: pSize * 1.3, height: pSize * 0.3), paint);
        canvas.restore();
      } else {
        final path = Path()
          ..moveTo(x, y - pSize * 0.5)
          ..lineTo(x + pSize * 0.4, y + pSize * 0.3)
          ..lineTo(x - pSize * 0.4, y + pSize * 0.3)
          ..close();
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.progress != progress;
}

class _SeededRandom {
  int _state;
  _SeededRandom(this._state);
  double next() {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state / 0x7fffffff;
  }
}

class _HexBadge extends StatelessWidget {
  const _HexBadge({required this.count, required this.color1, required this.color2});
  final int count;
  final Color color1;
  final Color color2;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: CustomPaint(
        painter: _HexPainter(color1: color1, color2: color2),
        child: Center(
          child: Text(
            '$count',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _HexPainter extends CustomPainter {
  final Color color1;
  final Color color2;
  _HexPainter({required this.color1, required this.color2});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;
    final r = w * 0.48;

    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (i * 60 - 90) * math.pi / 180;
      final x = cx + r * math.cos(angle);
      final y = cy + r * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    canvas.drawPath(
      path.shift(const Offset(0, 2)),
      Paint()
        ..color = color2.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color1, color2],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(path, paint);

    final highlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(path, highlightPaint);
  }

  @override
  bool shouldRepaint(covariant _HexPainter old) =>
      old.color1 != color1 || old.color2 != color2;
}


