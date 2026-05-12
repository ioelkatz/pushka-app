import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/hive_cache.dart';
import '../../auth/providers/auth_state_provider.dart';
import '../../users/presentation/user_profile_provider.dart';
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

  /// Joins a tenant org. Idempotent — safe to call even if already a member.
  /// On first join, sets tenantId and creates the per-tenant state doc.
  Future<void> joinTenant(String tenantId) async {
    await FirebaseFunctions.instance
        .httpsCallable('joinTenant')
        .call<Map<Object?, Object?>>({'tenantId': tenantId});
  }

  /// Switches the active tenant to [tenantId] (must be in the user's tenantIds).
  Future<void> switchTenant(String tenantId) async {
    await FirebaseFunctions.instance
        .httpsCallable('switchTenant')
        .call<Map<Object?, Object?>>({'tenantId': tenantId});
  }

  /// Leaves a tenant. If it was the active tenant, falls back to the first remaining.
  Future<void> leaveTenant(String tenantId) async {
    await FirebaseFunctions.instance
        .httpsCallable('leaveTenant')
        .call<Map<Object?, Object?>>({'tenantId': tenantId});
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

/// Streams the active tenant's config in real time.
///
/// Sequence:
///   1. Yield HiveCache value first (cold-start gets branded UI instantly).
///   2. Fetch fresh via `getTenantConfig` CF — that single call enforces the
///      suspended-tenant check + writes denormalized cache fields to
///      `users/{uid}/tenantState/{tenantId}` that other widgets depend on.
///   3. Subscribe to `tenants/{tenantId}` via `.snapshots()` so any branding
///      edit in the admin web (logo, color, designations, contact info,
///      welcome text, etc.) reaches active sessions within ~1s instead of
///      waiting for the next 60s poll tick. The Firestore rule
///      `isTenantMember() && callerTenantId() == tenantId` already permits
///      this read for any member of the tenant.
///
/// Errors:
///   - Throws [TenantSuspendedException] when status flips to "suspended"
///     (both on the CF response and on subsequent snapshot updates).
///   - Network failure on initial fetch falls back to the cached value so
///     offline users still see their org branding.
///
/// Note: in the multi-tenant model (a user may belong to several orgs), this
/// provider returns the config of the user's currently active tenant. Other
/// memberships are exposed separately by `userTenantsProvider` (see below).
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

  // 2. Fetch fresh from backend (CF enforces suspended-tenant + writes
  //    denormalized tenantState cache that other widgets read).
  TenantConfig? fresh;
  try {
    fresh = await ref.read(tenantRepositoryProvider).loadConfig();
  } catch (e) {
    if (e is TenantSuspendedException) rethrow;
    if (cached != null) return; // keep showing cache when offline
    rethrow;
  }

  if (fresh == null) {
    yield null;
    return;
  }

  // 3. Persist + yield first fresh value.
  try {
    await HiveCache.instance.saveTenantConfig(user.uid, fresh.tenantId, fresh.toMap());
  } catch (_) { /* non-fatal */ }
  yield fresh;

  // 4. Real-time stream on the tenant doc. Branding edits from the admin
  //    web propagate immediately instead of waiting for the next poll tick.
  final tenantId = fresh.tenantId;
  yield* FirebaseFirestore.instance
      .collection('tenants')
      .doc(tenantId)
      .snapshots()
      .skip(1) // first emission is the value we already yielded via the CF
      .asyncMap<TenantConfig?>((snap) async {
        if (!snap.exists) return null;
        final data = Map<String, dynamic>.from(snap.data() ?? {});
        if (data['status'] == 'suspended') {
          throw const TenantSuspendedException();
        }
        final live = TenantConfig.fromMap(tenantId, data);
        try {
          await HiveCache.instance.saveTenantConfig(user.uid, tenantId, live.toMap());
        } catch (_) { /* non-fatal */ }
        return live;
      });
});

/// Stream provider for the per-tenant state doc of the currently active tenant.
/// Contains pushkaAmount, pushkaGoal, streak, autoEmpty settings, etc.
/// Returns null if the user has no active tenant or is not logged in.
final tenantStateProvider = StreamProvider<Map<String, dynamic>?>((ref) {
  final user = ref.watch(authStateChangesProvider).valueOrNull;
  if (user == null) return const Stream.empty();

  final profile = ref.watch(userProfileProvider).valueOrNull;
  final currentTenantId = profile?['tenantId'] as String?;
  if (currentTenantId == null || currentTenantId.isEmpty) {
    return Stream.value(null);
  }

  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .collection('tenantState')
      .doc(currentTenantId)
      .snapshots()
      .map((snap) => snap.exists ? snap.data() : null);
});

/// Returns all tenantState summaries (name, logo, id) for the user's memberships,
/// read from the tenantState sub-docs that the CF caches at join time.
final userTenantSummariesProvider = StreamProvider<List<TenantSummary>>((ref) {
  final user = ref.watch(authStateChangesProvider).valueOrNull;
  if (user == null) return Stream.value([]);

  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .collection('tenantState')
      .snapshots()
      .map((snap) {
        return snap.docs.map((doc) {
          final d = doc.data();
          return TenantSummary.fromMap({
            'tenantId': doc.id,
            'name': d['tenantName'] ?? '',
            'appName': d['tenantAppName'] ?? d['tenantName'] ?? '',
            'slug': '',
            'logoUrl': d['tenantLogoUrl'],
            'primaryColor': d['tenantPrimaryColor'],
          });
        }).toList();
      });
});
