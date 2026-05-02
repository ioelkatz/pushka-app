import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/hive_cache.dart';
import '../../auth/providers/auth_state_provider.dart';
import '../domain/tenant_config.dart';
import '../domain/tenant_summary.dart';

class TenantRepository {
  const TenantRepository();

  /// Lists all active+discoverable tenants for the onboarding picker.
  /// Tenants with `discoverable: false` are hidden (joinable only via code).
  Future<List<TenantSummary>> listDiscoverable() async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('listDiscoverableTenants')
        .call<Map<Object?, Object?>>({});

    final data = Map<String, dynamic>.from(result.data);
    final raw = (data['tenants'] as List?) ?? const [];
    return raw
        .map((e) => TenantSummary.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Calls getTenantConfig Cloud Function for the currently logged-in user.
  /// Returns null if the user has no tenant yet.
  /// Throws if the tenant is suspended.
  Future<TenantConfig?> loadConfig() async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('getTenantConfig')
        .call<Map<Object?, Object?>>({});

    final data = Map<String, dynamic>.from(result.data);

    final tenantId = data['tenantId'] as String?;
    if (tenantId == null) return null;

    if (data['suspended'] == true) {
      throw const TenantSuspendedException();
    }

    final config = data['config'] as Map<Object?, Object?>?;
    if (config == null) return null;

    return TenantConfig.fromMap(tenantId, Map<String, dynamic>.from(config));
  }

  /// Validates a slug (invite code) and returns branding preview.
  /// Throws if the slug is invalid or org is inactive.
  Future<TenantConfig> validateSlug(String slug) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('getTenantBySlug')
        .call<Map<Object?, Object?>>({'slug': slug.trim().toLowerCase()});

    final data = Map<String, dynamic>.from(result.data);
    final tenantId = data['tenantId'] as String;
    return TenantConfig.fromMap(tenantId, data);
  }
}

class TenantSuspendedException implements Exception {
  const TenantSuspendedException();

  @override
  String toString() => 'TenantSuspendedException';
}

final tenantRepositoryProvider = Provider<TenantRepository>((ref) {
  return const TenantRepository();
});

/// Streams the current user's tenant config, yielding cached data first
/// (if any) so the UI renders branded immediately on cold-start, then a
/// fresh value from the backend.
///
/// - Returns null if the user has no tenant yet or is not logged in.
/// - Throws [TenantSuspendedException] if the live config reports suspended.
/// - Writes the fresh config back to HiveCache so the next cold-start has a
///   warm cache. Failures during the network fetch fall back to the cached
///   value so an offline user still sees their org's branding instead of
///   a blank/error screen.
final tenantConfigProvider = StreamProvider<TenantConfig?>((ref) async* {
  final user = ref.watch(authStateChangesProvider).valueOrNull;
  if (user == null) {
    yield null;
    return;
  }

  // 1. Yield cached value first (if any) so consumers paint immediately.
  TenantConfig? cached;
  final cachedRecord = HiveCache.instance.loadTenantConfig(user.uid);
  if (cachedRecord != null) {
    try {
      cached = TenantConfig.fromMap(cachedRecord.tenantId, cachedRecord.config);
      yield cached;
    } catch (_) {
      // Corrupted cache shape — ignore and fall through to network fetch.
    }
  }

  // 2. Fetch fresh from backend.
  TenantConfig? fresh;
  try {
    fresh = await ref.read(tenantRepositoryProvider).loadConfig();
  } catch (e) {
    // Suspension is a real signal — surface it so the listener redirects.
    if (e is TenantSuspendedException) rethrow;
    // Network/Cloud Functions failure: keep showing the cached value so the
    // user isn't bricked offline. Do NOT yield (the cached value is already
    // the most recent emission).
    if (cached != null) return;
    rethrow; // No cache, no network — let the AsyncValue.error propagate.
  }

  // 3. Persist fresh value to cache, then yield it.
  if (fresh != null) {
    try {
      await HiveCache.instance.saveTenantConfig(
        user.uid,
        fresh.tenantId,
        fresh.toMap(),
      );
    } catch (_) {
      // Cache-write failure is non-critical; the user still gets the fresh
      // config from this emission, just no warm cache for next cold-start.
    }
  }
  yield fresh;
});
