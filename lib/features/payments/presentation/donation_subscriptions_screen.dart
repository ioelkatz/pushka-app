import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Hide TextDirection from intl — it collides with Flutter's dart:ui
// TextDirection used elsewhere in this file (line 571 rtl check).
import 'package:intl/intl.dart' hide TextDirection;

import '../../../app/theme/app_tokens.dart';
import '../../../core/format_utils.dart';
import '../../../core/hive_cache.dart';
import '../../../core/keyboard_safe_sheet.dart';
import '../../../core/l10n/s.dart';
import '../../auth/biometric_service.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../donation_reason_picker.dart';
import '../stripe_service.dart';

class DonationSubscriptionsScreen extends ConsumerStatefulWidget {
  const DonationSubscriptionsScreen({super.key});

  @override
  ConsumerState<DonationSubscriptionsScreen> createState() =>
      _DonationSubscriptionsScreenState();
}

class _DonationSubscriptionsScreenState
    extends ConsumerState<DonationSubscriptionsScreen> {
  bool _loading = true;
  String? _error;
  bool _processingId = false;
  String? _cancelingId;
  List<Map<String, dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    // Hive cache: paint the last-known subs immediately so the screen
    // opens with content instead of a spinner. The CF refresh happens
    // silently in the background and swaps in fresh data when it lands.
    // TTL is informational — even a "stale" cache is a better first
    // frame than an empty spinner. If the user creates/cancels a sub
    // we invalidate immediately by rewriting the cache with the fresh
    // list after the CF call.
    final uid = ref.read(currentUserProvider)?.uid;
    final cached = uid == null ? null : HiveCache.instance.loadSubscriptions(uid);
    if (cached != null) {
      _subs = cached.subs;
      _loading = false;
    }
    _load(silent: cached != null);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final callable =
        FirebaseFunctions.instance.httpsCallable('listDonationSubscriptions');
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await callable.call({});
        if (!mounted) return;
        final data = result.data as Map<dynamic, dynamic>;
        final raw = data['subscriptions'] as List<dynamic>? ?? [];
        final subs = raw.map((s) => Map<String, dynamic>.from(s as Map)).toList();
        setState(() {
          _subs = subs;
          _loading = false;
          _error = null;
        });
        // Persist to Hive so the next open of this screen paints instantly.
        final uid = ref.read(currentUserProvider)?.uid;
        if (uid != null) {
          await HiveCache.instance.saveSubscriptions(uid: uid, subs: subs);
        }
        return;
      } catch (e) {
        lastError = e;
        if (attempt == 0 && mounted) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
    }
    if (!mounted) return;
    // Silent refresh failures keep whatever's already on screen — same UX
    // pattern as saved_cards_screen: better to leave the cached list up
    // than wipe it because a background retry hiccuped.
    if (silent) return;
    setState(() {
      _subs = [];
      _error = lastError?.toString();
      _loading = false;
    });
  }

  Future<void> _confirmAndCancel(Map<String, dynamic> sub) async {
    if (_processingId) return;
    final tr = S.of(context);
    // Round-4 audit MEDIUM fix: dialog was fully generic — user had no
    // idea which sub they were canceling. Now shows tenant + amount +
    // currency + interval so a user with multiple subs (multi-tenant or
    // multiple recurring donations) can cancel with confidence.
    final subCurrency = (sub['currency'] as String? ?? 'usd');
    final amountUnits = (sub['amount'] as num?)?.toInt() ?? 0;
    final subInterval = sub['interval'] as String? ?? 'month';
    final subTenantAppName = (sub['tenantAppName'] as String?)?.trim();
    final subTenantName = (sub['tenantName'] as String?)?.trim();
    final subTenantLabel = (subTenantAppName != null && subTenantAppName.isNotEmpty)
        ? subTenantAppName
        : (subTenantName != null && subTenantName.isNotEmpty ? subTenantName : '');
    final amountLabel = formatStripeUnits(amountUnits, subCurrency);
    final intervalLabel = subInterval == 'week' ? tr.weekly : tr.monthly;
    final details = subTenantLabel.isNotEmpty
        ? '$subTenantLabel — $amountLabel · $intervalLabel'
        : '$amountLabel · $intervalLabel';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.cancelSubscriptionConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(details, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(tr.cancelSubscriptionConfirmBody),
          ],
        ),
        actions: [
          // Explicit back-out. Without this the dialog had only "Confirm" so
          // users who tapped Cancel-subscription by mistake had to hit the
          // Android back button (and iOS users had no obvious escape).
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: AppTokens.primaryBlue,
            ),
            child: Text(
              tr.confirm,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppTokens.primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _processingId = true;
      _cancelingId = sub['id'] as String?;
    });
    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('cancelDonationSubscription');
      await callable.call({'subscriptionId': sub['id']});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.subscriptionCanceled)),
      );
      // Round-7 regression fix: optimistically remove the canceled sub
      // from local + Hive cache BEFORE the silent reload. If the reload
      // fails (network hiccup post-cancel) the user shouldn't see the
      // just-canceled sub as active on next screen open.
      final canceledId = sub['id'] as String?;
      if (canceledId != null) {
        final newList = _subs.where((s) => s['id'] != canceledId).toList();
        setState(() => _subs = newList);
        final uid = ref.read(currentUserProvider)?.uid;
        if (uid != null) {
          await HiveCache.instance.saveSubscriptions(uid: uid, subs: newList);
        }
      }
      // Silent refresh — the current list already shows the correct state
      // optimistically (cancel: sub removed / create: waiting for stream)
      // so there's no reason to flash a full-page spinner.
      await _load(silent: true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.subscriptionCancelFailed)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _processingId = false;
          _cancelingId = null;
        });
      }
    }
  }

  bool _biometricEnabled() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    return (profile?['biometricAuthenticationEnabled'] as bool?) ?? false;
  }

  // Removed — use `currencySymbol(code)` from format_utils.dart (single source
  // of truth, covers all Stripe-supported currencies incl. JPY/KRW/CHF/BHD).

  String _formatDate(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    // Hardcoded ES/EN/FR month tables previously fell through to Spanish for
    // Hebrew and any other locale. DateFormat.yMMMd handles all four app
    // languages (ES/EN/FR/HE) plus any future locale correctly.
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMMMd(locale).format(d);
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _subs.isEmpty
                      ? _buildErrorState(tr)
                      : _subs.isEmpty
                          ? _buildEmptyState(tr)
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView.separated(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 8, 16, 8),
                                itemCount: _subs.length,
                                separatorBuilder: (_, _) => Divider(
                                  height: 18,
                                  thickness: 1,
                                  color: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.grey.shade200,
                                ),
                                itemBuilder: (context, index) =>
                                    _buildSubTile(_subs[index], tr),
                              ),
                            ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: (_loading || _processingId)
                      ? null
                      : _openCreateRecurringSheet,
                  icon: const Icon(Icons.favorite_outline, color: Color(0xFFCC2936)),
                  label: Text(
                    tr.donate.toUpperCase(),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTokens.primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCreateRecurringSheet() async {
    final tr = S.of(context);
    final amountCtrl = TextEditingController();
    String interval = 'month';
    String? error;

    final profile = ref.read(userProfileProvider).valueOrNull;
    final currency =
        ((profile?['currencyCode'] as String?)?.trim().isNotEmpty ?? false)
            ? (profile!['currencyCode'] as String)
            : 'usd';
    // Round-7 regression fix: shortCurrencySymbol renders unambiguous
    // MX$/AR$/CL$/CO$/US$ prefixes (matches settings_screen / pushka_screen /
    // auto_empty_screen). The generic currencySymbol() falls back to '$'
    // for MXN/ARS/CLP/COP which the donor could mistake for USD.
    final symbol = shortCurrencySymbol(currency);
    final tenantConfig = ref.read(tenantConfigProvider).valueOrNull;
    final merchantDisplayName = tenantConfig?.appName ?? 'Pushka';
    final activeTenantId = profile?['tenantId'] as String?;

    // Round-4 audit MEDIUM fix: warn if the user already has an active
    // sub in this tenant — otherwise they'd end up double-billed and
    // wondering why. They can still proceed if intentional.
    final existingSubHere = activeTenantId == null
        ? null
        : _subs.cast<Map<String, dynamic>?>().firstWhere(
              (s) => s?['tenantId'] == activeTenantId,
              orElse: () => null,
            );
    if (existingSubHere != null && mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr.recurringAlreadyActiveTitle),
          content: Text(tr.recurringAlreadyActiveBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.continueLabel),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    // Tenant-configured donation destinations (e.g. "Familias necesitadas",
    // "Estudio de Torá"). Falls back to the in-app default Chabad list when
    // the tenant hasn't customized any. Empty list => skip the picker.
    final reasons = (tenantConfig?.donationReasons.isNotEmpty ?? false)
        ? tenantConfig!.donationReasons
        : tr.defaultDonationReasons;
    String? selectedReason = reasons.isNotEmpty ? reasons.first : null;

    Map<String, dynamic>? result;
    try {
      result = await showKeyboardSafeSheet<Map<String, dynamic>>(
        context: context,
        builder: (ctx, setSheetState) {
          final cs = Theme.of(ctx).colorScheme;
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
                child: Text(
                  tr.mySubscriptions,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _IntervalChip(
                      label: tr.weekly[0].toUpperCase() +
                          tr.weekly.substring(1),
                      selected: interval == 'week',
                      onTap: () => setSheetState(() => interval = 'week'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _IntervalChip(
                      label: tr.monthly[0].toUpperCase() +
                          tr.monthly.substring(1),
                      selected: interval == 'month',
                      onTap: () => setSheetState(() => interval = 'month'),
                    ),
                  ),
                ],
              ),
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
                      setSheetState(() => selectedReason = picked.reason);
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: tr.donationReasonTitle,
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
                    ),
                    child: Row(children: [
                      Expanded(
                        child: Text(
                          selectedReason ?? tr.donationReasonNone,
                          style: TextStyle(
                            fontSize: 16,
                            color: selectedReason == null
                                ? cs.onSurfaceVariant
                                : cs.onSurface,
                          ),
                        ),
                      ),
                      Icon(Icons.keyboard_arrow_down_rounded,
                          color: cs.onSurfaceVariant),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: tr.amount,
                  floatingLabelStyle:
                      TextStyle(color: cs.onSurfaceVariant),
                  hintText: '0',
                  prefixText: '$symbol ',
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
                  if (error != null) setSheetState(() => error = null);
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
                      amountCtrl.text.trim().replaceAll(',', '.'),
                    );
                    if (value == null || value <= 0) {
                      setSheetState(() => error = tr.enterValidAmount);
                      return;
                    }
                    Navigator.pop(ctx, {
                      'amount': value,
                      'interval': interval,
                      'reason': selectedReason,
                    });
                  },
                  child: Text(
                    tr.donate,
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
      Future.delayed(
          const Duration(milliseconds: 400), amountCtrl.dispose);
    }

    if (result == null || !mounted) return;
    final donationAmount = result['amount'] as double;
    final chosenInterval = result['interval'] as String? ?? 'month';
    final donationReason = (result['reason'] as String?)?.trim();
    final amountCents = amountToStripeUnits(donationAmount, currency);
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _processingId = true);
    try {
      if (_biometricEnabled()) {
        final authenticated = await BiometricService.instance.authenticate(
          reason: tr.biometricReasonDonate,
        );
        if (!authenticated) {
          if (!mounted) return;
          messenger.showSnackBar(
            SnackBar(content: Text(tr.authRequiredDonate)),
          );
          return;
        }
        if (!mounted) return;
      }

      await StripeService.instance.subscribe(
        amountCents: amountCents,
        currency: currency,
        interval: chosenInterval,
        merchantDisplayName: merchantDisplayName,
        donationReason: (donationReason == null || donationReason.isEmpty)
            ? null
            : donationReason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // Round-4 audit fix: symbol matches the sub currency, not $ default.
          content: Text(tr.donationProcessed(formatCurrencyAmount(donationAmount, currency))),
        ),
      );
      // Silent refresh — the current list already shows the correct state
      // optimistically (cancel: sub removed / create: waiting for stream)
      // so there's no reason to flash a full-page spinner.
      await _load(silent: true);
      // Round-7 regression fix: a transient network hiccup between create
      // and reload leaves Hive at the pre-create list. A delayed retry
      // covers that case — even if the first reload succeeded, a second
      // pass 3s later is cheap and idempotent, and Stripe list-subs
      // eventual-consistency benefits from a slightly-later read too.
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) _load(silent: true);
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? tr.error)),
      );
    } on StripeServiceException catch (e) {
      if (e.code == 'canceled') return;
      if (!mounted) return;
      // Surface specific known codes with actionable copy instead of the
      // generic "Error" that leaves the user staring at a red snackbar
      // with no hint what to do next.
      // Note: 'web_payment_sheet_not_supported' would show the recurring copy
      // by mistake (this screen only ever fires the recurring flow, but the
      // shared StripeService can throw it from any pay() path). Prefer the
      // more accurate 'errorPaymentServer' if that specific code sneaks in.
      final message = switch (e.code) {
        'web_recurring_not_available' => tr.recurringNotSupportedOnWeb,
        'web_payment_sheet_not_supported' => tr.errorPaymentServer,
        'network-error' => tr.errorPaymentServer,
        _ => tr.error,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.error)),
      );
    } finally {
      if (mounted) setState(() => _processingId = false);
    }
  }

  Widget _buildEmptyState(S tr) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_outline, size: 56, color: const Color(0xFFCC2936)),
            const SizedBox(height: 14),
            Text(
              tr.noActiveSubscriptions,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: cs.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(S tr) {
    return Padding(
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
                tr.errorLoadingSubscriptions,
                style: TextStyle(fontSize: 13, color: Colors.red.shade700),
              ),
            ),
            TextButton(
              onPressed: _load,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                tr.retry,
                style: TextStyle(color: Colors.red.shade700, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubTile(Map<String, dynamic> sub, S tr) {
    final cs = Theme.of(context).colorScheme;
    final id = sub['id'] as String? ?? '';
    final currency = (sub['currency'] as String? ?? 'usd').toLowerCase();
    final amountUnits = (sub['amount'] as num?)?.toInt() ?? 0;
    final interval = (sub['interval'] as String? ?? 'month');
    final tenantAppName = (sub['tenantAppName'] as String? ?? '').trim();
    final tenantName = (sub['tenantName'] as String? ?? '').trim();
    final orgLabel = tenantAppName.isNotEmpty
        ? tenantAppName
        : tenantName.isNotEmpty
            ? tenantName
            : '';
    final periodEnd = (sub['currentPeriodEnd'] as num?)?.toInt();

    final amount = stripeUnitsToAmount(amountUnits, currency);
    // Round-4 audit fix: use central formatter — was missing JPY/KRW/CHF/BHD
    // and falling back to `$` for those. Now correct symbol + code appended.
    final amountStr = formatCurrencyAmount(amount, currency);
    final intervalRaw = interval == 'week' ? tr.weekly : tr.monthly;
    final intervalLabel = intervalRaw.isEmpty
        ? intervalRaw
        : intervalRaw[0].toUpperCase() + intervalRaw.substring(1);

    final isCanceling = _cancelingId == id;
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _processingId ? null : () => _confirmAndCancel(sub),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTokens.primaryBlue.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.autorenew_rounded,
                color: AppTokens.primaryBlue,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    orgLabel.isNotEmpty ? orgLabel : amountStr,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    orgLabel.isNotEmpty
                        ? '$amountStr · $intervalLabel'
                        : intervalLabel,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  if (periodEnd != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr.nextChargeOn(_formatDate(periodEnd)),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            isCanceling
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    isRtl ? Icons.chevron_left : Icons.chevron_right,
                    color: cs.onSurfaceVariant,
                  ),
          ],
        ),
      ),
    );
  }
}

class _IntervalChip extends StatelessWidget {
  const _IntervalChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppTokens.primaryBlue.withValues(alpha: 0.10)
              : cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppTokens.primaryBlue : cs.outline,
            width: selected ? 1.6 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppTokens.primaryBlue : cs.onSurface,
          ),
        ),
      ),
    );
  }
}
