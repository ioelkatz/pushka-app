import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Async provider that loads the current user's tenant config.
/// Also returns `tenantIds` (all memberships) via [TenantConfigResult].
/// Returns null if user has no tenant yet or is not logged in.
/// Throws [TenantSuspendedException] if the tenant is suspended.
final tenantConfigProvider = FutureProvider<TenantConfig?>((ref) async {
  final user = ref.watch(authStateChangesProvider).valueOrNull;
  if (user == null) return null;
  return ref.read(tenantRepositoryProvider).loadConfig();
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
