import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../users/data/user_repository.dart';
import '../../../app/theme/app_tokens.dart';
import '../../users/presentation/user_profile_provider.dart';

class AutoEmptyScreen extends ConsumerStatefulWidget {
  const AutoEmptyScreen({super.key});

  @override
  ConsumerState<AutoEmptyScreen> createState() => _AutoEmptyScreenState();
}

class _AutoEmptyScreenState extends ConsumerState<AutoEmptyScreen> {
  bool _loaded = false;
  bool _enabled = false;
  String _frequency = 'weekly';
  int _weekday = DateTime.monday;
  int _dayOfMonth = 1;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;

    if (!_loaded && profile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          final freq = (profile['autoEmptyFrequency'] as String?) ?? 'manual';
          _enabled = freq != 'manual';
          _frequency = _enabled ? freq : 'weekly';
          _weekday = (profile['autoEmptyWeekday'] as int?) ?? DateTime.monday;
          _dayOfMonth = (profile['autoEmptyDayOfMonth'] as int?) ?? 1;
          _loaded = true;
        });
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Auto Vaciar'), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ON/OFF toggle
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: _enabled ? AppTokens.primaryBlue.withValues(alpha: 0.06) : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _enabled ? AppTokens.primaryBlue.withValues(alpha: 0.2) : Colors.grey.shade200,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _enabled ? Icons.autorenew : Icons.autorenew,
                      color: _enabled ? AppTokens.primaryBlue : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Auto Vaciado',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            _enabled ? 'Activado' : 'Desactivado',
                            style: TextStyle(
                              fontSize: 13,
                              color: _enabled ? AppTokens.primaryBlue : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _enabled,
                      onChanged: (v) => setState(() => _enabled = v),
                      activeColor: AppTokens.primaryBlue,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              if (!_enabled) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTokens.cardSilver,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Cuando est\u00e9 activado, tu Pushka se vaciar\u00e1 autom\u00e1ticamente seg\u00fan la frecuencia que elijas.\n\nSaldo m\u00ednimo para activar: \.',
                    style: TextStyle(color: AppTokens.textPrimary, height: 1.4),
                  ),
                ),
              ],

              if (_enabled) ...[
                const Text(
                  'Frecuencia',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTokens.textPrimary),
                ),
                const SizedBox(height: 8),

                // Frequency chips
                Wrap(
                  spacing: 8,
                  children: [
                    _FreqChip(label: 'Semanal', value: 'weekly', selected: _frequency, onTap: (v) => setState(() => _frequency = v)),
                    _FreqChip(label: 'Mensual', value: 'monthly', selected: _frequency, onTap: (v) => setState(() => _frequency = v)),
                    _FreqChip(label: 'Erev Rosh J\u00f3desh', value: 'erev_rosh_chodesh', selected: _frequency, onTap: (v) => setState(() => _frequency = v)),
                  ],
                ),

                const SizedBox(height: 20),

                if (_frequency == 'weekly') ...[
                  const Text('D\u00eda de la semana', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _buildDaySelector(),
                  const SizedBox(height: 20),
                ],

                if (_frequency == 'monthly') ...[
                  const Text('D\u00eda del mes', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _buildSelectTile(_dayOfMonth.toString(), _showMonthlyDialog),
                  const SizedBox(height: 20),
                ],

                if (_frequency == 'erev_rosh_chodesh') ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTokens.primaryBlue.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, color: AppTokens.primaryBlue, size: 18),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Se vaciar\u00e1 autom\u00e1ticamente cada v\u00edspera de Rosh J\u00f3desh seg\u00fan el calendario hebreo.',
                            style: TextStyle(fontSize: 13, color: AppTokens.primaryBlue),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Next empty estimate
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.withValues(alpha: 0.15)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.event_available, color: Colors.green, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Pr\u00f3ximo vaciado: ${_nextEmptyDescription()}',
                          style: const TextStyle(color: Colors.green, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTokens.cardSilver,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Si el saldo de tu Pushka es menor a \, el vaciado se pospondr\u00e1 hasta el pr\u00f3ximo ciclo.',
                    style: TextStyle(color: AppTokens.textPrimary, height: 1.4, fontSize: 13),
                  ),
                ),
              ],

              const SizedBox(height: 28),

              // Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.grey.shade400),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('CANCELAR'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: user == null ? null : () => _save(user.uid),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTokens.primaryBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('GUARDAR', style: TextStyle(fontWeight: FontWeight.w700)),
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

  Widget _buildDaySelector() {
    final days = [
      (DateTime.monday, 'Lun'),
      (DateTime.tuesday, 'Mar'),
      (DateTime.wednesday, 'Mi\u00e9'),
      (DateTime.thursday, 'Jue'),
      (DateTime.friday, 'Vie'),
    ];
    return Row(
      children: days.map((d) {
        final selected = _weekday == d.$1;
        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _weekday = d.$1),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected ? AppTokens.primaryBlue : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  d.$2,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.grey.shade700,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
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
            Expanded(child: Text(value, style: const TextStyle(fontSize: 16))),
            const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Future<void> _save(String uid) async {
    try {
      final repo = ref.read(userRepositoryProvider);
      final isManual = !_enabled;
      final freq = isManual ? 'manual' : _frequency;
      final nextRun = isManual ? null : _computeNextEmpty();

      await repo.updateSettings(
        uid: uid,
        autoEmptyFrequency: freq,
        autoEmptyWeekday: _frequency == 'weekly' ? _weekday : null,
        autoEmptyDayOfMonth: _frequency == 'monthly' ? _dayOfMonth : null,
        autoEmptyTopOffEnabled: false,
        autoEmptyTopOffAmount: null,
        autoEmptyNextRunAt: nextRun,
        autoEmptyClearNextRunAt: isManual,
      );

      // Clear stale fields
      if (!isManual) {
        final updates = <String, dynamic>{};
        if (_frequency != 'weekly') updates['autoEmptyWeekday'] = FieldValue.delete();
        if (_frequency != 'monthly') updates['autoEmptyDayOfMonth'] = FieldValue.delete();
        if (updates.isNotEmpty) {
          await FirebaseFirestore.instance.collection('users').doc(uid).update(updates);
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuraci\u00f3n guardada')),
        );
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al guardar. Intenta nuevamente.')),
        );
      }
    }
  }

  String _nextEmptyDescription() {
    final next = _computeNextEmpty();
    if (next == null) return 'No programado';
    const months = ['Ene','Feb','Mar','Abr','May','Jun','Jul','Ago','Sep','Oct','Nov','Dic'];
    const dayNames = ['Lun','Mar','Mi\u00e9','Jue','Vie','S\u00e1b','Dom'];
    final dayOfWeek = dayNames[(next.weekday - 1) % 7];
    return '$dayOfWeek ${next.day} ${months[next.month - 1]} ${next.year}';
  }

  DateTime? _computeNextEmpty() {
    final now = DateTime.now().toUtc();
    if (!_enabled) return null;
    if (_frequency == 'erev_rosh_chodesh') return _nextErevRoshChodesh(now);
    if (_frequency == 'monthly') {
      var year = now.year;
      var month = now.month;
      final day = _dayOfMonth.clamp(1, 31);
      var maxDay = DateTime(year, month + 1, 0).day;
      var run = DateTime.utc(year, month, day.clamp(1, maxDay), 8);
      if (!run.isAfter(now)) {
        month += 1;
        if (month > 12) { month = 1; year += 1; }
        maxDay = DateTime(year, month + 1, 0).day;
        run = DateTime.utc(year, month, day.clamp(1, maxDay), 8);
      }
      return run;
    }
    // weekly
    final target = _weekday.clamp(1, 7);
    var run = DateTime.utc(now.year, now.month, now.day, 8);
    var offset = target - run.weekday;
    if (offset < 0 || (offset == 0 && !run.isAfter(now))) offset += 7;
    return run.add(Duration(days: offset));
  }

  DateTime? _nextErevRoshChodesh(DateTime now) {
    const dates = {
      2025: [[1,29],[2,27],[3,29],[4,27],[5,27],[6,25],[7,25],[8,23],[10,21],[11,20],[12,19]],
      2026: [[1,18],[2,16],[3,18],[4,16],[5,16],[6,14],[7,14],[8,12],[10,10],[11,9],[12,9]],
      2027: [[1,8],[2,6],[3,8],[4,7],[5,6],[6,5],[7,4],[8,3],[9,1],[10,30],[11,29],[12,29]],
      2028: [[1,28],[2,26],[3,27],[4,25],[5,25],[6,23],[7,23],[8,21],[10,19],[11,18],[12,17]],
      2029: [[1,16],[2,14],[3,16],[4,14],[5,14],[6,12],[7,12],[8,10],[10,8],[11,7],[12,6]],
      2030: [[1,4],[2,2],[3,4],[4,3],[5,2],[6,1],[6,30],[7,30],[8,28],[10,26],[11,25],[12,25]],
    };
    for (final y in [now.year, now.year + 1]) {
      final yearDates = dates[y];
      if (yearDates == null) continue;
      for (final md in yearDates) {
        final d = DateTime.utc(y, md[0], md[1], 8);
        if (d.isAfter(now)) return d;
      }
    }
    return now.add(const Duration(days: 30));
  }

  Future<void> _showMonthlyDialog() async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            itemCount: 31,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7, mainAxisSpacing: 8, crossAxisSpacing: 8,
            ),
            itemBuilder: (context, index) {
              final value = index + 1;
              final isSelected = _dayOfMonth == value;
              return InkWell(
                onTap: () => Navigator.pop(context, value),
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected ? AppTokens.primaryBlue : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Center(
                    child: Text(
                      value.toString(),
                      style: TextStyle(
                        fontSize: 16,
                        color: isSelected ? Colors.white : null,
                        fontWeight: isSelected ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    if (result != null) setState(() => _dayOfMonth = result);
  }
}

class _FreqChip extends StatelessWidget {
  final String label;
  final String value;
  final String selected;
  final ValueChanged<String> onTap;

  const _FreqChip({required this.label, required this.value, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isSelected = value == selected;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppTokens.primaryBlue : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey.shade700,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}