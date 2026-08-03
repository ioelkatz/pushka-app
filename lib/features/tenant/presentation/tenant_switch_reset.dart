import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/hive_cache.dart';
import '../../history/providers/transactions_provider.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../data/tenant_repository.dart';

/// Shared reset used by every tenant-switch entry point (account switcher,
/// join-via-code screen, join-via-link screen). Historically each of the
/// three call sites diverged — the switcher invalidated userProfile /
/// history providers, the join screens didn't — and the History tab would
/// briefly paint the OLD tenant's transactions after a switch (bug #7 /
/// #8 in round-2 audit). Centralizing here keeps the reset sequence in
/// one place so a future addition can't silently drift again.
///
/// Callers must snapshot the outgoing tenantId BEFORE the switchTenant CF
/// completes (Firestore's live snapshot will overwrite it). Pass it via
/// [outgoingTenantId] so this helper can purge that tenant's Hive scope.
Future<void> resetTenantScopedState(
  ProviderContainer container, {
  required String? uid,
  required String? outgoingTenantId,
}) async {
  if (uid != null) {
    if (outgoingTenantId != null && outgoingTenantId.isNotEmpty) {
      await HiveCache.instance.clearTenant(uid, outgoingTenantId);
    }
    await HiveCache.instance.clearSavedCards(uid);
  }
  // Providers listed in the same order as their justifications:
  //   userProfileProvider   — refreshes tenantId from Firestore so downstream
  //                           .watch()s see the new tenant immediately instead
  //                           of after the snapshot RTT lands.
  //   tenantConfigProvider  — branding, features, appName.
  //   tenantStateProvider   — per-user tenant state (default card, pushka).
  //   historyLimitProvider  — reset pagination cursor so the new tenant
  //                           doesn't inherit the previous "Cargar más" limit.
  //   userTransactionsProvider — the History tab stream is keyed by tenantId;
  //                              invalidate so it doesn't briefly show the
  //                              old tenant's transactions.
  //   userTenantSummariesProvider — membership list (switcher itself).
  container.invalidate(userProfileProvider);
  container.invalidate(tenantConfigProvider);
  container.invalidate(tenantStateProvider);
  container.invalidate(historyLimitProvider);
  container.invalidate(userTransactionsProvider);
  container.invalidate(userTenantSummariesProvider);
}
