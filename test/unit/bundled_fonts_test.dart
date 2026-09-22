import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Blinda las fuentes empaquetadas.
///
/// Existe por una regresion real del 2026-09-22. La app descargaba las
/// tipografias de fonts.gstatic.com en tiempo de ejecucion y crasheaba cuando
/// la descarga fallaba. Al empaquetarlas se apago `allowRuntimeFetching`, pero
/// los archivos se declararon en la seccion `fonts:` del pubspec con nombres
/// como `PlusJakartaSans-400.ttf`.
///
/// Eso NO es como google_fonts busca un asset empaquetado: ignora la
/// declaracion de familia y busca el archivo por NOMBRE EXACTO dentro de
/// `assets:`, con la convencion `{Familia}-{Peso}.ttf`. Resultado: dejo de
/// descargarlas y tampoco las encontraba, asi que tiraba excepcion en cada
/// arranque — un crash PEOR que el original, porque el anterior solo aparecia
/// con mala conexion.
///
/// ⚠️ La primera version de este test llamaba a `GoogleFonts.plusJakartaSans()`
/// y esperaba `returnsNormally`. **Pasaba igual con el archivo borrado**:
/// google_fonts falla de forma asincrona, dentro de un future que nadie
/// espera, asi que la excepcion nunca llega al test. Un test que no puede
/// fallar es peor que ninguno.
///
/// Por eso se verifica el invariante de verdad: que cada archivo este en el
/// bundle con el nombre exacto. Eso es deterministico y SI falla cuando falta.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Nombres EXACTOS que google_fonts construye al pedir cada peso.
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

  group('las fuentes estan empaquetadas con el nombre que google_fonts espera', () {
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
