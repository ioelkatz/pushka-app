import 'package:flutter/material.dart';

class AppTokens {
  const AppTokens._();

  // ---------------------------------------------------------------------
  // Identidad JYM
  // ---------------------------------------------------------------------
  // Los tres colores salen de muestrear el logo oficial pixel por pixel el
  // 2026-11-03, no de estimarlos a ojo sobre una captura. El galon grande y
  // la llama son exactamente el mismo rojo: lo que parece un segundo tono
  // mas claro en el logo es el antialias del borde.
  static const Color brandRed = Color(0xFFF82D4A); // galon exterior + llama
  static const Color brandGreen = Color(0xFF05806E); // galon interior
  static const Color brandGrey = Color(0xFFD3D3D3); // galon del medio

  /// Acciones positivas: donar, guardar, continuar, el relleno de la barra
  /// de progreso.
  ///
  /// Es el VERDE y no el rojo a proposito. `primary` alimenta por defecto
  /// todos los ElevatedButton de la app — guardar tarjeta, confirmar, seguir
  /// — y un boton rojo solido se lee como destructivo en cualquier interfaz.
  /// El rojo queda reservado para lo que el diseno del cliente le asigna: la
  /// pildora de la racha, la llama y vaciar la pushka.
  static const Color primary = brandGreen;

  /// El mismo verde aclarado para fondo oscuro (lerp 0.3 hacia blanco).
  /// El verde de marca sobre el navy del modo oscuro queda demasiado apagado.
  static const Color primaryOnDark = Color(0xFF50A699);

  // ---------------------------------------------------------------------
  // Superficies
  // ---------------------------------------------------------------------
  /// Fondo de pantalla. NO es blanco puro a proposito: las tarjetas si lo
  /// son, y sin diferencia de luminosidad entre las dos desaparecen en
  /// monitores de poco contraste. Da ~6% de diferencia contra el blanco, por
  /// encima del 5% minimo de la regla de superficies.
  static const Color surface = Color(0xFFF6F7F9);
  static const Color cardSilver = Color(0xFFF1F5F9);
  static const Color white = Colors.white;

  // ---------------------------------------------------------------------
  // Texto
  // ---------------------------------------------------------------------
  /// Navy del prototipo del cliente. Muestreado da #0D1720; se redondea a
  /// slate-900, que es casi seguro lo que uso el disenador y que ademas ya
  /// vivia en este proyecto como fondo del modo oscuro.
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color mutedText = Color(0xFF64748B);

  // ---------------------------------------------------------------------
  // Bordes
  // ---------------------------------------------------------------------
  static const Color border = Color(0xFFE2E8F0);

  // ---------------------------------------------------------------------
  // Semanticos
  // ---------------------------------------------------------------------
  // Una sola familia de verde y una sola de rojo en toda la app: dos verdes
  // parecidos conviviendo se leen como un error de diseno, no como jerarquia.
  static const Color success = brandGreen;
  static const Color destructive = brandRed;

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
}
