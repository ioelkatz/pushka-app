import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'hive_cache.dart';

enum PushkaStyle { classic, building770 }

class PushkaStyleNotifier extends StateNotifier<PushkaStyle> {
  PushkaStyleNotifier() : super(_load());

  static PushkaStyle _load() {
    // Default to Building 770 (Chabad HQ visual) for new installs and any
    // user that hasn't picked a style yet. Saved values still win — once
    // the user explicitly selects 'pushka' (classic) we honor it.
    final saved = HiveCache.instance.loadPushkaStyle();
    if (saved == 'pushka') return PushkaStyle.classic;
    return PushkaStyle.building770;
  }

  Future<void> setStyle(PushkaStyle style) async {
    state = style;
    await HiveCache.instance.savePushkaStyle(
      style == PushkaStyle.building770 ? '770' : 'pushka',
    );
  }
}

final pushkaStyleProvider =
    StateNotifierProvider<PushkaStyleNotifier, PushkaStyle>(
  (_) => PushkaStyleNotifier(),
);
