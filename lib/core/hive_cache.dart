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
    // Round-8 audit HIGH fix: openBox can throw when the on-disk file is
    // corrupt (device disk-full during a prior write, killed mid-write, or
    // a Hive schema change). main.dart awaits this before runApp — an
    // unhandled throw here would crash the cold-start with no UI. Best-
    // effort recovery: wipe the corrupt box and open a fresh one. Loss of
    // local cache is acceptable (data is server-side authoritative);
    // never-launching is not.
    try {
      await Hive.initFlutter();
      _box = await Hive.openBox(_boxName);
      _initialized = true;
    } catch (e, st) {
      // ignore: avoid_print
      print('[HiveCache] openBox failed, wiping and retrying: $e\n$st');
      try {
        await Hive.deleteBoxFromDisk(_boxName);
        _box = await Hive.openBox(_boxName);
        _initialized = true;
      } catch (e2) {
        // Second failure — proceed uninitialised so downstream callers
        // (loadX / saveX) all no-op via their `if (!_initialized) return`
        // guards. App loses local cache but boots.
        // ignore: avoid_print
        print('[HiveCache] second openBox failed, running without cache: $e2');
        _initialized = false;
      }
    }
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

  /// Round-7 regression fix: called by resetTenantScopedState on tenant
  /// switch so the tenantConfigProvider doesn't emit the OLD tenant's
  /// cached config on next read (branding/appName/logo would flash the
  /// previous tenant for a beat while the CF re-fetches).
  Future<void> clearTenantConfig(String uid) async {
    if (!_initialized) return;
    await _box!.delete('${uid}_$_keyTenantId');
    await _box!.delete('${uid}_$_keyTenantConfig');
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
  // Saved cards — SCOPED (uid, tenantId) so a user who joins a new tenant
  // does NOT briefly see the previous tenant's cards. Direct Charges puts
  // customers per-connected-account, so the card list is inherently scoped
  // to the tenant. BUG #13 fix.
  //
  // BUG #5/#6 mitigation: even without explicit clearSavedCards() on tenant
  // switch (tenant_code_screen / join_via_link_screen forgot to call it),
  // scoping the key by tenantId means the previous tenant's cache can't leak.
  // Legacy uid-only keys are still cleared on write/read fallback so old
  // Hive entries don't zombie-persist.
  // ---------------------------------------------------------------------------

  static const _keySavedCards = 'saved_cards';
  static const _keySavedCardsAt = 'saved_cards_at';
  static const _keySavedCardsDefault = 'saved_cards_default';
  static const Duration savedCardsTtl = Duration(minutes: 10);

  static String _scKey(String uid, String? tenantId, String suffix) =>
      '${uid}_${tenantId ?? "_notenant"}_$suffix';

  Future<void> saveSavedCards({
    required String uid,
    String? tenantId,
    required List<Map<String, dynamic>> cards,
    required String? defaultPmId,
  }) async {
    if (!_initialized) return;
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
    await _box!.put(_scKey(uid, tenantId, _keySavedCards), clean);
    await _box!.put(_scKey(uid, tenantId, _keySavedCardsAt),
        DateTime.now().millisecondsSinceEpoch);
    await _box!.put(_scKey(uid, tenantId, _keySavedCardsDefault), defaultPmId);
  }

  /// Returns (cards, defaultPmId, fresh) or null if no cache for (uid, tenantId).
  ({List<Map<String, dynamic>> cards, String? defaultPmId, bool fresh})?
      loadSavedCards(String uid, {String? tenantId}) {
    if (!_initialized) return null;
    final raw = _box!.get(_scKey(uid, tenantId, _keySavedCards));
    final atMs = _box!.get(_scKey(uid, tenantId, _keySavedCardsAt));
    final defaultPmId = _box!.get(_scKey(uid, tenantId, _keySavedCardsDefault));
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

  // ---------------------------------------------------------------------------
  // Donation subscriptions cache — keyed by uid alone (subs list is
  // multi-tenant: listDonationSubscriptions returns subs from every tenant
  // the user belongs to, so scoping by tenantId would fragment the cache).
  // 5 min TTL: subs change less often than cards but the user's own
  // create/cancel actions invalidate immediately by calling saveSubscriptions
  // right after the CF response. Stale cache is fine — painted instantly
  // + refresh silent.
  // ---------------------------------------------------------------------------

  static const _keySubs = 'donation_subs';
  static const _keySubsAt = 'donation_subs_at';
  static const Duration subsTtl = Duration(minutes: 5);

  Future<void> saveSubscriptions({
    required String uid,
    required List<Map<String, dynamic>> subs,
  }) async {
    if (!_initialized) return;
    final clean = subs
        .map((s) => <String, dynamic>{
              for (final e in s.entries)
                if (e.value == null ||
                    e.value is num ||
                    e.value is String ||
                    e.value is bool)
                  e.key: e.value,
            })
        .toList();
    await _box!.put('${uid}_$_keySubs', clean);
    await _box!.put('${uid}_$_keySubsAt', DateTime.now().millisecondsSinceEpoch);
  }

  /// Returns (subs, fresh) or null if no cache for this uid.
  ({List<Map<String, dynamic>> subs, bool fresh})?
      loadSubscriptions(String uid) {
    if (!_initialized) return null;
    final raw = _box!.get('${uid}_$_keySubs');
    final atMs = _box!.get('${uid}_$_keySubsAt');
    if (raw is! List || atMs is! int) return null;
    final subs = raw
        .whereType<Map>()
        .map((m) => <String, dynamic>{
              for (final e in m.entries)
                if (e.key is String) e.key as String: e.value,
            })
        .toList();
    final ageMs = DateTime.now().millisecondsSinceEpoch - atMs;
    return (
      subs: subs,
      fresh: ageMs < subsTtl.inMilliseconds,
    );
  }

  Future<void> clearSubscriptions(String uid) async {
    if (!_initialized) return;
    await _box!.delete('${uid}_$_keySubs');
    await _box!.delete('${uid}_$_keySubsAt');
  }

  /// Clears saved cards cache. If `tenantId` is null, clears ALL tenants for
  /// this uid (used on logout / delete account). If specified, clears only
  /// that (uid, tenantId) scope (used on tenant switch, though scoping keys
  /// makes leaking impossible anyway — see class comment).
  Future<void> clearSavedCards(String uid, {String? tenantId}) async {
    if (!_initialized) return;
    if (tenantId != null) {
      await _box!.delete(_scKey(uid, tenantId, _keySavedCards));
      await _box!.delete(_scKey(uid, tenantId, _keySavedCardsAt));
      await _box!.delete(_scKey(uid, tenantId, _keySavedCardsDefault));
      return;
    }
    // Nuke every (uid, *) entry — also cleans up any legacy uid-only keys
    // from before this scoping change.
    final prefix = '${uid}_';
    final legacyPrefixes = <String>{
      '${uid}_$_keySavedCards',
      '${uid}_$_keySavedCardsAt',
      '${uid}_$_keySavedCardsDefault',
    };
    final toDelete = <dynamic>[];
    for (final k in _box!.keys) {
      if (k is! String) continue;
      if (legacyPrefixes.contains(k)) { toDelete.add(k); continue; }
      if (k.startsWith(prefix) &&
          (k.endsWith('_$_keySavedCards') ||
           k.endsWith('_$_keySavedCardsAt') ||
           k.endsWith('_$_keySavedCardsDefault'))) {
        toDelete.add(k);
      }
    }
    for (final k in toDelete) {
      await _box!.delete(k);
    }
  }
}
