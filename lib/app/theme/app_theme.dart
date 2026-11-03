import 'package:flutter/material.dart';

import 'app_tokens.dart';

class AppTheme {
  /// Tiene que coincidir EXACTO con el `family:` del pubspec.
  static const String _fontFamily = 'Plus Jakarta Sans';

  const AppTheme._();

  /// Arma los temas claro y oscuro.
  ///
  /// [primaryColor] llega del doc del tenant en Firestore y HOY SE IGNORA a
  /// proposito. Dos razones:
  ///
  ///   1. La identidad de JYM la aprobo el cliente y tiene que ser estable.
  ///      Con el color saliendo de Firestore, cualquiera con acceso al panel
  ///      de administracion podia descolorear la app entera y no quedaba
  ///      rastro en el codigo ni en el historial de git.
  ///   2. Rompia las vistas previas. El doc pisaba lo que dijera la rama, asi
  ///      que una previa del rediseno mostraba igual la paleta vieja.
  ///
  /// El parametro se mantiene en la firma para no reescribir el provider ni
  /// el camino del tenant. Si algun dia vuelve a haber mas de un tenant con
  /// marca propia, se vuelve a honrar aca y en ningun otro lado.
  ///
  /// Audit Round 4 — Bug C: removed `secondaryColor` parameter. The tenant
  /// admin used to be able to set a second color, but no widget consumed
  /// `colorScheme.secondary` visually — donors saw no effect. Re-introduce
  /// this when we actually wire up secondary accents (e.g. FAB, chips).
  /// Round-5 audit CRITICAL fix: pick a readable foreground color for the
  /// tenant's primary. Hardcoding `Colors.white` used to leave labels
  /// invisible when the tenant admin picked a light hue (yellow, cream,
  /// cyan, lime — all pass the hex regex). Threshold 0.5 matches the
  /// Material 3 heuristic used by ColorScheme.fromSeed().
  static Color _onColorFor(Color c) =>
      c.computeLuminance() > 0.5 ? const Color(0xFF0F172A) : Colors.white;

  static ({ThemeData light, ThemeData dark}) fromTenantColors({
    Color? primaryColor,
  }) {
    // Ver la nota de arriba: el color del tenant no se honra.
    const effectivePrimary = AppTokens.primary;
    const effectiveDark = AppTokens.primaryOnDark;
    final onLightPrimary = _onColorFor(effectivePrimary);
    final onDarkPrimary  = _onColorFor(effectiveDark);

    final lightBase = light();
    final darkBase = dark();

    final lightCS = lightBase.colorScheme.copyWith(
      primary: effectivePrimary,
      onPrimary: onLightPrimary,
    );

    final darkCS = darkBase.colorScheme.copyWith(
      primary: effectiveDark,
      onPrimary: onDarkPrimary,
    );

    return (
      light: lightBase.copyWith(
        colorScheme: lightCS,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: effectivePrimary,
            foregroundColor: onLightPrimary,
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
    // Familia nativa, NO google_fonts: se carga del bundle al arrancar y la
    // tipografia correcta esta desde el primer frame. Ver la nota del pubspec.
    final textTheme = ThemeData(brightness: Brightness.dark)
        .textTheme
        .apply(fontFamily: _fontFamily);

    const surfaceDark  = Color(0xFF0F172A);
    const cardDark     = Color(0xFF1E293B);
    const borderDark   = Color(0xFF334155);
    const textDark     = Color(0xFFF1F5F9);
    const mutedDark    = Color(0xFF94A3B8);

    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: AppTokens.primary,
      brightness: Brightness.dark,
      textTheme: textTheme,
    );

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: AppTokens.primaryOnDark,
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
          borderSide: const BorderSide(color: AppTokens.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: AppTokens.spaceMd,
        ),
        hintStyle: const TextStyle(color: mutedDark),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTokens.primary,
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
        selectedItemColor: AppTokens.primaryOnDark,
        unselectedItemColor: mutedDark,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: cardDark,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppTokens.primaryOnDark;
          return const Color(0xFF94A3B8); // mutedDark — visible circle when OFF
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppTokens.primaryOnDark.withValues(alpha: 0.45);
          return const Color(0xFF334155); // borderDark — muted track when OFF
        }),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppTokens.primary,
        selectionHandleColor: AppTokens.primary,
        selectionColor: AppTokens.primary.withValues(alpha: 0.3),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppTokens.primary,
      ),
    );
  }

  static ThemeData light() {
    // Familia nativa, NO google_fonts. Ver la nota del pubspec.
    final textTheme = ThemeData.light().textTheme.apply(fontFamily: _fontFamily);

    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: AppTokens.primary,
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
          borderSide: const BorderSide(color: AppTokens.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: AppTokens.spaceMd,
        ),
        hintStyle: const TextStyle(color: AppTokens.mutedText),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTokens.primary,
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
          foregroundColor: AppTokens.primary,
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
          foregroundColor: AppTokens.primary,
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
        selectedItemColor: AppTokens.primary,
        unselectedItemColor: AppTokens.mutedText,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: Colors.white,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppTokens.primary;
          return const Color(0xFF94A3B8); // muted grey — visible circle when OFF
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppTokens.primary.withValues(alpha: 0.45);
          return const Color(0xFFE2E8F0); // border light — muted track when OFF
        }),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppTokens.primary,
        selectionHandleColor: AppTokens.primary,
        selectionColor: AppTokens.primary.withValues(alpha: 0.3),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppTokens.primary,
      ),
    );
  }
}
