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
    // Remove all keys prefixed with uid — covers per-tenant pushka state
    // (`${uid}_${tenantId}_…`), the tenant-config cache (`${uid}_tenant_id`,
    // `${uid}_tenant_config`), and any future per-uid keys.
    final keys = _box!.keys.where((k) => k is String && k.startsWith('${uid}_')).toList();
    await _box!.deleteAll(keys);
  }

  Future<void> clearTenant(String uid, String tenantId) async {
    if (!_initialized) return;
    await _box!.delete(_tenantKey(uid, tenantId, _keyPushkaAmount));
    await _box!.delete(_tenantKey(uid, tenantId, _keyPushkaGoal));
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

  // ---------------------------------------------------------------------------
  // Saved cards (per-uid) — short-lived cache so reopening Métodos de pago
  // doesn't pay the full Stripe round trip every time. The CF call still
  // happens in the background to refresh the list; the cache just lets
  // the UI render immediately on the second+ visit within the TTL window.
  // ---------------------------------------------------------------------------

  static const _keySavedCards = 'saved_cards';
  static const _keySavedCardsAt = 'saved_cards_at';
  static const _keySavedCardsDefault = 'saved_cards_default';
  static const Duration savedCardsTtl = Duration(minutes: 10);

  Future<void> saveSavedCards({
    required String uid,
    required List<Map<String, dynamic>> cards,
    required String? defaultPmId,
  }) async {
    if (!_initialized) return;
    // Hive stores raw maps; strip non-primitive values to avoid type errors
    // on read-back.
    final clean = cards
        .map((c) => <String, dynamic>{
              for (final e in c.entries)
                if (e.value == null ||
                    e.value is num ||
                    e.value is String ||
                    e.value is bool)
                  e.key: e.value,
            })
        .toList();
    await _box!.put('${uid}_$_keySavedCards', clean);
    await _box!.put('${uid}_$_keySavedCardsAt', DateTime.now().millisecondsSinceEpoch);
    await _box!.put('${uid}_$_keySavedCardsDefault', defaultPmId);
  }

  /// Returns (cards, defaultPmId, fresh) or null if no cache.
  /// `fresh` is true when the cache was written within [savedCardsTtl].
  ({List<Map<String, dynamic>> cards, String? defaultPmId, bool fresh})?
      loadSavedCards(String uid) {
    if (!_initialized) return null;
    final raw = _box!.get('${uid}_$_keySavedCards');
    final atMs = _box!.get('${uid}_$_keySavedCardsAt');
    final defaultPmId = _box!.get('${uid}_$_keySavedCardsDefault');
    if (raw is! List || atMs is! int) return null;
    final cards = raw
        .whereType<Map>()
        .map((m) => <String, dynamic>{
              for (final e in m.entries)
                if (e.key is String) e.key as String: e.value,
            })
        .toList();
    final ageMs = DateTime.now().millisecondsSinceEpoch - atMs;
    return (
      cards: cards,
      defaultPmId: defaultPmId is String ? defaultPmId : null,
      fresh: ageMs < savedCardsTtl.inMilliseconds,
    );
  }

  Future<void> clearSavedCards(String uid) async {
    if (!_initialized) return;
    await _box!.delete('${uid}_$_keySavedCards');
    await _box!.delete('${uid}_$_keySavedCardsAt');
    await _box!.delete('${uid}_$_keySavedCardsDefault');
  }
}
