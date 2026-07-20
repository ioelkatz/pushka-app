import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// StreamProvider async* — seedeamos con checkConnectivity() antes de suscribirnos
// al stream de cambios. Sin este seed, en PWA/web (especialmente iOS Safari) el
// primer evento de onConnectivityChanged puede tardar o no emitirse hasta un
// cambio real de estado — el user queda con el banner "sin conexión" pegado
// aunque tenga internet perfecto.
final connectivityProvider = StreamProvider<bool>((ref) async* {
  final conn = Connectivity();
  try {
    final initial = await conn.checkConnectivity();
    yield initial.any((r) => r != ConnectivityResult.none);
  } catch (_) {
    // Si checkConnectivity falla (raro), asumimos online — es mejor mostrar la
    // app y que una request real falle con su propio error que bloquear con un
    // banner incorrecto.
    yield true;
  }
  yield* conn.onConnectivityChanged.map(
    (results) => results.any((r) => r != ConnectivityResult.none),
  );
});

final isOfflineProvider = Provider<bool>((ref) {
  return ref.watch(connectivityProvider).maybeWhen(
    data: (online) => !online,
    // Default a ONLINE mientras se resuelve el estado inicial. Antes era true
    // ("assume offline until first event") pero en PWA eso pintaba el banner
    // por segundos innecesariamente, y si el stream nunca emitía quedaba forever.
    orElse: () => false,
  );
});
