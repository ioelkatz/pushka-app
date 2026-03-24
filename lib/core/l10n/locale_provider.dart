import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final localeProvider = StateNotifierProvider<LocaleNotifier, Locale>((ref) {
  return LocaleNotifier();
});

class LocaleNotifier extends StateNotifier<Locale> {
  LocaleNotifier() : super(const Locale('es'));

  void setLocale(Locale locale) {
    if (['es', 'en', 'fr'].contains(locale.languageCode)) {
      state = locale;
    }
  }

  void setLanguageCode(String code) => setLocale(Locale(code));
}