import 'package:hive_flutter/hive_flutter.dart';

/// Lightweight local cache using Hive.
/// Keys are prefixed by uid to isolate data across accounts.
class HiveCache {
  HiveCache._();
  static final HiveCache instance = HiveCache._();

  static const _boxName = 'pushka_cache';
  late Box _box;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
    _initialized = true;
  }

  // ---------------------------------------------------------------------------
  // Pushka amount
  // ---------------------------------------------------------------------------

  static const _keyPushkaAmount = 'pushka_amount';
  static const _keyPushkaGoal = 'pushka_goal';

  Future<void> savePushkaAmount(String uid, double amount) async {
    await _box.put('${uid}_$_keyPushkaAmount', amount);
  }

  double? loadPushkaAmount(String uid) {
    final v = _box.get('${uid}_$_keyPushkaAmount');
    if (v is num) return v.toDouble();
    return null;
  }

  Future<void> savePushkaGoal(String uid, double goal) async {
    await _box.put('${uid}_$_keyPushkaGoal', goal);
  }

  double? loadPushkaGoal(String uid) {
    final v = _box.get('${uid}_$_keyPushkaGoal');
    if (v is num) return v.toDouble();
    return null;
  }

  Future<void> clearUser(String uid) async {
    await _box.delete('${uid}_$_keyPushkaAmount');
    await _box.delete('${uid}_$_keyPushkaGoal');
  }
}
