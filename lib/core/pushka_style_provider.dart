import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'hive_cache.dart';

enum PushkaStyle { classic, building770 }

class PushkaStyleNotifier extends StateNotifier<PushkaStyle> {
  PushkaStyleNotifier() : super(_load());

  static PushkaStyle _load() {
    final saved = HiveCache.instance.loadPushkaStyle();
    return saved == '770' ? PushkaStyle.building770 : PushkaStyle.classic;
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
