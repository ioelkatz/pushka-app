import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/reminders/domain/reminder.dart';

void main() {
  group('Reminder model', () {
    test('basic construction', () {
      final r = _makeReminder();
      expect(r.id, 'rem_1');
      expect(r.title, 'Shajarit');
      expect(r.time, const TimeOfDay(hour: 7, minute: 30));
      expect(r.isEnabled, true);
    });

    test('copyWith preserves unchanged fields', () {
      final r = _makeReminder();
      final copy = r.copyWith(title: 'Minjá');
      expect(copy.title, 'Minjá');
      expect(copy.id, r.id);
      expect(copy.time, r.time);
      expect(copy.days, r.days);
      expect(copy.isEnabled, r.isEnabled);
    });

    test('copyWith changes specified fields', () {
      final r = _makeReminder();
      final copy = r.copyWith(
        isEnabled: false,
        days: [6, 7],
        isHoliday: true,
      );
      expect(copy.isEnabled, false);
      expect(copy.days, [6, 7]);
      expect(copy.isHoliday, true);
    });
  });

  group('Reminder.toMap / fromMap round-trip', () {
    test('basic fields survive serialization', () {
      final original = _makeReminder();
      final map = original.toMap();
      final restored = Reminder.fromMap(original.id, map);

      expect(restored.title, original.title);
      expect(restored.time, original.time);
      expect(restored.days, original.days);
      expect(restored.isHoliday, original.isHoliday);
      expect(restored.isEnabled, original.isEnabled);
    });

    test('second time fields survive serialization', () {
      final original = _makeReminder(
        secondTime: const TimeOfDay(hour: 18, minute: 0),
        secondDays: [1, 3, 5],
        secondIsHoliday: true,
      );
      final map = original.toMap();
      final restored = Reminder.fromMap(original.id, map);

      expect(restored.secondTime, const TimeOfDay(hour: 18, minute: 0));
      expect(restored.secondDays, [1, 3, 5]);
      expect(restored.secondIsHoliday, true);
    });

    test('null secondTime is preserved', () {
      final original = _makeReminder();
      final map = original.toMap();
      final restored = Reminder.fromMap(original.id, map);
      expect(restored.secondTime, isNull);
    });

    test('minutesBefore survives serialization', () {
      final original = _makeReminder(minutesBefore: 15);
      final map = original.toMap();
      final restored = Reminder.fromMap(original.id, map);
      expect(restored.minutesBefore, 15);
    });
  });

  group('Reminder.fromMap edge cases', () {
    test('missing fields use defaults', () {
      final r = Reminder.fromMap('id', {});
      expect(r.title, '');
      expect(r.time, const TimeOfDay(hour: 12, minute: 0));
      expect(r.days, isEmpty);
      expect(r.isHoliday, false);
      expect(r.isEnabled, true);
      expect(r.secondTime, isNull);
      expect(r.secondDays, isEmpty);
      expect(r.secondIsHoliday, false);
    });

    test('partial map still constructs', () {
      final r = Reminder.fromMap('id', {'title': 'Test', 'timeHour': 8});
      expect(r.title, 'Test');
      expect(r.time.hour, 8);
      expect(r.time.minute, 0);
    });
  });

  group('Reminder.subtitle', () {
    test('weekdays abbreviation', () {
      final r = _makeReminder(days: [1, 2, 3, 4, 5]);
      expect(r.subtitle, contains('Días de Semana'));
    });

    test('all days abbreviation', () {
      final r = _makeReminder(days: [1, 2, 3, 4, 5, 6, 7]);
      expect(r.subtitle, contains('Todos los días'));
    });

    test('specific days are listed', () {
      final r = _makeReminder(days: [1, 3]);
      expect(r.subtitle, contains('Lun'));
      expect(r.subtitle, contains('Mié'));
    });

    test('holiday mode', () {
      final r = _makeReminder(days: [], isHoliday: true);
      expect(r.subtitle, contains('Viernes y festivos'));
    });

    test('includes minutesBefore', () {
      final r = _makeReminder(days: [1], minutesBefore: 10);
      expect(r.subtitle, contains('10 min antes'));
    });

    test('time format uses AM/PM', () {
      final r = _makeReminder(
        time: const TimeOfDay(hour: 15, minute: 30),
        days: [1],
      );
      expect(r.subtitle, contains('3:30 PM'));
    });
  });

  group('Reminder.subtitleSecondary', () {
    test('returns null when no second time', () {
      final r = _makeReminder();
      expect(r.subtitleSecondary, isNull);
    });

    test('returns formatted string with second time and days', () {
      final r = _makeReminder(
        secondTime: const TimeOfDay(hour: 19, minute: 0),
        secondDays: [6, 7],
      );
      expect(r.subtitleSecondary, isNotNull);
      expect(r.subtitleSecondary, contains('7:00 PM'));
    });

    test('returns holiday label for secondary', () {
      final r = _makeReminder(
        secondTime: const TimeOfDay(hour: 8, minute: 0),
        secondDays: [],
        secondIsHoliday: true,
      );
      expect(r.subtitleSecondary, contains('Viernes y festivos'));
    });
  });
}

Reminder _makeReminder({
  TimeOfDay time = const TimeOfDay(hour: 7, minute: 30),
  List<int> days = const [1, 2, 3, 4, 5],
  bool isHoliday = false,
  int? minutesBefore,
  TimeOfDay? secondTime,
  List<int> secondDays = const [],
  bool secondIsHoliday = false,
}) {
  return Reminder(
    id: 'rem_1',
    title: 'Shajarit',
    time: time,
    days: days,
    isHoliday: isHoliday,
    minutesBefore: minutesBefore,
    isEnabled: true,
    secondTime: secondTime,
    secondDays: secondDays,
    secondIsHoliday: secondIsHoliday,
  );
}
