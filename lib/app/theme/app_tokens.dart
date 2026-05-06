import 'package:flutter/material.dart';

class AppTokens {
  const AppTokens._();

  // Brand colors
  static const Color primaryBlue = Color(0xFF2563EB);
  static const Color skyBlue = Color(0xFF60A5FA);
  static const Color turquoise = Color(0xFF38BDF8);

  // Surfaces
  static const Color surface = Colors.white;
  static const Color cardSilver = Color(0xFFF1F5F9);
  static const Color white = Colors.white;

  // Text
  static const Color textPrimary = Color(0xFF1E293B);
  static const Color mutedText = Color(0xFF64748B);

  // Borders
  static const Color border = Color(0xFFE2E8F0);

  // Semantic
  static const Color success = Color(0xFF059669);
  static const Color destructive = Color(0xFFDC2626);

  // Radii
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 24;

  // Spacing
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;

  // Sizes
  static const double buttonHeight = 48;

  // App version — must match `version:` in pubspec.yaml.
  //
  // TODO: replace with PackageInfo.fromPlatform().version (package_info_plus)
  // so the constant can't drift. The async API would force support_screen +
  // app_drawer to load the version asynchronously, so deferring to its own PR.
  // For now: update this constant any time pubspec.yaml's version bumps.
  static const String appVersion = '1.0.0';
}