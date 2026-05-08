import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/format_utils.dart';
import '../../../core/keyboard_safe_sheet.dart';
import '../../../core/l10n/s.dart';
import '../../auth/biometric_service.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
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
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final callable =
        FirebaseFunctions.instance.httpsCallable('listDonationSubscriptions');
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await callable.call({});
        if (!mounted) return;
        final data = result.data as Map<dynamic, dynamic>;
        final raw = data['subscriptions'] as List<dynamic>? ?? [];
        setState(() {
          _subs = raw.map((s) => Map<String, dynamic>.from(s as Map)).toList();
          _loading = false;
        });
        return;
      } catch (e) {
        lastError = e;
        if (attempt == 0 && mounted) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _subs = [];
      _error = lastError?.toString();
      _loading = false;
    });
  }

  Future<void> _confirmAndCancel(Map<String, dynamic> sub) async {
    if (_processingId) return;
    final tr = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.cancelSubscriptionConfirmTitle),
        content: Text(tr.cancelSubscriptionConfirmBody),
        actions: [
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
      await _load();
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

  String _currencySymbol(String code) {
    const symbols = {
      'usd': 'US\$', 'eur': '€', 'gbp': '£', 'cad': 'CA\$',
      'mxn': 'MX\$', 'ars': 'ARS\$', 'brl': 'R\$', 'ils': '₪',
      'clp': 'CL\$', 'cop': 'CO\$',
    };
    return symbols[code.toLowerCase()] ?? '\$';
  }

  String _formatDate(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    final lang = Localizations.localeOf(context).languageCode;
    final months = lang == 'en'
        ? const ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
        : lang == 'fr'
          ? const ['janv.','févr.','mars','avr.','mai','juin','juil.','août','sept.','oct.','nov.','déc.']
          : const ['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
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
    final symbol = _currencySymbol(currency);
    final tenantConfig = ref.read(tenantConfigProvider).valueOrNull;
    final merchantDisplayName = tenantConfig?.appName ?? 'Pushka';

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
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr.donationProcessed(formatMoney(donationAmount))),
        ),
      );
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? tr.error)),
      );
    } on StripeServiceException catch (e) {
      if (e.code == 'canceled') return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.error)),
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
    final symbol = _currencySymbol(currency);
    final amountStr = formatMoney(amount, symbol: symbol);
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
