import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/s.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';

class WalletAutoRefillScreen extends ConsumerStatefulWidget {
  const WalletAutoRefillScreen({super.key});

  @override
  ConsumerState<WalletAutoRefillScreen> createState() => _WalletAutoRefillScreenState();
}

class _WalletAutoRefillScreenState extends ConsumerState<WalletAutoRefillScreen> {
  final TextEditingController _amountController = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  String _frequency = 'weekly';
  int _weekday = DateTime.monday;
  int _dayOfMonth = 1;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  String get _currencyCode {
    final profile = ref.read(userProfileProvider).valueOrNull;
    final code = profile?['currencyCode'] as String?;
    return (code != null && code.trim().isNotEmpty) ? code : 'usd';
  }

  String _currencySymbol(String code) {
    const symbols = {
      'usd': 'US\$', 'eur': '€', 'gbp': '£', 'cad': 'CA\$',
      'mxn': 'MX\$', 'ars': 'ARS\$', 'brl': 'R\$', 'ils': '₪',
      'clp': 'CL\$', 'cop': 'CO\$',
    };
    return symbols[code.toLowerCase()] ?? '\$';
  }

  DateTime _computeNextRun({
    required String frequency,
    required int weekday,
    required int dayOfMonth,
  }) {
    // Use UTC to match the Cloud Function scheduler which runs in Etc/UTC.
    final now = DateTime.now().toUtc();
    if (frequency == 'monthly') {
      var month = now.month;
      var year = now.year;
      // Clamp day for the current month before creating the run date.
      final maxDayCurrent = DateTime.utc(year, month + 1, 0).day;
      var runDate = DateTime.utc(year, month, dayOfMonth.clamp(1, maxDayCurrent), 8);
      if (!runDate.isAfter(now)) {
        month += 1;
        if (month > 12) {
          month = 1;
          year += 1;
        }
        final maxDay = DateTime.utc(year, month + 1, 0).day;
        runDate = DateTime.utc(year, month, dayOfMonth.clamp(1, maxDay), 8);
      }
      return runDate;
    }

    var runDate = DateTime.utc(now.year, now.month, now.day, 8);
    while (runDate.weekday != weekday || !runDate.isAfter(now)) {
      runDate = runDate.add(const Duration(days: 1));
    }
    return runDate;
  }

  Future<bool> _showConsentDialog() async {
    final tr = S.of(context);
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            title: Row(
              children: [
                const Icon(Icons.verified_user_rounded, color: Color(0xFFE05A4F), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr.autoRefillConsentTitle,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.autoRefillConsentBody, style: const TextStyle(fontSize: 14, height: 1.55)),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFED7AA), width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr.autoRefillConsentBullet1, style: const TextStyle(fontSize: 13, height: 1.5)),
                        const SizedBox(height: 6),
                        Text(tr.autoRefillConsentBullet2, style: const TextStyle(fontSize: 13, height: 1.5)),
                        const SizedBox(height: 6),
                        Text(tr.autoRefillConsentBullet3, style: const TextStyle(fontSize: 13, height: 1.5)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE05A4F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(tr.autoRefillConsentAccept, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr.autoEmptyConsentCancel),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    final user = ref.read(currentUserProvider);
    if (user == null || _saving) return;

    final parsedAmount = double.tryParse(_amountController.text.trim().replaceAll(',', '.'));
    if (parsedAmount == null || parsedAmount < 1.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).enterValidAmount)),
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final accepted = await _showConsentDialog();
    if (!accepted || !mounted) return;

