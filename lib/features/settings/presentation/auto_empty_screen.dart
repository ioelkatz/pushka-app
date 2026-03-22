import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';

class AutoEmptyScreen extends ConsumerStatefulWidget {
  const AutoEmptyScreen({super.key});

  @override
  ConsumerState<AutoEmptyScreen> createState() => _AutoEmptyScreenState();
}

class _AutoEmptyScreenState extends ConsumerState<AutoEmptyScreen> {
  final _amountController = TextEditingController();
  bool _loaded = false;

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
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;

    if (!_loaded && profile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _frequency = (profile['autoEmptyFrequency'] as String?) ?? 'manual';
          _weekday = (profile['autoEmptyWeekday'] as int?) ?? DateTime.monday;
          _dayOfMonth = (profile['autoEmptyDayOfMonth'] as int?) ?? 1;
          _topOffEnabled =
              (profile['autoEmptyTopOffEnabled'] as bool?) ?? false;
          _topOffAmount = (profile['autoEmptyTopOffAmount'] as num?)?.toDouble();
          _amountController.text = _topOffAmount?.toStringAsFixed(0) ?? '';
          _loaded = true;
        });
      });
    }

    const red = Color(0xFFE05A4F);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Auto Vaciar'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Frecuencia de Auto Vaciado',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _frequency,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                items: const [
                  DropdownMenuItem(value: 'manual', child: Text('Manual')),
                  DropdownMenuItem(value: 'weekly', child: Text('Semanal')),
                  DropdownMenuItem(value: 'monthly', child: Text('Mensual')),
                  DropdownMenuItem(
                    value: 'erev_rosh_chodesh',
                    child: Text('Víspera de Rosh Jódesh'),
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
                  color: const Color(0xFFF4F7FB),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Saldo mínimo para activar el auto vaciado:\n'
                  'Si el saldo de la Pushka es menor a \$5, no se vaciará en ese momento.',
                  style: TextStyle(color: Colors.black87),
                ),
              ),
              const SizedBox(height: 20),
              if (_frequency == 'weekly') ...[
                const Text(
                  'Día recurrente',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _buildSelectTile(
                  _weekdayLabel(_weekday),
                  _showWeeklyDialog,
                ),
                const SizedBox(height: 20),
              ],
              if (_frequency == 'monthly') ...[
                const Text(
                  'Día del mes',
                  style: TextStyle(fontWeight: FontWeight.w600),
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
                    const Expanded(
                      child: Text(
                        'Relleno de Pushka',
                        style: TextStyle(
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
                      activeThumbColor: const Color(0xFFFF9500),
                      activeTrackColor: const Color(0xFFFF9500).withValues(alpha: 0.45),
                      inactiveThumbColor: Colors.white,
                      inactiveTrackColor: Colors.grey.shade300,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Si el saldo es muy bajo, lo completaremos al mínimo antes de vaciar.',
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
                      child: const Text('CANCELAR'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: user == null
                          ? null
                          : () async {
                              await _saveConfig(user.uid);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Configuración guardada'),
                                  ),
                                );
                              }
                            },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: red, width: 2),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        'GUARDAR',
                        style: TextStyle(
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

  Future<void> _saveConfig(String uid) async {
    final repo = ref.read(userRepositoryProvider);
    await repo.updateSettings(
      uid: uid,
      autoEmptyFrequency: _frequency,
      autoEmptyWeekday: _frequency == 'weekly' ? _weekday : null,
      autoEmptyDayOfMonth: _frequency == 'monthly' ? _dayOfMonth : null,
      autoEmptyTopOffEnabled: _frequency == 'manual' ? false : _topOffEnabled,
      autoEmptyTopOffAmount:
          _frequency == 'manual' ? null : (_topOffAmount ?? 0),
    );
  }

  Future<void> _showWeeklyDialog() async {
    final days = [
      {'label': 'Lunes', 'value': DateTime.monday},
      {'label': 'Martes', 'value': DateTime.tuesday},
      {'label': 'Miércoles', 'value': DateTime.wednesday},
      {'label': 'Jueves', 'value': DateTime.thursday},
      {'label': 'Viernes', 'value': DateTime.friday},
      {'label': 'Sábado', 'value': DateTime.saturday},
      {'label': 'Domingo', 'value': DateTime.sunday},
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

    if (result != null) {
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

    if (result != null) {
      setState(() => _dayOfMonth = result);
    }
  }

  String _weekdayLabel(int weekday) {
    switch (weekday) {
      case DateTime.monday:
        return 'Lunes';
      case DateTime.tuesday:
        return 'Martes';
      case DateTime.wednesday:
        return 'Miércoles';
      case DateTime.thursday:
        return 'Jueves';
      case DateTime.friday:
        return 'Viernes';
      case DateTime.saturday:
        return 'Sábado';
      case DateTime.sunday:
        return 'Domingo';
      default:
        return 'Seleccionar';
    }
  }
}
