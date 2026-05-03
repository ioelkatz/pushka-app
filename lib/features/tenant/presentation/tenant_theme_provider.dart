import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../data/tenant_repository.dart';

/// Derives the tenant-branded ThemeData pair from the loaded TenantConfig.
/// Falls back to default AppTheme colors when no tenant is loaded.
///
/// `select`-narrowed to (primaryColor, secondaryColor) so a tenant doc
/// re-emit (from the 60s app.dart status poll, or branding sync trigger)
/// only rebuilds MaterialApp's theme when those two fields actually change —
/// without this, every poll tick produced a fresh ({light, dark}) record and
/// rebuilt the entire UI tree even when the tenant config was unchanged.
final tenantThemeProvider = Provider<({ThemeData light, ThemeData dark})>((ref) {
  final colors = ref.watch(
    tenantConfigProvider.select((async) {
      final c = async.valueOrNull;
      return (primary: c?.primaryColor, secondary: c?.secondaryColor);
    }),
  );

  return AppTheme.fromTenantColors(
    primaryColor: colors.primary,
    secondaryColor: colors.secondary,
  );
});
