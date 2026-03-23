import 'package:cloud_functions/cloud_functions.dart';

class WalletService {
  WalletService._();

  static final WalletService instance = WalletService._();

  Future<void> confirmTopUpFromPaymentIntent(String paymentIntentId) async {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'walletTopUpFromPaymentIntent',
    );
    try {
      await callable.call({'paymentIntentId': paymentIntentId});
    } on FirebaseFunctionsException catch (error) {
      final message = error.message ?? 'No se pudo confirmar la recarga.';
      throw Exception(message);
    }
  }

  Future<void> transfer({
    required String targetWalletId,
    required double amount,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('walletTransfer');
    try {
      await callable.call({
        'targetWalletId': targetWalletId,
        'amount': amount,
      });
    } on FirebaseFunctionsException catch (error) {
      final message = error.message ?? 'No se pudo completar la transferencia.';
      throw Exception(message);
    }
  }

  Future<void> requestTransfer({
    required String fromWalletId,
    required double amount,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('walletRequestTransfer');
    try {
      await callable.call({
        'fromWalletId': fromWalletId,
        'amount': amount,
      });
    } on FirebaseFunctionsException catch (error) {
      final message = error.message ?? 'No se pudo enviar la solicitud.';
      throw Exception(message);
    }
  }

    Future<void> addContact(String walletId) async {
    final callable = FirebaseFunctions.instance.httpsCallable('addWalletContact');
    try {
      await callable.call({'walletId': walletId});
    } on FirebaseFunctionsException catch (error) {
      final message = error.message ?? 'No se pudo agregar el contacto.';
      throw Exception(message);
    }
  }
}

