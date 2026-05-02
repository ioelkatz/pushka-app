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
  // Pushka amount
  // ---------------------------------------------------------------------------

  static const _keyPushkaAmount = 'pushka_amount';
  static const _keyPushkaGoal = 'pushka_goal';

  Future<void> savePushkaAmount(String uid, double amount) async {
    if (!_initialized) return;
    await _box!.put('${uid}_$_keyPushkaAmount', amount);
  }

  double? loadPushkaAmount(String uid) {
    if (!_initialized) return null;
    final v = _box!.get('${uid}_$_keyPushkaAmount');
    if (v is num) return v.toDouble();
    return null;
  }

  Future<void> savePushkaGoal(String uid, double goal) async {
    if (!_initialized) return;
    await _box!.put('${uid}_$_keyPushkaGoal', goal);
  }

  double? loadPushkaGoal(String uid) {
    if (!_initialized) return null;
    final v = _box!.get('${uid}_$_keyPushkaGoal');
    if (v is num) return v.toDouble();
    return null;
  }

  Future<void> clearUser(String uid) async {
    if (!_initialized) return;
    await _box!.delete('${uid}_$_keyPushkaAmount');
    await _box!.delete('${uid}_$_keyPushkaGoal');
    await _box!.delete('${uid}_$_keyTenantId');
    await _box!.delete('${uid}_$_keyTenantConfig');
  }

  // ---------------------------------------------------------------------------
  // Tenant config (per-uid — branding, currency, locale)
  //
  // Cached so the app can render the correct tenant branding on cold-start
  // before the network call returns. Without this, users on slow/no networks
  // see the generic "Pushka" branding for several seconds before their
  // chabad-house's name and colors appear.
  // ---------------------------------------------------------------------------

  static const _keyTenantId = 'tenant_id';
  static const _keyTenantConfig = 'tenant_config';

  Future<void> saveTenantConfig(
    String uid,
    String tenantId,
    Map<String, dynamic> configMap,
  ) async {
    if (!_initialized) return;
    await _box!.put('${uid}_$_keyTenantId', tenantId);
    // Hive stores Map<String, dynamic> as Map<dynamic, dynamic> — that's fine,
    // we re-cast on load. We also strip null values up front so the round-trip
    // through Hive doesn't introduce unexpected nulls into Map keys.
    final clean = <String, dynamic>{
      for (final e in configMap.entries)
        if (e.value != null) e.key: e.value,
    };
    await _box!.put('${uid}_$_keyTenantConfig', clean);
  }

  /// Returns (tenantId, configMap) or null if there is no cache for this uid.
  ({String tenantId, Map<String, dynamic> config})? loadTenantConfig(String uid) {
    if (!_initialized) return null;
    final tenantId = _box!.get('${uid}_$_keyTenantId');
    final raw = _box!.get('${uid}_$_keyTenantConfig');
    if (tenantId is! String || raw is! Map) return null;
    final config = <String, dynamic>{};
    raw.forEach((k, v) {
      if (k is String) config[k] = v;
    });
    return (tenantId: tenantId, config: config);
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
