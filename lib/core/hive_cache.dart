import 'package:hive_flutter/hive_flutter.dart';

/// Lightweight local cache using Hive.
/// Keys are prefixed by uid to isolate data across accounts.
class HiveCache {
  HiveCache._();
  static final HiveCache instance = HiveCache._();

  static const _boxName = 'pushka_cache';
  Box? _box;
  bool _initialized = false;
  Future<void>? _initFuture;

  /// Calling init() concurrently is safe — only one Hive.openBox is ever started.
  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
    _initialized = true;
  }

  // ---------------------------------------------------------------------------
  // Pushka amount and goal — scoped per user + tenant
  // ---------------------------------------------------------------------------

  static const _keyPushkaAmount = 'pushka_amount';
  static const _keyPushkaGoal = 'pushka_goal';

  String _tenantKey(String uid, String tenantId, String suffix) =>
      '${uid}_${tenantId}_$suffix';

  Future<void> savePushkaAmount(String uid, String tenantId, double amount) async {
    if (!_initialized) return;
    await _box!.put(_tenantKey(uid, tenantId, _keyPushkaAmount), amount);
  }

  double? loadPushkaAmount(String uid, String tenantId) {
    if (!_initialized) return null;
    final v = _box!.get(_tenantKey(uid, tenantId, _keyPushkaAmount));
    if (v is num) return v.toDouble();
    return null;
  }

  Future<void> savePushkaGoal(String uid, String tenantId, double goal) async {
    if (!_initialized) return;
    await _box!.put(_tenantKey(uid, tenantId, _keyPushkaGoal), goal);
  }

  double? loadPushkaGoal(String uid, String tenantId) {
    if (!_initialized) return null;
    final v = _box!.get(_tenantKey(uid, tenantId, _keyPushkaGoal));
    if (v is num) return v.toDouble();
    return null;
  }

  Future<void> clearUser(String uid) async {
    if (!_initialized) return;
    // Remove all keys prefixed with uid (covers all tenants)
    final keys = _box!.keys.where((k) => k is String && k.startsWith('${uid}_')).toList();
    await _box!.deleteAll(keys);
  }

  Future<void> clearTenant(String uid, String tenantId) async {
    if (!_initialized) return;
    await _box!.delete(_tenantKey(uid, tenantId, _keyPushkaAmount));
    await _box!.delete(_tenantKey(uid, tenantId, _keyPushkaGoal));
  }

  // ---------------------------------------------------------------------------
  // Pushka style preference (device-level, no uid prefix)
  // ---------------------------------------------------------------------------

  static const _keyPushkaStyle = 'pushka_style';

  Future<void> savePushkaStyle(String style) async {
    if (!_initialized) return;
    await _box!.put(_keyPushkaStyle, style);
  }

  String? loadPushkaStyle() {
    if (!_initialized) return null;
    final v = _box!.get(_keyPushkaStyle);
    if (v is String) return v;
    return null;
  }

  // ---------------------------------------------------------------------------
  // Language (device-level preference, no uid prefix)
  // ---------------------------------------------------------------------------

  static const _keyLanguage = 'language';

  Future<void> saveLanguage(String code) async {
    if (!_initialized) return;
    await _box!.put(_keyLanguage, code);
  }

  String? loadLanguage() {
    if (!_initialized) return null;
    final v = _box!.get(_keyLanguage);
    if (v is String) return v;
    return null;
  }

  // ---------------------------------------------------------------------------
  // Theme mode (device-level preference, no uid prefix)
  // ---------------------------------------------------------------------------

  static const _keyThemeMode = 'theme_mode';

  Future<void> saveThemeMode(String mode) async {
    if (!_initialized) return;
    await _box!.put(_keyThemeMode, mode);
  }

  String? loadThemeMode() {
    if (!_initialized) return null;
    final v = _box!.get(_keyThemeMode);
    if (v is String) return v;
    return null;
  }
}
