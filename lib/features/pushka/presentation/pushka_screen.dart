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
import '../../../core/network_status_provider.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

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
import '../domain/streak.dart';

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
  // Coin animation (classic pushka style). Bill is for 770. We track them
  // separately so a fast-tap during the bill flight doesn't fire a coin and
  // vice-versa — each style stays self-contained.
  bool _showCoin = false;
  int _coinKey = 0;
  double _coinStartY = -90.0;
  double _coinTargetY = 200.0;
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
  // Round-7 regression fix: tag the recent-write with its tenantId so a
  // switch to a different tenant does NOT let the guard block the new
  // tenant's first sync. Previously the un-scoped stopwatch would still
  // report `recentWrite=true` up to 4s after donating in A, silently
  // dropping the incoming pushkaAmount for B.
  String? _localWriteTenantId;
  // Fingerprint of the relevant fields from the last tenantState snapshot
  // we synced to local state. Compared as a value so two snapshots with
  // the same numbers but different Map identity (Riverpod re-emits new map
  // instances frequently — e.g. serverTimestamp resolution, neighbouring
  // field touches) don't re-enqueue a useless post-frame callback. The
  // earlier `identical()` check missed those, scheduling work on every
  // tick even though nothing about pushka had actually changed.
  //
  // Round-7 regression fix (HIGH #1): also tag with the tenantId. If two
  // tenants share the same fingerprint values (both freshly onboarded,
  // both at defaults), the fingerprint match used to block the sync when
  // switching between them.
  String? _lastSyncedTenantStateFingerprint;
  String? _lastSyncedFingerprintTenantId;
  String? _lastLoadedCacheTenantId;

  /// uid del que se cargó el caché actualmente pintado.
  ///
  /// Va SIEMPRE junto a `_lastLoadedCacheTenantId`. La identidad de lo que se
  /// muestra en esta pantalla es el par (uid, tenantId): mirar solo el tenant
  /// deja pasar dos cuentas distintas dentro de la misma organización.
  String? _lastLoadedCacheUid;

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
    final tenantId =
        ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    _loadFromCacheFor(uid, tenantId);
  }

  /// Reads the (uid, tenantId)-scoped cached pushka amount + goal into
  /// local state. Called on first mount AND cuando cambia el usuario o la
  /// organización activa (via el listener de build()), para repintar desde
  /// el caché correcto en vez de dejar en pantalla los números del anterior.
  ///
  /// La guarda compara uid Y tenantId. Antes miraba solo el tenantId, y eso
  /// dejaba pasar el caso real de dos cuentas distintas en la MISMA
  /// organización: cerrar sesión e iniciar con otro usuario no reseteaba
  /// nada, y quedaban en pantalla el monto, la meta y la racha del usuario
  /// anterior hasta que la pantalla se destruyera. En un celular compartido
  /// eso es mostrarle a alguien el saldo de otra persona.
  void _loadFromCacheFor(String uid, String tenantId) {
    if (_lastLoadedCacheUid == uid && _lastLoadedCacheTenantId == tenantId) {
      return;
    }
    _lastLoadedCacheUid = uid;
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
      // Currency-aware fallback (was hardcoded 3600 which is way too high
      // for USD/EUR — showed an unreachable "$3,600 goal" out of the box —
      // and way too low for ARS/CLP/COP where 3600 barely covers a bus fare).
      // Uses the same calibrated table as UserRepository.defaultGoalForCurrency
      // (mirrored server-side in functions/index.js::defaultGoalForCurrency).
      pushkaGoal =
          cachedGoal ??
          UserRepository.defaultGoalForCurrency(_currencyCodeFromProfile());
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
    final tenantId =
        ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
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

    // Si ya se contó hoy no hay nada que escribir: evita una escritura por
    // cada monto que el usuario agregue en el día.
    if (lastDate != null &&
        DateTime(lastDate.year, lastDate.month, lastDate.day) == today) {
      return;
    }

    final stored =
        (tenantState['streakCount'] as num?)?.toInt() ?? _streakCount;
    _streakCount = streakAfterActivity(
      stored: stored,
      lastActivity: lastDate,
      today: today,
    );

    if (mounted) setState(() {});
    try {
      await ref
          .read(userRepositoryProvider)
          .updateTenantState(
            uid: user.uid,
            tenantId: tenantId,
            streakCount: _streakCount,
            lastStreakDate: today,
          );
    } catch (e, st) {
      _reportError(e, st, op: 'updateStreak');
    }
  }

  Future<void> addAmount(
    double amount, {
    bool skipBillAnimation = false,
  }) async {
    // Prevent adding to a full pushka (already reached goal).
    if (pushkaGoal > 0 && pushkaAmount >= pushkaGoal) return;
    // Clamp so we never exceed the goal.
    final headroom = pushkaGoal > 0
        ? (pushkaGoal - pushkaAmount)
        : double.infinity;
    final clamped = pushkaGoal > 0 ? amount.clamp(0.0, headroom) : amount;
    if (clamped <= 0) return;

    final wasFull = pushkaGoal > 0 && pushkaAmount >= pushkaGoal;
    setState(() => pushkaAmount += clamped);
    final nowFull = pushkaGoal > 0 && pushkaAmount >= pushkaGoal;
    final goalJustReached = !wasFull && nowFull;
    if (goalJustReached) {
      _triggerCelebration();
    } else if (!skipBillAnimation) {
      _launchFallingAnimation();
    }
    // Round-8 audit CRITICAL fix: persist the DELTA via FieldValue.increment
    // instead of writing the local absolute total. Two devices adding
    // concurrently used to silently lose one of the increments because
    // both wrote `base + delta` from the same base snapshot.
    try {
      await _persistPushkaDelta(clamped);
    } catch (_) {
      // Persistence failure is non-critical: local state is updated and
      // the next tenantState snapshot reconciles.
    }
    _updateStreak();
  }

  Future<void> _persistPushkaDelta(double delta) async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    final tenantId =
        ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    _localWriteTenantId = tenantId;
    _localWriteStopwatch
      ..reset()
      ..start();
    await Future.wait([
      ref
          .read(userRepositoryProvider)
          .incrementPushkaAmount(
            uid: user.uid,
            tenantId: tenantId,
            delta: delta,
          ),
      HiveCache.instance.savePushkaAmount(user.uid, tenantId, pushkaAmount),
    ]);
  }

  /// Reads the tenant's default PM from tenantState (Direct Charges model)
  /// and returns a DefaultCardInfo the StripeService can use to render the
  /// express-checkout confirmation sheet BEFORE opening the full PaymentSheet
  /// picker. Returns null when the user has no default cached — pay() then
  /// falls through to the picker directly.
  DefaultCardInfo? _readDefaultCard() {
    final ts = ref.read(tenantStateProvider).valueOrNull;
    if (ts == null) return null;
    final id = ts['stripeConnectDefaultPaymentMethodId'] as String?;
    final brand = ts['stripeConnectDefaultPaymentMethodBrand'] as String?;
    final last4 = ts['stripeConnectDefaultPaymentMethodLast4'] as String?;
    if (id == null ||
        id.isEmpty ||
        brand == null ||
        brand.isEmpty ||
        last4 == null ||
        last4.isEmpty) {
      return null;
    }
    return DefaultCardInfo(id: id, brand: brand, last4: last4);
  }

  Future<void> emptyPushka() async {
    if (_isProcessing) return;
    // Warm empty-state hint instead of silent no-op: previously tapping
    // "Vaciar Pushka" with amount=0 did nothing (early return), which looked
    // broken. Show a friendly snackbar so the donor knows to add coins first.
    if (pushkaAmount <= 0) {
      if (!mounted) return;
      final tr = S.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr.pushkaEmptyHint),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }
    // Offline gate: payments require a live CF call. Bail with a friendly
    // dialog instead of firing a callable that will fail with a scary
    // network error. Firestore-cached data (pushka amount, history) keeps
    // working while offline — only the checkout / auto-empty path is gated.
    if (!await _ensureOnlineForPayment()) return;
    if (!mounted) return;
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
      final maxCents = _maxAmountCentsForCurrency(currency);

      if (amountCents < minCents) {
        if (!mounted) return;
        _showMinAmountDialog(currency, minCents, amountToEmpty);
        return;
      }
      if (amountCents > maxCents) {
        if (!mounted) return;
        _showMaxAmountDialog(currency, maxCents, amountToEmpty);
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
      final remaining = (pushkaAmount - amountToEmpty).clamp(
        0.0,
        double.infinity,
      );

      // Pass the active tenantId so the pushka-empty lock release (on
      // cancel/failure) scopes to the same tenant the CF locked — multi-
      // tenant donors would otherwise release the wrong lock.
      final activeTenantId =
          ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
      await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: ref.read(currentUserProvider)?.email,
        purpose: 'pushka_empty',
        merchantDisplayName:
            ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
        donorMessage: details.message.isEmpty ? null : details.message,
        pushkaAmountAfter: remaining,
        tenantId: activeTenantId,
        sheetContext: context,
        defaultCard: _readDefaultCard(),
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
        SnackBar(
          content: Text(
            remaining > 0
                ? tr.paymentProcessedRemaining(
                    formatCurrencyAmount(remaining, _currencyCodeFromProfile()),
                  )
                : tr.pushkaEmptied,
          ),
        ),
      );
    } catch (error, st) {
      // User-canceled flows aren't bugs — don't pollute Crashlytics with them.
      final isUserCancel =
          error is StripeServiceException && error.code == 'canceled';
      if (!isUserCancel) {
        _reportError(error, st, op: 'emptyPushka');
      }
      if (!mounted) return;
      final reason = _donationErrorMessage(error, tr);
      if (isUserCancel) {
        // Cancels are not payment failures — keep the lightweight SnackBar
        // so users who dismissed the sheet don't get a scary alert.
        _showError(reason);
      } else {
        _showDonationErrorDialog(reason, () {
          if (mounted) emptyPushka();
        });
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _donateNow() async {
    if (_isProcessing) return;
    // Set _isProcessing IMMEDIATELY to block re-entrant triggers (banner tap,
    // deep link, notification tap) while the amount sheet is still open. The
    // previous code set the flag AFTER the sheet closed (line 574) leaving a
    // multi-second window where a second _donateNow could open a parallel
    // sheet → 2 createPaymentIntent calls → 2 charges (MF2 adversarial).
    // The old _isProcessing=true on line 574 is now redundant (removed).
    setState(() => _isProcessing = true);
    try {
      if (!await _ensureOnlineForPayment()) return;
      if (!mounted) return;
      final tr = S.of(context);
      // Prefer the tenant's custom donationReasons; fall back to the locale's
      // default list only when the tenant hasn't configured one. Pre-fix this
      // ignored the tenant config entirely, so admin-web changes to the
      // designation list never showed up on the donor screen.
      final tenantReasons =
          ref.read(tenantConfigProvider).valueOrNull?.donationReasons ??
          const <String>[];
      final reasons = tenantReasons.isNotEmpty
          ? tenantReasons
          : tr.defaultDonationReasons;
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
                    Text(
                      tr.donateNowTitle,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Monthly (recurring) chip: enabled on web too in
              // Stage 6 — StripeService.subscribe() now routes to
              // the Elements inline sheet on web via
              // showWebDonationSheet(recurringInterval: 'month').
              Row(
                children: [
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
                      iconColor: const Color(0xFFCC2936),
                      onTap: () => setDialogState(() => monthly = true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: tr.amount,
                  floatingLabelStyle: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                  hintText: '0',
                  // Round-10 audit fix (LOW #1): no trailing space —
                  // shortCurrencySymbol already appends one for
                  // unknown codes ('PEN '), producing double-spaces.
                  prefixText: _shortSymbol(_currencyCodeFromProfile()),
                  suffixText: _currencyCodeFromProfile().toUpperCase(),
                  errorText: error,
                  filled: true,
                  fillColor: Theme.of(ctx).colorScheme.surface,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(ctx).colorScheme.outline,
                    ),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(ctx).colorScheme.outline,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: AppTokens.primaryBlue,
                      width: 1.6,
                    ),
                  ),
                ),
                onChanged: (_) {
                  if (error != null) setDialogState(() => error = null);
                },
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
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Theme.of(ctx).colorScheme.outline,
                        ),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Theme.of(ctx).colorScheme.outline,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
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
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setDialogState(() => dedicateOn = !dedicateOn),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: dedicateOn,
                          onChanged: (v) =>
                              setDialogState(() => dedicateOn = v ?? false),
                          activeColor: AppTokens.primaryBlue,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        tr.dedicateDonation,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
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
                    floatingLabelStyle: TextStyle(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                    hintText: tr.donationMessageHint,
                    filled: true,
                    fillColor: Theme.of(ctx).colorScheme.surface,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Theme.of(ctx).colorScheme.outline,
                      ),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Theme.of(ctx).colorScheme.outline,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: AppTokens.primaryBlue,
                        width: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
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
                  onPressed: () {
                    final value = double.tryParse(
                      amountCtrl.text.trim().replaceAll(',', '.'),
                    );
                    if (value == null || value <= 0) {
                      setDialogState(() => error = tr.enterValidAmount);
                      return;
                    }
                    final msg = dedicateOn ? messageCtrl.text.trim() : '';
                    Navigator.pop(ctx, {
                      'amount': value,
                      'reason': selectedReason,
                      'message': msg,
                      'monthly': monthly,
                    });
                  },
                  child: Text(
                    monthly ? tr.donateMonthlyBtn : tr.donate,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
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
      final donationReason = (result['reason'] as String?)?.trim();
      final isMonthly = result['monthly'] == true;

      // Note: _isProcessing was already set at the top of _donateNow (MF2
      // fix — blocks re-entry BEFORE the amount sheet opens). No re-set here.
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
        final maxCents = _maxAmountCentsForCurrency(currency);
        if (amountCents < minCents) {
          if (!mounted) return;
          _showMinAmountDialog(currency, minCents, donationAmount);
          return;
        }
        if (amountCents > maxCents) {
          if (!mounted) return;
          _showMaxAmountDialog(currency, maxCents, donationAmount);
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
            donationReason: (donationReason == null || donationReason.isEmpty)
                ? null
                : donationReason,
            merchantDisplayName:
                ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
            sheetContext: context,
          );
        } else {
          await StripeService.instance.pay(
            amountCents: amountCents,
            currency: currency,
            customerEmail: ref.read(currentUserProvider)?.email,
            purpose: 'donation',
            merchantDisplayName:
                ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
            donorMessage: donationMessage.isEmpty ? null : donationMessage,
            donationReason: (donationReason == null || donationReason.isEmpty)
                ? null
                : donationReason,
            sheetContext: context,
            defaultCard: _readDefaultCard(),
          );
        }

        await AnalyticsService.instance.logDonation(donationAmount, currency);
        // Transaction is written server-side by the Stripe webhook (payment_intent.succeeded).

        FeedbackService.instance.playSuccess();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                S
                    .of(context)
                    .donationProcessed(
                      formatCurrencyAmount(
                        donationAmount,
                        _currencyCodeFromProfile(),
                      ),
                    ),
              ),
            ),
          );
        }
      } catch (error, st) {
        final isUserCancel =
            error is StripeServiceException && error.code == 'canceled';
        if (!isUserCancel) {
          _reportError(error, st, op: 'donateNow');
        }
        if (!mounted) return;
        final reason = _donationErrorMessage(error, S.of(context));
        if (isUserCancel) {
          _showError(reason);
        } else {
          // Retry re-opens the donate-now sheet from scratch. We do NOT
          // stash the previous amount/reason/message — a failed payment
          // often means the donor picked the wrong card or amount, so
          // letting them start fresh is friendlier than auto-resubmitting.
          _showDonationErrorDialog(reason, () {
            if (mounted) _donateNow();
          });
        }
      }
    } finally {
      // Outer try opened at top of _donateNow (MF2). Resets _isProcessing
      // even if the amount sheet was dismissed early, biometric failed, or
      // an unexpected exception escaped the inner try/catch above.
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _processCardPayment(
    double donationAmount, {
    String? donorMessage,
    String? donationReason,
  }) async {
    if (!mounted) return;
    if (!await _ensureOnlineForPayment()) return;
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
      final maxCents = _maxAmountCentsForCurrency(currency);
      if (amountCents < minCents) {
        if (!mounted) return;
        _showMinAmountDialog(currency, minCents, donationAmount);
        return;
      }
      if (amountCents > maxCents) {
        if (!mounted) return;
        _showMaxAmountDialog(currency, maxCents, donationAmount);
        return;
      }
      // Si el caller ya nos pasó una razón (flujo de festividad → "Pesaj",
      // "Janucá", etc.), saltamos el picker — fuerza pre-categorizar la
      // donación en el admin sin preguntarle al donor otra vez.
      String? finalReason = donationReason;
      if (finalReason == null) {
        final (proceed, picked) = await _resolveDonationReason();
        if (!proceed || !mounted) return;
        finalReason = picked;
      }

      await StripeService.instance.pay(
        amountCents: amountCents,
        currency: currency,
        customerEmail: ref.read(currentUserProvider)?.email,
        purpose: 'donation',
        merchantDisplayName:
            ref.read(tenantConfigProvider).valueOrNull?.appName ?? 'Pushka',
        donorMessage: donorMessage,
        donationReason: finalReason,
        sheetContext: context,
        defaultCard: _readDefaultCard(),
      );

      await AnalyticsService.instance.logDonation(donationAmount, currency);
      // Transaction is written server-side by the Stripe webhook (payment_intent.succeeded).
      final remaining = (pushkaAmount - donationAmount).clamp(
        0.0,
        double.infinity,
      );
      // MF4: on web, DON'T write pushkaAmount from the client — the webhook
      // is the single writer via processed_events + Firestore transaction.
      // Double-writing here can clobber a webhook that already ran (e.g. a
      // fast 3DS-less card whose success arrived before this line). The
      // tenantState listener reconciles the UI within seconds. On native
      // the client is still the primary writer for the donation path
      // (webhook writes only for pushka_empty), so keep the sync there.
      if (!kIsWeb) {
        await _persistPushkaAmount(overrideAmount: remaining);
      }
      if (!mounted) return;
      setState(() => pushkaAmount = remaining);

      FeedbackService.instance.playSuccess();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            remaining > 0
                ? tr.paymentProcessedRemaining(
                    formatCurrencyAmount(remaining, _currencyCodeFromProfile()),
                  )
                : tr.paymentProcessedHistory,
          ),
        ),
      );
    } catch (error, st) {
      final isUserCancel =
          error is StripeServiceException && error.code == 'canceled';
      if (!isUserCancel) {
        _reportError(error, st, op: 'processCardPayment');
      }
      if (!mounted) return;
      final reason = _donationErrorMessage(error, tr);
      if (isUserCancel) {
        _showError(reason);
      } else {
        _showDonationErrorDialog(reason, () {
          if (mounted) {
            _processCardPayment(
              donationAmount,
              donorMessage: donorMessage,
              donationReason: donationReason,
            );
          }
        });
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _processDirectDonation(
    double amount, {
    String? donorMessage,
    String? donationReason,
  }) async {
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

    await _processCardPayment(
      amount,
      donorMessage: donorMessage,
      donationReason: donationReason,
    );
  }

  double get fillPercentage {
    if (pushkaGoal <= 0) return 0;
    final percentage = (pushkaAmount / pushkaGoal).clamp(0.0, 1.0);
    return percentage;
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    // Cache Theme + ColorScheme + brightness once per build. Theme.of() is
    // an InheritedWidget lookup — cheap, but called 6+ times in this build
    // tree, and a few of the call sites previously did `Theme.of(context).
    // colorScheme...Theme.of(context).colorScheme...` patterns that read
    // worse than just having `cs` and `isDark` available.
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Reacciona a los cambios de IDENTIDAD: cambio de usuario (cerrar sesión
    // e iniciar con otra cuenta) o cambio de organización (switchTenant desde
    // el selector de cuentas). En los dos casos hay que repintar desde el
    // caché correcto para no dejar en pantalla los números del anterior
    // mientras llega la red.
    ref.listen<AsyncValue<Map<String, dynamic>?>>(userProfileProvider, (
      prev,
      next,
    ) {
      final newTenantId = next.valueOrNull?['tenantId'] as String?;
      final uid = ref.read(currentUserProvider)?.uid;
      if (uid != null && newTenantId != null && newTenantId.isNotEmpty) {
        // Round-7 regression fix: cuando cambia la identidad, se descarta
        // cualquier guarda de escritura reciente y se limpia la huella de
        // sincronización, para que el tenantState entrante siempre se
        // aplique — aunque su huella numérica coincida por casualidad con
        // la anterior.
        //
        // La comparación incluye el UID, no solo el tenantId. Antes miraba
        // solo el tenant, y eso dejaba pasar el caso real: dos cuentas
        // distintas DENTRO DE LA MISMA organización. Cerrar sesión e
        // iniciar con otra cuenta no reseteaba nada y quedaban pintados el
        // monto, la meta y la racha del usuario anterior hasta que la
        // pantalla se destruyera. Reportado con la cuenta de prueba de
        // Google Play: una cuenta recién creada mostraba racha de 1 día.
        final identityChanged =
            _lastLoadedCacheUid != uid ||
            _lastLoadedCacheTenantId != newTenantId;
        if (identityChanged) {
          _localWriteStopwatch.reset();
          _localWriteTenantId = null;
          _lastSyncedTenantStateFingerprint = null;
          _lastSyncedFingerprintTenantId = null;
          // Round-9 regression fix: streakCount está detrás de
          // `if (!_loadedRemote)` en el bloque de sincronización, lo que lo
          // convierte en un one-shot por instancia de pantalla. Sin
          // reiniciar `_loadedRemote` acá, el banner sigue pintando la
          // racha anterior hasta que el usuario done o se destruya la
          // pantalla. Se limpia `_streakCount` para no mostrar el valor
          // viejo mientras llega el snapshot nuevo.
          _loadedRemote = false;
          setState(() => _streakCount = 0);
        }
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
    //
    // Round-7 regression fix (HIGH #1): scope by tenantId so two tenants
    // with identical values (both fresh-onboarded at defaults) don't fool
    // the fingerprint check into skipping the very first sync of the new
    // tenant after a switch.
    final tenantStateFingerprint = tenantState == null
        ? null
        : '${tenantState['pushkaAmount']}|${tenantState['pushkaGoal']}|'
              '${tenantState['streakCount']}|'
              '${(tenantState['presetAmounts'] as List?)?.join(",") ?? ""}';
    final fingerprintMatches =
        tenantStateFingerprint == _lastSyncedTenantStateFingerprint &&
        tenantId == _lastSyncedFingerprintTenantId;

    // Cinturón de seguridad: NUNCA pintar un snapshot que no sea del usuario
    // logueado. `tenantState` lleva el campo `uid` de su dueño (lo exige
    // validTenantStateFields en firestore.rules), así que se puede comprobar
    // directamente en vez de confiar en que los providers se invaliden en el
    // orden correcto.
    //
    // Sin esto, quedaba una ventana entre que cambia el usuario y que el
    // provider de tenantState emite el documento nuevo, durante la cual se
    // pintaban los datos del usuario anterior. Con dos cuentas en la misma
    // organización ese estado podía quedar pegado indefinidamente.
    final currentUid = ref.watch(currentUserProvider)?.uid;
    final snapshotUid = tenantState?['uid'] as String?;
    final snapshotBelongsToCurrentUser =
        currentUid != null &&
        (snapshotUid == null || snapshotUid == currentUid);

    if (tenantState != null &&
        !fingerprintMatches &&
        snapshotBelongsToCurrentUser) {
      _lastSyncedTenantStateFingerprint = tenantStateFingerprint;
      _lastSyncedFingerprintTenantId = tenantId;
      final uid = ref.read(currentUserProvider)?.uid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        bool changed = false;
        // Sync local pushkaAmount with the remote tenantState snapshot,
        // EXCEPT during the recent-write window: stream snapshots that
        // pre-date our own write would otherwise revert the optimistic
        // setState. 4-second window comfortably outlasts write+echo.
        // Stopwatch is monotonic (no system-clock-jump risk).
        //
        // Round-7 regression fix (CRITICAL): honor the recentWrite guard
        // ONLY when the incoming snapshot belongs to the same tenant the
        // write was for. Otherwise a donation in A blocked B's first
        // pushkaAmount sync for up to 4s after switching.
        if (remoteAmount is num) {
          final remote = remoteAmount.toDouble();
          final recentWrite =
              _localWriteStopwatch.isRunning &&
              _localWriteStopwatch.elapsed.inSeconds < 4 &&
              _localWriteTenantId == tenantId;
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
            final parsed = remotePresets
                .whereType<num>()
                .map((e) => e.toDouble())
                .toList();
            final newPresets =
                (parsed.length == 3 && parsed.every((v) => v > 0))
                ? parsed
                : <double>[];
            if (newPresets.length != _presetAmounts.length ||
                !newPresets.every((v) => _presetAmounts.contains(v))) {
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
      maintainBottomViewPadding: true,
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

            // La racha que se MUESTRA no es la guardada: es la vigente hoy.
            //
            // `streakCount` en Firestore es el valor de la última vez que
            // hubo actividad y no caduca solo. Pintarlo tal cual hacía que
            // alguien que dejó de dar hace semanas siguiera viendo su racha
            // vieja intacta, hasta que volviera a agregar un monto.
            final int bannerStreak = currentStreak(
              stored: _streakCount,
              lastActivity: (tenantState?['lastStreakDate'] as Timestamp?)
                  ?.toDate(),
              today: DateTime.now(),
            );
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
                      color: cs.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr.donationGoalReached,
                    style: TextStyle(
                      color: isDark ? cs.onSurfaceVariant : AppTokens.mutedText,
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
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // En RTL Flutter no reordena tokens latinos (MX$..., números),
                  // los pinta en el orden literal del string. Invertimos a mano
                  // así el monto actual queda a la derecha (lado de partida del
                  // ojo en hebreo) y la meta a la izquierda, espejando el LTR.
                  Builder(
                    builder: (ctx) {
                      final symbol = _currencySymbol(
                        _currencyCodeFromProfile(),
                      );
                      final amountStr = '$symbol${formatAmount(pushkaAmount)}';
                      final goalStr = '$symbol${formatAmount(pushkaGoal)}';
                      final isRtl = Directionality.of(ctx) == TextDirection.rtl;
                      final str = isRtl
                          ? '$goalStr / $amountStr'
                          : '$amountStr / $goalStr';
                      return Text(
                        str,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurfaceVariant,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: constraints.maxWidth * 0.09,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: fillPercentage,
                        minHeight: 4,
                        backgroundColor: cs.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDark ? Colors.white : AppTokens.primaryBlue,
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
                            currencySymbol: _currencySymbol(
                              _currencyCodeFromProfile(),
                            ),
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
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        tr.emptyPushkaBtn,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: _showTzedakahSettingsDialog,
                    child: Text(
                      tr.changePushkaGoal,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      _moneyBtn(
                        _formatQuickAmount(quickAmounts[0]),
                        () => addAmount(quickAmounts[0]),
                      ),
                      const SizedBox(width: 10),
                      _moneyBtn(
                        _formatQuickAmount(quickAmounts[1]),
                        () => addAmount(quickAmounts[1]),
                      ),
                      const SizedBox(width: 10),
                      _moneyBtn(
                        _formatQuickAmount(quickAmounts[2]),
                        () => addAmount(quickAmounts[2]),
                      ),
                      const SizedBox(width: 10),
                      _moneyBtn(tr.otherAmount, _otherAmount),
                    ],
                  ),

                  const SizedBox(height: 14),

                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 50,
                          child: OutlinedButton(
                            onPressed: _donateNow,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: isDark
                                  ? Colors.white
                                  : AppTokens.primaryBlue,
                              side: BorderSide(
                                color: isDark
                                    ? Colors.white
                                    : AppTokens.primaryBlue,
                                width: 1.6,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                tr.donateNowBtn,
                                maxLines: 1,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
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
                              backgroundColor: isDark
                                  ? Colors.white
                                  : AppTokens.primaryBlue,
                              foregroundColor: isDark
                                  ? cs.surface
                                  : Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                tr.emptyPushkaBtn,
                                maxLines: 1,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                        ),
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
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
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
                        onDone: () {
                          if (mounted) setState(() => _showBill = false);
                        },
                      ),
                    ),
                  ),
                if (_showCoin)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CoinFallAnimation(
                        key: ValueKey(_coinKey),
                        startY: _coinStartY,
                        targetY: _coinTargetY,
                        onDone: () {
                          if (mounted) setState(() => _showCoin = false);
                        },
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
    final double streakW =
        pillW -
        (holiday?.key == 'roshHashana'
            ? (isEn ? 142 : 137)
            : holiday?.key == 'januca' && isEn
            ? 142
            : holiday?.key == 'yomKippur'
            ? 147
            : 132);
    const double holidayW = 168.0;

    // Both together: full pill. Solo: the individual width, centered.
    final bool both = hasStreak && hasHoliday;
    final double containerW = both ? pillW : (hasStreak ? streakW : holidayW);

    final pill = SizedBox(
      width: containerW,
      child: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(h / 2)),
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
                      onTap: () {
                        if (_isProcessing) return;
                        _showHolidayDonationDialog(holiday);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: holiday.key == 'sucot'
                                ? const [Color(0xFFFEEDD8), Color(0xFFFCAB64)]
                                : holiday.key == 'roshHashana' ||
                                      holiday.key == 'purim' ||
                                      holiday.key == 'januca' ||
                                      holiday.key == 'yomKippur'
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
                            : EdgeInsets.only(
                                left: holiday.key == 'sucot' ? 8.0 : 0.0,
                                right: 8,
                              ),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _holidayIcon(holiday.key, size: 26),
                            const SizedBox(width: 10),
                            Text(
                              holiday.localizedBannerName(S.of(context)),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize:
                                    (holiday.key == 'roshHashana' ||
                                            holiday.key == 'yomKippur') &&
                                        both
                                    ? 13.0
                                    : 15.0,
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
                  // PositionedDirectional respeta RTL: en hebreo `start:0`
                  // ancla la pill de racha a la DERECHA física (donde el
                  // hebreohablante mira primero), espejando el holiday
                  // hacia la izquierda. El badge usa PositionedDirectional
                  // también, así queda junto a la pill en ambos idiomas.
                  PositionedDirectional(
                    start: 0,
                    top: 0,
                    bottom: 0,
                    child: SizedBox(
                      width: both ? streakW : containerW,
                      child: Container(
                        padding: holiday?.key == 'yomKippur' && both
                            ? const EdgeInsetsDirectional.fromSTEB(36, 0, 8, 0)
                            : const EdgeInsetsDirectional.fromSTEB(
                                38,
                                0,
                                12,
                                0,
                              ),
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
                            const Icon(
                              Icons.local_fire_department,
                              color: Colors.white,
                              size: 18,
                            ),
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
            child: _HexBadge(
              count: streakCount,
              color1: _hexColor1(streakCount),
              color2: _hexColor2(streakCount),
            ),
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

  // Matcheamos por `key` estable, no por el nombre localizado. Antes
  // usábamos `lower.contains('kipur')` lo que falló para "Yom Kippur"
  // (2 p's no contienen "kipur" como substring) y mostraba el emoji ✨
  // de fallback. Ahora el switch es exhaustivo sobre las 7 keys del
  // array `_holidays`: si alguien agrega una festividad nueva y olvida
  // su ícono, el `_` lanza un assert en debug que avisa exactamente
  // qué falta. En release devuelve un SizedBox vacío para no crashear.
  Widget _holidayIcon(String key, {double size = 28}) {
    final asset = switch (key) {
      'pesaj' => 'assets/icons/pesaj.png',
      'shavuot' => 'assets/icons/shavuot.png',
      'roshHashana' => 'assets/icons/rosh_hashana.png',
      'yomKippur' => 'assets/icons/yom_kipur.png',
      'sucot' => 'assets/icons/sucot.png',
      'januca' => 'assets/icons/januca.png',
      'purim' => 'assets/icons/purim.png',
      _ => null,
    };
    assert(
      asset != null,
      'Missing icon for holiday key: $key — agregalo a _holidayIcon.',
    );
    if (asset == null) return SizedBox(width: size, height: size);
    final img = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
    // El Book-of-Life de Yom Kippur tiene una baseline visual distinta
    // a los demás íconos, lo bajamos 4 px para que quede alineado.
    if (key == 'yomKippur') {
      return Transform.translate(offset: const Offset(0, 4), child: img);
    }
    return img;
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
            final parsed = double.tryParse(
              amountCtrl.text.trim().replaceAll(',', '.'),
            );
            return parsed ?? 0;
          }

          return Column(
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
                    _holidayIcon(holiday.key, size: 28),
                    const SizedBox(width: 8),
                    Text(
                      holiday.localizedName(S.of(context)),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                holiday.localizedDescription(S.of(context)),
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
              ),
              const SizedBox(height: 18),
              // Amount field — same shape as the donate-now sheet.
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: S.of(context).amount,
                  floatingLabelStyle: TextStyle(color: cs.onSurfaceVariant),
                  hintText: '0',
                  // Round-10 audit fix (LOW #1): no trailing space.
                  prefixText: _shortSymbol(_currencyCodeFromProfile()),
                  errorText: error,
                  filled: true,
                  fillColor: cs.surface,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: cs.outline),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: cs.outline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: AppTokens.primaryBlue,
                      width: 1.6,
                    ),
                  ),
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
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: dedicateOn,
                          onChanged: (v) =>
                              setDialogState(() => dedicateOn = v ?? false),
                          activeColor: AppTokens.primaryBlue,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        S.of(context).dedicateDonation,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
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
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: cs.outline),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: cs.outline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: AppTokens.primaryBlue,
                        width: 1.6,
                      ),
                    ),
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
                      setDialogState(
                        () => error = S.of(context).enterValidAmount,
                      );
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    S.of(context).donateNowBtn,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
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
    // donationReason: holiday.nameEs (siempre en español, consistente para
    // agrupar en el admin entre donors de distintos idiomas — el donor
    // hebreo no envía "פסח" mientras el español envía "Pesaj").
    await _processDirectDonation(
      result.amount,
      donorMessage: result.message.isEmpty ? null : result.message,
      donationReason: holiday.nameEs,
    );
  }

  Expanded _moneyBtn(String label, VoidCallback onTap) {
    return Expanded(
      child: SizedBox(
        height: 44,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, maxLines: 1, softWrap: false),
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
        builder: (ctx, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
            Text(
              S.of(context).otherAmountTitle,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                final value = double.tryParse(
                  controller.text.trim().replaceAll(',', '.'),
                );
                if (value != null && value > 0) {
                  FocusScope.of(ctx).unfocus();
                  Navigator.pop(ctx, value);
                }
              },
              decoration: InputDecoration(
                labelText: S.of(context).amount,
                floatingLabelStyle: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
                // Round-5 audit HIGH fix: prefix matches active
                // currency instead of hardcoded `$` (misleading
                // for MXN/ARS/EUR/ILS/JPY donors).
                hintText: S.of(context).amountHint,
                // Round-10 audit fix (LOW #1): shortCurrencySymbol
                // now returns 'PEN ' (trailing space) for unknown
                // codes, so appending our own ' ' produced 'PEN  '.
                // Use the raw symbol; unknown codes still visually
                // separate from the digits via the built-in gap.
                prefixText: shortCurrencySymbol(_currencyCodeFromProfile()),
                errorText: error,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                    color: AppTokens.primaryBlue,
                    width: 2,
                  ),
                ),
              ),
              onChanged: (_) {
                if (error != null) setDialogState(() => error = null);
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
                onPressed: () {
                  final value = double.tryParse(
                    controller.text.trim().replaceAll(',', '.'),
                  );
                  if (value == null || value <= 0) {
                    setDialogState(
                      () => error = S.of(context).enterValidAmount,
                    );
                    return;
                  }
                  FocusScope.of(ctx).unfocus();
                  Navigator.pop(ctx, value);
                },
                child: Text(
                  S.of(context).add,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    }

    if (!mounted || result == null) return;
    // Update amount immediately so the fill animation plays during sheet dismiss.
    await addAmount(result, skipBillAnimation: true);
    // Wait until keyboard is fully dismissed before showing the bill animation.
    final deadline = DateTime.now().add(const Duration(milliseconds: 600));
    while (mounted && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 16));
      if (!mounted) break;
      if (MediaQuery.of(context).viewInsets.bottom == 0) break;
    }
    if (!mounted) return;
    _launchFallingAnimation();
  }

  // Dispatch the right falling animation based on the donor's chosen
  // pushka style: a 3D coin (classic lata) or the rebbe's dollar bill
  // (770 building). Centralized here so both addAmount paths
  // (quick-amount tap + "Otro" sheet) stay in sync. Sounds gated by
  // FeedbackService.soundEnabled — silent automatically when the user
  // toggles sonido off.
  void _launchFallingAnimation() {
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final titleBox =
        _fillItTitleKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null) return;

    // startY: bottom of the "¡Llénala!" title + 8 px ≈ where the progress
    // bar sits (title → amount text → bar are stacked tightly below).
    final startY = titleBox != null
        ? stackBox
                  .globalToLocal(
                    titleBox.localToGlobal(Offset(0, titleBox.size.height)),
                  )
                  .dy +
              8
        : -90.0;

    final style = ref.read(pushkaStyleProvider);

    if (style == PushkaStyle.classic) {
      // Coin lands right at the slot of the pushka image. Pushka3DWidget
      // wraps the asset in Center > FractionallySizedBox(0.80) > BoxFit
      // .contain — the portrait image fits by height, so the rendered
      // image starts at 10% from the SizedBox top, and the slot sits at
      // ~10% from the image top → 18% of the widget's height. If the
      // RenderBox isn't available (first paint race), we fall back to
      // a mid-screen target which still looks acceptable.
      final pushkaBox =
          _pushkaKey.currentContext?.findRenderObject() as RenderBox?;
      double targetY;
      if (pushkaBox != null) {
        final pushkaTopGlobal = pushkaBox.localToGlobal(Offset.zero).dy;
        final pushkaHeight = pushkaBox.size.height;
        final slotGlobalY = pushkaTopGlobal + pushkaHeight * 0.18;
        targetY = stackBox.globalToLocal(Offset(0, slotGlobalY)).dy;
      } else {
        targetY = stackBox.size.height * 0.43;
      }

      FeedbackService.instance.playCoinDrop();
      setState(() {
        _showCoin = true;
        _coinKey++;
        _coinStartY = startY;
        _coinTargetY = targetY;
      });
    } else {
      FeedbackService.instance.playBillFall();
      setState(() {
        _showBill = true;
        _billKey++;
        _billStartY = startY;
      });
    }
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
    final tenantId =
        ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    // Round-7 regression fix: tag the recent-write with the tenant it
    // belongs to. The recentWrite guard downstream only honors this
    // stopwatch when the incoming snapshot is for the SAME tenant.
    _localWriteTenantId = tenantId;
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
      ref
          .read(userRepositoryProvider)
          .updatePushkaAmount(
            uid: user.uid,
            tenantId: tenantId,
            amount: amount,
          ),
      HiveCache.instance.savePushkaAmount(user.uid, tenantId, amount),
    ]);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Offline gate for payment flows. Payments require network — Firestore
  /// persistence is fine for browsing but Stripe callables MUST reach the
  /// server. If we've confirmed offline (opportunistic detection via
  /// [networkStatusProvider]), show a friendly modal instead of firing a
  /// callable that will fail with a scary error. Returns true if online (or
  /// unknown — trust that state until proven otherwise).
  Future<bool> _ensureOnlineForPayment() async {
    if (!ref.read(isOfflineProvider)) return true;
    if (!mounted) return false;
    final tr = S.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  tr.offlineDialogTitle,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                Text(
                  tr.offlineDonationBlocked,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
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
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(
                      tr.commonUnderstood,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
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
    return false;
  }

  /// Persistent error alert for donation failures. Replaces the previous
  /// SnackBar-based UX (auto-dismissed in ~4s, easy to miss, no next-step).
  ///
  /// - `reason` is the sanitized failure message (from `_donationErrorMessage`).
  /// - `onRetry` is invoked after the dialog closes; pass a closure that
  ///   re-triggers the same donation flow the user just attempted.
  ///
  /// The dialog is `barrierDismissible: false` so users must explicitly pick
  /// Retry / Contact / Close — a critical payment error should not vanish
  /// on an accidental tap-outside.
  Future<void> _showDonationErrorDialog(
    String reason,
    VoidCallback? onRetry,
  ) async {
    if (!mounted) return;
    final tr = S.of(context);
    // Prefer the active tenant's contactEmail; fall back to the app-wide
    // support address so the "Contact rab" action never dead-ends when a
    // tenant has no contact configured.
    final tenantContact = ref
        .read(tenantConfigProvider)
        .valueOrNull
        ?.contactEmail;
    final supportEmail =
        (tenantContact != null && tenantContact.trim().isNotEmpty)
        ? tenantContact.trim()
        : 'support@pushkaapp.com';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // Force explicit dismissal — payment failure is critical, tap-outside
      // must not silently close the alert.
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => PopScope(
        canPop: false,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Theme.of(ctx).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE5E5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.error_outline_rounded,
                          color: Color(0xFFCC2936),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          tr.donationFailedTitle,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    tr.donationFailedBody(reason),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (onRetry != null) ...[
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
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          onRetry();
                        },
                        child: Text(
                          tr.donationRetryBtn,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: TextButton(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        // Build a mailto: with a pre-filled subject + body that
                        // includes the failure detail — saves the donor typing and
                        // gives the rab enough context to triage.
                        final uri = Uri(
                          scheme: 'mailto',
                          path: supportEmail,
                          query: _encodeMailtoQuery({
                            'subject': tr.donationEmailSubject,
                            'body': tr.donationEmailBody(reason),
                          }),
                        );
                        try {
                          await launchUrl(
                            uri,
                            mode: LaunchMode.externalApplication,
                          );
                        } catch (_) {
                          // launchUrl can throw on platforms without a mail handler;
                          // swallow — sheet already closed, user can try again.
                        }
                      },
                      child: Text(
                        tr.donationContactRabBtn,
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text(
                        tr.donationCloseBtn,
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
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
      ),
    );
  }

  /// `Uri(queryParameters: ...)` percent-encodes spaces as `+`, which some
  /// mail clients render literally in the subject/body. Encode manually with
  /// `%20` so the email opens clean on both Gmail and Apple Mail.
  String _encodeMailtoQuery(Map<String, String> params) => params.entries
      .map(
        (e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeQueryComponent(e.value).replaceAll('+', '%20')}',
      )
      .join('&');

  // Round-9 regression fix: was a local map that shadowed shortCurrencySymbol
  // — covered only 10 codes, used 'ARS$' (vs canonical 'AR$'), and fell
  // back to plain '$' for anything unknown (JPY/AUD/CHF/etc.). Header,
  // min/max dialogs called this, so a JPY user saw '$1000' as goal +
  // 'the minimum amount is $50 JPY' in the min dialog. Now delegates
  // to the shared canonical.
  String _currencySymbol(String code) => shortCurrencySymbol(code);

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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.info_outline_rounded,
                  color: Color(0xFFFF9500),
                  size: 30,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                tr.minAmountTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                tr.minAmountBody(code, symbol, minAmount),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                tr.minAmountHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTokens.primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    tr.understood,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
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

  // Round-4 audit HIGH residual: symmetric max-amount dialog. Fires client-
  // side before hitting the CF so donors see an actionable message
  // ("máximo por transacción: $X") instead of a generic backend rejection.
  void _showMaxAmountDialog(String currency, int maxCents, double attempted) {
    final tr = S.of(context);
    final symbol = _currencySymbol(currency);
    final maxAmount = _formatAmountFromCents(maxCents, currency: currency);
    final code = currency.toUpperCase();

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.info_outline_rounded,
                  color: Color(0xFFFF9500),
                  size: 30,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                tr.maxAmountTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                tr.maxAmountBody(code, symbol, maxAmount),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTokens.primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    tr.understood,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
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

  String _donationErrorMessage(Object error, S tr) {
    if (error is FirebaseFunctionsException) {
      // For codes where the backend intentionally forwards a user-facing
      // message (business-rule violations, tenant-not-ready reasons, Stripe
      // decline reasons), prefer the sanitized backend text over the generic
      // fallback so donors see the actionable detail (e.g. "El monto excede
      // el límite permitido" instead of "Verificación de seguridad fallida").
      switch (error.code) {
        case 'unauthenticated':
          return tr.errorSessionInvalid;
        case 'failed-precondition':
          final backendMsg = _sanitizeUserFacingError(error.message);
          if (backendMsg != null) return backendMsg;
          return tr.errorSecurityCheck;
        case 'permission-denied':
          final backendMsg = _sanitizeUserFacingError(error.message);
          if (backendMsg != null) return backendMsg;
          return tr.errorAccessDenied;
        case 'internal':
          // Stripe decline reasons are forwarded via HttpsError('internal', ...).
          // Translate the common decline codes/messages into user-friendly
          // Spanish so the donor knows whether to retry, use another card,
          // or complete 3-D Secure. Fall back to the generic server error
          // when the message doesn't look like a decline.
          final declineMsg = _translateStripeDeclineReason(error.message);
          if (declineMsg != null) return declineMsg;
          return tr.errorPaymentServer;
        case 'unavailable':
          return tr.errorServerUnavailable;
        default:
          // Unknown codes: surface the message but sanitize first — backend
          // could in theory throw `HttpsError("foo", err.stack)` which would
          // dump a multi-line trace into a SnackBar otherwise.
          return _sanitizeUserFacingError(error.message) ??
              tr.couldNotStartPayment;
      }
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
    final stripped = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    if (stripped.isEmpty || stripped == 'null') return null;
    final looksLikeStack =
        stripped.contains('/home/') ||
        stripped.contains('node_modules') ||
        stripped.contains('package:') ||
        stripped.length > 400;
    if (looksLikeStack) return null;
    return stripped.length > 200 ? '${stripped.substring(0, 200)}…' : stripped;
  }

  /// Maps a Stripe decline reason (either a decline code like
  /// `card_declined` / `insufficient_funds` or a human-readable message
  /// containing them) into a short user-facing Spanish string.
  ///
  /// Returns `null` when the input doesn't look like a payment decline —
  /// the caller then falls back to the generic payment-server error.
  ///
  /// The `error.message` string from a Cloud Function `HttpsError('internal',
  /// ...)` is the raw Stripe error message the CF forwarded, which may be
  /// either the machine code or the English description.
  String? _translateStripeDeclineReason(String? raw) {
    if (raw == null) return null;
    final msg = raw.trim();
    if (msg.isEmpty) return null;
    final lower = msg.toLowerCase();

    // Match by decline code / keyword — order matters (specific → generic).
    if (lower.contains('insufficient_funds') ||
        lower.contains('insufficient funds')) {
      return 'Fondos insuficientes en la tarjeta.';
    }
    if (lower.contains('expired_card') || lower.contains('expired card')) {
      return 'La tarjeta expiró. Probá con otra.';
    }
    if (lower.contains('incorrect_cvc') ||
        lower.contains('cvc') && lower.contains('incorrect')) {
      return 'Código CVC incorrecto.';
    }
    if (lower.contains('incorrect_number') ||
        (lower.contains('card number') && lower.contains('incorrect'))) {
      return 'Número de tarjeta incorrecto.';
    }
    if (lower.contains('authentication_required') ||
        lower.contains('authentication required')) {
      return 'La tarjeta requiere autenticación adicional. Intenta de nuevo.';
    }
    if (lower.contains('do_not_honor') || lower.contains('generic_decline')) {
      return 'La tarjeta fue rechazada por el banco. Probá con otra.';
    }
    if (lower.contains('lost_card') || lower.contains('stolen_card')) {
      return 'La tarjeta fue rechazada por el banco. Probá con otra.';
    }
    if (lower.contains('processing_error')) {
      return 'Error procesando la tarjeta. Intenta de nuevo en unos minutos.';
    }
    if (lower.contains('card_declined') || lower.contains('card declined')) {
      return 'La tarjeta fue rechazada. Probá con otra tarjeta.';
    }
    // Generic "declin..." catch-all — surface the original message so the
    // donor at least sees the specific reason.
    if (lower.contains('declin')) {
      final sanitized = _sanitizeUserFacingError(msg);
      if (sanitized != null) return 'Tarjeta rechazada: $sanitized';
      return 'La tarjeta fue rechazada. Probá con otra tarjeta.';
    }
    return null;
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
    // Web (PWA) no soporta biometría — el package `local_auth` solo
    // tiene implementación en Android/iOS/macOS/Windows. Si un user
    // heredó `biometricAuthenticationEnabled: true` de una sesión
    // nativa (APK anterior) y ahora abre la PWA, sin este short-circuit
    // cada donación / vaciado dispara "Autenticación requerida" y
    // bloquea el flow. Retornar false en web hace que ni siquiera se
    // intente autenticar.
    if (kIsWeb) return false;
    final profile = ref.read(userProfileProvider).valueOrNull;
    return (profile?['biometricAuthenticationEnabled'] as bool?) ?? false;
  }

  /// Optional designación picker. Returns `(false, null)` if the user dismissed
  /// the dialog → caller aborts. The picked reason is intentionally discarded:
  /// nothing is sent to Stripe metadata or written to Firestore.
  Future<(bool proceed, String? reason)> _resolveDonationReason() async {
    // Same tenant-first fallback as _donateNow above.
    final tenantReasons =
        ref.read(tenantConfigProvider).valueOrNull?.donationReasons ??
        const <String>[];
    final reasons = tenantReasons.isNotEmpty
        ? tenantReasons
        : S.of(context).defaultDonationReasons;
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
  Future<({String? reason, String message, bool auto, double amount})?>
  _showEmptyPushkaSheet({required double amount}) async {
    final tr = S.of(context);
    // Same tenant-first fallback as _donateNow above.
    final tenantReasons =
        ref.read(tenantConfigProvider).valueOrNull?.donationReasons ??
        const <String>[];
    final reasons = tenantReasons.isNotEmpty
        ? tenantReasons
        : tr.defaultDonationReasons;
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
    final autoEmptyAlreadyActive =
        activeAutoFreq != null &&
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
      result =
          await showKeyboardSafeSheet<
            ({String? reason, String message, bool auto, double amount})
          >(
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
                      Text(
                        tr.donateNowTitle,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (!autoEmptyAlreadyActive) ...[
                  Row(
                    children: [
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
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
                if (partialEnabled && !auto) ...[
                  Row(
                    children: [25, 50, 75, 100].map((p) {
                      final isSelected = selectedPercent == p;
                      final idx = [25, 50, 75, 100].indexOf(p);
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsetsDirectional.only(
                            start: idx == 0 ? 0 : 6,
                          ),
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
                                    ? AppTokens.primaryBlue.withValues(
                                        alpha: 0.12,
                                      )
                                    : surface(ctx),
                                border: Border.all(
                                  color: isSelected
                                      ? AppTokens.primaryBlue
                                      : outline(ctx),
                                  width: isSelected ? 1.6 : 1,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '$p%',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: surface(ctx),
                    border: Border.all(color: outline(ctx)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          // Symbol matches the active currency — `formatMoney` alone
                          // renders `$` unconditionally which lied about EUR/JPY/ILS.
                          // Round-7 regression fix: shortCurrencySymbol keeps
                          // the LatAm prefixes (MX$/AR$/CL$/CO$/US$) unambiguous
                          // instead of the plain '$' currencySymbol() falls back
                          // to. The ISO code trails on the next Text so we don't
                          // want the full "X SYMB $10 USD" repetition either.
                          //
                          // Round-9 regression fix (LOW #4): use currency-aware
                          // formatter so CLP/JPY/KRW render as integers and BHD/JOD
                          // get three decimals. formatMoney was locked to
                          // two-decimal-max — a CLP 10 000 preview came out as
                          // "$10,000.00" which reads as ten thousand cents.
                          formatCurrencyAmountWithSymbol(
                            currentAmount,
                            _currencyCodeFromProfile(),
                            symbol: shortCurrencySymbol(
                              _currencyCodeFromProfile(),
                            ),
                          ),
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
                    ],
                  ),
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
                      child: Row(
                        children: [
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
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setDialogState(() => dedicateOn = !dedicateOn),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: dedicateOn,
                              onChanged: (v) =>
                                  setDialogState(() => dedicateOn = v ?? false),
                              activeColor: AppTokens.primaryBlue,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            tr.dedicateDonation,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
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
                        floatingLabelStyle: TextStyle(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      if (auto) {
                        // Push AutoEmptyScreen ON TOP so back returns to the
                        // still-open sheet. popExtra=true makes save dismiss
                        // both AutoEmpty AND this sheet, dropping the user
                        // back on Mi Pushka.
                        Navigator.of(ctx, rootNavigator: true).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                const AutoEmptyScreen(popExtra: true),
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
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
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
        return 500; // 500 CLP (~$0.55 USD, zero-decimal — value == amount).
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

  // Round-4 audit HIGH residual: client-side max amount validation so the
  // user sees an actionable error BEFORE hitting the CF (which rejects
  // with a generic "amount exceeds cap" HttpsError). Values MUST stay
  // aligned with functions/index.js:CURRENCY_MAX_AMOUNTS.
  int _maxAmountCentsForCurrency(String currency) {
    switch (currency.toLowerCase()) {
      case 'usd':
        return 100000; // $1000
      case 'eur':
        return 100000; // €1000
      case 'gbp':
        return 80000; // £800
      case 'cad':
        return 130000; // C$1300
      case 'ils':
        return 350000; // ₪3500
      case 'mxn':
        return 2000000; // MX$20000
      case 'brl':
        return 500000; // R$5000
      case 'ars':
        return 100000000; // AR$1M
      case 'clp':
        return 900000; // CLP $900k (zero-decimal)
      case 'cop':
        return 400000000; // COP $4M
      default:
        return 100000; // safe default matching USD
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

  // Kept as a thin wrapper for source-compat with existing prefixText calls.
  // Uses the central shortCurrencySymbol() from format_utils (which returns
  // MX$ / AR$ / CL$ / CO$ instead of ambiguous $ for LatAm currencies).
  String _shortSymbol(String code) => shortCurrencySymbol(code);

  String _formatPresetValue(double amount) {
    if (amount == amount.roundToDouble()) return amount.toInt().toString();
    return amount.toStringAsFixed(2);
  }

  String _formatQuickAmount(double amount) {
    // Round-9 regression fix (LOW #5): delegate to the currency-aware
    // formatter so zero-decimal currencies (CLP/JPY/KRW) round to whole
    // units and three-decimal (BHD/JOD) get the right precision.
    // Previously toStringAsFixed(2) forced a decimal tail on integer-only
    // currencies — CLP 5000 preview became "5000.00" which is nonsense.
    final currency = _currencyCodeFromProfile();
    return formatCurrencyAmountWithSymbol(
      amount,
      currency,
      symbol: _shortSymbol(currency),
    );
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
    final tenantId =
        ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
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
    final currentPresets =
        (_presetAmounts.length == 3 && _presetAmounts.every((v) => v > 0))
        ? _presetAmounts
        : defaults;
    final symbol = _shortSymbol(currency);

    double selectedGoal = pushkaGoal;
    double displayedAmount = pushkaAmount;
    bool isSaving = false;

    final ctrl1 = TextEditingController(
      text: _formatPresetValue(currentPresets[0]),
    );
    final ctrl2 = TextEditingController(
      text: _formatPresetValue(currentPresets[1]),
    );
    final ctrl3 = TextEditingController(
      text: _formatPresetValue(currentPresets[2]),
    );
    // Inline TextField for monto acumulado (replaced the prior tap-to-edit
    // dialog) so the user can edit it the same way as the presets.
    final amountAccCtrl = TextEditingController(
      text: _formatPresetValue(displayedAmount),
    );
    // Inline TextField for the pushka goal — replaced the prior tap-to-open
    // bottom-sheet picker. The user prefers a single editable field over
    // a list of preset goals; "Otro" is no longer needed because every
    // value is freely typable.
    final goalCtrl = TextEditingController(
      text: _formatPresetValue(selectedGoal),
    );
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
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
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
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
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
                    borderSide: BorderSide(
                      color: AppTokens.primaryBlue,
                      width: 2,
                    ),
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
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
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
                    borderSide: BorderSide(
                      color: AppTokens.primaryBlue,
                      width: 2,
                    ),
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
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
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
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 14,
                          ),
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
                            borderSide: BorderSide(
                              color: AppTokens.primaryBlue,
                              width: 2,
                            ),
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
                          final p1 =
                              double.tryParse(
                                ctrl1.text.replaceAll(',', '.'),
                              ) ??
                              0;
                          final p2 =
                              double.tryParse(
                                ctrl2.text.replaceAll(',', '.'),
                              ) ??
                              0;
                          final p3 =
                              double.tryParse(
                                ctrl3.text.replaceAll(',', '.'),
                              ) ??
                              0;
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
                            _persistPushkaAmount(
                              resetToZero: displayedAmount <= 0,
                            ),
                          );
                        },
                  child: isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.of(context).settingsApplied)));
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
    'pesaj' => tr.holidayPesaj,
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
    'pesaj' => tr.holidayPesajDesc,
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

  // Calendario de festividades del banner de la pantalla principal.
  //
  // GENERADA CON hebcal, NO SE EDITA A MANO. Cada `startDate` es el PRIMER DÍA
  // de la festividad (Pesach I, Sukkot I, 1ª vela de Janucá…), y el banner se
  // muestra desde `showDaysBefore` días antes hasta `startDate + durationDays`.
  //
  // ⚠️ ESTA LISTA CADUCA: llega hasta diciembre de 2031. Cuando se agote,
  // getActiveHoliday() devuelve null en silencio y el banner desaparece para
  // siempre sin ningún aviso. La versión anterior terminaba en Pesaj de abril
  // 2027 — se habría apagado sola en 8 meses sin que nadie lo notara.
  // Regenerar antes de 2031.
  //
  // Se corrigió de paso Janucá 2026: decía 5 de diciembre y la primera vela es
  // el 4.
  //
  // Para regenerar (desde functions/). El TZ=UTC no es opcional: hebcal lee los
  // componentes LOCALES de la fecha, y generarla desde otro huso corre toda la
  // tabla un día — ver la misma advertencia en _computeNextErevRoshChodesh.
  //   TZ=UTC node -e "(async()=>{const {HebrewCalendar}=await import('@hebcal/core');
  //     const ev=HebrewCalendar.calendar({start:new Date(Date.UTC(2026,7,1)),
  //       end:new Date(Date.UTC(2031,11,31)),il:false});
  //     for(const e of ev){const d=e.getDate().greg();
  //       if(/^(Pesach I|Shavuot I|Rosh Hashana \d+|Yom Kippur|Sukkot I|Chanukah: 1 Candle|Purim)$/.test(e.getDesc()))
  //         console.log(d.toISOString().slice(0,10), e.getDesc());}})()"
  static final List<_HolidayInfo> _holidays = [
    _HolidayInfo(
      key: 'roshHashana',
      nameEs: 'Rosh Hashaná',
      descriptionEs:
          'Año Nuevo judío. Comienza el año con tzedaká y buenas acciones',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2026, 9, 12),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'yomKippur',
      nameEs: 'Yom Kippur',
      descriptionEs:
          'Día de la Expiación. La tzedaká es un mérito especial antes de Yom Kippur',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2026, 9, 21),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'sucot',
      nameEs: 'Sucot',
      descriptionEs:
          'Fiesta de las Cabañas. Comparte alegría con quienes más lo necesitan',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2026, 9, 26),
      showDaysBefore: 14,
      durationDays: 7,
    ),
    _HolidayInfo(
      key: 'januca',
      nameEs: 'Janucá',
      descriptionEs:
          'Festival de las Luces. Ilumina vidas con tu donación de tzedaká',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2026, 12, 4),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'purim',
      nameEs: 'Purim',
      descriptionEs:
          "Matanot la'Evionim: regalos a los necesitados, una mitzvá central de Purim",
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2027, 3, 23),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'pesaj',
      nameEs: 'Pesaj',
      descriptionEs:
          'Celebramos la salida de Egipto. Dona tzedaká para una seuda de Pésaj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2027, 4, 22),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'shavuot',
      nameEs: 'Shavuot',
      descriptionEs:
          'Celebramos la entrega de la Torá. Dona tzedaká en honor a esta festividad',
      presetAmounts: [18, 36, 180],
      startDate: DateTime(2027, 6, 11),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'roshHashana',
      nameEs: 'Rosh Hashaná',
      descriptionEs:
          'Año Nuevo judío. Comienza el año con tzedaká y buenas acciones',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2027, 10, 2),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'yomKippur',
      nameEs: 'Yom Kippur',
      descriptionEs:
          'Día de la Expiación. La tzedaká es un mérito especial antes de Yom Kippur',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2027, 10, 11),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'sucot',
      nameEs: 'Sucot',
      descriptionEs:
          'Fiesta de las Cabañas. Comparte alegría con quienes más lo necesitan',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2027, 10, 16),
      showDaysBefore: 14,
      durationDays: 7,
    ),
    _HolidayInfo(
      key: 'januca',
      nameEs: 'Janucá',
      descriptionEs:
          'Festival de las Luces. Ilumina vidas con tu donación de tzedaká',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2027, 12, 24),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'purim',
      nameEs: 'Purim',
      descriptionEs:
          "Matanot la'Evionim: regalos a los necesitados, una mitzvá central de Purim",
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2028, 3, 12),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'pesaj',
      nameEs: 'Pesaj',
      descriptionEs:
          'Celebramos la salida de Egipto. Dona tzedaká para una seuda de Pésaj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2028, 4, 11),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'shavuot',
      nameEs: 'Shavuot',
      descriptionEs:
          'Celebramos la entrega de la Torá. Dona tzedaká en honor a esta festividad',
      presetAmounts: [18, 36, 180],
      startDate: DateTime(2028, 5, 31),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'roshHashana',
      nameEs: 'Rosh Hashaná',
      descriptionEs:
          'Año Nuevo judío. Comienza el año con tzedaká y buenas acciones',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2028, 9, 21),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'yomKippur',
      nameEs: 'Yom Kippur',
      descriptionEs:
          'Día de la Expiación. La tzedaká es un mérito especial antes de Yom Kippur',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2028, 9, 30),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'sucot',
      nameEs: 'Sucot',
      descriptionEs:
          'Fiesta de las Cabañas. Comparte alegría con quienes más lo necesitan',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2028, 10, 5),
      showDaysBefore: 14,
      durationDays: 7,
    ),
    _HolidayInfo(
      key: 'januca',
      nameEs: 'Janucá',
      descriptionEs:
          'Festival de las Luces. Ilumina vidas con tu donación de tzedaká',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2028, 12, 12),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'purim',
      nameEs: 'Purim',
      descriptionEs:
          "Matanot la'Evionim: regalos a los necesitados, una mitzvá central de Purim",
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2029, 3, 1),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'pesaj',
      nameEs: 'Pesaj',
      descriptionEs:
          'Celebramos la salida de Egipto. Dona tzedaká para una seuda de Pésaj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2029, 3, 31),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'shavuot',
      nameEs: 'Shavuot',
      descriptionEs:
          'Celebramos la entrega de la Torá. Dona tzedaká en honor a esta festividad',
      presetAmounts: [18, 36, 180],
      startDate: DateTime(2029, 5, 20),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'roshHashana',
      nameEs: 'Rosh Hashaná',
      descriptionEs:
          'Año Nuevo judío. Comienza el año con tzedaká y buenas acciones',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2029, 9, 10),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'yomKippur',
      nameEs: 'Yom Kippur',
      descriptionEs:
          'Día de la Expiación. La tzedaká es un mérito especial antes de Yom Kippur',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2029, 9, 19),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'sucot',
      nameEs: 'Sucot',
      descriptionEs:
          'Fiesta de las Cabañas. Comparte alegría con quienes más lo necesitan',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2029, 9, 24),
      showDaysBefore: 14,
      durationDays: 7,
    ),
    _HolidayInfo(
      key: 'januca',
      nameEs: 'Janucá',
      descriptionEs:
          'Festival de las Luces. Ilumina vidas con tu donación de tzedaká',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2029, 12, 1),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'purim',
      nameEs: 'Purim',
      descriptionEs:
          "Matanot la'Evionim: regalos a los necesitados, una mitzvá central de Purim",
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2030, 3, 19),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'pesaj',
      nameEs: 'Pesaj',
      descriptionEs:
          'Celebramos la salida de Egipto. Dona tzedaká para una seuda de Pésaj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2030, 4, 18),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'shavuot',
      nameEs: 'Shavuot',
      descriptionEs:
          'Celebramos la entrega de la Torá. Dona tzedaká en honor a esta festividad',
      presetAmounts: [18, 36, 180],
      startDate: DateTime(2030, 6, 7),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'roshHashana',
      nameEs: 'Rosh Hashaná',
      descriptionEs:
          'Año Nuevo judío. Comienza el año con tzedaká y buenas acciones',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2030, 9, 28),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'yomKippur',
      nameEs: 'Yom Kippur',
      descriptionEs:
          'Día de la Expiación. La tzedaká es un mérito especial antes de Yom Kippur',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2030, 10, 7),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'sucot',
      nameEs: 'Sucot',
      descriptionEs:
          'Fiesta de las Cabañas. Comparte alegría con quienes más lo necesitan',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2030, 10, 12),
      showDaysBefore: 14,
      durationDays: 7,
    ),
    _HolidayInfo(
      key: 'januca',
      nameEs: 'Janucá',
      descriptionEs:
          'Festival de las Luces. Ilumina vidas con tu donación de tzedaká',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2030, 12, 20),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'purim',
      nameEs: 'Purim',
      descriptionEs:
          "Matanot la'Evionim: regalos a los necesitados, una mitzvá central de Purim",
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2031, 3, 9),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'pesaj',
      nameEs: 'Pesaj',
      descriptionEs:
          'Celebramos la salida de Egipto. Dona tzedaká para una seuda de Pésaj',
      presetAmounts: [54, 180, 1800],
      startDate: DateTime(2031, 4, 8),
      showDaysBefore: 14,
      durationDays: 8,
    ),
    _HolidayInfo(
      key: 'shavuot',
      nameEs: 'Shavuot',
      descriptionEs:
          'Celebramos la entrega de la Torá. Dona tzedaká en honor a esta festividad',
      presetAmounts: [18, 36, 180],
      startDate: DateTime(2031, 5, 28),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'roshHashana',
      nameEs: 'Rosh Hashaná',
      descriptionEs:
          'Año Nuevo judío. Comienza el año con tzedaká y buenas acciones',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2031, 9, 18),
      showDaysBefore: 14,
      durationDays: 2,
    ),
    _HolidayInfo(
      key: 'yomKippur',
      nameEs: 'Yom Kippur',
      descriptionEs:
          'Día de la Expiación. La tzedaká es un mérito especial antes de Yom Kippur',
      presetAmounts: [36, 180, 360],
      startDate: DateTime(2031, 9, 27),
      showDaysBefore: 14,
      durationDays: 1,
    ),
    _HolidayInfo(
      key: 'sucot',
      nameEs: 'Sucot',
      descriptionEs:
          'Fiesta de las Cabañas. Comparte alegría con quienes más lo necesitan',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2031, 10, 2),
      showDaysBefore: 14,
      durationDays: 7,
    ),
    _HolidayInfo(
      key: 'januca',
      nameEs: 'Janucá',
      descriptionEs:
          'Festival de las Luces. Ilumina vidas con tu donación de tzedaká',
      presetAmounts: [18, 54, 180],
      startDate: DateTime(2031, 12, 9),
      showDaysBefore: 14,
      durationDays: 8,
    ),
  ];
}

class _HexBadge extends StatelessWidget {
  const _HexBadge({
    required this.count,
    required this.color1,
    required this.color2,
  });
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
                0.2126,
                0.7152,
                0.0722,
                0,
                0,
                0.2126,
                0.7152,
                0.0722,
                0,
                0,
                0.2126,
                0.7152,
                0.0722,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
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
                  Shadow(
                    color: Color(0x99000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
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
          color: selected
              ? AppTokens.primaryBlue.withValues(alpha: 0.08)
              : cs.surface,
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
