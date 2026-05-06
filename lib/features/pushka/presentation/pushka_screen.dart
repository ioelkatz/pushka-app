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
import '../../payments/donation_reason_picker.dart';
import '../../payments/stripe_service.dart';
import '../../settings/presentation/auto_empty_screen.dart';
import '../../feedback/feedback_service.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../../config/stripe_config.dart';

/// Holds the callback that opens the Pushka settings sheet, exposed so the
/// home AppBar (defined in router.dart) can trigger it without us moving
/// the AppBar into this file. PushkaScreen sets it on init and clears on
/// dispose so the gear icon up top maps to the same sheet as the inline
/// gear button used to be.
final pushkaSettingsTapProvider = StateProvider<VoidCallback?>((ref) => null);

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
  // Fingerprint of the relevant fields from the last tenantState snapshot
  // we synced to local state. Compared as a value so two snapshots with
  // the same numbers but different Map identity (Riverpod re-emits new map
  // instances frequently — e.g. serverTimestamp resolution, neighbouring
  // field touches) don't re-enqueue a useless post-frame callback. The
  // earlier `identical()` check missed those, scheduling work on every
  // tick even though nothing about pushka had actually changed.
  String? _lastSyncedTenantStateFingerprint;
  String? _lastLoadedCacheTenantId;

  // Reference to OUR callback so dispose can compare-and-clear instead of
  // unconditionally nulling — fixes a subtle race where a fast back+forward
  // navigation leaves Screen A's pending dispose-microtask nulling Screen
  // B's callback (B then has a non-functional gear icon until next mount).
  VoidCallback? _ourSettingsTapCallback;

  @override
  void initState() {
    super.initState();
    _loadFromCache();
    _ourSettingsTapCallback = _showTzedakahSettingsDialog;
    // Wire the home AppBar gear → in-screen settings sheet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(pushkaSettingsTapProvider.notifier).state =
          _ourSettingsTapCallback;
    });
  }

  void _loadFromCache() {
    // Show locally-cached amount immediately — no spinner on open
    final uid = ref.read(currentUserProvider)?.uid;
    if (uid == null) return;
    final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    _loadFromCacheFor(uid, tenantId);
  }

  /// Reads the (uid, tenantId)-scoped cached pushka amount + goal into
  /// local state. Called on first mount AND whenever the active tenantId
  /// changes (via the listener wired in build()), so switching tenants
  /// repaints from the new tenant's cache instead of leaking the old
  /// tenant's numbers onto the screen.
  void _loadFromCacheFor(String uid, String tenantId) {
    if (_lastLoadedCacheTenantId == tenantId) return;
    _lastLoadedCacheTenantId = tenantId;
    double? cached;
    double? cachedGoal;
    try {
      cached = HiveCache.instance.loadPushkaAmount(uid, tenantId);
      cachedGoal = HiveCache.instance.loadPushkaGoal(uid, tenantId);
    } catch (e, st) {
      // Hive box not opened, corrupted, or platform IO failure. Defaults
      // below paint a clean state and the network stream will repopulate.
      // Surface to Crashlytics so we notice if it happens systematically.
      _reportError(e, st, op: 'loadFromCacheFor');
    }
    setState(() {
      // Reset to defaults when no cache exists for the new tenant —
      // otherwise we'd inherit the previous tenant's values until the
      // network catches up.
      pushkaAmount = cached ?? 0;
      pushkaGoal = cachedGoal ?? 3600;
    });
  }

  @override
  void dispose() {
    _confettiController.dispose();
    final ours = _ourSettingsTapCallback;
    Future.microtask(() {
      try {
        // Compare-and-clear: only null the provider if it still points at
        // OUR callback. Without this, a successor PushkaScreen that mounted
        // before our microtask ran would have its freshly-set callback
        // wiped out (gear icon would silently no-op until next mount).
        final notifier = ref.read(pushkaSettingsTapProvider.notifier);
        if (notifier.state == ours) {
          notifier.state = null;
        }
      } catch (_) {}
    });
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
      // Open the unified sheet first — it surfaces the partial-percent
      // chips (25/50/75/100) when the donor has partialPaymentsEnabled, so
      // the previous standalone _showPartialDonationDialog is gone. The
      // sheet returns the actual amount to charge.
      final details = await _showEmptyPushkaSheet(amount: pushkaAmount);
      // Sheet returns null both on dismiss AND on auto-branch.
      if (details == null || !mounted) return;
      final amountToEmpty = details.amount;

      final currency = _currencyCodeFromProfile();
      final amountCents = amountToStripeUnits(amountToEmpty, currency);
      final minCents = _minAmountCentsForCurrency(currency);

      if (amountCents < minCents) {
        if (!mounted) return;
        _showMinAmountDialog(currency, minCents, amountToEmpty);
        return;
      }

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

      // Compute the post-charge pushka value here and stamp it via the
      // CF metadata so the WEBHOOK writes it (atomic with the txn record).
      // Previously the client wrote pushkaAmount locally — but if Stripe
      // succeeded and the webhook never fired, money was charged with no
      // txn record AND pushka shown as empty. The webhook is now the
      // single owner of this write.
      final remaining = (pushkaAmount - amountToEmpty).clamp(0.0, double.infinity);

      await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: ref.read(currentUserProvider)?.email,
        purpose: 'pushka_empty',
        merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
        donorMessage: details.message.isEmpty ? null : details.message,
        pushkaAmountAfter: remaining,
      );

      await AnalyticsService.instance.logPushkaEmpty(amountToEmpty);
      // Transaction + pushkaAmount reset are written server-side by the
      // Stripe webhook (payment_intent.succeeded). The tenantStateProvider
      // listener will refresh the UI as soon as Firestore propagates the
      // new pushkaAmount.

      if (!mounted) return;
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
    final reasons = tr.defaultDonationReasons;
    // The amount controller must be disposed when the sheet closes —
    // keeping it alive in function scope without dispose() is a memory
    // leak the Flutter framework will warn about in debug. try/finally below.
    final amountCtrl = TextEditingController();
    final messageCtrl = TextEditingController();
    Map<String, dynamic>? result;
    String? error;
    bool monthly = false;
    bool dedicateOn = false;
    // Inline picker state — defaults to the tenant's first reason so the
    // donor isn't forced to opt in to a destination. They can still choose
    // "Sin designación" from the picker if they want to opt out.
    String? selectedReason = reasons.isNotEmpty ? reasons.first : null;
    try {
    result = await showKeyboardSafeSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx, setDialogState) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _SecureShieldIcon(size: 26),
                            const SizedBox(width: 8),
                            Text(tr.donateNowTitle, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                          child: _FrequencyChip(
                            label: tr.donateOnce,
                            selected: !monthly,
                            onTap: () => setDialogState(() => monthly = false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _FrequencyChip(
                            label: tr.donateMonthly,
                            selected: monthly,
                            icon: Icons.favorite,
                            iconColor: const Color(0xFFE05A8A),
                            onTap: () => setDialogState(() => monthly = true),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 14),
                      TextField(
                        controller: amountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: tr.amount,
                          floatingLabelStyle: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                          hintText: '0', prefixText: '\$ ', errorText: error,
                          filled: true,
                          fillColor: Theme.of(ctx).colorScheme.surface,
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(ctx).colorScheme.outline)),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(ctx).colorScheme.outline)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      // Inline designación picker — only when the tenant has
                      // reasons configured. Tap-to-open row that mirrors the
                      // amount TextField styling (OutlineInputBorder, labelText).
                      // Opens a bottom sheet styled like the History filter so
                      // donor picks a destino without losing the donation flow.
                      if (reasons.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () async {
                            final picked = await showDonationReasonPicker(
                              context: ctx,
                              reasons: reasons,
                              currentSelection: selectedReason,
                            );
                            if (picked is DonationReasonSelected) {
                              setDialogState(() => selectedReason = picked.reason);
                            }
                          },
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: tr.donationReasonTitle,
                              filled: true,
                              fillColor: Theme.of(ctx).colorScheme.surface,
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(ctx).colorScheme.outline)),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(ctx).colorScheme.outline)),
                            ),
                            child: Row(children: [
                              Expanded(
                                child: Text(
                                  selectedReason ?? tr.donationReasonNone,
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: selectedReason == null
                                        ? Theme.of(ctx).colorScheme.onSurfaceVariant
                                        : Theme.of(ctx).colorScheme.onSurface,
                                  ),
                                ),
                              ),
                              Icon(Icons.keyboard_arrow_down_rounded, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                            ]),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setDialogState(() => dedicateOn = !dedicateOn),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            SizedBox(
                              width: 22,
                              height: 22,
                              child: Checkbox(
                                value: dedicateOn,
                                onChanged: (v) => setDialogState(() => dedicateOn = v ?? false),
                                activeColor: AppTokens.primaryBlue,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              tr.dedicateDonation,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                            ),
                          ]),
                        ),
                      ),
                      if (dedicateOn) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: messageCtrl,
                          textCapitalization: TextCapitalization.sentences,
                          maxLength: 240,
                          decoration: InputDecoration(
                            labelText: tr.donationMessageLabel,
                            floatingLabelStyle: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                            hintText: tr.donationMessageHint,
                            filled: true,
                            fillColor: Theme.of(ctx).colorScheme.surface,
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(ctx).colorScheme.outline)),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Theme.of(ctx).colorScheme.outline)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          final value = double.tryParse(amountCtrl.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = tr.enterValidAmount); return; }
                          final msg = dedicateOn ? messageCtrl.text.trim() : '';
                          Navigator.pop(ctx, {'amount': value, 'reason': selectedReason, 'message': msg, 'monthly': monthly});
                        },
                        child: Text(monthly ? tr.donateMonthlyBtn : tr.donate, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
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
    final donationMessage = (result['message'] as String?)?.trim() ?? '';
    final isMonthly = result['monthly'] == true;

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

      // Note: donation reason already collected inline in the donate-now
      // sheet (see `result['reason']` above) — no separate picker step.

      if (isMonthly) {
        await StripeService.instance.subscribe(
          amountCents: amountCents,
          currency: currency,
          interval: 'month',
          donorMessage: donationMessage.isEmpty ? null : donationMessage,
          merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
        );
      } else {
        await StripeService.instance.pay(
          amountCents: amountCents,
          currency: currency,
          customerEmail: ref.read(currentUserProvider)?.email,
          purpose: 'donation',
          merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
          donorMessage: donationMessage.isEmpty ? null : donationMessage,
        );
      }

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

  Future<void> _processCardPayment(double donationAmount, {String? donorMessage}) async {
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
      final (proceed, _) = await _resolveDonationReason();
      if (!proceed || !mounted) return;

      await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: ref.read(currentUserProvider)?.email,
        purpose: 'donation',
        merchantDisplayName: ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
        donorMessage: donorMessage,
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

  Future<void> _processDirectDonation(double amount, {String? donorMessage}) async {
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

    await _processCardPayment(amount, donorMessage: donorMessage);
  }
    double get fillPercentage {
    if (pushkaGoal <= 0) return 0;
    final percentage = (pushkaAmount / pushkaGoal).clamp(0.0, 1.0);
    return percentage;
  }


  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);

    // React to tenant switches: when userProfile.tenantId changes (via
    // account_switcher_sheet → switchTenant), repaint from the new
    // tenant's local cache so we don't display the previous tenant's
    // pushka amount + goal during the network refresh window.
    ref.listen<AsyncValue<Map<String, dynamic>?>>(userProfileProvider, (prev, next) {
      final newTenantId = next.valueOrNull?['tenantId'] as String?;
      final uid = ref.read(currentUserProvider)?.uid;
      if (uid != null && newTenantId != null && newTenantId.isNotEmpty) {
        _loadFromCacheFor(uid, newTenantId);
      }
    });

    final userProfile = ref.watch(userProfileProvider).valueOrNull;
    final tenantState = ref.watch(tenantStateProvider).valueOrNull;
    final pushkaStyle = ref.watch(pushkaStyleProvider);
    final tenantId = userProfile?['tenantId'] as String?;
    final remoteGoal = tenantState?['pushkaGoal'];
    final remoteAmount = tenantState?['pushkaAmount'];
    final remotePresets = tenantState?['presetAmounts'];

    // Build a value-fingerprint of the fields we actually consume. Two
    // snapshots with the same fingerprint produce no observable change on
    // this screen, so we skip the post-frame entirely.
    final tenantStateFingerprint = tenantState == null
        ? null
        : '${tenantState['pushkaAmount']}|${tenantState['pushkaGoal']}|'
          '${tenantState['streakCount']}|'
          '${(tenantState['presetAmounts'] as List?)?.join(",") ?? ""}';
    if (tenantState != null && tenantStateFingerprint != _lastSyncedTenantStateFingerprint) {
      _lastSyncedTenantStateFingerprint = tenantStateFingerprint;
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
        if (remoteGoal is num) {
          final newGoal = remoteGoal.toDouble();
          if (newGoal != pushkaGoal) {
            pushkaGoal = newGoal;
            changed = true;
            if (uid != null && tenantId != null) {
              HiveCache.instance.savePushkaGoal(uid, tenantId, pushkaGoal);
            }
          }
        }
        if (remotePresets is List) {
          try {
            final parsed = remotePresets.whereType<num>().map((e) => e.toDouble()).toList();
            final newPresets = (parsed.length == 3 && parsed.every((v) => v > 0)) ? parsed : <double>[];
            if (newPresets.length != _presetAmounts.length || !newPresets.every((v) => _presetAmounts.contains(v))) {
              _presetAmounts = newPresets;
              changed = true;
            }
          } catch (_) {}
        }
        if (!_loadedRemote) {
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

            final int bannerStreak = _streakCount;
            final _HolidayInfo? bannerHoliday = activeHoliday;

            final content = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            _buildCombinedBanner(bannerStreak, bannerHoliday),

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
                    valueColor: const AlwaysStoppedAnimation<Color>(AppTokens.primaryBlue),
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

              const SizedBox(height: 14),

              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: OutlinedButton(
                      onPressed: _donateNow,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTokens.primaryBlue,
                        side: const BorderSide(color: AppTokens.primaryBlue, width: 1.6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        tr.donateNowBtn,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: emptyPushka,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTokens.primaryBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        tr.emptyPushkaBtn,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                  ),
                ),
              ]),
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
    final bool isEn = Localizations.localeOf(context).languageCode == 'en';
    final double streakW = pillW - (holiday?.key == 'roshHashana' ? (isEn ? 130 : 125) : holiday?.key == 'januca' && isEn ? 130 : holiday?.key == 'yomKippur' ? 135 : 120);
    const double holidayW = 168.0;

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
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: holiday.key == 'roshHashana'
                                ? const [Color(0xFFDCDCE8), Color(0xFF9898A8)]
                                : holiday.key == 'sucot'
                                ? const [Color(0xFFFEEDD8), Color(0xFFFCAB64)]
                                : holiday.key == 'purim' || holiday.key == 'januca' || holiday.key == 'yomKippur'
                                ? const [Color(0xFF222222), Color(0xFF000000)]
                                : const [Color(0xFF6B3800), Color(0xFF3A1A00)],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                        ),
                        // Combined: content pushed to the right 120px zone.
                        // Alone: content centered within the 120px pill.
                        padding: both
                            ? EdgeInsetsDirectional.fromSTEB(streakW, 0, 12, 0)
                            : EdgeInsets.only(left: holiday.key == 'sucot' ? 8.0 : 0.0, right: 8),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _holidayIcon(holiday.nameEs, size: 26),
                            const SizedBox(width: 10),
                            Text(
                              holiday.localizedBannerName(S.of(context)),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: (holiday.key == 'roshHashana' || holiday.key == 'yomKippur') && both ? 13.0 : 15.0,
                                fontWeight: FontWeight.w800,
                                shadows: const [
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
                        padding: holiday?.key == 'yomKippur' && both
                            ? const EdgeInsetsDirectional.fromSTEB(44, 0, 12, 0)
                            : const EdgeInsetsDirectional.fromSTEB(50, 0, 20, 0),
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
            child: _HexBadge(count: streakCount, color1: _hexColor1(streakCount), color2: _hexColor2(streakCount)),
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

  Color _hexColor1(int count) {
    final day = ((count - 1) % 7) + 1;
    if (day == 3) return const Color(0xFF81D4FA);
    return _streakColors(count).$1;
  }

  Color _hexColor2(int count) {
    final day = ((count - 1) % 7) + 1;
    if (day == 3) return const Color(0xFF29B6F6);
    return _streakColors(count).$2;
  }

  Widget _holidayIcon(String name, {double size = 28}) {
    final lower = name.toLowerCase();
    String? asset;
    String emoji = '✨';
    if (lower.contains('shavuot')) {
      asset = 'assets/icons/shavuot.png';
    } else if (lower.contains('pesaj') || lower.contains('jitim') || lower.contains('ma\u0027ot')) {
      asset = 'assets/icons/pesaj.png';
    } else if (lower.contains('rosh')) {
      asset = 'assets/icons/rosh_hashana.png';
    } else if (lower.contains('kipur')) {
      asset = 'assets/icons/yom_kipur.png';
    } else if (lower.contains('sucot')) {
      asset = 'assets/icons/sucot.png';
    } else if (lower.contains('januc')) {
      asset = 'assets/icons/januca.png';
    } else if (lower.contains('purim')) {
      asset = 'assets/icons/purim.png';
    }
    if (asset != null) {
      final img = Image.asset(asset, width: size, height: size, fit: BoxFit.contain);
      if (lower.contains('kipur')) {
        return Transform.translate(offset: const Offset(0, 4), child: img);
      }
      return img;
    }
    return Text(emoji, style: TextStyle(fontSize: size * 0.55));
  }
  Future<void> _showHolidayDonationDialog(_HolidayInfo holiday) async {
    final amountCtrl = TextEditingController();
    final messageCtrl = TextEditingController();
    bool dedicateOn = false;
    ({double amount, String message})? result;
    String? error;
    try {
      result = await showKeyboardSafeSheet<({double amount, String message})>(
        context: context,
        builder: (ctx, setDialogState) {
          final cs = Theme.of(ctx).colorScheme;
          double currentAmount() {
            final parsed = double.tryParse(amountCtrl.text.trim().replaceAll(',', '.'));
            return parsed ?? 0;
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _holidayIcon(holiday.nameEs, size: 28),
                    const SizedBox(width: 8),
                    Text(
                      holiday.localizedName(S.of(context)),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                holiday.localizedDescription(S.of(context)),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTokens.mutedText, fontSize: 14),
              ),
              const SizedBox(height: 18),
              // Amount field — same shape as the donate-now sheet.
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: S.of(context).amount,
                  floatingLabelStyle: TextStyle(color: cs.onSurfaceVariant),
                  hintText: '0',
                  prefixText: '${_shortSymbol(_currencyCodeFromProfile())} ',
                  errorText: error,
                  filled: true,
                  fillColor: cs.surface,
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outline)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outline)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                ),
                onChanged: (_) {
                  if (error != null) setDialogState(() => error = null);
                },
              ),
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setDialogState(() => dedicateOn = !dedicateOn),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: Checkbox(
                        value: dedicateOn,
                        onChanged: (v) => setDialogState(() => dedicateOn = v ?? false),
                        activeColor: AppTokens.primaryBlue,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(S.of(context).dedicateDonation,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                  ]),
                ),
              ),
              if (dedicateOn) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: messageCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: 240,
                  decoration: InputDecoration(
                    labelText: S.of(context).donationMessageLabel,
                    floatingLabelStyle: TextStyle(color: cs.onSurfaceVariant),
                    hintText: S.of(context).donationMessageHint,
                    filled: true,
                    fillColor: cs.surface,
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outline)),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outline)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    final amt = currentAmount();
                    if (amt <= 0) {
                      setDialogState(() => error = S.of(context).enterValidAmount);
                      return;
                    }
                    Navigator.pop(ctx, (
                      amount: amt,
                      message: dedicateOn ? messageCtrl.text.trim() : '',
                    ));
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTokens.primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(S.of(context).donateNowBtn, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ),
            ],
          );
        },
      );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), () {
        amountCtrl.dispose();
        messageCtrl.dispose();
      });
    }

    if (result == null || !mounted) return;
    await _processDirectDonation(
      result.amount,
      donorMessage: result.message.isEmpty ? null : result.message,
    );
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
                          floatingLabelStyle: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                          hintText: S.of(context).amountHint, prefixText: '\$ ', errorText: error,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 2),
                          ),
                        ),
                        onChanged: (_) { if (error != null) setDialogState(() => error = null); },
                      ),
                      const SizedBox(height: 16),
                      SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTokens.primaryBlue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                          if (value == null || value <= 0) { setDialogState(() => error = S.of(context).enterValidAmount); return; }
                          Navigator.pop(ctx, value);
                        },
                        child: Text(S.of(context).add, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                    ]),
    );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    }

    if (!mounted || result == null) return;
    await addAmount(result);
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
        // Unknown codes: surface the message but sanitize first — backend
        // could in theory throw `HttpsError("foo", err.stack)` which would
        // dump a multi-line trace into a SnackBar otherwise.
        _ => _sanitizeUserFacingError(error.message) ?? tr.couldNotStartPayment,
      };
    }
    if (error is StripeServiceException) {
      if (error.code == 'canceled') return tr.paymentCanceled;
      return tr.couldNotStartPayment;
    }
    if (error is Exception) {
      final raw = error.toString().replaceFirst('Exception: ', '');
      final sanitized = _sanitizeUserFacingError(raw);
      if (sanitized != null) return sanitized;
    }
    return tr.couldNotCompleteDonation;
  }

  /// Strips control chars + newlines + caps at 200 chars so a backend stack
  /// trace can never reach a SnackBar. Returns null when the input is empty
  /// or looks unsafe (very long, contains "/home/" or "node_modules" or
  /// "package:" path markers) so the caller falls back to a generic message.
  String? _sanitizeUserFacingError(String? raw) {
    if (raw == null) return null;
    final stripped = raw
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .trim();
    if (stripped.isEmpty || stripped == 'null') return null;
    final looksLikeStack = stripped.contains('/home/') ||
        stripped.contains('node_modules') ||
        stripped.contains('package:') ||
        stripped.length > 400;
    if (looksLikeStack) return null;
    return stripped.length > 200 ? '${stripped.substring(0, 200)}…' : stripped;
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

  bool _biometricEnabled() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    return (profile?['biometricAuthenticationEnabled'] as bool?) ?? false;
  }

  /// Optional designación picker. Returns `(false, null)` if the user dismissed
  /// the dialog → caller aborts. The picked reason is intentionally discarded:
  /// nothing is sent to Stripe metadata or written to Firestore.
  Future<(bool proceed, String? reason)> _resolveDonationReason() async {
    final reasons = S.of(context).defaultDonationReasons;
    final result = await showDonationReasonPicker(
      context: context,
      reasons: reasons,
    );
    if (result is DonationReasonSelected) return (true, result.reason);
    return (false, null);
  }

  /// Confirmation sheet for the Empty-Pushka flow. Mirrors the donate-now
  /// sheet visually (header + segmented selector + cards). When `auto` is
  /// chosen the body collapses to a single frequency dropdown; when `once`
  /// is chosen it surfaces designación + optional dedication.
  ///
  /// Returns null if the user dismissed the sheet → caller aborts.
  Future<({String? reason, String message, bool auto, double amount})?> _showEmptyPushkaSheet({
    required double amount,
  }) async {
    final tr = S.of(context);
    final reasons = tr.defaultDonationReasons;
    final messageCtrl = TextEditingController();
    String? selectedReason = reasons.first;
    bool dedicateOn = false;
    bool auto = false;
    // Partial chips appear only when the donor has explicitly enabled the
    // "Donaciones parciales" toggle in Settings. Default 100% (full empty).
    final partialEnabled = _partialPaymentsEnabled();
    int selectedPercent = 100;
    double currentAmount = amount;
    // Hide the Manual / Automático toggle when the user already has an
    // auto-empty schedule active — re-asking on every Vaciar tap is noisy.
    final tenantState = ref.read(tenantStateProvider).valueOrNull;
    final activeAutoFreq = tenantState?['autoEmptyFrequency'] as String?;
    final autoEmptyAlreadyActive = activeAutoFreq != null &&
        activeAutoFreq.isNotEmpty &&
        activeAutoFreq != 'manual';
    ({String? reason, String message, bool auto, double amount})? result;

    Color outline(BuildContext c) => Theme.of(c).colorScheme.outline;
    Color surface(BuildContext c) => Theme.of(c).colorScheme.surface;
    OutlineInputBorder defaultBorder(BuildContext c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: outline(c)),
        );
    OutlineInputBorder focusedBorder() => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6),
        );

    try {
      result = await showKeyboardSafeSheet<({String? reason, String message, bool auto, double amount})>(
        context: context,
        builder: (ctx, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SecureShieldIcon(size: 26),
                  const SizedBox(width: 8),
                  Text(tr.donateNowTitle,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (!autoEmptyAlreadyActive) ...[
              Row(children: [
                Expanded(
                  child: _FrequencyChip(
                    label: tr.emptyOnce,
                    selected: !auto,
                    onTap: () => setDialogState(() => auto = false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _FrequencyChip(
                    label: tr.emptyAuto,
                    selected: auto,
                    icon: Icons.autorenew_rounded,
                    iconColor: AppTokens.primaryBlue,
                    onTap: () => setDialogState(() => auto = true),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
            ],
            if (partialEnabled && !auto) ...[
              Row(
                children: [25, 50, 75, 100].map((p) {
                  final isSelected = selectedPercent == p;
                  final idx = [25, 50, 75, 100].indexOf(p);
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(start: idx == 0 ? 0 : 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => setDialogState(() {
                          selectedPercent = p;
                          currentAmount = amount * p / 100.0;
                        }),
                        child: Container(
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppTokens.primaryBlue.withValues(alpha: 0.12)
                                : surface(ctx),
                            border: Border.all(
                              color: isSelected ? AppTokens.primaryBlue : outline(ctx),
                              width: isSelected ? 1.6 : 1,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$p%',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                              color: Theme.of(ctx).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
            ],
            // Amount preview — read-only header line.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: surface(ctx),
                border: Border.all(color: outline(ctx)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(
                    formatMoney(currentAmount),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(ctx).colorScheme.onSurface,
                    ),
                  ),
                ),
                Text(
                  _currencyCodeFromProfile().toUpperCase(),
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ]),
            ),
            if (!auto) ...[
              const SizedBox(height: 14),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final picked = await showDonationReasonPicker(
                    context: ctx,
                    reasons: reasons,
                    currentSelection: selectedReason,
                  );
                  if (picked is DonationReasonSelected) {
                    setDialogState(() => selectedReason = picked.reason);
                  }
                },
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: tr.donationReasonTitle,
                    filled: true,
                    fillColor: surface(ctx),
                    enabledBorder: defaultBorder(ctx),
                    border: defaultBorder(ctx),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        selectedReason ?? tr.donationReasonNone,
                        style: TextStyle(
                          fontSize: 16,
                          color: selectedReason == null
                              ? Theme.of(ctx).colorScheme.onSurfaceVariant
                              : Theme.of(ctx).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down_rounded,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setDialogState(() => dedicateOn = !dedicateOn),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: Checkbox(
                        value: dedicateOn,
                        onChanged: (v) => setDialogState(() => dedicateOn = v ?? false),
                        activeColor: AppTokens.primaryBlue,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(tr.dedicateDonation,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                  ]),
                ),
              ),
              if (dedicateOn) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: messageCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: 240,
                  decoration: InputDecoration(
                    labelText: tr.donationMessageLabel,
                    floatingLabelStyle: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                    hintText: tr.donationMessageHint,
                    filled: true,
                    fillColor: surface(ctx),
                    enabledBorder: defaultBorder(ctx),
                    border: defaultBorder(ctx),
                    focusedBorder: focusedBorder(),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTokens.primaryBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  if (auto) {
                    // Push AutoEmptyScreen ON TOP so back returns to the
                    // still-open sheet. popExtra=true makes save dismiss
                    // both AutoEmpty AND this sheet, dropping the user
                    // back on Mi Pushka.
                    Navigator.of(ctx, rootNavigator: true).push(
                      MaterialPageRoute(
                        builder: (_) => const AutoEmptyScreen(popExtra: true),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(ctx, (
                    reason: selectedReason,
                    message: dedicateOn ? messageCtrl.text.trim() : '',
                    auto: false,
                    amount: currentAmount,
                  ));
                },
                child: Text(
                  auto ? tr.emptyAutoBtn : tr.emptyPushkaBtn,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), messageCtrl.dispose);
    }
    return result;
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
      case 'uyu':
        return [50, 200, 500];
      case 'pen':
        return [5, 20, 50];
      case 'bob':
        return [10, 30, 50];
      case 'gtq':
        return [10, 30, 50];
      case 'dop':
        return [100, 300, 600];
      case 'aud':
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
    // Inline TextField for monto acumulado (replaced the prior tap-to-edit
    // dialog) so the user can edit it the same way as the presets.
    final amountAccCtrl = TextEditingController(text: _formatPresetValue(displayedAmount));
    // Inline TextField for the pushka goal — replaced the prior tap-to-open
    // bottom-sheet picker. The user prefers a single editable field over
    // a list of preset goals; "Otro" is no longer needed because every
    // value is freely typable.
    final goalCtrl = TextEditingController(text: _formatPresetValue(selectedGoal));
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
                  TextField(
                    controller: goalCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      prefixText: '$symbol ',
                      prefixStyle: TextStyle(
                        fontSize: 16,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                      filled: true,
                      fillColor: cs.surface,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outline),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppTokens.primaryBlue, width: 2),
                      ),
                    ),
                    onChanged: (value) {
                      final parsed = double.tryParse(value.replaceAll(',', '.'));
                      if (parsed != null && parsed > 0) {
                        selectedGoal = parsed;
                      }
                    },
                  ),

                  // ── Monto acumulado ──────────────────────────────────
                  // Inline TextField (mismo patrón que los presets) en
                  // lugar del antiguo tap-to-open dialog. Los cambios se
                  // confirman al tocar Guardar abajo, junto con presets +
                  // meta. El estilo coincide con Settings (filled surface
                  // + cs.outline + 12 radius + 16/14 padding).
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
                  const SizedBox(height: 8),
                  TextField(
                    controller: amountAccCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      prefixText: '$symbol ',
                      prefixStyle: TextStyle(
                        fontSize: 16,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                      filled: true,
                      fillColor: cs.surface,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outline),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppTokens.primaryBlue, width: 2),
                      ),
                    ),
                    onChanged: (value) {
                      final parsed = double.tryParse(value.replaceAll(',', '.'));
                      if (parsed != null && parsed >= 0) {
                        final capped = pushkaGoal > 0
                            ? parsed.clamp(0.0, pushkaGoal)
                            : parsed.clamp(0.0, 100000.0);
                        displayedAmount = capped;
                      }
                    },
                  ),

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
                              filled: true,
                              fillColor: cs.surface,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: cs.outline),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: cs.outline),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: AppTokens.primaryBlue, width: 2),
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
                  // Cancelar button removed by request — the user can
                  // dismiss the sheet by swiping down or tapping the
                  // dim barrier, so the explicit button was redundant.
                      ],
                    );
      },
    );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), () {
        ctrl1.dispose();
        ctrl2.dispose();
        ctrl3.dispose();
        amountAccCtrl.dispose();
        goalCtrl.dispose();
      });
    }

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).settingsApplied)),
      );
    }
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
    'maotJitim' => tr.holidayPesaj,
    'shavuot' => tr.holidayShavuot,
    'roshHashana' => tr.holidayRoshHashana,
    'yomKippur' => tr.holidayYomKippur,
    'sucot' => tr.holidaySucot,
    'januca' => tr.holidayJanuca,
    'purim' => tr.holidayPurim,
    _ => nameEs,
  };

  String localizedBannerName(S tr) => switch (key) {
    'roshHashana' => tr.holidayRoshHashanaBanner,
    _ => localizedName(tr),
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
            child: ColorFiltered(
              colorFilter: const ColorFilter.matrix([
                0.2126, 0.7152, 0.0722, 0, 0,
                0.2126, 0.7152, 0.0722, 0, 0,
                0.2126, 0.7152, 0.0722, 0, 0,
                0,      0,      0,      1, 0,
              ]),
              child: Image.asset(
                'assets/icons/gem_badge.png',
                width: size,
                height: size,
                fit: BoxFit.contain,
              ),
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

/// Pill toggle for the donation-frequency selector ("Donar una vez" /
/// "Mensual"). Selected state mirrors the rest of the picker convention:
/// AppTokens.primaryBlue border + tinted background.
/// Shield-with-lock icon used in the donation-secure header. Sources the
/// asset bundled at `assets/images/secure_shield.jpeg`.
class _SecureShieldIcon extends StatelessWidget {
  const _SecureShieldIcon({this.size = 26});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/secure_shield.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}

class _FrequencyChip extends StatelessWidget {
  const _FrequencyChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.iconColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppTokens.primaryBlue.withValues(alpha: 0.08) : cs.surface,
          border: Border.all(
            color: selected ? AppTokens.primaryBlue : cs.outline,
            width: selected ? 1.6 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: iconColor ?? cs.onSurface, size: 18),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

