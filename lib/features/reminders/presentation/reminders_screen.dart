import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../analytics/analytics_service.dart';
import '../../notifications/notification_service.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../data/reminder_repository.dart';
import '../domain/reminder.dart';
import '../providers/reminders_provider.dart';

class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});

  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFFF9500);
    const red = Color(0xFFE05A4F);

    return Column(
      children: [
        Expanded(
          child: ref.watch(userRemindersProvider).when(
                data: (reminders) {
                  if (reminders.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.notifications_none_rounded,
                            size: 54,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'No hay recordatorios',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Toca el botón para agregar uno',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.separated(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    itemCount: reminders.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      thickness: 1,
                      color: Colors.grey.shade200,
                    ),
                    itemBuilder: (context, index) {
                      final reminder = reminders[index];
                      return _buildReminderItem(
                        reminder: reminder,
                        onToggle: (value) => _toggleReminder(reminder, value),
                        onEdit: () => _showEditReminderDialog(reminder),
                        onDelete: () => _deleteReminder(reminder),
                        activeColor: orange,
                      );
                    },
                  );
                },
                loading: () => const Center(
                  child: CircularProgressIndicator(),
                ),
                error: (_, __) => const Center(
                  child: Text('Error cargando recordatorios'),
                ),
              ),
        ),
        // Botón agregar recordatorio
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => _showAddReminderDialog(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: red,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      '+ Agregar recordatorio',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      await NotificationService.instance.showTestNotification();
                    },
                    child: const Text('Probar notificación'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReminderItem({
    required Reminder reminder,
    required ValueChanged<bool> onToggle,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
    required Color activeColor,
  }) {
    final subtitle = reminder.subtitle;
    final subtitle2 = reminder.subtitleSecondary;

    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reminder.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Colors.black.withOpacity(0.6),
                    ),
                  ),
                  if (subtitle2 != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle2!,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: Colors.black.withOpacity(0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            Column(
              children: [
                Switch(
                  value: reminder.isEnabled,
                  onChanged: onToggle,
                  activeThumbColor: activeColor,
                  activeTrackColor: activeColor.withValues(alpha: 0.45),
                  inactiveThumbColor: Colors.white,
                  inactiveTrackColor: Colors.grey.shade300,
                ),
                const SizedBox(height: 8),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.grey),
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddReminderDialog() async {
    final result = await showModalBottomSheet<ReminderDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _ReminderDialog(),
    );

    if (result != null) {
      await _saveReminder(result);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recordatorio agregado')),
        );
      }
    }
  }

  Future<void> _showEditReminderDialog(Reminder reminder) async {
    final result = await showModalBottomSheet<ReminderDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ReminderDialog(reminder: reminder),
    );

    if (result != null) {
      await _saveReminder(result, existingId: reminder.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recordatorio actualizado')),
        );
      }
    }
  }

  Future<void> _saveReminder(ReminderDraft draft, {String? existingId}) async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showMessage('Inicia sesión para guardar recordatorios');
      return;
    }
    final repo = ref.read(reminderRepositoryProvider);

    final reminder = Reminder(
      id: existingId ?? '',
      title: draft.title,
      time: draft.time,
      days: draft.days,
      isHoliday: draft.isHoliday,
      minutesBefore: draft.minutesBefore,
      isEnabled: draft.isEnabled,
      secondTime: draft.secondTime,
      secondDays: draft.secondDays,
      secondIsHoliday: draft.secondIsHoliday,
    );

    if (existingId == null) {
      try {
        final id = await repo.addReminder(user.uid, reminder);
        await NotificationService.instance.scheduleReminder(
          reminder.copyWith(id: id),
        );
        await AnalyticsService.instance.logReminderCreated();
      } catch (_) {
        _showMessage('No se pudo guardar el recordatorio');
      }
    } else {
      try {
        await repo.updateReminder(user.uid, reminder.copyWith(id: existingId));
        await NotificationService.instance.scheduleReminder(
          reminder.copyWith(id: existingId),
        );
        await AnalyticsService.instance.logReminderUpdated();
      } catch (_) {
        _showMessage('No se pudo actualizar el recordatorio');
      }
    }
  }

  Future<void> _toggleReminder(Reminder reminder, bool value) async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showMessage('Inicia sesión para modificar recordatorios');
      return;
    }
    final repo = ref.read(reminderRepositoryProvider);
    final updated = reminder.copyWith(isEnabled: value);
    try {
      await repo.updateReminder(user.uid, updated);
      await NotificationService.instance.scheduleReminder(updated);
    } catch (_) {
      _showMessage('No se pudo actualizar el recordatorio');
    }
  }

  Future<void> _deleteReminder(Reminder reminder) async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showMessage('Inicia sesión para eliminar recordatorios');
      return;
    }
    final repo = ref.read(reminderRepositoryProvider);
    try {
      await repo.deleteReminder(user.uid, reminder.id);
      await NotificationService.instance.cancelReminder(reminder);
      await AnalyticsService.instance.logReminderDeleted();
    } catch (_) {
      _showMessage('No se pudo eliminar el recordatorio');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _ReminderDialog extends StatefulWidget {
  final Reminder? reminder;

  const _ReminderDialog({this.reminder});

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late TimeOfDay _selectedTime;
  late final Set<int> _selectedDays;
  late bool _isHoliday;
  int? _minutesBefore;
  late bool _hasSecondTime;
  TimeOfDay? _secondTime;
  late final Set<int> _secondDays;
  late bool _secondIsHoliday;

  @override
  void initState() {
    super.initState();
    if (widget.reminder != null) {
      // Modo edición - precargar valores
      final reminder = widget.reminder!;
      _titleController = TextEditingController(text: reminder.title);
      _selectedTime = reminder.time;
      _selectedDays = reminder.days.toSet();
      _isHoliday = reminder.isHoliday;
      _minutesBefore = reminder.minutesBefore;
      _hasSecondTime = reminder.secondTime != null;
      _secondTime = reminder.secondTime;
      _secondDays = reminder.secondDays.toSet();
      _secondIsHoliday = reminder.secondIsHoliday;
    } else {
      // Modo creación - valores por defecto
      _titleController = TextEditingController();
      _selectedTime = const TimeOfDay(hour: 12, minute: 0);
      _selectedDays = {};
      _isHoliday = false;
      _hasSecondTime = false;
      _secondDays = {};
      _secondIsHoliday = false;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle + Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 14),
              decoration: BoxDecoration(
                color: const Color(0xFF2F60C5),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(children: [
                Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)))),
                Row(children: [
                  Expanded(child: Text(
                    widget.reminder != null ? 'Editar Recordatorio' : 'Nuevo Recordatorio',
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                  )),
                  IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
                ]),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Título', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87)),
                    const SizedBox(height: 8),
                    Form(
                      key: _formKey,
                      child: TextFormField(
                        controller: _titleController,
                        textInputAction: TextInputAction.next,
                        validator: _validateTitle,
                        decoration: InputDecoration(
                          hintText: 'Ej: Antes del Encendido de Velas',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2F60C5), width: 1.6)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Hora
                    const Text(
                      'Hora',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: _selectedTime,
                        );
                        if (time != null) {
                          setState(() => _selectedTime = time);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.access_time),
                            const SizedBox(width: 12),
                            Text(
                              _formatTimeOfDay(context, _selectedTime),
                              style: const TextStyle(fontSize: 16),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Días de la semana
                    const Text(
                      'Días de la Semana',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildDayChip('L', DateTime.monday),
                        _buildDayChip('M', DateTime.tuesday),
                        _buildDayChip('X', DateTime.wednesday),
                        _buildDayChip('J', DateTime.thursday),
                        _buildDayChip('V', DateTime.friday),
                        _buildDayChip('S', DateTime.saturday),
                        _buildDayChip('D', DateTime.sunday),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Festivos
                    CheckboxListTile(
                      title: const Text('Incluir Festivos'),
                      value: _isHoliday,
                      onChanged: (value) => setState(() => _isHoliday = value ?? false),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 8),

                    // Minutos antes (opcional)
                    CheckboxListTile(
                      title: const Text('Minutos antes (opcional)'),
                      value: _minutesBefore != null,
                      onChanged: (value) {
                        setState(() {
                          _minutesBefore = value == true ? 15 : null;
                        });
                      },
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (_minutesBefore != null) ...[
                      const SizedBox(height: 8),
                      Slider(
                        value: _minutesBefore!.toDouble(),
                        min: 5,
                        max: 60,
                        divisions: 11,
                        label: '$_minutesBefore minutos antes',
                        onChanged: (value) {
                          setState(() => _minutesBefore = value.toInt());
                        },
                      ),
                    ],
                    const SizedBox(height: 14),

                    // Segunda hora opcional
                    CheckboxListTile(
                      title: const Text('Agregar segunda hora'),
                      value: _hasSecondTime,
                      onChanged: (value) {
                        setState(() {
                          _hasSecondTime = value ?? false;
                          if (_hasSecondTime && _secondTime == null) {
                            _secondTime = const TimeOfDay(hour: 13, minute: 0);
                          }
                        });
                      },
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (_hasSecondTime) ...[
                      const SizedBox(height: 14),
                      const Text(
                        'Segunda Hora',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () async {
                          final time = await showTimePicker(
                            context: context,
                            initialTime: _secondTime ?? const TimeOfDay(hour: 13, minute: 0),
                          );
                          if (time != null) {
                            setState(() => _secondTime = time);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.access_time),
                              const SizedBox(width: 12),
                              Text(
                                _secondTime != null
                                    ? _formatTimeOfDay(context, _secondTime!)
                                    : 'Seleccionar hora',
                                style: const TextStyle(fontSize: 16),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Días para Segunda Hora',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildSecondDayChip('L', DateTime.monday),
                          _buildSecondDayChip('M', DateTime.tuesday),
                          _buildSecondDayChip('X', DateTime.wednesday),
                          _buildSecondDayChip('J', DateTime.thursday),
                          _buildSecondDayChip('V', DateTime.friday),
                          _buildSecondDayChip('S', DateTime.saturday),
                          _buildSecondDayChip('D', DateTime.sunday),
                        ],
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        title: const Text('Incluir Festivos (segunda hora)'),
                        value: _secondIsHoliday,
                        onChanged: (value) => setState(() => _secondIsHoliday = value ?? false),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            SafeArea(top: false, child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2F60C5), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: _validateAndSave,
                  child: const Text('Guardar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                )),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, height: 44, child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Cancelar', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                )),
              ]),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildDayChip(String label, int day) {
    final isSelected = _selectedDays.contains(day);
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          if (selected) {
            _selectedDays.add(day);
          } else {
            _selectedDays.remove(day);
          }
        });
      },
    );
  }

  Widget _buildSecondDayChip(String label, int day) {
    final isSelected = _secondDays.contains(day);
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          if (selected) {
            _secondDays.add(day);
          } else {
            _secondDays.remove(day);
          }
        });
      },
    );
  }

  String _formatTimeOfDay(BuildContext context, TimeOfDay time) {
    final localizations = MaterialLocalizations.of(context);
    return localizations.formatTimeOfDay(time, alwaysUse24HourFormat: false);
  }

  void _validateAndSave() {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    if (_selectedDays.isEmpty && !_isHoliday) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona al menos un día o festivos')),
      );
      return;
    }

    if (_hasSecondTime && (_secondDays.isEmpty && !_secondIsHoliday)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona días para la segunda hora')),
      );
      return;
    }

    final reminder = ReminderDraft(
      title: _titleController.text.trim(),
      time: _selectedTime,
      days: _selectedDays.toList(),
      isHoliday: _isHoliday,
      minutesBefore: _minutesBefore,
      isEnabled: widget.reminder?.isEnabled ?? true,
      secondTime: _hasSecondTime ? _secondTime : null,
      secondDays: _hasSecondTime ? _secondDays.toList() : <int>[],
      secondIsHoliday: _hasSecondTime ? _secondIsHoliday : false,
    );

    Navigator.pop(context, reminder);
  }

  String? _validateTitle(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Ingresa un título';
    if (text.length < 3) return 'Título muy corto';
    return null;
  }
}

class ReminderDraft {
  const ReminderDraft({
    required this.title,
    required this.time,
    required this.days,
    required this.isHoliday,
    required this.minutesBefore,
    required this.isEnabled,
    required this.secondTime,
    required this.secondDays,
    required this.secondIsHoliday,
  });

  final String title;
  final TimeOfDay time;
  final List<int> days;
  final bool isHoliday;
  final int? minutesBefore;
  final bool isEnabled;
  final TimeOfDay? secondTime;
  final List<int> secondDays;
  final bool secondIsHoliday;
}
