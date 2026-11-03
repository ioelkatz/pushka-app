import 'package:flutter/material.dart';

class AppTokens {
  const AppTokens._();

  // =====================================================================
  // PALETA OFICIAL JYM — fuente unica de verdad
  // =====================================================================
  // Los tres valores los dio el cliente el 2026-11-03 y coinciden exactos
  // con el muestreo del logo pixel por pixel. NO se tocan sin pedirselos de
  // nuevo: son la identidad de Jabad en Campus, no una decision de diseno
  // nuestra.
  //
  //   rosado  #F82D4A   galon exterior del logo + la llama
  //   gris    #D3D3D3   galon del medio
  //   verde   #05806E   galon interior
  //
  // Lo que parece un segundo rojo mas claro en el logo es el antialias del
  // borde, no un cuarto color.
  //
  // Todo color de marca de la app sale de aca. `test/unit/paleta_jym_test.dart`
  // bloquea los tres valores Y falla si alguien vuelve a escribir uno de estos
  // hex a mano en cualquier archivo de `lib/`.

  /// El rosado del logo. El cliente lo llama "rosado"; en pantalla lee como
  /// un rojo frambuesa.
  static const Color brandRed = Color(0xFFF82D4A);

  /// El verde del galon interior.
  static const Color brandGreen = Color(0xFF05806E);

  /// El gris del galon del medio.
  static const Color brandGrey = Color(0xFFD3D3D3);

  // ---------------------------------------------------------------------
  // Roles derivados
  // ---------------------------------------------------------------------

  /// Acciones positivas: donar, guardar, continuar, el relleno de la barra
  /// de progreso.
  ///
  /// Es el VERDE y no el rosado a proposito. `primary` alimenta por defecto
  /// todos los ElevatedButton de la app — guardar tarjeta, confirmar, seguir
  /// — y un boton rojo solido se lee como destructivo en cualquier interfaz.
  /// El rosado queda reservado para lo que el diseno del cliente le asigna:
  /// la pildora de la racha, la llama y vaciar la pushka.
  static const Color primary = brandGreen;

  /// El mismo verde aclarado para fondo oscuro (lerp 0.3 hacia blanco).
  /// El verde de marca sobre el navy del modo oscuro queda demasiado apagado.
  static const Color primaryOnDark = Color(0xFF50A699);

  // ---------------------------------------------------------------------
  // Superficies
  // ---------------------------------------------------------------------
  /// Fondo de pantalla. NO es blanco puro a proposito: las tarjetas si lo
  /// son, y sin diferencia de luminosidad entre las dos desaparecen en
  /// monitores de poco contraste. Da ~7% de diferencia contra el blanco, por
  /// encima del 5% minimo de la regla de superficies (el test lo verifica).
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
  // Una sola familia de verde y una sola de rosado en toda la app: dos verdes
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
