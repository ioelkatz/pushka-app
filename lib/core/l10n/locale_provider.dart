import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../hive_cache.dart';

const _supportedCodes = ['es', 'en', 'fr', 'he'];

final localeProvider = StateNotifierProvider<LocaleNotifier, Locale>((ref) {
  final saved = HiveCache.instance.loadLanguage();
  final initial = (saved != null && _supportedCodes.contains(saved))
      ? Locale(saved)
      : const Locale('es');
  // Round-6 audit MEDIUM fix: set Intl.defaultLocale so NumberFormat +
  // DateFormat (in format_utils and Reminder) render in the user's language
  // WITHOUT threading a locale param through every callsite.
  Intl.defaultLocale = initial.languageCode;
  return LocaleNotifier(initial);
});

class LocaleNotifier extends StateNotifier<Locale> {
  LocaleNotifier(super.initial);

  void setLocale(Locale locale) {
    if (_supportedCodes.contains(locale.languageCode)) {
      state = locale;
      Intl.defaultLocale = locale.languageCode;
      // Persist immediately so the choice survives app restarts
      HiveCache.instance.saveLanguage(locale.languageCode);
    }
  }

  void setLanguageCode(String code) => setLocale(Locale(code));

  /// Called when Firestore profile data loads. Applies the remote language
  /// change so a multi-device user who changes language on device A
  /// eventually sees B update too.
  ///
  /// Round-8 audit MEDIUM fix: previously any Hive-saved value pinned the
  /// device forever — language change on A never propagated to B because
  /// B had its own Hive preference. Now Firestore wins when it differs
  /// from the current state (user just set it on another device); Hive
  /// is updated so cold-starts persist the latest choice.
  void syncFromRemote(String code) {
    if (!_supportedCodes.contains(code)) return;
    if (state.languageCode == code) return;
    state = Locale(code);
    Intl.defaultLocale = code;
    HiveCache.instance.saveLanguage(code);
  }
}
