import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

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
    this.nextTriggerAt,
    this.lastTriggeredAt,
    this.timezone,
    this.oneShotDate,
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

  // SERVER-OWNED FIELDS: populated by the onReminderWrite Cloud Function
  // and the processDueReminders scheduler. NEVER emitted from toMap() —
  // firestore.rules reject client writes that mutate them. Kept in the
  // model as read-only so a settings/debug screen could surface them.
  final DateTime? nextTriggerAt;
  final DateTime? lastTriggeredAt;
  final String? timezone;

  // ONE-SHOT (chooseDate) — nullable Firestore Timestamp for reminders that
  // fire once on a specific date. Set by the reminders screen when the user
  // picks a date; consumed by the CF to compute nextTriggerAt as the
  // absolute (timezone-frozen) UTC instant. Previously lived in Hive local
  // storage only (see NotificationService.setOneShotDate) — mirrored to
  // Firestore now so server-side scheduling can honor it.
  final DateTime? oneShotDate;

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
    DateTime? nextTriggerAt,
    DateTime? lastTriggeredAt,
    String? timezone,
    DateTime? oneShotDate,
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
      nextTriggerAt: nextTriggerAt ?? this.nextTriggerAt,
      lastTriggeredAt: lastTriggeredAt ?? this.lastTriggeredAt,
      timezone: timezone ?? this.timezone,
      oneShotDate: oneShotDate ?? this.oneShotDate,
    );
  }

  /// Whitelist: only CLIENT-EDITABLE fields go here. `nextTriggerAt`,
  /// `lastTriggeredAt`, and `timezone` are server-owned and their inclusion
  /// in a client write is rejected by Firestore rules (see the
  /// hasNoServerOnlyReminderFieldsWritten helper in firestore.rules).
  /// `oneShotDate` IS client-writable (the user picks the date) but the
  /// server computes `nextTriggerAt` from it.
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
      'oneShotDate': oneShotDate, // Firestore auto-converts DateTime → Timestamp
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
      // Server-owned reads (Firestore Timestamp → DateTime via .toDate()).
      // We accept both a Timestamp and a raw int millis for backwards-compat
      // with any older client versions that might have shipped either.
      nextTriggerAt: _readDateTime(map['nextTriggerAt']),
      lastTriggeredAt: _readDateTime(map['lastTriggeredAt']),
      timezone: map['timezone'] as String?,
      oneShotDate: _readDateTime(map['oneShotDate']),
    );
  }

  static DateTime? _readDateTime(dynamic value) {
    if (value == null) return null;
    // Firestore Timestamp — use dynamic dispatch to avoid an import here.
    try {
      final asDate = (value as dynamic).toDate();
      if (asDate is DateTime) return asDate;
    } catch (_) {}
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is DateTime) return value;
    return null;
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

  // Bidi separator + isolation marks. The hyphen-minus is bidi-neutral and
  // gets pulled by the bidi algorithm to the wrong visual side when mixing
  // RTL Hebrew day-names with LTR clock times ("8:00 AM"). Bullet (U+2022)
  // is visually symmetric, and FSI (U+2068) / PDI (U+2069) wrap each segment
  // so the time always renders as a coherent LTR run inside Hebrew/Arabic
  // context. Use String.fromCharCode to keep the literal source bidi-trojan
  // free (otherwise the embedded chars trip the analyzer warning).
  static const _bidiSep = ' • ';
  static final String _fsi = String.fromCharCode(0x2068);
  static final String _pdi = String.fromCharCode(0x2069);
  static String _isoLtr(String s) => '$_fsi$s$_pdi';

  String subtitleFor(S tr) {
    final timeStr = _formatTime(time);
    final dayNames = _getDayNames(days, tr);

    var result = '';
    if (dayNames.isNotEmpty) {
      result = '$dayNames$_bidiSep${_isoLtr(timeStr)}';
    } else if (isHoliday) {
      result = '${tr.repeatFridayHoliday}$_bidiSep${_isoLtr(timeStr)}';
    }

    if (minutesBefore != null) {
      result += '$_bidiSep${_isoLtr(tr.minBefore(minutesBefore.toString()))}';
    }

    return result;
  }

  String? subtitleSecondaryFor(S tr) {
    if (secondTime == null) return null;
    final timeStr = _formatTime(secondTime!);
    final dayNames = _getDayNames(secondDays, tr);
    if (dayNames.isNotEmpty) {
      return '$dayNames$_bidiSep${_isoLtr(timeStr)}';
    }
    if (secondIsHoliday) {
      return '${tr.repeatFridayHoliday}$_bidiSep${_isoLtr(timeStr)}';
    }
    return null;
  }

  String _formatTime(TimeOfDay t) {
    // Was hardcoded English "AM"/"PM" — surfaced in the reminders list under
    // every reminder subtitle regardless of app language. Reminder lives in
    // the domain layer with no BuildContext, so we use DateFormat.jm() with
    // no explicit locale — intl falls back to Intl.defaultLocale (set by
    // MaterialApp.localizationsDelegates via the S locale) or, absent that,
    // to the system locale. This gets HE/FR/EN right; 24h locales get 24h.
    final now = DateTime.now();
    final dt = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    return DateFormat.jm().format(dt);
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
