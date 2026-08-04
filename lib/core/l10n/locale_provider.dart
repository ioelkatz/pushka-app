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

  /// Called when Firestore profile data loads. Applies the remote language only
  /// if the device has no locally-saved preference (i.e. first install / new device).
  /// Once the user sets a language manually it is saved in Hive and takes priority.
  void syncFromRemote(String code) {
    final saved = HiveCache.instance.loadLanguage();
    if (saved != null) {
      // Device already has a preference — make sure the notifier reflects it
      if (_supportedCodes.contains(saved) && state.languageCode != saved) {
        state = Locale(saved);
      }
      return;
    }
    // No local preference yet (fresh install) — trust Firestore
    if (_supportedCodes.contains(code) && state.languageCode != code) {
      state = Locale(code);
      HiveCache.instance.saveLanguage(code);
    }
  }
}
