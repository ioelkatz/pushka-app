import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../../core/l10n/s.dart';

class AutoEmptyScreen extends ConsumerStatefulWidget {
  const AutoEmptyScreen({super.key});

  @override
  ConsumerState<AutoEmptyScreen> createState() => _AutoEmptyScreenState();
}

class _AutoEmptyScreenState extends ConsumerState<AutoEmptyScreen> {
  final _amountController = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  // The frequency value that was already saved in Firestore when the screen opened.
  // Used to decide whether to show the consent dialog (only when enabling for first time).
  String _savedFrequency = 'manual';

  String _frequency = 'manual';
  int _weekday = DateTime.monday;
  int _dayOfMonth = 1;
  bool _topOffEnabled = false;
  double? _topOffAmount;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;

    if (!_loaded && profile != null) {
      _loaded = true; // set synchronously so subsequent rebuilds never enqueue a second callback
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _frequency = (profile['autoEmptyFrequency'] as String?) ?? 'manual';
          _savedFrequency = _frequency;
          _weekday = (profile['autoEmptyWeekday'] as num?)?.toInt() ?? DateTime.monday;
          _dayOfMonth = (profile['autoEmptyDayOfMonth'] as num?)?.toInt() ?? 1;
          _topOffEnabled =
              (profile['autoEmptyTopOffEnabled'] as bool?) ?? false;
          _topOffAmount = (profile['autoEmptyTopOffAmount'] as num?)?.toDouble();
          _amountController.text = _topOffAmount?.toStringAsFixed(0) ?? '';
        });
      });
    }

    const red = Color(0xFFE05A4F);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.autoEmpty),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr.autoEmptyLabel,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(initialValue: _frequency,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                items: [
                  DropdownMenuItem(value: 'manual', child: Text(tr.manualEmpty)),
                  DropdownMenuItem(value: 'weekly', child: Text(tr.freqWeekly)),
                  DropdownMenuItem(value: 'monthly', child: Text(tr.freqMonthly)),
                  DropdownMenuItem(
                    value: 'erev_rosh_chodesh',
                    child: Text(tr.freqErevRosh),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _frequency = value;
                    if (_frequency == 'weekly') {
                      _topOffAmount ??= 18;
                    } else if (_frequency == 'monthly' ||
                        _frequency == 'erev_rosh_chodesh') {
                      _topOffAmount ??= 36;
                    }
                    _amountController.text =
                        _topOffAmount?.toStringAsFixed(0) ?? '';
                  });
                },
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${tr.autoEmptyInfo}\n\n${tr.minBalanceInfo}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
              const SizedBox(height: 20),
              if (_frequency == 'weekly') ...[
                Text(
                  tr.dayOfWeek,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _buildSelectTile(
                  _weekdayLabel(_weekday),
                  _showWeeklyDialog,
                ),
                const SizedBox(height: 20),
              ],
              if (_frequency == 'monthly') ...[
                Text(
                  tr.dayOfMonth,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _buildSelectTile(
                  _dayOfMonth.toString(),
                  _showMonthlyDialog,
                ),
                const SizedBox(height: 20),
              ],
              if (_frequency != 'manual') ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        tr.pushkaTopOff,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Switch(
                      value: _topOffEnabled,
                      onChanged: (value) {
                        setState(() => _topOffEnabled = value);
                        if (value && _topOffAmount == null) {
                          setState(() {
                            _topOffAmount =
                                _frequency == 'weekly' ? 18 : 36;
                            _amountController.text =
                                _topOffAmount!.toStringAsFixed(0);
                          });
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  tr.topOffDescription,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                const SizedBox(height: 12),
                if (_topOffEnabled)
                  TextField(
                    controller: _amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      prefixText: '\$ ',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onChanged: (value) {
                      final parsed =
                          double.tryParse(value.replaceAll(',', '.'));
                      _topOffAmount = parsed;
                    },
                  ),
                const SizedBox(height: 24),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.grey.shade400),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(tr.cancelBtn),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: user == null || _saving
                          ? null
                          : () async {
                              if (_frequency != 'manual' &&
                                  _topOffEnabled &&
                                  (_topOffAmount == null || _topOffAmount! <= 0)) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(tr.enterValidAmount)),
                                );
                                return;
                              }
                              final messenger = ScaffoldMessenger.of(context);
                              final navigator = Navigator.of(context);
                              // Require explicit consent only when switching FROM manual
                              // (i.e., enabling auto-empty for the first time or re-enabling).
                              // No consent re-prompt when simply changing day/frequency of
                              // an already-active schedule.
                              if (_frequency != 'manual' && _savedFrequency == 'manual') {
                                final accepted = await _showConsentDialog();
                                if (!accepted || !mounted) return;
                              }
                              setState(() => _saving = true);
                              try {
                                await _saveConfig(user.uid);
                                if (!mounted) return;
                                navigator.pop();
                                messenger.showSnackBar(
                                  SnackBar(content: Text(tr.settingsSaved)),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                debugPrint('auto-empty save error: $e');
                                messenger.showSnackBar(
                                  SnackBar(content: Text(tr.saveError)),
                                );
                              } finally {
                                if (mounted) setState(() => _saving = false);
                              }
                            },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: red, width: 2),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        tr.saveBtn,
                        style: const TextStyle(
                          color: red,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectTile(String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  /// Returns true if the user accepted the auto-empty consent terms.
  /// Only shown when setting a non-manual frequency.
  Future<bool> _showConsentDialog() async {
    final tr = S.of(context);
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            title: Row(
              children: [
                const Icon(Icons.verified_user_rounded,
                    color: Color(0xFFE05A4F), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr.autoEmptyConsentTitle,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr.autoEmptyConsentBody,
                    style: const TextStyle(fontSize: 14, height: 1.55),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: const Color(0xFFFED7AA), width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr.autoEmptyConsentBullet1,
                            style: const TextStyle(fontSize: 13, height: 1.5)),
                        const SizedBox(height: 6),
                        Text(tr.autoEmptyConsentBullet2,
                            style: const TextStyle(fontSize: 13, height: 1.5)),
                        const SizedBox(height: 6),
                        Text(tr.autoEmptyConsentBullet3,
                            style: const TextStyle(fontSize: 13, height: 1.5)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE05A4F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    tr.autoEmptyConsentAccept,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    tr.autoEmptyConsentCancel,
                    style: TextStyle(
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _saveConfig(String uid) async {
    final repo = ref.read(userRepositoryProvider);
    final nextRunAt = _frequency == 'manual' ? null : _computeNextRunAt();
    await repo.updateSettings(
      uid: uid,
      autoEmptyFrequency: _frequency,
      autoEmptyWeekday: _frequency == 'weekly' ? _weekday : null,
      autoEmptyDayOfMonth: _frequency == 'monthly' ? _dayOfMonth : null,
      autoEmptyTopOffEnabled: _frequency == 'manual' ? false : _topOffEnabled,
      autoEmptyTopOffAmount:
          _frequency == 'manual' ? null : (_topOffAmount ?? 0),
      autoEmptyNextRunAt: nextRunAt,
      autoEmptyClearNextRunAt: _frequency == 'manual',
    );
  }

  DateTime _computeNextRunAt() {
    final now = DateTime.now().toUtc();
    if (_frequency == 'weekly') {
      var next = DateTime.utc(now.year, now.month, now.day, 8, 0, 0);
      while (next.weekday != _weekday || !next.isAfter(now)) {
        next = next.add(const Duration(days: 1));
      }
      return next;
    }
    if (_frequency == 'monthly') {
      int clampDay(int year, int month) {
        final maxDay = DateTime.utc(year, month + 1, 0).day;
        return _dayOfMonth.clamp(1, maxDay);
      }
      var next = DateTime.utc(now.year, now.month, clampDay(now.year, now.month), 8, 0, 0);
      if (!next.isAfter(now)) {
        final nm = now.month == 12 ? 1 : now.month + 1;
        final ny = now.month == 12 ? now.year + 1 : now.year;
        next = DateTime.utc(ny, nm, clampDay(ny, nm), 8, 0, 0);
      }
      return next;
    }
    if (_frequency == 'erev_rosh_chodesh') {
      return _computeNextErevRoshChodesh(now);
    }
    return now.add(const Duration(days: 30));
  }

  DateTime _computeNextErevRoshChodesh(DateTime now) {
    // months are 0-indexed to match the Cloud Function table (JS convention)
    const table = <int, List<List<int>>>{
      2025: [[0,29],[1,27],[2,29],[3,27],[4,27],[5,25],[6,25],[7,23],[9,21],[10,20],[11,19]],
      2026: [[0,18],[1,16],[2,18],[3,16],[4,16],[5,14],[6,14],[7,12],[9,10],[10,9],[11,9]],
      2027: [[0,8],[1,6],[2,8],[3,7],[4,6],[5,5],[6,4],[7,3],[8,1],[9,30],[10,29],[11,29]],
      2028: [[0,28],[1,26],[2,27],[3,25],[4,25],[5,23],[6,23],[7,21],[9,19],[10,18],[11,17]],
      2029: [[0,16],[1,14],[2,16],[3,14],[4,14],[5,12],[6,12],[7,10],[9,8],[10,7],[11,6]],
      2030: [[0,4],[1,2],[2,4],[3,3],[4,2],[5,1],[5,30],[6,30],[7,28],[9,26],[10,25],[11,25]],
      2031: [[0,24],[1,22],[2,24],[3,22],[4,22],[5,20],[6,20],[7,18],[9,16],[10,15],[11,15]],
      2032: [[0,13],[1,12],[2,12],[3,11],[4,10],[5,9],[6,8],[7,7],[9,5],[10,3],[11,3]],
      2033: [[0,2],[1,1],[1,28],[2,30],[3,29],[4,28],[5,27],[6,26],[7,25],[9,22],[10,22],[11,21]],
      2034: [[0,21],[1,19],[2,21],[3,19],[4,19],[5,17],[6,17],[7,15],[9,13],[10,12],[11,12]],
      2035: [[0,10],[1,9],[2,11],[3,9],[4,9],[5,7],[6,7],[7,5],[9,3],[10,2],[11,1],[11,31]],
    };
    for (final year in [now.year, now.year + 1]) {
      final yearDates = table[year];
      if (yearDates == null) continue;
      for (final md in yearDates) {
        final candidate = DateTime.utc(year, md[0] + 1, md[1], 8, 0, 0);
        if (candidate.isAfter(now)) return candidate;
      }
    }
    return now.add(const Duration(days: 30));
  }

  Future<void> _showWeeklyDialog() async {
    final tr = S.of(context);
    final days = [
      {'label': tr.dayMonFull, 'value': DateTime.monday},
      {'label': tr.dayTueFull, 'value': DateTime.tuesday},
      {'label': tr.dayWedFull, 'value': DateTime.wednesday},
      {'label': tr.dayThuFull, 'value': DateTime.thursday},
      {'label': tr.dayFriFull, 'value': DateTime.friday},
      {'label': tr.daySatFull, 'value': DateTime.saturday},
      {'label': tr.daySunFull, 'value': DateTime.sunday},
    ];

    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: days.length,
            separatorBuilder: (_, _) =>
                Divider(height: 1, color: Colors.grey.shade200),
            itemBuilder: (context, index) {
              final item = days[index];
              return ListTile(
                title: Text(item['label'] as String),
                onTap: () => Navigator.pop(context, item['value'] as int),
              );
            },
          ),
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() => _weekday = result);
    }
  }

  Future<void> _showMonthlyDialog() async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            itemCount: 30,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemBuilder: (context, index) {
              final value = index + 1;
              return InkWell(
                onTap: () => Navigator.pop(context, value),
                child: Center(
                  child: Text(
                    value.toString(),
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() => _dayOfMonth = result);
    }
  }

  String _weekdayLabel(int weekday) {
    final tr = S.of(context);
    switch (weekday) {
      case DateTime.monday:
        return tr.dayMonFull;
      case DateTime.tuesday:
        return tr.dayTueFull;
      case DateTime.wednesday:
        return tr.dayWedFull;
      case DateTime.thursday:
        return tr.dayThuFull;
      case DateTime.friday:
        return tr.dayFriFull;
      case DateTime.saturday:
        return tr.daySatFull;
      case DateTime.sunday:
        return tr.daySunFull;
      default:
        return tr.selectHint;
    }
  }
}


