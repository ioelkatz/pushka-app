// Arnes de capturas — NO es parte de la suite.
//
// Vive fuera de `test/` a proposito: `flutter test` sin argumentos no lo
// levanta. Se corre a mano cuando hay que mirar como cae la lata en
// pantallas de distinto tamano:
//
//   flutter test tool/capturas/pushka_capturas_test.dart
//
// Deja los PNG en la carpeta que indique la variable SALIDA, o en
// tool/capturas/salida (gitignorada).
//
// Reproduce la geometria vertical real de PushkaScreen: AppBar de
// kToolbarHeight, SafeArea con el inset de la barra de estado,
// Padding(16,20,16,10), el mismo clamp de imageHeight y el Pushka3DWidget de
// verdad. Lo unico simulado son los textos y los botones, que no influyen en
// como entra la imagen.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/app/theme/app_theme.dart';
import 'package:pushka_app/app/theme/app_tokens.dart';
import 'package:pushka_app/features/pushka/presentation/pushka_3d_widget.dart';

/// Celulares reales, en puntos logicos (dp) con su densidad.
class Telefono {
  final String nombre;
  final double ancho;
  final double alto;
  final double densidad;
  final double insetArriba;

  const Telefono(
    this.nombre,
    this.ancho,
    this.alto,
    this.densidad,
    this.insetArriba,
  );
}

const telefonos = <Telefono>[
  // El mas chico que sigue siendo comun. Es el caso duro: poco alto.
  Telefono('1-chico-320x568', 320, 568, 2.0, 20),
  Telefono('2-android-360x640', 360, 640, 3.0, 24),
  // El celular de Ioel: Galaxy S25, 1080x2340 @3.0.
  Telefono('3-galaxy-s25-360x780', 360, 780, 3.0, 36),
  Telefono('4-pixel-393x852', 393, 852, 2.75, 48),
  Telefono('5-grande-412x915', 412, 915, 2.625, 48),
];

final _raiz = GlobalKey();

Future<void> _cargarFuentes() async {
  const pesos = [
    'ExtraLight',
    'Light',
    'Regular',
    'Medium',
    'SemiBold',
    'Bold',
    'ExtraBold',
  ];
  final jakarta = FontLoader('Plus Jakarta Sans');
  for (final peso in pesos) {
    jakarta.addFont(rootBundle.load('assets/fonts/PlusJakartaSans-$peso.ttf'));
  }
  await jakarta.load();

  // Sin esta familia los textos de los botones salen como recuadros negros:
  // el tema la usa para ellos y flutter_test no carga nada por su cuenta.
  final plex = FontLoader('IBM Plex Sans');
  for (final peso in ['Light', 'Regular']) {
    plex.addFont(rootBundle.load('assets/fonts/IBMPlexSans-$peso.ttf'));
  }
  await plex.load();

  // Los iconos viven en el cache del SDK, no en el bundle de la app. Si no
  // esta, las capturas salen igual con recuadros en lugar de iconos: es
  // cosmetico y no vale romper el arnes por eso.
  final raizFlutter = Platform.environment['FLUTTER_ROOT'];
  if (raizFlutter != null) {
    final archivo = File(
      '$raizFlutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (archivo.existsSync()) {
      final iconos = FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(archivo.readAsBytesSync())));
      await iconos.load();
    }
  }
}

