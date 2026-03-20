import 'package:flutter/material.dart';

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
      'minutesBefore': minutesBefore,
      'isEnabled': isEnabled,
      'secondTimeHour': secondTime?.hour,
      'secondTimeMinute': secondTime?.minute,
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

  String get subtitle {
    final timeStr = _formatTime(time);
    final dayNames = _getDayNames(days);

    var result = '';
    if (dayNames.isNotEmpty) {
      result = '$dayNames - $timeStr';
    } else if (isHoliday) {
      result = 'Festivos - $timeStr';
    }

    if (minutesBefore != null) {
      result += ' - $minutesBefore min antes';
    }

    return result;
  }

  String? get subtitleSecondary {
    if (secondTime == null) return null;
    final timeStr = _formatTime(secondTime!);
    final dayNames = _getDayNames(secondDays);
    if (dayNames.isNotEmpty) {
      return '$dayNames - $timeStr';
    }
    if (secondIsHoliday) {
      return 'Festivos - $timeStr';
    }
    return null;
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  String _getDayNames(List<int> dayNumbers) {
    const dayNames = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

    if (dayNumbers.length == 5 &&
        dayNumbers.contains(DateTime.monday) &&
        dayNumbers.contains(DateTime.tuesday) &&
        dayNumbers.contains(DateTime.wednesday) &&
        dayNumbers.contains(DateTime.thursday) &&
        dayNumbers.contains(DateTime.friday)) {
      return 'Días de Semana';
    }

    if (dayNumbers.length == 7) {
      return 'Todos los días';
    }

    return dayNumbers.map((d) => dayNames[d - 1]).join(', ');
  }
}
