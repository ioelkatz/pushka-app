import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/app/theme/app_tokens.dart';

/// Blinda la paleta oficial de Jabad en Campus.
///
/// Los tres colores los dio el cliente el 2026-11-03 (rosado #F82D4A,
/// gris #D3D3D3, verde #05806E) y son identidad de marca, no una decision de
/// diseno nuestra. Un color de marca se rompe de dos maneras, y las dos son
/// invisibles en code review:
///
/// 1. Alguien "ajusta" un token en `app_tokens.dart` y toda la app se corre
///    de la identidad del cliente.
/// 2. Alguien escribe el hex a mano en una pantalla nueva. Ese valor queda
///    fuera del tema: cuando la paleta cambie, esa pantalla se queda atras y
///    nadie se va a dar cuenta hasta verla al lado de otra.
///
/// Este test cubre las dos. El segundo caso es el que importa mas, porque es
/// el que ya paso en este proyecto con los rojos #CC2936 y #FFE5E5.
///
/// Se verifico que los tres grupos FALLAN de verdad: cambiando un digito de
/// un token, y pegando `Color(0xFFF82D4A)` en un archivo de `lib/`.
void main() {
  group('paleta oficial JYM', () {
    test('los tres colores del cliente son exactos', () {
      // Si uno de estos falla, NO lo arregles cambiando el test: el valor
      // correcto es el que mando el cliente. Pedilo de nuevo antes de tocar.
      expect(AppTokens.brandRed, const Color(0xFFF82D4A), reason: 'rosado');
      expect(AppTokens.brandGreen, const Color(0xFF05806E), reason: 'verde');
      expect(AppTokens.brandGrey, const Color(0xFFD3D3D3), reason: 'gris');
    });

    test('los roles derivados apuntan a los colores de marca', () {
      // El verde manda las acciones positivas y el rosado lo destructivo.
      // Invertirlos deja botones de "donar" en rojo, que se leen como peligro.
      expect(AppTokens.primary, AppTokens.brandGreen);
      expect(AppTokens.success, AppTokens.brandGreen);
      expect(AppTokens.destructive, AppTokens.brandRed);
    });
  });

  group('regla de superficies', () {
    // Ioel trabaja en un monitor de poco contraste: menos de 5% de diferencia
    // de luminosidad entre el fondo y una tarjeta se ve bien en el celular y
    // desaparece en su pantalla. Ya paso varias veces.
    test('el fondo se separa del blanco de las tarjetas al menos 5%', () {
      final diferencia =
          (AppTokens.white.computeLuminance() -
                  AppTokens.surface.computeLuminance())
              .abs();
      expect(
        diferencia,
        greaterThanOrEqualTo(0.05),
        reason:
            'fondo ${AppTokens.surface} contra tarjeta blanca: '
            '${(diferencia * 100).toStringAsFixed(1)}% de diferencia',
      );
    });
  });

  group('la paleta no se duplica', () {
    test('ningun archivo de lib/ repite un hex de marca a mano', () {
      // Los hex se arman por pedazos para que este test no se delate a si
      // mismo si algun dia alguien corre el scanner sobre test/ tambien.
      final hexDeMarca = <String, String>{
        'F8' '2D' '4A': 'AppTokens.brandRed',
        '05' '80' '6E': 'AppTokens.brandGreen',
        'D3' 'D3' 'D3': 'AppTokens.brandGrey',
      };
      const permitido = 'app_tokens.dart';

      final culpables = <String>[];
      final lib = Directory('lib');
      expect(
        lib.existsSync(),
        isTrue,
        reason: 'el test corre desde la raiz del paquete',
      );

      for (final entidad in lib.listSync(recursive: true)) {
        if (entidad is! File || !entidad.path.endsWith('.dart')) continue;
        if (entidad.path.endsWith(permitido)) continue;

        final contenido = entidad.readAsStringSync().toUpperCase();
        for (final entrada in hexDeMarca.entries) {
          if (contenido.contains(entrada.key)) {
            culpables.add(
              '${entidad.path} tiene #${entrada.key} '
              '(usar ${entrada.value})',
            );
          }
        }
      }

      expect(
        culpables,
        isEmpty,
        reason:
            'un color de marca escrito a mano queda fuera del tema y no '
            'sigue los cambios de paleta:\n  ${culpables.join('\n  ')}',
      );
    });
  });
}
