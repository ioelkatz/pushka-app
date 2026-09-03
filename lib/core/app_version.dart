import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Versión + build leídos del PAQUETE INSTALADO, no de una constante.
///
/// Importa que salga del binario real: la app se distribuye también por
/// sideload, donde no hay una tienda que garantice que todos tengan la última.
/// Cuando alguien reporta algo, lo primero es saber qué build tiene puesto.
///
/// Antes había una constante `AppTokens.appVersion = '1.0.0'` escrita a mano
/// que el menú lateral y la pantalla de soporte mostraban. Quedó congelada:
/// con la app ya en 1.0.2, el menú seguía diciendo 1.0.0 mientras la pantalla
/// Acerca de mostraba la correcta. Exactamente el tipo de dato que no debe
/// duplicarse a mano.
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
});

