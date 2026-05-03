import 'dart:async';
import '../../../core/hive_cache.dart';
import 'jewish_confetti.dart';
import '../../../core/format_utils.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../core/keyboard_safe_sheet.dart';
import 'pushka_3d_widget.dart';
import 'building_770_widget.dart';
import 'bill_fall_animation.dart';
import '../../../core/pushka_style_provider.dart';
import '../../../core/l10n/s.dart';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../analytics/analytics_service.dart';
import '../../auth/biometric_service.dart';
import '../../history/data/transaction_repository.dart';
import '../../history/domain/transaction.dart';
import '../../payments/stripe_service.dart';
import '../../feedback/feedback_service.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../../config/stripe_config.dart';

class PushkaScreen extends ConsumerStatefulWidget {
  const PushkaScreen({super.key});

  @override
  ConsumerState<PushkaScreen> createState() => _PushkaScreenState();
}

class _PushkaScreenState extends ConsumerState<PushkaScreen>
    with SingleTickerProviderStateMixin {
  final _pushkaKey = GlobalKey<Pushka3DWidgetState>();
  final _fillItTitleKey = GlobalKey();
  final _stackKey = GlobalKey();
  final _confettiController = JewishConfettiController();
  bool _showBill = false;
  int _billKey = 0;
  double _billStartY = -90.0;
  double pushkaAmount = 0;
  double pushkaGoal = UserRepository.defaultGoalForCurrency('USD');
  List<double> _presetAmounts = [];
  bool _loadedRemote = false;
  bool _isProcessing = false;
  int _streakCount = 0;
  // Wall-clock-independent monotonic timer for the "recent local write"
  // window. Using DateTime.now() makes a system clock change (manual or NTP)
  // mis-classify a stale snapshot as recent (or vice versa).
  final Stopwatch _localWriteStopwatch = Stopwatch();
  // Identity of the last tenantState snapshot we synced to local state.
  // Lets us short-circuit the rebuild→sync→setState→rebuild loop that
  // happens when addPostFrameCallback runs in build() on every tick.
  Object? _lastSyncedTenantState;

  @override
  void initState() {
    super.initState();
    _loadFromCache();
  }

  void _loadFromCache() {
    // Show locally-cached amount immediately — no spinner on open
    final uid = ref.read(currentUserProvider)?.uid;
    if (uid == null) return;
    final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    final cached = HiveCache.instance.loadPushkaAmount(uid, tenantId);
    final cachedGoal = HiveCache.instance.loadPushkaGoal(uid, tenantId);
    if (cached != null) setState(() => pushkaAmount = cached);
    if (cachedGoal != null) setState(() => pushkaGoal = cachedGoal);
  }

  @override
  void dispose() {
    _confettiController.dispose();
    super.dispose();
  }

  void _triggerCelebration() {
    _confettiController.play();
    FeedbackService.instance.playSuccess();
  }

  // Centralized non-fatal error reporter so caught exceptions in this screen
  // surface in production Crashlytics with uid/tenantId context.
  void _reportError(Object error, StackTrace st, {required String op}) {
    final uid = ref.read(currentUserProvider)?.uid;
    final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    try {
      FirebaseCrashlytics.instance.recordError(
        error,
        st,
        reason: 'pushka_screen:$op',
        information: [
          if (uid != null) 'uid=$uid',
          if (tenantId != null) 'tenantId=$tenantId',
        ],
        fatal: false,
      );
    } catch (_) {
      // Crashlytics may be unavailable on some platforms — never throw from here.
    }
  }

  Future<void> _updateStreak() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    final userProfile = ref.read(userProfileProvider).valueOrNull;
    final tenantId = userProfile?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    final tenantState = ref.read(tenantStateProvider).valueOrNull;
    if (tenantState == null) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastDateRaw = tenantState['lastStreakDate'];
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
        final authoritative = (tenantState['streakCount'] as num?)?.toInt() ?? _streakCount;
        _streakCount = (authoritative > 0 ? authoritative : 1) + 1;
      } else {
        _streakCount = 1;
      }
    } else {
      _streakCount = 1;
    }

    if (mounted) setState(() {});
    try {
      await ref.read(userRepositoryProvider).updateTenantState(
        uid: user.uid,
        tenantId: tenantId,
        streakCount: _streakCount,
        lastStreakDate: today,
      );
    } catch (e, st) {
      _reportError(e, st, op: 'updateStreak');
    }
  }
  Future<void> addAmount(double amount) async {
    // Prevent adding to a full pushka (already reached goal).
    if (pushkaGoal > 0 && pushkaAmount >= pushkaGoal) return;
    // Clamp so we never exceed the goal.
    final headroom = pushkaGoal > 0 ? (pushkaGoal - pushkaAmount) : double.infinity;
    final clamped = pushkaGoal > 0 ? amount.clamp(0.0, headroom) : amount;
    if (clamped <= 0) return;

    final wasFull = pushkaGoal > 0 && pushkaAmount >= pushkaGoal;
    setState(() => pushkaAmount += clamped);
    final nowFull = pushkaGoal > 0 && pushkaAmount >= pushkaGoal;
    final goalJustReached = !wasFull && nowFull;
    if (goalJustReached) {
      _triggerCelebration();
    } else {
      // Coin drop animation + jingle sound were removed by product decision —
      // only the bill animation remains. The slot in the pushka 3D model is
      // still drawn (visual identity), but nothing falls through it except
      // bills now.
      FeedbackService.instance.playBillFall();
      final titleBox = _fillItTitleKey.currentContext?.findRenderObject() as RenderBox?;
      final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final startY = (titleBox != null && stackBox != null)
          ? stackBox.globalToLocal(titleBox.localToGlobal(Offset(0, titleBox.size.height))).dy + 8
          : -90.0;
      setState(() { _showBill = true; _billKey++; _billStartY = startY; });
    }
    try {
      await _persistPushkaAmount();
    } catch (_) {
      // Persistence failure is non-critical: the local state is updated and
      // Hive will be retried next time. Swallow to avoid unhandled exceptions.
    }
    _updateStreak();
  }
  
  Future<void> emptyPushka() async {
    if (pushkaAmount <= 0 || _isProcessing) return;
    final tr = S.of(context);
    // Hold _isProcessing true for the ENTIRE flow including blocking dialogs.
    // Previously we set it false before showing the partial-payment / confirm
    // dialogs so the spinner wouldn't visually overlap them — but that opened
    // a window where a second tap on "Vaciar Pushka" started a parallel flow
    // and produced two PaymentSheets / two charges. The button itself is
    // disabled while _isProcessing is true, which is the correct behavior.
    setState(() => _isProcessing = true);
    try {
      double amountToEmpty = pushkaAmount;
      if (_partialPaymentsEnabled()) {
        final partial = await _showPartialDonationDialog();
        if (partial == null || !mounted) return;
        amountToEmpty = partial;
      }

      final currency = _currencyCodeFromProfile();
      final amountCents = amountToStripeUnits(amountToEmpty, currency);
      final minCents = _minAmountCentsForCurrency(currency);

      if (amountCents < minCents) {
        if (!mounted) return;
        _showMinAmountDialog(currency, minCents, amountToEmpty);
        return;
      }

      final confirmed = await _confirmIfLarge(amountToEmpty);
      if (!confirmed || !mounted) return;

      if (_biometricEnabled()) {
        final authenticated = await BiometricService.instance.authenticate(
          reason: tr.biometricReasonEmpty,
        );
        if (!authenticated) {
          _showError(tr.authRequired);
          return;
        }
      }

      if (StripeConfig.publishableKey.isEmpty) {
        throw Exception(tr.stripeNotConfigured);
      }

      await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: ref.read(currentUserProvider)?.email,
        purpose: 'pushka_empty',
        merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
      );

      await AnalyticsService.instance.logPushkaEmpty(amountToEmpty);
      // Transaction is written server-side by the Stripe webhook (payment_intent.succeeded).
      // Writing here too with the same docId causes a race condition when the webhook fires
      // first — the client's set() would be an update, denied by Firestore rules.

      final remaining = (pushkaAmount - amountToEmpty).clamp(0.0, double.infinity);
      if (!mounted) return;
      // Persist FIRST then update local — close the race where the app
      // is killed between optimistic setState and Firestore write.
      await _persistPushkaAmount(overrideAmount: remaining);
      if (!mounted) return;
      setState(() => pushkaAmount = remaining);
      FeedbackService.instance.vibratePushkaEmpty();
      FeedbackService.instance.playSuccess();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          remaining > 0
              ? tr.paymentProcessedRemaining(formatMoney(remaining))
              : tr.pushkaEmptied,
        )),
      );
    } catch (error, st) {
      // User-canceled flows aren't bugs — don't pollute Crashlytics with them.
      final isUserCancel = error is StripeServiceException && error.code == 'canceled';
      if (!isUserCancel) {
        _reportError(error, st, op: 'emptyPushka');
      }
      if (!mounted) return;
      _showError(_donationErrorMessage(error, tr));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _donateNow() async {
    if (_isProcessing) return;
    final tr = S.of(context);
    // Controllers must be disposed when the sheet closes — keeping them
    // alive in function scope without dispose() is a memory leak the
    // Flutter framework will warn about in debug. try/finally below.
    final amountCtrl = TextEditingController();
    final messageCtrl = TextEditingController();
    Map<String, dynamic>? result;
    String? error;
    try {
    result = await showKeyboardSafeSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      Center(child: Text(tr.donateNowTitle, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
                      const SizedBox(height: 16),
                      TextField(
                        controller: amountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: tr.amount, hintText: '0', prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: messageCtrl,
                        decoration: InputDecoration(
                          labelText: tr.optionalMessage,
                          hintText: tr.writeMessage,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(tr.instantDonationNote, style: const TextStyle(color: Color(0xFF888888), fontSize: 12), textAlign: TextAlign.center),
                      const SizedBox(height: 14),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(amountCtrl.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = tr.enterValidAmount); return; }
                          Navigator.pop(ctx, {'amount': value, 'message': messageCtrl.text.trim()});
                        },
                        child: Text(tr.donateNowBtn, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      )),
                    ]),
    );
    } finally {
      // Defer ~400ms: showModalBottomSheet returns at pop-time, NOT at
      // animation-end. Disposing immediately fires a notification that
      // hits the still-rebuilding TextField mid-exit-animation →
      // "TextEditingController was used after being disposed".
      Future.delayed(const Duration(milliseconds: 400), () {
        amountCtrl.dispose();
        messageCtrl.dispose();
      });
    }
    if (result == null || !mounted) return;
    final donationAmount = result['amount'] as double;

    final confirmed = await _confirmIfLarge(donationAmount);
    if (!confirmed || !mounted) return;

    setState(() => _isProcessing = true);
    try {
      if (_biometricEnabled()) {
        final authenticated = await BiometricService.instance.authenticate(
          reason: tr.biometricReasonDonate,
        );
        if (!authenticated) {
          _showError(tr.authRequiredDonate);
          return;
        }
      }
      if (!mounted) return;

      if (StripeConfig.publishableKey.isEmpty) {
        throw Exception(tr.stripeNotConfigured);
      }

      final currency = _currencyCodeFromProfile();
      final amountCents = amountToStripeUnits(donationAmount, currency);
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
        merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
      );

      await AnalyticsService.instance.logDonation(donationAmount, currency);
      // Transaction is written server-side by the Stripe webhook (payment_intent.succeeded).

      FeedbackService.instance.playSuccess();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).donationProcessed(formatMoney(donationAmount)))),
        );
      }
    } catch (error) {
      if (!mounted) return;
      _showError(_donationErrorMessage(error, S.of(context)));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _processCardPayment(double donationAmount) async {
    if (!mounted) return;
    final tr = S.of(context);
    setState(() => _isProcessing = true);
    try {
      if (StripeConfig.publishableKey.isEmpty) {
        throw Exception(tr.stripeNotConfigured);
      }

      final currency = _currencyCodeFromProfile();
      final amountCents = amountToStripeUnits(donationAmount, currency);
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
        merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
      );

      await AnalyticsService.instance.logDonation(donationAmount, currency);
      // Transaction is written server-side by the Stripe webhook (payment_intent.succeeded).
      final remaining = (pushkaAmount - donationAmount).clamp(0.0, double.infinity);
      // Persist FIRST then update local — same race fix as the other paths.
      await _persistPushkaAmount(overrideAmount: remaining);
      if (!mounted) return;
      setState(() => pushkaAmount = remaining);

      FeedbackService.instance.playSuccess();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            remaining > 0
                ? tr.paymentProcessedRemaining(formatMoney(remaining))
                : tr.paymentProcessedHistory,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      _showError(_donationErrorMessage(error, tr));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _processAlternativePayment(double amount, PaymentMethod method) async {
    final confirmed = await _showPaymentInstructions(method, amount);
    if (confirmed != true) return;

    if (!mounted) return;
    final tr = S.of(context);
    setState(() => _isProcessing = true);
    try {
      final remaining = (pushkaAmount - amount).clamp(0.0, double.infinity);
      // Persist FIRST then update local: if the app is killed mid-flight
      // we don't want the user to think the donation reduced the pushka
      // (local) when it actually didn't make it to Firestore.
      await _persistPushkaAmount(overrideAmount: remaining);
      if (!mounted) return;
      setState(() => pushkaAmount = remaining);

      final currency = _currencyCodeFromProfile();
      final user = ref.read(currentUserProvider);
      final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
      if (user != null) {
        final methodLabels = {
          PaymentMethod.check: tr.methodCheckFull,
          PaymentMethod.transfer: tr.methodTransferFull,
          PaymentMethod.daf: tr.methodDafFull,
        };
        await ref.read(transactionRepositoryProvider).addTransaction(
          uid: user.uid,
          type: TransactionType.tzedaka,
          amount: amount,
          description: tr.donationVia(methodLabels[method] ?? method.name),
          paymentMethod: method,
          status: PaymentStatus.pending,
          currencyCode: currency,
          tenantId: tenantId,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr.donationPending(formatMoney(amount)),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (error) {
      if (mounted) _showError(tr.couldNotRegister);
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _processDirectDonation(double amount) async {
    if (amount <= 0 || _isProcessing) return;
    final tr = S.of(context);

    if (_biometricEnabled()) {
      final authenticated = await BiometricService.instance.authenticate(
        reason: tr.biometricReasonDonate,
      );
      if (!authenticated) {
        _showError(tr.authRequiredDonate);
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
    final tr = S.of(context);

    final userProfile = ref.watch(userProfileProvider).valueOrNull;
    final tenantState = ref.watch(tenantStateProvider).valueOrNull;
    final pushkaStyle = ref.watch(pushkaStyleProvider);
    final tenantId = userProfile?['tenantId'] as String?;
    final remoteGoal = tenantState?['pushkaGoal'];
    final remoteAmount = tenantState?['pushkaAmount'];
    final remotePresets = tenantState?['presetAmounts'];

    if (tenantState != null && !identical(tenantState, _lastSyncedTenantState)) {
      // Guard with identity check on the snapshot map so this only runs
      // when Riverpod hands us a NEW tenantState — not on every unrelated
      // rebuild (preset tap, animation tick). Without this, the
      // addPostFrameCallback was being re-enqueued on every build, and the
      // setState() inside re-triggered build → infinite micro-rebuilds.
      _lastSyncedTenantState = tenantState;
      final uid = ref.read(currentUserProvider)?.uid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        bool changed = false;
        // Sync local pushkaAmount with the remote tenantState snapshot,
        // EXCEPT during the recent-write window: stream snapshots that
        // pre-date our own write would otherwise revert the optimistic
        // setState. 4-second window comfortably outlasts write+echo.
        // Stopwatch is monotonic (no system-clock-jump risk).
        if (remoteAmount is num) {
          final remote = remoteAmount.toDouble();
          final recentWrite = _localWriteStopwatch.isRunning &&
              _localWriteStopwatch.elapsed.inSeconds < 4;
          if (!recentWrite && remote != pushkaAmount) {
            pushkaAmount = remote;
            changed = true;
            if (uid != null && tenantId != null) {
              HiveCache.instance.savePushkaAmount(uid, tenantId, pushkaAmount);
            }
          }
        }
        if (!_loadedRemote) {
          if (remoteGoal is num) {
            pushkaGoal = remoteGoal.toDouble();
            changed = true;
            if (uid != null && tenantId != null) {
              HiveCache.instance.savePushkaGoal(uid, tenantId, pushkaGoal);
            }
          }
          if (remotePresets is List && remotePresets.length == 3) {
            try {
              _presetAmounts = remotePresets.whereType<num>().map((e) => e.toDouble()).toList();
              if (_presetAmounts.length != 3) _presetAmounts = [];
              changed = true;
            } catch (_) {
              _presetAmounts = [];
            }
          }
          _loadedRemote = true;
          _streakCount = (tenantState['streakCount'] as num?)?.toInt() ?? 0;
          changed = true;
          if (userProfile != null) {
            FeedbackService.instance.updatePreferences(
              sound: (userProfile['soundEnabled'] as bool?) ?? true,
              vibration: (userProfile['vibrationEnabled'] as bool?) ?? true,
              ambient: (userProfile['ambientEnabled'] as bool?) ?? false,
            );
          }
        }
        if (changed) setState(() {});
      });
    }

    final quickAmounts = _buildQuickAmounts();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxHeight < 560;
            final availableForImage = constraints.maxHeight - 260;
            final imageHeight = availableForImage.clamp(220.0, 440.0);
            // Bumped from 4/8 → 16/24: with the AppBar already minimal
            // and the streak banner above, the "¡Llénala!" title was
            // sitting too close to the top, looked cramped.
            final topGap = isCompact ? 16.0 : 24.0;
            final titleSize = isCompact ? 20.0 : 24.0;
            final subtitleSize = isCompact ? 14.0 : 16.0;
            final titleBottomGap = isCompact ? 2.0 : 4.0;
            final actionsTopGap = isCompact ? 2.0 : 4.0;

                        final activeHoliday = _HolidayInfo.getActiveHoliday();
            final bool isFull = pushkaGoal > 0 && pushkaAmount >= pushkaGoal;

            final content = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            _buildCombinedBanner(_streakCount, activeHoliday),

            SizedBox(height: topGap),

            // Title / subtitle / progress vary by full vs filling state.
            if (isFull) ...[
              Text(
                tr.pushkaFull,
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                tr.donationGoalReached,
                style: TextStyle(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : AppTokens.mutedText,
                  fontSize: subtitleSize,
                ),
                textAlign: TextAlign.center,
              ),
            ] else ...[
              Text(
                key: _fillItTitleKey,
                tr.fillIt,
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${_currencySymbol(_currencyCodeFromProfile())}${formatAmount(pushkaAmount)} / ${_currencySymbol(_currencyCodeFromProfile())}${formatAmount(pushkaGoal)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: constraints.maxWidth * 0.09),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: fillPercentage,
                    minHeight: 4,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).brightness == Brightness.dark
                          ? Theme.of(context).colorScheme.primary
                          : AppTokens.primaryBlue,
                    ),
                  ),
                ),
              ),
            ],
            SizedBox(height: titleBottomGap),

            // Single Pushka3DWidget instance — keyed once at this position so
            // the AnimationControllers (wave/fill/coin) survive isFull flips
            // without GlobalKey duplication. Previously the same _pushkaKey was
            // attached to two widgets in different branches of an if/else,
            // which is a Flutter footgun: any moment both branches mount
            // (animated transitions, hot-reload races, debug overlays) crashes
            // with "Multiple widgets used the same GlobalKey".
            RepaintBoundary(
              child: SizedBox(
                height: imageHeight,
                child: pushkaStyle == PushkaStyle.building770
                    ? Building770Widget(fillFraction: fillPercentage)
                    : Pushka3DWidget(
                        key: _pushkaKey,
                        fillPercentage: fillPercentage,
                        goal: pushkaGoal,
                        amount: pushkaAmount,
                        currencySymbol: _currencySymbol(_currencyCodeFromProfile()),
                      ),
              ),
            ),

            SizedBox(height: actionsTopGap),

            // Action buttons differ by state.
            if (isFull) ...[
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
                  child: Text(tr.emptyPushkaBtn, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _showTzedakahSettingsDialog,
                child: Text(
                  tr.changePushkaGoal,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ] else ...[
              Row(
                children: [
                  _moneyBtn(_formatQuickAmount(quickAmounts[0]), () => addAmount(quickAmounts[0])),
                  const SizedBox(width: 10),
                  _moneyBtn(_formatQuickAmount(quickAmounts[1]), () => addAmount(quickAmounts[1])),
                  const SizedBox(width: 10),
                  _moneyBtn(_formatQuickAmount(quickAmounts[2]), () => addAmount(quickAmounts[2])),
                  const SizedBox(width: 10),
                  _moneyBtn(tr.otherAmount, _otherAmount),
                ],
              ),

              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _donateNow,
                    child: Text(
                      tr.donateNowBtn,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(
                    onPressed: emptyPushka,
                    child: Text(
                      tr.emptyPushkaBtn,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.settings, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    onPressed: _showTzedakahSettingsDialog,
                  ),
                ],
              ),
            ],
              ],
            );
            return Stack(
              key: _stackKey,
              children: [
                // ConstrainedBox + center alignment: now that the system
                // nav bar is hidden (immersiveSticky), the screen has
                // extra vertical space at the bottom. Without this wrap
                // the Column(mainAxisSize: min) just stuck at the top
                // and the freed space appeared as a blank strip.
                // Centering the content distributes the extra room
                // evenly (top + bottom) so the layout looks balanced.
                SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.max,
                      children: [content],
                    ),
                  ),
                ),
                Positioned.fill(
                  child: JewishConfetti(controller: _confettiController),
                ),
                if (_showBill)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: BillFallAnimation(
                        key: ValueKey(_billKey),
                        startY: _billStartY,
                        onDone: () { if (mounted) setState(() => _showBill = false); },
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCombinedBanner(int streakCount, _HolidayInfo? holiday) {
    final hasStreak = streakCount > 0;
    final hasHoliday = holiday != null;
    if (!hasStreak && !hasHoliday) return const SizedBox.shrink();

    final sc = hasStreak
        ? _streakColors(streakCount)
        : (const Color(0xFFFFD54F), const Color(0xFFFFC107));
    const double h = 38.0;
    const double badgeSize = 34.0;
    final double pillW = MediaQuery.of(context).size.width - 32;
    final double streakW = pillW - 120;
    const double holidayW = 120.0;

    // Both together: full pill. Solo: the individual width, centered.
    final bool both = hasStreak && hasHoliday;
    final double containerW = both ? pillW : (hasStreak ? streakW : holidayW);

    final pill = SizedBox(
      width: containerW,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(h / 2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(h / 2),
          child: SizedBox(
            height: h,
            child: Stack(
              children: [
                // Holiday: fills entire pill background
                if (hasHoliday)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () { if (_isProcessing) return; _showHolidayDonationDialog(holiday); },
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF6B3800), Color(0xFF3A1A00)],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                        ),
                        // Combined: content pushed to the right 120px zone.
                        // Alone: content centered within the 120px pill.
                        padding: both
                            ? EdgeInsetsDirectional.fromSTEB(streakW, 0, 12, 0)
                            : const EdgeInsets.only(left: 0, right: 20),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _holidayIcon(holiday.nameEs, size: 26),
                            const SizedBox(width: 6),
                            Text(
                              holiday.localizedName(S.of(context)),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                shadows: [
                                  Shadow(
                                    color: Color(0x33000000),
                                    blurRadius: 3,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                // Streak: combined → fills all but 120px; alone → fills full pill
                if (hasStreak)
                  Positioned(
                    left: 0, top: 0, bottom: 0,
                    child: SizedBox(
                      width: both ? streakW : containerW,
                      child: Container(
                        padding: const EdgeInsetsDirectional.fromSTEB(50, 0, 20, 0),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [sc.$1, sc.$2],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                          borderRadius: BorderRadius.circular(h / 2),
                        ),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              S.of(context).streakDays,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                                shadows: [
                                  Shadow(
                                    color: Color(0x33000000),
                                    blurRadius: 3,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                                  ),
                                  const SizedBox(width: 6),
                                  const Icon(Icons.local_fire_department, color: Colors.white, size: 18),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // Glass sheen over everything
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: const Alignment(0, 0.5),
                                colors: const [Color(0x55FFFFFF), Color(0x00FFFFFF)],
                              ),
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

    final Widget stack = Stack(
      clipBehavior: Clip.none,
      children: [
        pill,
        if (hasStreak)
          PositionedDirectional(
            start: 4,
            top: -(badgeSize - h) / 2,
            child: _HexBadge(count: streakCount, color1: sc.$1, color2: sc.$2),
          ),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      child: both ? stack : Align(alignment: Alignment.center, child: stack),
    );
  }

  (Color, Color) _streakColors(int count) {
    final day = ((count - 1) % 7) + 1;
    return switch (day) {
      1 => (const Color(0xFFFFE040), const Color(0xFFE8720C)),
      2 => (const Color(0xFFFF7070), const Color(0xFFB71C1C)),
      3 => (const Color(0xFF64B5F6), const Color(0xFF1565C0)),
      4 => (const Color(0xFF81C784), const Color(0xFF2E7D32)),
      5 => (const Color(0xFFCE93D8), const Color(0xFF6A1B9A)),
      6 => (const Color(0xFF4DD0E1), const Color(0xFF00695C)),
      _ => (const Color(0xFF9FA8DA), const Color(0xFF1A237E)),
    };
  }

  Widget _holidayIcon(String name, {double size = 28}) {
    final lower = name.toLowerCase();
    String? asset;
    String emoji = '✨';
    if (lower.contains('shavuot')) {
      asset = 'assets/icons/shavuot.png';
    } else if (lower.contains('pesaj') || lower.contains('jitim') || lower.contains('ma\u0027ot')) {
      emoji = '🫓';
    } else if (lower.contains('rosh')) {
      emoji = '🍎';
    } else if (lower.contains('kipur')) {
      emoji = '🕊️';
    } else if (lower.contains('sucot')) {
      emoji = '🌴';
    } else if (lower.contains('januc')) {
      emoji = '🕯️';
    } else if (lower.contains('purim')) {
      emoji = '🎉';
    }
    if (asset != null) {
      return Image.asset(asset, width: size, height: size, fit: BoxFit.contain);
    }
    return Text(emoji, style: TextStyle(fontSize: size * 0.55));
  }
  Future<void> _showHolidayDonationDialog(_HolidayInfo holiday) async {
    final amountCtrl = TextEditingController();
    Map<String, dynamic>? result;
    double? selectedPreset;
    try {
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
                          holiday.localizedName(S.of(context)),
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFFE8912D)),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          holiday.localizedDescription(S.of(context)),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppTokens.mutedText, fontSize: 14),
                        ),
                        const SizedBox(height: 18),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(S.of(context).chooseAmount, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
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
                        Text(S.of(context).tapToEdit, style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
                            child: Text(S.of(context).donateNowBtn, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
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
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: Text(S.of(context).addToPushka, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          ),
                        ),
                      ],
                    );
      },
    );
    } finally {
      // Defer to outlast the sheet's exit animation — see _donateNow.
      Future.delayed(const Duration(milliseconds: 400), amountCtrl.dispose);
    }

    if (result == null || !mounted) return;
    final amount = result['amount'] as double;
    if (result['action'] == 'pushka') {
      await addAmount(amount);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).addedToPushka(formatMoney(amount)))),
        );
      }
    } else {
      await _processDirectDonation(amount);
    }
  }

  Expanded _moneyBtn(String label, VoidCallback onTap) {
    return Expanded(
      child: SizedBox(
        height: 44,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
    try {
    result = await showKeyboardSafeSheet<double>(
      context: context,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      Text(S.of(context).otherAmountTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
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
                          labelText: S.of(context).amount,
                          hintText: S.of(context).amountHint, prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      const SizedBox(height: 16),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = S.of(context).enterValidAmount); return; }
                          Navigator.pop(ctx, value);
                        },
                        child: Text(S.of(context).add, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      SizedBox(width: double.infinity, height: 44, child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(S.of(context).cancel, style: const TextStyle(fontWeight: FontWeight.w500)),
                      )),
                    ]),
    );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    }

    if (!mounted || result == null) return;
    await addAmount(result);
  }


  /// Returns true if the user confirmed (or amount <= threshold — no dialog needed).
  Future<bool> _confirmIfLarge(double amount) async {
    const threshold = 100.0;
    if (amount <= threshold) return true;
    if (!mounted) return false;
    final tr = S.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              tr.confirmPaymentTitle,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            content: Text(
              tr.confirmPaymentBody(formatMoney(amount)),
              style: const TextStyle(fontSize: 15, height: 1.5),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(tr.cancel),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTokens.primaryBlue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  tr.confirmDonate,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _persistPushkaAmount({
    bool resetToZero = false,
    double? overrideAmount,
  }) async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showError(S.of(context).signInToContinue);
      return;
    }
    final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    _localWriteStopwatch
      ..reset()
      ..start();
    // overrideAmount lets the caller persist the new value BEFORE
    // touching local pushkaAmount — the persist-then-setState order
    // closes a race where the app is killed between the optimistic
    // setState and the await, which would otherwise leave Firestore
    // with the old value while the user thinks the donation registered.
    final amount = overrideAmount ?? (resetToZero ? 0.0 : pushkaAmount);
    await Future.wait([
      ref.read(userRepositoryProvider).updatePushkaAmount(
        uid: user.uid,
        tenantId: tenantId,
        amount: amount,
      ),
      HiveCache.instance.savePushkaAmount(user.uid, tenantId, amount),
    ]);
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
    final tr = S.of(context);
    final symbol = _currencySymbol(currency);
    final minAmount = _formatAmountFromCents(minCents, currency: currency);
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
            Text(
              tr.minAmountTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              tr.minAmountBody(code, symbol, minAmount),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700, height: 1.4),
            ),
            const SizedBox(height: 6),
            Text(
              tr.minAmountHint,
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
                child: Text(tr.understood, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  String _donationErrorMessage(Object error, S tr) {
    if (error is FirebaseFunctionsException) {
      return switch (error.code) {
        'unauthenticated' =>
          tr.errorSessionInvalid,
        'failed-precondition' =>
          tr.errorSecurityCheck,
        'permission-denied' =>
          tr.errorAccessDenied,
        'internal' =>
          tr.errorPaymentServer,
        'unavailable' =>
          tr.errorServerUnavailable,
        _ => error.message ?? tr.couldNotStartPayment,
      };
    }
    if (error is StripeServiceException) {
      if (error.code == 'canceled') return tr.paymentCanceled;
      return tr.couldNotStartPayment;
    }
    if (error is Exception) {
      final msg = error.toString().replaceFirst('Exception: ', '');
      if (msg.isNotEmpty && msg != 'null') {
        return msg;
      }
    }
    return tr.couldNotCompleteDonation;
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
    return (profile?['partialPaymentsEnabled'] as bool?) ?? true;
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
    final tr = S.of(context);
    return showDialog<PaymentMethod>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr.paymentMethodTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(tr.paymentMethodSubtitle, style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            const SizedBox(height: 18),
            _paymentMethodTile(ctx, PaymentMethod.card, Icons.credit_card, tr.paymentCard, tr.paymentCardSub),
            const SizedBox(height: 10),
            _paymentMethodTile(ctx, PaymentMethod.check, Icons.mail_outline, tr.paymentCheck, tr.paymentCheckSub),
            const SizedBox(height: 10),
            _paymentMethodTile(ctx, PaymentMethod.transfer, Icons.account_balance, tr.paymentTransfer, tr.paymentTransferSub),
            const SizedBox(height: 10),
            _paymentMethodTile(ctx, PaymentMethod.daf, Icons.volunteer_activism, tr.paymentDaf, tr.paymentDafSub),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, height: 44, child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr.cancel, style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
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
          border: Border.all(color: Theme.of(ctx).colorScheme.outline),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: Theme.of(ctx).colorScheme.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ])),
          Icon(Icons.chevron_right, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
        ]),
      ),
    );
  }

  Future<bool?> _showPaymentInstructions(PaymentMethod method, double amount) async {
    final tr = S.of(context);
    if (method == PaymentMethod.card) return null;

    final String title;
    final String instructionText;
    final IconData icon;

    switch (method) {
      case PaymentMethod.check:
        title = tr.checkTitle;
        icon = Icons.mail_outline;
        instructionText = tr.checkInstructions(formatMoney(amount));
      case PaymentMethod.transfer:
        title = tr.transferTitle;
        icon = Icons.account_balance;
        instructionText = tr.transferInstructions(formatMoney(amount));
      case PaymentMethod.daf:
        title = tr.dafTitle;
        icon = Icons.volunteer_activism;
        instructionText = tr.dafInstructions(formatMoney(amount));
      case PaymentMethod.card:
        return null;
      case PaymentMethod.auto:
        return null;
    }

    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Column(children: [
                  Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2)))),
                  Icon(icon, size: 40, color: cs.primary),
                  const SizedBox(height: 10),
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                    child: Text(formatMoney(amount), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: cs.primary)),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Flexible(child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                  child: Text(instructionText, style: TextStyle(fontSize: 14, height: 1.55, color: cs.onSurface)),
                ),
              )),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Column(children: [
                  SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                    style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(tr.confirmDonation, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  )),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, height: 44, child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(tr.cancel, style: const TextStyle(fontWeight: FontWeight.w500)),
                  )),
                ]),
              ),
            ]),
          ),
        ),
        );
      },
    );
  }

  Future<double?> _showPartialDonationDialog() async {
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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

  String _formatAmountFromCents(int cents, {String? currency}) {
    final code = currency ?? _currencyCodeFromProfile();
    final value = stripeUnitsToAmount(cents, code);
    final mult = currencyUnitMultiplier(code);
    if (mult == 1) return value.toStringAsFixed(0);
    if (value == value.roundToDouble() && value >= 1) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(mult == 1000 ? 3 : 2);
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
    final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    try {
      await ref
          .read(userRepositoryProvider)
          .updateTenantState(
            uid: uid,
            tenantId: tenantId,
            pushkaGoal: goal,
            presetAmounts: presets,
          )
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      if (!mounted) return;
      _showError(S.of(context).offlineSaved);
    } on FirebaseException catch (e) {
      if (!mounted) return;
      if (e.code == 'unavailable') {
        _showError(S.of(context).firestoreUnavailable);
      } else {
        _showError(S.of(context).couldNotSync);
      }
    } catch (_) {
      if (!mounted) return;
      _showError(S.of(context).couldNotSync);
    }
  }

  Future<void> _showTzedakahSettingsDialog() async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showError(S.of(context).signInToContinue);
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
    double displayedAmount = pushkaAmount;
    bool isSaving = false;

    final ctrl1 = TextEditingController(text: _formatPresetValue(currentPresets[0]));
    final ctrl2 = TextEditingController(text: _formatPresetValue(currentPresets[1]));
    final ctrl3 = TextEditingController(text: _formatPresetValue(currentPresets[2]));
    bool? saved;
    try {
    saved = await showKeyboardSafeSheet<bool>(
      context: context,
      builder: (ctx, setDialogState) {
        final cs = Theme.of(ctx).colorScheme;
        return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2)))),
                  Center(
                    child: Text(
                      S.of(context).tzedakahSettings,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    S.of(context).pushkaGoalLabel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<double>(
                    initialValue: goalOptions.contains(selectedGoal) ? selectedGoal : null,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    isExpanded: true,
                    menuMaxHeight: 620,
                    dropdownColor: cs.surface,
                    borderRadius: BorderRadius.circular(16),
                    itemHeight: 52,
                    decoration: InputDecoration(
                      hintText: formatMoney(selectedGoal),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: cs.primary, width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                    ),
                    items: goalOptions.map((value) {
                      return DropdownMenuItem<double>(
                        value: value,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              symbol,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              formatAmount(value),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList()
                      ..add(
                        DropdownMenuItem<double>(
                          value: -1,
                          child: Text(
                            S.of(context).dropdownOther,
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

                  // ── Corregir monto acumulado ─────────────────────────────
                  if (displayedAmount > 0) ...[
                    const SizedBox(height: 18),
                    Text(
                      S.of(context).correctAmountLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurfaceVariant,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        // Declare controller OUTSIDE showDialog's builder
                        // so we can dispose it in the finally below.
                        final amtCtrl = TextEditingController(
                          text: _formatPresetValue(displayedAmount),
                        );
                        double? corrected;
                        try {
                        corrected = await showDialog<double>(
                          context: ctx,
                          builder: (dCtx) {
                            String? errorText;
                            return StatefulBuilder(
                              builder: (dCtx, setDState) => AlertDialog(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                title: Text(
                                  S.of(context).correctAmountDialogTitle,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                content: TextField(
                                  controller: amtCtrl,
                                  autofocus: true,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  textInputAction: TextInputAction.done,
                                  decoration: InputDecoration(
                                    labelText: S.of(context).amount,
                                    prefixText: '$symbol ',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(color: cs.primary, width: 2),
                                    ),
                                    errorText: errorText,
                                  ),
                                  onSubmitted: (_) {
                                    final v = double.tryParse(
                                      amtCtrl.text.trim().replaceAll(',', '.'),
                                    );
                                    if (v == null || v < 0) {
                                      setDState(() => errorText = S.of(context).enterValidAmount);
                                      return;
                                    }
                                    Navigator.pop(dCtx, v);
                                  },
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dCtx),
                                    child: Text(S.of(context).cancel),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: cs.primary,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    onPressed: () {
                                      final v = double.tryParse(
                                        amtCtrl.text.trim().replaceAll(',', '.'),
                                      );
                                      if (v == null || v < 0) {
                                        setDState(() => errorText = S.of(context).enterValidAmount);
                                        return;
                                      }
                                      Navigator.pop(dCtx, v);
                                    },
                                    child: Text(S.of(context).save),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                        } finally {
                          Future.delayed(
                            const Duration(milliseconds: 400),
                            amtCtrl.dispose,
                          );
                        }
                        if (corrected == null || !mounted) return;
                        final capped = pushkaGoal > 0
                            ? corrected.clamp(0.0, pushkaGoal)
                            : corrected.clamp(0.0, 100000.0);
                        setDialogState(() => displayedAmount = capped);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          border: Border.all(color: cs.outline, width: 1.2),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  symbol,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _formatPresetValue(displayedAmount),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            Icon(Icons.edit_outlined, size: 18, color: cs.onSurfaceVariant),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 18),
                  Text(
                    S.of(context).presetAmountsLabel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    S.of(context).editQuickAmountHint,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [ctrl1, ctrl2, ctrl3].asMap().entries.map((entry) {
                      final idx = entry.key;
                      final ctrl = entry.value;
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsetsDirectional.only(end: idx < 2 ? 8 : 0),
                          child: TextField(
                            controller: ctrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                            decoration: InputDecoration(
                              prefixText: symbol,
                              prefixStyle: TextStyle(
                                fontSize: 15,
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: cs.outline, width: 1.2),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: cs.outline, width: 1.2),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: cs.primary, width: 2),
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
                                _showError(S.of(context).allAmountsMustBePositive);
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
                                pushkaAmount = displayedAmount;
                              });
                              unawaited(
                                _syncTzedakahSettings(
                                  uid: user.uid,
                                  goal: selectedGoal,
                                  presets: newPresets,
                                ),
                              );
                              unawaited(
                                _persistPushkaAmount(resetToZero: displayedAmount <= 0),
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
                          : Text(
                              S.of(context).saveBtn,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: isSaving
                          ? null
                          : () => Navigator.of(ctx).pop(false),
                      child: Text(
                        S.of(context).cancelBtn,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                      ],
                    );
      },
    );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), () {
        ctrl1.dispose();
        ctrl2.dispose();
        ctrl3.dispose();
      });
    }

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).settingsApplied)),
      );
    }
  }

  Future<double?> _showCustomGoalDialog() async {
    final controller = TextEditingController();
    String? error;
    double? result;
    try {
    result = await showKeyboardSafeSheet<double>(
      context: context,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      Text(S.of(context).customGoal, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
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
                          hintText: S.of(context).customGoalHint, prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      const SizedBox(height: 16),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = S.of(context).enterValidAmount); return; }
                          Navigator.pop(ctx, value);
                        },
                        child: Text(S.of(context).accept, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      SizedBox(width: double.infinity, height: 44, child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(S.of(context).cancel, style: const TextStyle(fontWeight: FontWeight.w500)),
                      )),
                    ]),
    );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    }
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
      setState(() => _error = S.of(context).enterValidAmount);
      return;
    }
    if (parsed > widget.available) {
      setState(() => _error = S.of(context).cannotExceedBalance);
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  tr.partialDonationTitle,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  tr.availableInPushka(formatMoney(widget.available)),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  tr.quickSelect,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
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
                    labelText: tr.amountToDonate,
                    prefixText: '\$ ',
                    errorText: _error,
                    hintText: tr.amountHint,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _submit,
                    child: Text(
                      tr.donate,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
                      tr.cancel,
                      style: const TextStyle(fontWeight: FontWeight.w500),
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
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _applyPercent(percent),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? cs.primary.withValues(alpha: 0.12) : cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? cs.primary : cs.outline,
            width: isSelected ? 1.8 : 1.2,
          ),
        ),
        child: Text(
          '$percent%',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: isSelected ? cs.primary : cs.onSurface,
          ),
        ),
      ),
    );
  }
}


