import 'package:flutter/material.dart';

class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  // Lista de recordatorios
  final List<ReminderItem> reminders = [
    ReminderItem(
      id: '1',
      title: 'Antes del Encendido de Velas',
      time: const TimeOfDay(hour: 17, minute: 45),
      days: [DateTime.friday],
      isHoliday: true,
      minutesBefore: 15,
      isEnabled: false,
    ),
    ReminderItem(
      id: '2',
      title: 'Recordatorio de Racha',
      time: const TimeOfDay(hour: 20, minute: 0),
      days: [DateTime.monday, DateTime.tuesday, DateTime.wednesday, DateTime.thursday],
      isHoliday: false,
      isEnabled: true,
      secondTime: const TimeOfDay(hour: 13, minute: 0),
      secondDays: [DateTime.friday],
      secondIsHoliday: true,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFFF9500);
    const red = Color(0xFFE05A4F);

    return Column(
      children: [
        Expanded(
          child: reminders.isEmpty
              ? const Center(
                  child: Text(
                    'No hay recordatorios\nToca el botón para agregar uno',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
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
                      onToggle: (value) {
                        setState(() {
                          reminders[index].isEnabled = value;
                        });
                      },
                      onEdit: () => _showEditReminderDialog(index),
                      activeColor: orange,
                    );
                  },
                ),
        ),
        // Botón agregar recordatorio
        Container(
          padding: const EdgeInsets.all(18),
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
            child: SizedBox(
              width: double.infinity,
              height: 50,
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
                  '+ AGREGAR RECORDATORIO',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReminderItem({
    required ReminderItem reminder,
    required ValueChanged<bool> onToggle,
    required VoidCallback onEdit,
    required Color activeColor,
  }) {
    final subtitle = reminder.generateSubtitle();
    final subtitle2 = reminder.generateSubtitle2();

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
            Switch(
              value: reminder.isEnabled,
              onChanged: onToggle,
              activeColor: activeColor,
              activeTrackColor: activeColor.withOpacity(0.5),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddReminderDialog() async {
    final result = await showDialog<ReminderItem>(
      context: context,
      builder: (context) => const _ReminderDialog(),
    );

    if (result != null) {
      setState(() {
        reminders.add(result);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recordatorio agregado')),
        );
      }
    }
  }

  Future<void> _showEditReminderDialog(int index) async {
    final reminder = reminders[index];
    final result = await showDialog<ReminderItem>(
      context: context,
      builder: (context) => _ReminderDialog(reminder: reminder),
    );

    if (result != null) {
      setState(() {
        reminders[index] = result;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recordatorio actualizado')),
        );
      }
    }
  }
}

class _ReminderDialog extends StatefulWidget {
  final ReminderItem? reminder;

  const _ReminderDialog({this.reminder});

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
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
      _secondDays = reminder.secondDays?.toSet() ?? {};
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
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF2F60C5),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.reminder != null ? 'Editar Recordatorio' : 'Nuevo Recordatorio',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Título
                    const Text(
                      'Título',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _titleController,
                      decoration: InputDecoration(
                        hintText: 'Ej: Antes del Encendido de Velas',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

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
                    const SizedBox(height: 24),

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
                    const SizedBox(height: 16),

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
                    const SizedBox(height: 16),

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
                      const SizedBox(height: 16),
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
                      const SizedBox(height: 16),
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
            // Footer buttons
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _validateAndSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2F60C5),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Guardar'),
                  ),
                ],
              ),
            ),
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
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor ingresa un título')),
      );
      return;
    }

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

    final reminder = ReminderItem(
      id: widget.reminder?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: _titleController.text.trim(),
      time: _selectedTime,
      days: _selectedDays.toList(),
      isHoliday: _isHoliday,
      minutesBefore: _minutesBefore,
      isEnabled: widget.reminder?.isEnabled ?? true,
      secondTime: _hasSecondTime ? _secondTime : null,
      secondDays: _hasSecondTime ? _secondDays.toList() : null,
      secondIsHoliday: _hasSecondTime ? _secondIsHoliday : false,
    );

    Navigator.pop(context, reminder);
  }
}

class ReminderItem {
  final String id;
  final String title;
  final TimeOfDay time;
  final List<int> days;
  final bool isHoliday;
  final int? minutesBefore;
  bool isEnabled;
  final TimeOfDay? secondTime;
  final List<int>? secondDays;
  final bool secondIsHoliday;

  ReminderItem({
    required this.id,
    required this.title,
    required this.time,
    required this.days,
    required this.isHoliday,
    this.minutesBefore,
    required this.isEnabled,
    this.secondTime,
    this.secondDays,
    this.secondIsHoliday = false,
  });

  String generateSubtitle() {
    final timeStr = _formatTime(time);
    final dayNames = _getDayNames(days);
    
    String subtitle = '';
    if (dayNames.isNotEmpty) {
      subtitle = '$dayNames - $timeStr';
    } else if (isHoliday) {
      subtitle = 'Festivos - $timeStr';
    }
    
    if (minutesBefore != null) {
      subtitle += ' - $minutesBefore Min Antes';
    }
    
    return subtitle;
  }

  String? generateSubtitle2() {
    if (secondTime == null) return null;
    
    final timeStr = _formatTime(secondTime!);
    final dayNames = secondDays != null && secondDays!.isNotEmpty
        ? _getDayNames(secondDays!)
        : '';
    
    String subtitle = '';
    if (dayNames.isNotEmpty) {
      subtitle = '$dayNames - $timeStr';
    } else if (secondIsHoliday) {
      subtitle = 'Festivos - $timeStr';
    }
    
    return subtitle;
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  String _getDayNames(List<int> dayNumbers) {
    const dayNames = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
    const fullDayNames = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
    
    if (dayNumbers.length == 1) {
      return fullDayNames[dayNumbers[0] - 1];
    }
    
    if (dayNumbers.length == 5 && 
        dayNumbers.contains(DateTime.monday) &&
        dayNumbers.contains(DateTime.tuesday) &&
        dayNumbers.contains(DateTime.wednesday) &&
        dayNumbers.contains(DateTime.thursday) &&
        dayNumbers.contains(DateTime.friday)) {
      return 'Días de Semana';
    }
    
    if (dayNumbers.length == 7) {
      return 'Todos los Días';
    }
    
    if (dayNumbers.contains(DateTime.friday) && dayNumbers.length == 1) {
      return 'Viernes';
    }
    
    if (dayNumbers.contains(DateTime.friday) && dayNumbers.length <= 3) {
      final otherDays = dayNumbers.where((d) => d != DateTime.friday).toList();
      if (otherDays.isEmpty) {
        return 'Viernes';
      }
      return 'Viernes y ${_getDayNames(otherDays)}';
    }
    
    final names = dayNumbers.map((d) => dayNames[d - 1]).join(', ');
    return names;
  }
}
