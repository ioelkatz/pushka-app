import 'package:cloud_functions/cloud_functions.dart';

class WalletService {
  WalletService._();

  static final WalletService instance = WalletService._();

  Future<void> confirmTopUpFromPaymentIntent(String paymentIntentId) async {
    final callable = FirebaseFunctions.instance.httpsCallable(
      'walletTopUpFromPaymentIntent',
    );
    await callable.call({'paymentIntentId': paymentIntentId});
  }

  Future<void> transfer({
    required String targetWalletId,
    required double amount,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('walletTransfer');
    await callable.call({
      'targetWalletId': targetWalletId,
      'amount': amount,
    });
  }

  Future<void> requestTransfer({
    required String fromWalletId,
    required double amount,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('walletRequestTransfer');
    await callable.call({
      'fromWalletId': fromWalletId,
      'amount': amount,
    });
  }

  Future<void> addContact(String walletId) async {
    final callable = FirebaseFunctions.instance.httpsCallable('addWalletContact');
    await callable.call({'walletId': walletId});
  }
}
