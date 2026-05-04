import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_tokens.dart';

class AppTheme {
  const AppTheme._();

  /// Builds light + dark themes using a custom primary color from the tenant.
  /// If [primaryColor] is null, falls back to [AppTokens.primaryBlue].
  static ({ThemeData light, ThemeData dark}) fromTenantColors({
    Color? primaryColor,
    Color? secondaryColor,
  }) {
    final effectivePrimary = primaryColor ?? AppTokens.primaryBlue;
    final effectiveDark = Color.lerp(effectivePrimary, Colors.white, 0.3) ?? AppTokens.skyBlue;

    final lightBase = light();
    final darkBase = dark();

    var lightCS = lightBase.colorScheme.copyWith(
      primary: effectivePrimary,
      onPrimary: Colors.white,
    );
    if (secondaryColor != null) {
      lightCS = lightCS.copyWith(secondary: secondaryColor, onSecondary: Colors.white);
    }

    var darkCS = darkBase.colorScheme.copyWith(
      primary: effectiveDark,
      onPrimary: Colors.white,
    );
    if (secondaryColor != null) {
      final darkSecondary = Color.lerp(secondaryColor, Colors.white, 0.2) ?? secondaryColor;
      darkCS = darkCS.copyWith(secondary: darkSecondary, onSecondary: Colors.white);
    }

    return (
      light: lightBase.copyWith(
        colorScheme: lightCS,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: effectivePrimary,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, AppTokens.buttonHeight),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
            elevation: 0,
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
        ),
      ),
      dark: darkBase.copyWith(colorScheme: darkCS),
    );
  }

  static ThemeData dark() {
    final textTheme = GoogleFonts.plusJakartaSansTextTheme(
      ThemeData(brightness: Brightness.dark).textTheme,
    );

    const surfaceDark  = Color(0xFF0F172A);
    const cardDark     = Color(0xFF1E293B);
    const borderDark   = Color(0xFF334155);
    const textDark     = Color(0xFFF1F5F9);
    const mutedDark    = Color(0xFF94A3B8);

    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: AppTokens.primaryBlue,
      brightness: Brightness.dark,
      textTheme: textTheme,
    );

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: AppTokens.skyBlue,
        onPrimary: Colors.white,
        surface: cardDark,
        surfaceContainerLowest: surfaceDark,
        surfaceContainerLow: surfaceDark,
        surfaceContainer: cardDark,
        surfaceContainerHigh: cardDark,
        surfaceContainerHighest: borderDark,
        onSurface: textDark,
        onSurfaceVariant: mutedDark,
        outline: Colors.white.withValues(alpha: 0.20),
        outlineVariant: Colors.white.withValues(alpha: 0.20),
      ),
      scaffoldBackgroundColor: surfaceDark,
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: cardDark,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: surfaceDark,
        foregroundColor: textDark,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: textDark,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          side: const BorderSide(color: borderDark, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardDark,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: const BorderSide(color: borderDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: const BorderSide(color: borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: AppTokens.spaceMd,
        ),
        hintStyle: const TextStyle(color: mutedDark),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTokens.primaryBlue,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, AppTokens.buttonHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          elevation: 0,
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textDark,
          minimumSize: const Size(0, AppTokens.buttonHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          side: const BorderSide(color: textDark, width: 1),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: textDark,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cardDark,
        contentTextStyle: const TextStyle(
          color: textDark,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardDark,
        surfaceTintColor: cardDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: borderDark,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: cardDark,
        selectedItemColor: AppTokens.skyBlue,
        unselectedItemColor: mutedDark,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: cardDark,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppTokens.skyBlue;
          return const Color(0xFF94A3B8); // mutedDark — visible circle when OFF
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppTokens.skyBlue.withValues(alpha: 0.45);
          return const Color(0xFF334155); // borderDark — muted track when OFF
        }),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppTokens.primaryBlue,
        selectionHandleColor: AppTokens.primaryBlue,
        selectionColor: AppTokens.primaryBlue.withValues(alpha: 0.3),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppTokens.primaryBlue,
      ),
    );
  }

  static ThemeData light() {
    final textTheme = GoogleFonts.plusJakartaSansTextTheme();

    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: AppTokens.primaryBlue,
      brightness: Brightness.light,
      textTheme: textTheme,
    );

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        outline: AppTokens.border,
        outlineVariant: AppTokens.border,
      ),
      scaffoldBackgroundColor: AppTokens.surface,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: AppTokens.surface,
        foregroundColor: AppTokens.textPrimary,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppTokens.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppTokens.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          side: const BorderSide(color: AppTokens.border, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppTokens.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: const BorderSide(color: AppTokens.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: const BorderSide(color: AppTokens.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: AppTokens.spaceMd,
        ),
        hintStyle: const TextStyle(color: AppTokens.mutedText),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTokens.primaryBlue,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, AppTokens.buttonHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          elevation: 0,
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTokens.primaryBlue,
          minimumSize: const Size(0, AppTokens.buttonHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          side: const BorderSide(color: AppTokens.border),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppTokens.primaryBlue,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTokens.textPrimary,
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppTokens.white,
        surfaceTintColor: AppTokens.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppTokens.border,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: AppTokens.primaryBlue,
        unselectedItemColor: AppTokens.mutedText,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: Colors.white,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return const Color(0xFFFF9500);
          return const Color(0xFF94A3B8); // muted grey — visible circle when OFF
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return const Color(0xFFFF9500).withValues(alpha: 0.45);
          return const Color(0xFFE2E8F0); // border light — muted track when OFF
        }),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppTokens.primaryBlue,
        selectionHandleColor: AppTokens.primaryBlue,
        selectionColor: AppTokens.primaryBlue.withValues(alpha: 0.3),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppTokens.primaryBlue,
      ),
    );
  }
}
