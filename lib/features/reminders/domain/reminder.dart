import 'package:flutter/material.dart';

import '../../../core/l10n/s.dart';

class Reminder {
  const Reminder({
    required this.id,
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

  final String id;
  final String title;
  final TimeOfDay time;
  final List<int> days;
  final bool isHoliday;
  final int? minutesBefore;
  final bool isEnabled;
  final TimeOfDay? secondTime;
  final List<int> secondDays;
  final bool secondIsHoliday;

  Reminder copyWith({
    String? id,
    String? title,
    TimeOfDay? time,
    List<int>? days,
    bool? isHoliday,
    int? minutesBefore,
    bool? isEnabled,
    TimeOfDay? secondTime,
    List<int>? secondDays,
    bool? secondIsHoliday,
  }) {
    return Reminder(
      id: id ?? this.id,
      title: title ?? this.title,
      time: time ?? this.time,
      days: days ?? this.days,
      isHoliday: isHoliday ?? this.isHoliday,
      minutesBefore: minutesBefore ?? this.minutesBefore,
      isEnabled: isEnabled ?? this.isEnabled,
      secondTime: secondTime ?? this.secondTime,
      secondDays: secondDays ?? this.secondDays,
      secondIsHoliday: secondIsHoliday ?? this.secondIsHoliday,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'timeHour': time.hour,
      'timeMinute': time.minute,
      'days': days,
      'isHoliday': isHoliday,
      'minutesBefore': minutesBefore, // always write; null clears stale value on merge
      'isEnabled': isEnabled,
      'secondTimeHour': secondTime?.hour,   // null clears stale value on merge
      'secondTimeMinute': secondTime?.minute, // null clears stale value on merge
      'secondDays': secondDays,
      'secondIsHoliday': secondIsHoliday,
    };
  }

  static Reminder fromMap(String id, Map<String, dynamic> map) {
    final timeHour = map['timeHour'] as int? ?? 12;
    final timeMinute = map['timeMinute'] as int? ?? 0;
    final secondHour = map['secondTimeHour'] as int?;
    final secondMinute = map['secondTimeMinute'] as int?;

    return Reminder(
      id: id,
      title: map['title'] as String? ?? '',
      time: TimeOfDay(hour: timeHour, minute: timeMinute),
      days: List<int>.from(map['days'] as List? ?? const <int>[]),
      isHoliday: map['isHoliday'] as bool? ?? false,
      minutesBefore: map['minutesBefore'] as int?,
      isEnabled: map['isEnabled'] as bool? ?? true,
      secondTime: (secondHour != null && secondMinute != null)
          ? TimeOfDay(hour: secondHour, minute: secondMinute)
          : null,
      secondDays: List<int>.from(map['secondDays'] as List? ?? const <int>[]),
      secondIsHoliday: map['secondIsHoliday'] as bool? ?? false,
    );
  }

  /// Spanish-only subtitle used for push notification bodies.
  String get subtitle => _subtitleEs();
  String? get subtitleSecondary => _subtitleSecondaryEs();

  String _subtitleEs() {
    final timeStr = _formatTime(time);
    final dayNames = _getDayNamesEs(days);
    var result = '';
    if (dayNames.isNotEmpty) {
      result = '$dayNames - $timeStr';
    } else if (isHoliday) {
      result = 'Viernes y festivos - $timeStr';
    }
    if (minutesBefore != null) result += ' - $minutesBefore min antes';
    return result;
  }

  String? _subtitleSecondaryEs() {
    if (secondTime == null) return null;
    final timeStr = _formatTime(secondTime!);
    final dayNames = _getDayNamesEs(secondDays);
    if (dayNames.isNotEmpty) return '$dayNames - $timeStr';
    if (secondIsHoliday) return 'Viernes y festivos - $timeStr';
    return null;
  }

  String _getDayNamesEs(List<int> dayNumbers) {
    if (dayNumbers.length == 7) return 'Todos los días';
    if (dayNumbers.length == 5 &&
        dayNumbers.every((d) => d >= DateTime.monday && d <= DateTime.friday)) {
      return 'Días de Semana';
    }
    const names = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
    return dayNumbers.where((d) => d >= 1 && d <= 7).map((d) => names[d - 1]).join(', ');
  }

  String subtitleFor(S tr) {
    final timeStr = _formatTime(time);
    final dayNames = _getDayNames(days, tr);

    var result = '';
    if (dayNames.isNotEmpty) {
      result = '$dayNames - $timeStr';
    } else if (isHoliday) {
      result = '${tr.repeatFridayHoliday} - $timeStr';
    }

    if (minutesBefore != null) {
      result += ' - ${tr.minBefore(minutesBefore.toString())}';
    }

    return result;
  }

  String? subtitleSecondaryFor(S tr) {
    if (secondTime == null) return null;
    final timeStr = _formatTime(secondTime!);
    final dayNames = _getDayNames(secondDays, tr);
    if (dayNames.isNotEmpty) {
      return '$dayNames - $timeStr';
    }
    if (secondIsHoliday) {
      return '${tr.repeatFridayHoliday} - $timeStr';
    }
    return null;
  }

  String _formatTime(TimeOfDay t) {
    final hour = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final minute = t.minute.toString().padLeft(2, '0');
    final period = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  String _getDayNames(List<int> dayNumbers, S tr) {
    if (dayNumbers.length == 5 &&
        dayNumbers.contains(DateTime.monday) &&
        dayNumbers.contains(DateTime.tuesday) &&
        dayNumbers.contains(DateTime.wednesday) &&
        dayNumbers.contains(DateTime.thursday) &&
        dayNumbers.contains(DateTime.friday)) {
      return tr.weekdaysLabel;
    }

    if (dayNumbers.length == 7) {
      return tr.everyDay;
    }

    final names = [
      tr.dayMonShort, tr.dayTueShort, tr.dayWedShort, tr.dayThuShort,
      tr.dayFriShort, tr.daySatShort, tr.daySunShort,
    ];
    return dayNumbers.where((d) => d >= 1 && d <= 7).map((d) => names[d - 1]).join(', ');
  }
}
