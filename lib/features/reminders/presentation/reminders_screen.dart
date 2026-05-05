import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../../core/widgets/shimmer_list.dart';
import '../../../core/widgets/empty_state.dart';
import '../../../core/widgets/option_picker_sheet.dart';

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
    final tr = S.of(context);
    return Column(
      children: [
        Expanded(
          child: ref.watch(userRemindersProvider).when(
                data: (reminders) {
                  if (reminders.isEmpty) {
                    return EmptyState(
                      icon: Icons.notifications_none_rounded,
                      iconColor: const Color(0xFFD97706),
                      title: tr.noReminders,
                      subtitle: tr.tapToAddReminder,
                    );
                  }

                  // ListView.separated with a transparent SizedBox spacer so
                  // each reminder reads as its own outlined card, matching
                  // the Settings + Wallet visual language. Replaces the old
                  // edge-to-edge Divider list which felt visually inconsistent
                  // with the rest of the app.
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    itemCount: reminders.length,
                    separatorBuilder: (context, i) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final reminder = reminders[index];
                      return Dismissible(
                        key: ValueKey(reminder.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: AlignmentDirectional.centerEnd,
                          padding: const EdgeInsetsDirectional.only(end: 20),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.delete_outline,
                              color: Colors.red.shade400),
                        ),
                        confirmDismiss: (_) => _confirmDelete(reminder),
                        onDismissed: (_) => _deleteReminder(reminder),
                        child: _buildReminderItem(
                          reminder: reminder,
                          onToggle: (v) => _toggleReminder(reminder, v),
                          onEdit: () => _showEditReminderDialog(reminder),
                        ),
                      );
                    },
                  );
                },
                loading: () => const ShimmerList(count: 5, itemHeight: 80),
                error: (error, stack) =>
                    Center(child: Text(tr.errorLoadingReminders)),
              ),
        ),
        ref.watch(userRemindersProvider).whenData((reminders) {
          final atLimit = reminders.length >= kMaxReminders;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                height: AppTokens.buttonHeight,
                child: Tooltip(
                  message: atLimit ? tr.reminderLimitReached(kMaxReminders) : '',
                  child: OutlinedButton(
                    onPressed: atLimit ? null : _showAddReminderDialog,
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppTokens.radiusMd),
                      ),
                    ),
                    child: Text(
                      atLimit
                          ? tr.reminderLimitReached(kMaxReminders)
                          : tr.addReminder,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).valueOrNull ??
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SafeArea(
            child: SizedBox(
              width: double.infinity,
              height: AppTokens.buttonHeight,
              child: OutlinedButton(
                onPressed: _showAddReminderDialog,
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppTokens.radiusMd),
                  ),
                ),
                child: Text(
                  tr.addReminder,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
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
    required Reminder reminder,
    required ValueChanged<bool> onToggle,
    required VoidCallback onEdit,
  }) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final subtitle = reminder.subtitleFor(tr);
    final subtitle2 = reminder.subtitleSecondaryFor(tr);

    // Outlined surface container — same recipe as Settings' _buildActionButton
    // and Wallet's _ActionRow, so the three screens share one visual language.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: cs.surface,
            border: Border.all(color: cs.outline),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reminder.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    if (subtitle2 != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle2,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(
                value: reminder.isEnabled,
                onChanged: onToggle,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(Reminder reminder) {
    final tr = S.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.deleteReminderTitle),
        content: Text(tr.deleteReminderConfirm(reminder.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddReminderDialog() async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<ReminderDraft>(
      MaterialPageRoute(builder: (_) => const _ReminderFormPage()),
    );

    if (result != null) {
      final ok = await _saveReminder(result);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).reminderAdded)),
        );
      }
    }
  }

  Future<void> _showEditReminderDialog(Reminder reminder) async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<ReminderDraft>(
      MaterialPageRoute(
          builder: (_) => _ReminderFormPage(reminder: reminder)),
    );

    if (result != null) {
      final ok = await _saveReminder(result, existingId: reminder.id);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).reminderUpdated)),
        );
      }
    }
  }

  Future<bool> _saveReminder(ReminderDraft draft,
      {String? existingId}) async {
    final tr = S.of(context);
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showMessage(tr.signInToSaveReminders);
      return false;
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
      // Fast UI-layer guard: avoids the server round-trip in the common case.
      final reminders = ref.read(userRemindersProvider).valueOrNull ?? [];
      if (reminders.length >= kMaxReminders) {
        if (mounted) _showMessage(tr.reminderLimitReached(kMaxReminders));
        return false;
      }
      try {
        final id = await repo.addReminder(user.uid, reminder);
        try {
          await NotificationService.instance.scheduleReminder(
            reminder.copyWith(id: id),
            tr: tr,
          );
        } catch (e) {
          // Notification scheduling may fail if exact-alarm permission is not
          // granted on Android 12+. The reminder is still saved in Firestore.
          debugPrint('scheduleReminder failed: $e');
        }
        try { await AnalyticsService.instance.logReminderCreated(); } catch (_) {}
        return true;
      } catch (e, st) {
        debugPrint('addReminder failed: $e\n$st');
        if (mounted) {
          // Surface the server-side limit error with a friendlier message.
          final isLimitError = e.toString().contains('resource-exhausted') ||
              e.toString().contains('límite');
          _showMessage(
              isLimitError ? tr.reminderLimitReached(kMaxReminders) : tr.couldNotSaveReminder);
        }
        return false;
      }
    } else {
      try {
        await repo.updateReminder(
            user.uid, reminder.copyWith(id: existingId));
        try {
          await NotificationService.instance.scheduleReminder(
            reminder.copyWith(id: existingId),
            tr: tr,
          );
        } catch (e) {
          debugPrint('scheduleReminder failed: $e');
        }
        try { await AnalyticsService.instance.logReminderUpdated(); } catch (_) {}
        return true;
      } catch (e, st) {
        debugPrint('updateReminder failed: $e\n$st');
        if (mounted) _showMessage(tr.couldNotUpdateReminder);
        return false;
      }
    }
  }

  Future<void> _toggleReminder(Reminder reminder, bool value) async {
    final tr = S.of(context);
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showMessage(tr.signInToModify);
      return;
    }
    final repo = ref.read(reminderRepositoryProvider);
    final updated = reminder.copyWith(isEnabled: value);
    try {
      await repo.updateReminder(user.uid, updated);
    } catch (_) {
      if (mounted) _showMessage(tr.couldNotUpdateReminder);
      return;
    }
    try {
      await NotificationService.instance.scheduleReminder(updated, tr: tr);
    } catch (e) {
      debugPrint('scheduleReminder failed: $e');
    }
  }

  Future<void> _deleteReminder(Reminder reminder) async {
    final tr = S.of(context);
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _showMessage(tr.signInToDelete);
      return;
    }
    final repo = ref.read(reminderRepositoryProvider);
    try {
      await repo.deleteReminder(user.uid, reminder.id);
    } catch (_) {
      if (mounted) _showMessage(tr.couldNotDelete);
      return;
    }
    try {
      await NotificationService.instance.cancelReminder(reminder);
    } catch (e) {
      debugPrint('cancelReminder failed: $e');
    }
    try { await AnalyticsService.instance.logReminderDeleted(); } catch (_) {}
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

