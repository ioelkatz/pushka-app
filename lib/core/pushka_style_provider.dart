import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'hive_cache.dart';

enum PushkaStyle { classic, building770 }

class PushkaStyleNotifier extends StateNotifier<PushkaStyle> {
  PushkaStyleNotifier() : super(_load());

  static PushkaStyle _load() {
    // Default to the classic pushka (lata de tzedaka) for new installs y para
    // cualquier usuario que todavia no eligio estilo. Es la metafora central
    // de la app y lo que el cliente quiere que vea alguien que entra por
    // primera vez; el 770 queda como opcion opt-in en Ajustes > Apariencia.
    //
    // Los valores guardados siguen ganando: quien eligio 770 explicitamente
    // lo conserva.
    final saved = HiveCache.instance.loadPushkaStyle();
    if (saved == '770') return PushkaStyle.building770;
    return PushkaStyle.classic;
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
