import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Blinda las fuentes empaquetadas.
///
/// Las tipografias se declaran como familias en el pubspec y Flutter las carga
/// del bundle AL ARRANCAR. Este test verifica que cada archivo este ahi con el
/// nombre exacto: si falta uno, la familia queda sin ese peso y la app cae a la
/// fuente del sistema en las pantallas que lo usen, sin ningun error visible.
///
/// Historia, porque explica por que el test existe y como esta escrito:
///
/// 1. La app usaba google_fonts, que DESCARGABA las tipografias de
///    fonts.gstatic.com en cada instalacion. Crashlytics lo reporto como fatal
///    cuando la descarga fallaba.
/// 2. Se empaquetaron, pero declaradas en `fonts:` con nombres tipo
///    PlusJakartaSans-400.ttf. google_fonts ignora esa declaracion y busca por
///    NOMBRE EXACTO dentro de `assets:`, asi que dejo de descargarlas y tampoco
///    las encontraba: excepcion en cada arranque, peor que el bug original.
/// 3. Aun bien empaquetadas, google_fonts las cargaba ASINCRONO: el primer
///    frame salia con Roboto y la tipografia cambiaba a los segundos. Por eso
///    se saco la dependencia y se usan familias nativas.
///
/// ⚠️ La primera version de este test llamaba a `GoogleFonts.plusJakartaSans()`
/// esperando `returnsNormally`, y **pasaba igual con el archivo borrado**: la
/// falla era asincrona y nunca llegaba al test. Un test que no puede fallar es
/// peor que ninguno. Esta version usa `rootBundle.load`, y se comprobo que
/// falla de verdad escondiendo un archivo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Cada archivo declarado en la seccion `fonts:` del pubspec.
  /// Si se agrega una familia o un peso nuevo en el codigo, va aca tambien.
  const fuentesEsperadas = <String>[
    // Plus Jakarta Sans — el TextTheme de toda la app. Se empaqueta el rango
    // completo (200-800) para que ningun peso que el tema pida quede sin
    // archivo: cada faltante es un crash en la pantalla que lo use, no antes.
    'assets/fonts/PlusJakartaSans-ExtraLight.ttf', // 200
    'assets/fonts/PlusJakartaSans-Light.ttf', // 300
    'assets/fonts/PlusJakartaSans-Regular.ttf', // 400
    'assets/fonts/PlusJakartaSans-Medium.ttf', // 500
    'assets/fonts/PlusJakartaSans-SemiBold.ttf', // 600
    'assets/fonts/PlusJakartaSans-Bold.ttf', // 700
    'assets/fonts/PlusJakartaSans-ExtraBold.ttf', // 800
    // IBM Plex Sans — pantalla de Soporte. Light es el que aparecio en el
    // crash de la 1.0.7+10.
    'assets/fonts/IBMPlexSans-Light.ttf', // 300
    'assets/fonts/IBMPlexSans-Regular.ttf', // 400
  ];

  group('cada archivo declarado en el pubspec esta en el bundle', () {
    for (final ruta in fuentesEsperadas) {
      test(ruta.split('/').last, () async {
        final data = await rootBundle.load(ruta);
        // Un archivo presente pero vacio o truncado tampoco sirve: el header
        // de un TTF ya ocupa mas que esto.
        expect(
          data.lengthInBytes,
          greaterThan(1024),
          reason: '$ruta esta en el bundle pero parece vacio o truncado',
        );
      });
    }
  });

  test('todas son TTF de verdad, no HTML de error ni EOT', () async {
    // Al bajarlas de Google Fonts, segun el User-Agent te devuelven woff2 o
    // EOT en vez de TTF, y Flutter no puede usar ninguno de los dos. El
    // formato no se nota hasta que la app corre.
    for (final ruta in fuentesEsperadas) {
      final data = await rootBundle.load(ruta);
      final b = data.buffer.asUint8List(0, 4);
      // TTF valido: 0x00010000 (TrueType) o 'true'/'OTTO'.
      final esTtf = (b[0] == 0x00 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00) ||
          (b[0] == 0x74 && b[1] == 0x72 && b[2] == 0x75 && b[3] == 0x65) ||
          (b[0] == 0x4F && b[1] == 0x54 && b[2] == 0x54 && b[3] == 0x4F);
      expect(esTtf, isTrue, reason: '$ruta no tiene cabecera de TTF/OTF');
    }
  });
}
