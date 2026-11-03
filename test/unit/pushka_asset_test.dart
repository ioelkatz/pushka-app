import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/pushka/presentation/pushka_3d_widget.dart';

/// Ata las medidas del PNG de la lata a las constantes que las describen.
///
/// `Pushka3DWidget` calcula su alto dividiendo el ancho disponible por
/// [Pushka3DWidget.assetAspect], y la animacion de la moneda apunta a
/// [Pushka3DWidget.slotFromTop]. Los dos numeros salen de medir el archivo.
///
/// Si alguien reemplaza la imagen por una de otra proporcion y no toca las
/// constantes, no explota nada: la lata queda estirada o con una franja
/// muerta, y la moneda aterriza al lado de la ranura. Son bugs que solo se
/// ven mirando la pantalla, y ya pasaron al pasar de la lata vertical
/// (786x1153) a la apaisada (1249x978).
///
/// Se verifico que falla: cambiando assetWidth a 1200.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('el PNG de la lata mide lo que dicen las constantes', () async {
    final datos = await rootBundle.load('assets/images/pushka_can.png');
    final bytes = datos.buffer.asUint8List();

    // Cabecera PNG: 8 bytes de firma, luego largo(4) + "IHDR"(4), y recien
    // ahi ancho(4) y alto(4), big-endian.
    expect(
      bytes.sublist(1, 4),
      equals('PNG'.codeUnits),
      reason: 'el asset dejo de ser un PNG',
    );
    final vista = ByteData.sublistView(bytes);
    final ancho = vista.getUint32(16);
    final alto = vista.getUint32(20);

    expect(
      ancho,
      Pushka3DWidget.assetWidth.toInt(),
      reason:
          'el ancho del PNG cambio. Actualiza assetWidth/assetHeight Y '
          'volve a medir slotFromTop (donde cae la ranura).',
    );
    expect(
      alto,
      Pushka3DWidget.assetHeight.toInt(),
      reason:
          'el alto del PNG cambio. Actualiza assetWidth/assetHeight Y '
          'volve a medir slotFromTop (donde cae la ranura).',
    );
  });

  test('la ranura cae en el tercio superior de la lata', () {
    // No se puede verificar el pixel exacto sin decodificar la imagen, pero
    // si se puede atajar el error grueso: un valor fuera de este rango
    // significa que la moneda aterriza en el cuerpo de la lata o fuera de
    // la imagen.
    expect(Pushka3DWidget.slotFromTop, greaterThan(0.0));
    expect(Pushka3DWidget.slotFromTop, lessThan(0.33));
  });
}
