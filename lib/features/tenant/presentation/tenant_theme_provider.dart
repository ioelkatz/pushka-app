import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../data/tenant_repository.dart';

/// Derives the tenant-branded ThemeData pair from the loaded TenantConfig.
/// Falls back to default AppTheme colors when no tenant is loaded.
///
/// `select`-narrowed to primaryColor so a tenant doc re-emit (from the
/// 60s app.dart status poll, or branding sync trigger) only rebuilds
/// MaterialApp's theme when that field actually changes — without this,
/// every poll tick produced a fresh ({light, dark}) record and rebuilt the
/// entire UI tree even when the tenant config was unchanged.
///
/// Audit Round 4 — Bug C: secondaryColor removed from this select.
final tenantThemeProvider = Provider<({ThemeData light, ThemeData dark})>((ref) {
  final primaryColor = ref.watch(
    tenantConfigProvider.select((async) => async.valueOrNull?.primaryColor),
  );

  return AppTheme.fromTenantColors(primaryColor: primaryColor);
});