void main() {
  final salida = Directory(
    Platform.environment['SALIDA'] ?? 'tool/capturas/salida',
  );

  setUpAll(() async {
    await _cargarFuentes();
    if (!salida.existsSync()) salida.createSync(recursive: true);
  });

  // Cada captura despues de la primera tarda 10 minutos (ver la nota en
  // docs/rediseno-pendientes.md). Con SOLO=s25 se corre una sola.
  final filtro = Platform.environment['SOLO'];
  final aCapturar = filtro == null || filtro.isEmpty
      ? telefonos
      : telefonos.where((t) => t.nombre.contains(filtro)).toList();

  for (final tel in aCapturar) {
    testWidgets('captura ${tel.nombre}', (tester) async {
      tester.view.devicePixelRatio = tel.densidad;
      tester.view.physicalSize = Size(
        tel.ancho * tel.densidad,
        tel.alto * tel.densidad,
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        RepaintBoundary(
          key: _raiz,
          child: MediaQuery(
            data: MediaQueryData(
              size: Size(tel.ancho, tel.alto),
              devicePixelRatio: tel.densidad,
              padding: EdgeInsets.only(top: tel.insetArriba),
            ),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              home: const _PantallaFalsa(),
            ),
          ),
        ),
      );

      // La imagen se decodifica async y el reloj falso del test no la deja
      // avanzar: sin esto se captura el hueco.
      //
      // ⚠️ Aca vivia `precacheImage`, que NO completa dentro de runAsync y
      // se comia el timeout de 10 minutos del propio runAsync — cada captura
      // tardaba eso. Escuchar el ImageStream a mano completa en milisegundos.
      // El timeout corto es a proposito: si algun dia vuelve a colgarse,
      // falla rapido en vez de simular que trabaja.
      await tester.runAsync(() async {
        final flujo = const AssetImage(
          'assets/images/pushka_can.png',
        ).resolve(ImageConfiguration.empty);
        final listo = Completer<void>();
        late ImageStreamListener oyente;
        oyente = ImageStreamListener(
          (info, _) {
            flujo.removeListener(oyente);
            if (!listo.isCompleted) listo.complete();
          },
          onError: (error, pila) {
            flujo.removeListener(oyente);
            if (!listo.isCompleted) listo.completeError(error);
          },
        );
        flujo.addListener(oyente);
        await listo.future.timeout(const Duration(seconds: 30));
      });
      await tester.pumpAndSettle();

      final limite =
          _raiz.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final imagen = await limite.toImage(pixelRatio: tel.densidad);
      final bytes = await imagen.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${salida.path}/${tel.nombre}.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());

      // Deja la medida a la vista en la consola: sirve para discutir el
      // tamano sin tener que medir el PNG a ojo.
      final cajaLata =
          tester.renderObject(find.byType(Pushka3DWidget)) as RenderBox;
      // ignore: avoid_print
      print(
        'MEDIDA ${tel.nombre}: lata '
        '${cajaLata.size.width.toStringAsFixed(0)}x'
        '${cajaLata.size.height.toStringAsFixed(0)} dp',
      );
    });
  }
}

/// Copia fiel del esqueleto vertical de PushkaScreen.
class _PantallaFalsa extends StatelessWidget {
  const _PantallaFalsa();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Mi Pushka',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        leading: const Icon(Icons.menu),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Mismos numeros que pushka_screen.dart.
              final isCompact = constraints.maxHeight < 560;
              final imageHeight = (constraints.maxHeight - 260).clamp(
                220.0,
                440.0,
              );
              final topGap = isCompact ? 16.0 : 24.0;
              final titleSize = isCompact ? 20.0 : 24.0;
              final aire = ((constraints.maxHeight - 560) / 2).clamp(0.0, 40.0);
              final titleBottomGap = (isCompact ? 2.0 : 4.0) + aire;
              final actionsTopGap = (isCompact ? 2.0 : 4.0) + aire;

              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding(
                        // Igual que en pushka_screen: el margen de la
                        // pantalla vive aca adentro, y la lata se le escapa.
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            _banner(),
                            SizedBox(height: topGap),
                            Text(
                              'Llenala!',
                              style: TextStyle(
                                fontSize: titleSize,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'MX\$120.00 / MX\$500.00',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: (constraints.maxWidth - 32) * 0.09,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: 0.24,
                                  minHeight: 4,
                                  backgroundColor: cs.surfaceContainerHighest,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                        AppTokens.primary,
                                      ),
                                ),
                              ),
                            ),
                            SizedBox(height: titleBottomGap),
                            RepaintBoundary(
                              child: Pushka3DWidget(
                                maxHeight: imageHeight,
                                fillPercentage: 0.24,
                                goal: 500,
                                amount: 120,
                                currencySymbol: 'MX\$',
                              ),
                            ),
                            SizedBox(height: actionsTopGap),
                            _montos(),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton(
                                onPressed: () {},
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTokens.primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text(
                                  'Donar ahora',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _banner() => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    decoration: BoxDecoration(
      color: AppTokens.brandRed.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.local_fire_department, size: 18, color: AppTokens.brandRed),
        SizedBox(width: 6),
        Text(
          '5 dias',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppTokens.brandRed,
          ),
        ),
      ],
    ),
  );

  Widget _montos() => Row(
    children: [
      for (final monto in ['MX\$20', 'MX\$50', 'MX\$100', 'Otro'])
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: () {},
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  side: const BorderSide(color: AppTokens.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  monto,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTokens.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