class _HolidayInfo {
  final String nameEs;
  final String descriptionEs;
  final String key;
  final List<double> presetAmounts;
  final DateTime startDate;
  final int showDaysBefore;
  final int durationDays;
  const _HolidayInfo({
    required this.nameEs,
    required this.descriptionEs,
    required this.key,
    required this.presetAmounts,
    required this.startDate,
    required this.showDaysBefore,
    this.durationDays = 1,
  });

  String localizedName(S tr) => switch (key) {
    'maotJitim' => tr.holidayMaotJitim,
    'shavuot' => tr.holidayShavuot,
    'roshHashana' => tr.holidayRoshHashana,
    'yomKippur' => tr.holidayYomKippur,
    'sucot' => tr.holidaySucot,
    'januca' => tr.holidayJanuca,
    'purim' => tr.holidayPurim,
    _ => nameEs,
  };

  String localizedDescription(S tr) => switch (key) {
    'maotJitim' => tr.holidayMaotJitimDesc,
    'shavuot' => tr.holidayShavuotDesc,
    'roshHashana' => tr.holidayRoshHashanaDesc,
    'yomKippur' => tr.holidayYomKippurDesc,
    'sucot' => tr.holidaySucotDesc,
    'januca' => tr.holidayJanucaDesc,
    'purim' => tr.holidayPurimDesc,
    _ => descriptionEs,
  };

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
      key: 'maotJitim',
      nameEs: 'Ma\u0027ot Jitim',
      descriptionEs: 'Fondos para los necesitados de Israel para sus necesidades de P\u00e9saj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2026, 4, 2),
      showDaysBefore: 30,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'shavuot',
      nameEs: 'Shavuot',
      descriptionEs: 'Celebramos la entrega de la Tor\u00e1. Dona tzedak\u00e1 en honor a esta festividad',
      presetAmounts: [18, 36, 180],
      startDate: DateTime(2026, 5, 22),
      showDaysBefore: 21,
      durationDays: 2,
    ),
    // 5787 (2026-2027)
    _HolidayInfo(
      key: 'roshHashana',
      nameEs: 'Rosh Hashan\u00e1',
      descriptionEs: 'A\u00f1o Nuevo jud\u00edo. Comienza el a\u00f1o con tzedak\u00e1 y buenas acciones',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2026, 9, 12),
      showDaysBefore: 30,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'yomKippur',
      nameEs: 'Yom Kippur',
      descriptionEs: 'D\u00eda de la Expiaci\u00f3n. La tzedak\u00e1 es un m\u00e9rito especial antes de Yom Kippur',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2026, 9, 21),
      showDaysBefore: 14,
    ),
    _HolidayInfo(
      key: 'sucot',
      nameEs: 'Sucot',
      descriptionEs: 'Fiesta de las Caba\u00f1as. Comparte alegr\u00eda con quienes m\u00e1s lo necesitan',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2026, 9, 26),
      showDaysBefore: 14,
      durationDays: 7,
    ),
    _HolidayInfo(
      key: 'januca',
      nameEs: 'Januc\u00e1',
      descriptionEs: 'Festival de las Luces. Ilumina vidas con tu donaci\u00f3n de tzedak\u00e1',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2026, 12, 5),
      showDaysBefore: 21,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'purim',
      nameEs: 'Purim',
      descriptionEs: "Matanot la'Evionim: regalos a los necesitados, una mitzv\u00e1 central de Purim",
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2027, 3, 23),
      showDaysBefore: 21,
    ),
    _HolidayInfo(
      key: 'maotJitim',
      nameEs: 'Ma\u0027ot Jitim',
      descriptionEs: 'Fondos para los necesitados de Israel para sus necesidades de P\u00e9saj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2027, 4, 22),
      showDaysBefore: 30,
      durationDays: 8,
    ),
  ];
}

class _HexBadge extends StatelessWidget {
  const _HexBadge({required this.count, required this.color1, required this.color2});
  final int count;
  final Color color1;
  final Color color2;

  @override
  Widget build(BuildContext context) {
    const double size = 34.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ShaderMask(
            blendMode: BlendMode.modulate,
            shaderCallback: (bounds) => LinearGradient(
              colors: [color1, color2],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ).createShader(bounds),
            child: Image.asset(
              'assets/icons/gem_badge.png',
              width: size,
              height: size,
              fit: BoxFit.contain,
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -1.5),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                height: 1,
                shadows: [
                  Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 2)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}



