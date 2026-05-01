import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../data/tenant_repository.dart';

/// Derives the tenant-branded ThemeData pair from the loaded TenantConfig.
/// Falls back to default AppTheme colors when no tenant is loaded.
final tenantThemeProvider = Provider<({ThemeData light, ThemeData dark})>((ref) {
  final tenantAsync = ref.watch(tenantConfigProvider);
  final config = tenantAsync.valueOrNull;

  return AppTheme.fromTenantColors(
    primaryColor: config?.primaryColor,
    secondaryColor: config?.secondaryColor,
  );
});
