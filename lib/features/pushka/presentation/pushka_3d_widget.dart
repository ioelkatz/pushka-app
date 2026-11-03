import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Static PNG pushka. Ioel pidió reemplazar la pushka 3D pintada (cilindro
/// custom-painter + animación de líquido + labels de meta/monto flotantes)
/// por una imagen única — el progreso ya se ve en la barra de arriba, así
/// que duplicarlo flotando sobre la pushka era ruido visual.
///
/// La signature mantiene fillPercentage / goal / amount / currencySymbol para
/// no romper el callsite en pushka_screen ni la GlobalKey
/// `Pushka3DWidgetState`. Esos parámetros se ignoran: la imagen es estática.
///
/// ---------------------------------------------------------------------
/// Por qué el alto lo calcula el widget y no se lo impone la pantalla
/// ---------------------------------------------------------------------
/// La lata original era VERTICAL (786×1153). Metida en una caja más ancha que
/// alta, `BoxFit.contain` la ajustaba por el alto y sobraba ancho a los
/// costados: daba igual qué ancho tuviera la caja.
///
/// La lata del 2026-11-03 es APAISADA (1249×978): trae los chevrones del logo
/// abriéndose a izquierda y derecha, cortados contra ambos bordes del archivo
/// a propósito. Ahora manda el ANCHO, y una caja de alto fijo deja una franja
/// muerta arriba y abajo — en un celular angosto, casi la mitad de la caja.
///
/// Por eso el widget pide el ancho disponible, deriva el alto de la
/// proporción real del archivo y se queda exactamente con ese alto. La
/// pantalla ya no fija el alto: pasa un `maxHeight` como techo, y la columna
/// (centrada en su scroll) reparte sola lo que sobre.
class Pushka3DWidget extends StatefulWidget {
  final double fillPercentage;
  final double goal;
  final double amount;
  final String currencySymbol;

  /// Techo de alto, no alto fijo. El widget usa menos si el ancho no da.
  final double maxHeight;

  const Pushka3DWidget({
    super.key,
    required this.fillPercentage,
    required this.goal,
    required this.amount,
    required this.currencySymbol,
    required this.maxHeight,
  });

  /// Proporción exacta del asset `pushka_can.png` (1249×978), ya recortado
  /// el aire transparente que traía arriba y abajo.
  ///
  /// ⚠️ Si se reemplaza la imagen hay que actualizar este número Y
  /// [slotFromTop]. `test/unit/pushka_asset_test.dart` falla si el archivo
  /// deja de medir lo que dice acá, justamente para que no se desincronicen
  /// en silencio.
  static const double assetWidth = 1249;
  static const double assetHeight = 978;
  static const double assetAspect = assetWidth / assetHeight;

  /// Dónde cae la ranura de la lata, medida desde el borde superior de la
  /// imagen (9,4% = 92 px de 978). La usa `_launchFallingAnimation` en
  /// pushka_screen para que la moneda aterrice justo en la ranura.
  ///
  /// Antes era 0.18, un número atado a la lata vertical: con esa imagen la
  /// caja medía más que la foto y había que sumarle el margen de arriba. Hoy
  /// la caja calza exacto con la imagen, así que el porcentaje de la imagen
  /// ES el porcentaje del widget.
  static const double slotFromTop = 0.094;

  @override
  State<Pushka3DWidget> createState() => Pushka3DWidgetState();
}

class Pushka3DWidgetState extends State<Pushka3DWidget> {
  @override
  Widget build(BuildContext context) {
    // Ancho util de la pantalla: el total menos lo que se comen muescas o
    // bordes curvos. En un celular en vertical esos insets son 0, pero
    // restarlos evita que la imagen se meta debajo de un notch lateral en
    // horizontal o en un plegable.
    final medios = MediaQuery.of(context);
    final anchoPantalla =
        medios.size.width - medios.padding.left - medios.padding.right;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Ojo: `constraints.maxWidth` es el ancho de la COLUMNA, que lleva el
        // margen de 16 de la pantalla. La imagen no lo respeta a proposito.
        final alto = math.min(
          anchoPantalla / Pushka3DWidget.assetAspect,
          widget.maxHeight,
        );
        return SizedBox(
          width: constraints.maxWidth,
          height: alto,
          // La lata se sale del margen de la pantalla y llega borde a borde.
          // Los chevrones del logo vienen cortados contra los bordes del
          // archivo: encerrados entre dos franjas blancas el corte se lee
          // como un error, y contra el borde del celular se lee como lo que
          // es. Quien recorta de verdad es el SingleChildScrollView de
          // pushka_screen, que mide la pantalla completa — por eso esto no
          // desborda a ningun lado.
          child: OverflowBox(
            minWidth: anchoPantalla,
            maxWidth: anchoPantalla,
            minHeight: alto,
            maxHeight: alto,
            alignment: Alignment.center,
            child: Image.asset(
              'assets/images/pushka_can.png',
              // `contain` y no `cover`: en pantallas muy bajas el techo de
              // alto manda y la imagen se achica dejando un hilo de margen a
              // los costados. Es feo, pero `cover` ahi le cortaria la tapa y
              // la base a la lata, que es peor.
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        );
      },
    );
  }
}
