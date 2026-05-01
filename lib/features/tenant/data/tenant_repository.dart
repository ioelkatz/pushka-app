import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Async provider that loads the current user's tenant config.
/// Returns null if user has no tenant yet or is not logged in.
/// Throws [TenantSuspendedException] if the tenant is suspended.
final tenantConfigProvider = FutureProvider<TenantConfig?>((ref) async {
  final user = ref.watch(authStateChangesProvider).valueOrNull;
  if (user == null) return null;
  return ref.read(tenantRepositoryProvider).loadConfig();
});