// ---------------------------------------------------------------------------
// Repeat option enum
// ---------------------------------------------------------------------------

enum _RepeatOption {
  daily,
  weekdays,
  fridayHoliday,
  chooseDate,
  custom;

}

// ---------------------------------------------------------------------------
// Full-screen reminder form page
// ---------------------------------------------------------------------------

class _ReminderFormPage extends StatefulWidget {
  final Reminder? reminder;
  const _ReminderFormPage({this.reminder});

  @override
  State<_ReminderFormPage> createState() => _ReminderFormPageState();
}

class _ReminderFormPageState extends State<_ReminderFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late TimeOfDay _selectedTime;
  late _RepeatOption _repeatOption;
  late final Set<int> _selectedDays;
  late bool _isHoliday;
  int? _minutesBefore;
  DateTime? _selectedDate;

  late bool _hasSecondTime;
  TimeOfDay? _secondTime;
  late Set<int> _secondDays;
  late bool _secondIsHoliday;

  @override
  void initState() {
    super.initState();
    final r = widget.reminder;
    if (r != null) {
      _titleController = TextEditingController(text: r.title);
      _selectedTime = r.time;
      _selectedDays = r.days.toSet();
      _isHoliday = r.isHoliday;
      _minutesBefore = r.minutesBefore;
      _hasSecondTime = r.secondTime != null;
      _secondTime = r.secondTime;
      _secondDays = r.secondDays.toSet();
      _secondIsHoliday = r.secondIsHoliday;
      _repeatOption = _inferRepeatOption(r.days, r.isHoliday);
    } else {
      _titleController = TextEditingController();
      _selectedTime = const TimeOfDay(hour: 12, minute: 0);
      _selectedDays = {1, 2, 3, 4, 5, 6, 7};
      _isHoliday = false;
      _minutesBefore = null;
      _hasSecondTime = false;
      _secondDays = {};
      _secondIsHoliday = false;
      _repeatOption = _RepeatOption.daily;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  static _RepeatOption _inferRepeatOption(List<int> days, bool isHoliday) {
    final s = days.toSet();
    if (s.length == 7 && s.containsAll([1, 2, 3, 4, 5, 6, 7])) {
      return _RepeatOption.daily;
    }
    if (s.length == 5 && s.containsAll([1, 2, 3, 4, 5]) && !isHoliday) {
      return _RepeatOption.weekdays;
    }
    if (s.length == 1 && s.contains(5) && isHoliday) {
      return _RepeatOption.fridayHoliday;
    }
    return _RepeatOption.custom;
  }

  void _applyRepeatOption(_RepeatOption option) {
    setState(() {
      _repeatOption = option;
      switch (option) {
        case _RepeatOption.daily:
          _selectedDays
            ..clear()
            ..addAll([1, 2, 3, 4, 5, 6, 7]);
          _isHoliday = false;
          _selectedDate = null;
        case _RepeatOption.weekdays:
          _selectedDays
            ..clear()
            ..addAll([1, 2, 3, 4, 5]);
          _isHoliday = false;
          _selectedDate = null;
        case _RepeatOption.fridayHoliday:
          _selectedDays
            ..clear()
            ..add(5);
          _isHoliday = true;
          _selectedDate = null;
        case _RepeatOption.chooseDate:
          _selectedDays.clear();
          _isHoliday = false;
          _selectedDate ??= DateTime.now();
        case _RepeatOption.custom:
          _selectedDate = null;
      }
      // Keep secondDays in sync with primary days when a second time is enabled.
      if (_hasSecondTime) {
        _secondDays
          ..clear()
          ..addAll(_selectedDays);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final isEditing = widget.reminder != null;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Directionality.of(context) == TextDirection.rtl ? Icons.arrow_forward : Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          isEditing ? tr.editReminder : tr.newReminder,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        centerTitle: false,
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel(tr.labelSection),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _titleController,
                      textInputAction: TextInputAction.done,
                      validator: (v) => _validateTitle(context, v),
                      decoration:
                          _inputDecoration(tr.reminderTitleHint),
                    ),
                    const SizedBox(height: 20),
                    _sectionLabel(tr.timeSection),
                    const SizedBox(height: 8),
                    _buildTimePicker(),
                    const SizedBox(height: 20),
                    _sectionLabel(tr.repeatSection),
                    const SizedBox(height: 8),
                    _buildRepeatDropdown(),
                    if (_repeatOption == _RepeatOption.chooseDate) ...[
                      const SizedBox(height: 20),
                      _sectionLabel(tr.dateSection),
                      const SizedBox(height: 8),
                      _buildDatePicker(),
                    ],
                    if (_repeatOption == _RepeatOption.custom) ...[
                      const SizedBox(height: 20),
                      _sectionLabel(tr.daysSection),
                      const SizedBox(height: 8),
                      _buildDayChips(),
                      const SizedBox(height: 12),
                      _buildHolidayToggle(),
                    ],
                    const SizedBox(height: 24),
                    const Divider(height: 1),
                    const SizedBox(height: 20),
                    _sectionLabel(tr.secondTimeSection),
                    const SizedBox(height: 8),
                    _buildSecondTimeToggle(),
                    if (_hasSecondTime) ...[
                      const SizedBox(height: 16),
                      _sectionLabel(tr.secondTimeLabel),
                      const SizedBox(height: 8),
                      _buildSecondTimePicker(),
                    ],
                    if (_isHoliday || _repeatOption == _RepeatOption.fridayHoliday) ...[
                      const SizedBox(height: 24),
                      const Divider(height: 1),
                      const SizedBox(height: 20),
                      _sectionLabel(tr.advanceNoticeSection),
                      const SizedBox(height: 8),
                      _buildMinutesBeforeDropdown(),
                    ],
                  ],
                ),
              ),
            ),
            _buildBottomButtons(),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        letterSpacing: 1.2,
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  Widget _buildTimePicker() {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      onTap: _pickTime,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(_formatTime(_selectedTime), style: const TextStyle(fontSize: 15)),
            ),
            Icon(Icons.arrow_drop_down, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  String _minutesBeforeLabel(int? value) {
    final tr = S.of(context);
    return switch (value) {
      null => tr.atExactTime,
      30 => tr.minutesBefore30,
      60 => tr.minutesBefore60,
      90 => tr.minutesBefore90,
      120 => tr.minutesBefore120,
      _ => '$value min',
    };
  }

  Widget _buildMinutesBeforeDropdown() {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      onTap: () async {
        final picked = await showOptionPickerSheet<int?>(
          context: context,
          currentValue: _minutesBefore,
          options: [
            (value: null, label: _minutesBeforeLabel(null)),
            (value: 30, label: _minutesBeforeLabel(30)),
            (value: 60, label: _minutesBeforeLabel(60)),
            (value: 90, label: _minutesBeforeLabel(90)),
            (value: 120, label: _minutesBeforeLabel(120)),
          ],
        );
        // Distinguishing "user dismissed sheet" from "user picked null
        // (= 'a la hora exacta')" is impossible with the helper's API
        // (both return null). Mitigation: skip the setState when nothing
        // changed, so a dismiss is a no-op.
        if (!mounted || picked == _minutesBefore) return;
        setState(() => _minutesBefore = picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _minutesBeforeLabel(_minutesBefore),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: cs.onSurface),
              ),
            ),
            Icon(Icons.keyboard_arrow_down, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  String _repeatOptionLabel(_RepeatOption o) {
    final tr = S.of(context);
    return switch (o) {
      _RepeatOption.daily => tr.repeatDaily,
      _RepeatOption.weekdays => tr.repeatWeekdays,
      _RepeatOption.fridayHoliday => tr.repeatFridayHoliday,
      _RepeatOption.chooseDate => tr.repeatChooseDate,
      _RepeatOption.custom => tr.repeatCustom,
    };
  }

  Widget _buildRepeatDropdown() {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      onTap: () async {
        final picked = await showOptionPickerSheet<_RepeatOption>(
          context: context,
          currentValue: _repeatOption,
          options: [
            for (final o in _RepeatOption.values)
              (value: o, label: _repeatOptionLabel(o)),
          ],
        );
        if (picked != null) _applyRepeatOption(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _repeatOptionLabel(_repeatOption),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: cs.onSurface),
              ),
            ),
            Icon(Icons.keyboard_arrow_down, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildDatePicker() {
    final dateText = _selectedDate != null
        ? '${_selectedDate!.day.toString().padLeft(2, '0')}/'
            '${_selectedDate!.month.toString().padLeft(2, '0')}/'
            '${_selectedDate!.year}'
        : S.of(context).selectDate;

    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      onTap: _pickDate,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today_outlined, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(dateText, style: const TextStyle(fontSize: 15)),
            ),
            Icon(Icons.arrow_drop_down, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildDayChips() {
    final tr = S.of(context);
    final labels = [tr.dayL, tr.dayM, tr.dayX, tr.dayJ, tr.dayV, tr.dayS, tr.dayD];
    const dayValues = [
      DateTime.monday,
      DateTime.tuesday,
      DateTime.wednesday,
      DateTime.thursday,
      DateTime.friday,
      DateTime.saturday,
      DateTime.sunday,
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(7, (i) {
        final day = dayValues[i];
        final selected = _selectedDays.contains(day);
        final cs = Theme.of(context).colorScheme;
        return GestureDetector(
          onTap: () {
            setState(() {
              if (selected) {
                _selectedDays.remove(day);
              } else {
                _selectedDays.add(day);
              }
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? AppTokens.primaryBlue : cs.surface,
              border: Border.all(
                color: selected ? AppTokens.primaryBlue : cs.outline,
              ),
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : cs.onSurfaceVariant,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildHolidayToggle() {
    return GestureDetector(
      onTap: () => setState(() => _isHoliday = !_isHoliday),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: _isHoliday,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
              onChanged: (v) =>
                  setState(() => _isHoliday = v ?? false),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            S.of(context).includeHolidays,
            style: const TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomButtons() {
    final tr = S.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: AppTokens.buttonHeight,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppTokens.radiusMd),
                    ),
                  ),
                  child: Text(
                    tr.cancelBtn,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: AppTokens.buttonHeight,
                child: OutlinedButton(
                  onPressed: _validateAndSave,
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppTokens.radiusMd),
                    ),
                  ),
                  child: Text(
                    tr.saveBtn,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
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

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: _bluePickerBuilder,
    );
    if (time != null && mounted) setState(() => _selectedTime = time);
  }

  /// Wraps the showTimePicker subtree with an overridden ColorScheme
  /// so the clock dial, hour/minute selection, and OK button render in
  /// AppTokens.primaryBlue instead of the tenant primary.
  Widget _bluePickerBuilder(BuildContext ctx, Widget? child) {
    final base = Theme.of(ctx);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: AppTokens.primaryBlue,
          onPrimary: Colors.white,
        ),
      ),
      child: child!,
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      builder: _bluePickerBuilder,
    );
    if (date != null && mounted) setState(() => _selectedDate = date);
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  void _validateAndSave() {
    if (_formKey.currentState?.validate() != true) return;

    List<int> days;
    bool isHoliday = _isHoliday;

    switch (_repeatOption) {
      case _RepeatOption.daily:
        days = [1, 2, 3, 4, 5, 6, 7];
        isHoliday = false;
      case _RepeatOption.weekdays:
        days = [1, 2, 3, 4, 5];
        isHoliday = false;
      case _RepeatOption.fridayHoliday:
        days = [5];
        isHoliday = true;
      case _RepeatOption.chooseDate:
        if (_selectedDate == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).selectDateRequired)),
          );
          return;
        }
        days = [_selectedDate!.weekday];
        isHoliday = false;
      case _RepeatOption.custom:
        days = _selectedDays.toList()..sort();
        if (days.isEmpty && !isHoliday) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(S.of(context).selectDayOrHoliday)),
          );
          return;
        }
    }

    Navigator.pop(
      context,
      ReminderDraft(
        title: _titleController.text.trim(),
        time: _selectedTime,
        days: days,
        isHoliday: isHoliday,
        minutesBefore: _minutesBefore,
        isEnabled: widget.reminder?.isEnabled ?? true,
        secondTime: _hasSecondTime ? _secondTime : null,
        secondDays: _hasSecondTime ? _secondDays.toList() : <int>[],
        secondIsHoliday: _hasSecondTime ? _secondIsHoliday : false,
      ),
    );
  }

  Widget _buildSecondTimeToggle() {
    final tr = S.of(context);
    return GestureDetector(
      onTap: () {
        setState(() {
          _hasSecondTime = !_hasSecondTime;
          if (_hasSecondTime) {
            _secondTime ??= const TimeOfDay(hour: 18, minute: 0);
            if (_secondDays.isEmpty) _secondDays.addAll(_selectedDays);
            _secondIsHoliday = _isHoliday;
          }
        });
      },
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: _hasSecondTime,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
              onChanged: (v) {
                setState(() {
                  _hasSecondTime = v ?? false;
                  if (_hasSecondTime) {
                    _secondTime ??= const TimeOfDay(hour: 18, minute: 0);
                    if (_secondDays.isEmpty) _secondDays.addAll(_selectedDays);
                    _secondIsHoliday = _isHoliday;
                  }
                });
              },
            ),
          ),
          const SizedBox(width: 10),
          Text(
            tr.addSecondTime,
            style: const TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildSecondTimePicker() {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      onTap: _pickSecondTime,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _formatTime(_secondTime ?? const TimeOfDay(hour: 18, minute: 0)),
                style: const TextStyle(fontSize: 15),
              ),
            ),
            Icon(Icons.arrow_drop_down, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSecondTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _secondTime ?? const TimeOfDay(hour: 18, minute: 0),
      builder: _bluePickerBuilder,
    );
    if (time != null && mounted) {
      setState(() {
        _secondTime = time;
        _secondDays
          ..clear()
          ..addAll(_selectedDays);
        _secondIsHoliday = _isHoliday;
      });
    }
  }

  String? _validateTitle(BuildContext context, String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return S.of(context).enterTitle;
    if (text.length < 3) return S.of(context).titleTooShort;
    return null;
  }
}

// ---------------------------------------------------------------------------
// Draft model (unchanged)
// ---------------------------------------------------------------------------

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