    setState(() => _saving = true);
    try {
      final nextRun = _computeNextRun(
        frequency: _frequency,
        weekday: _weekday,
        dayOfMonth: _dayOfMonth,
      );
      await ref.read(userRepositoryProvider).updateSettings(
            uid: user.uid,
            walletAutoTopUpEnabled: true,
            walletAutoTopUpAmount: parsedAmount,
            walletAutoTopUpFrequency: _frequency,
            walletAutoTopUpWeekday: _weekday,
            walletAutoTopUpDayOfMonth: _dayOfMonth,
            walletAutoTopUpNextRunAt: nextRun,
            walletAutoTopUpClearNextRunAt: false,
          );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(S.of(context).autoRefillSaved)));
      context.go('/wallet');
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(S.of(context).couldNotSaveError('$e'))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildFrequencyOption({
    required String value,
    required String label,
  }) {
    final selected = _frequency == value;
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => setState(() => _frequency = value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? cs.primary : cs.onSurface,
              size: 30,
            ),
            const SizedBox(width: 14),
            Text(label, style: const TextStyle(fontSize: 17)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;

    if (!_loaded && profile != null) {
      _loaded = true; // set synchronously so subsequent rebuilds don't enqueue more callbacks
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final rawAmount = (profile['walletAutoTopUpAmount'] as num?)?.toDouble() ?? 0.0;
        final amount = rawAmount > 0 ? rawAmount : 25.0;
        setState(() {
          _frequency = (profile['walletAutoTopUpFrequency'] as String?) == 'monthly'
              ? 'monthly'
              : 'weekly';
          _weekday = (profile['walletAutoTopUpWeekday'] as num?)?.toInt() ?? DateTime.monday;
          _dayOfMonth = (profile['walletAutoTopUpDayOfMonth'] as num?)?.toInt() ?? 1;
          _amountController.text = amount.toStringAsFixed(0);
        });
      });
    }

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 18, 26, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 42),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr.frequencyLabel,
                    style: const TextStyle(
                      fontSize: 34 / 2,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildFrequencyOption(value: 'weekly', label: tr.freqWeekly),
                  _buildFrequencyOption(value: 'monthly', label: tr.freqMonthly),
                  const SizedBox(height: 24),
                  Text(
                    tr.recurringDay,
                    style: const TextStyle(
                      fontSize: 34 / 2,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int>(key: ValueKey(_frequency), initialValue: _frequency == 'weekly' ? _weekday : _dayOfMonth,
                    decoration: InputDecoration(
                      hintText: tr.selectHint,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    items: _frequency == 'weekly'
                        ? [
                            DropdownMenuItem(value: DateTime.monday, child: Text(tr.dayMonFull)),
                            DropdownMenuItem(value: DateTime.tuesday, child: Text(tr.dayTueFull)),
                            DropdownMenuItem(value: DateTime.wednesday, child: Text(tr.dayWedFull)),
                            DropdownMenuItem(value: DateTime.thursday, child: Text(tr.dayThuFull)),
                            DropdownMenuItem(value: DateTime.friday, child: Text(tr.dayFriFull)),
                            DropdownMenuItem(value: DateTime.saturday, child: Text(tr.daySatFull)),
                            DropdownMenuItem(value: DateTime.sunday, child: Text(tr.daySunFull)),
                          ]
                        : List.generate(
                            31,
                            (i) => DropdownMenuItem(
                              value: i + 1,
                              child: Text('${i + 1}'),
                            ),
                          ),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        if (_frequency == 'weekly') {
                          _weekday = v;
                        } else {
                          _dayOfMonth = v;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 24),
                  Text(
                    tr.amountLabel,
                    style: const TextStyle(
                      fontSize: 34 / 2,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      prefixText: _currencySymbol(_currencyCode),
                      hintText: ' ',
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving ? null : () => context.go('/wallet'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 52),
                            side: BorderSide(color: Colors.grey.shade400, width: 2),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: Text(
                            tr.cancelBtn,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving ? null : _save,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 52),
                            side: const BorderSide(color: Color(0xFFE05A4F), width: 2),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(
                                  tr.saveBtn,
                                  style: const TextStyle(
                                    color: Color(0xFFE05A4F),
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    onPressed: _saving ? null : _disableAutoRefill,
                    icon: const Icon(Icons.cancel_outlined, size: 16, color: Color(0xFFDC2626)),
                    label: Text(
                      tr.disableAutoRefill,
                      style: const TextStyle(
                        color: Color(0xFFDC2626),
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _disableAutoRefill() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(userRepositoryProvider).updateSettings(
        uid: user.uid,
        walletAutoTopUpEnabled: false,
        walletAutoTopUpClearNextRunAt: true,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).autoRefillDisabled)),
        );
        context.go('/wallet');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).genericError('$e'))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
