import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final localeProvider = StateNotifierProvider<LocaleNotifier, Locale>((ref) {
  return LocaleNotifier();
});

class LocaleNotifier extends StateNotifier<Locale> {
  LocaleNotifier() : super(const Locale('es'));

  DateTime? _lastManualChange;

  void setLocale(Locale locale) {
    if (['es', 'en', 'fr', 'he'].contains(locale.languageCode)) {
      _lastManualChange = DateTime.now();
      state = locale;
    }
  }

  void setLanguageCode(String code) => setLocale(Locale(code));

  /// Called from Firestore profile sync. Ignores stale values that arrive
  /// shortly after the user manually switched languages.
  void syncFromRemote(String code) {
    if (_lastManualChange != null &&
        DateTime.now().difference(_lastManualChange!).inSeconds < 5) {
      return;
    }
    if (['es', 'en', 'fr', 'he'].contains(code) &&
        state.languageCode != code) {
      state = Locale(code);
    }
  }
}