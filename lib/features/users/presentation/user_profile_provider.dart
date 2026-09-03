import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_state_provider.dart';
import '../data/user_repository.dart';

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authStateChangesProvider).valueOrNull;
});

final userProfileProvider = StreamProvider<Map<String, dynamic>?>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return const Stream.empty();
  final repository = ref.watch(userRepositoryProvider);
  return repository.watchUser(user.uid);
});

/// Moneda elegida por el usuario que todavía no llegó por el stream del perfil.
///
/// El cambio de moneda pasa por la Cloud Function `changeUserCurrency`, que
/// escribe con el admin SDK **del lado del servidor**. Eso quita el eco
/// optimista de Firestore: si el cliente escribiera directo, el listener
/// dispararía al instante desde la caché local, pero una escritura que nace en
/// el servidor tiene que hacer el viaje de vuelta — 2 o 3 segundos en móvil.
///
/// Durante esa ventana, la pantalla de ajustes ya mostraba la moneda nueva
/// (hace `setState` local) mientras la pantalla principal, el historial y las
/// suscripciones seguían mostrando la vieja. Este provider cierra ese desfasaje.
///
/// Lo setea `settings_screen` cuando la CF responde OK, y lo limpia `app.dart`
/// cuando el perfil finalmente trae la moneda nueva.
final pendingCurrencyProvider = StateProvider<String?>((ref) => null);

/// La moneda vigente para mostrar: la elegida si todavía está en tránsito, si
/// no la del perfil. Siempre en minúsculas, como la usa el resto de la app.
///
/// Todo lo que muestre montos debe leer de acá y no de
/// `profile['currencyCode']` directamente, para que el cambio se vea al
/// instante en TODA la app y no pantalla por pantalla.
final activeCurrencyProvider = Provider<String>((ref) {
  final pending = ref.watch(pendingCurrencyProvider);
  if (pending != null && pending.trim().isNotEmpty) {
    return pending.toLowerCase();
  }
  final profile = ref.watch(userProfileProvider).valueOrNull;
  final code = (profile?['currencyCode'] as String?)?.trim();
  if (code != null && code.isNotEmpty) return code.toLowerCase();
  return 'usd';
});
