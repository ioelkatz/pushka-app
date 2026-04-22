import 'package:cloud_functions/cloud_functions.dart';

class WalletService {
  WalletService._();

  static final WalletService instance = WalletService._();

  Future<void> confirmTopUpFromPaymentIntent(String paymentIntentId) async {
    final id = paymentIntentId.trim();
    if (id.isEmpty) throw ArgumentError('paymentIntentId must not be empty');
    if (!id.startsWith('pi_')) {
      throw ArgumentError(
          'paymentIntentId does not look like a valid Stripe payment intent: $id');
    }
    final callable = FirebaseFunctions.instance.httpsCallable(
      'walletTopUpFromPaymentIntent',
    );
    await callable.call({'paymentIntentId': id});
  }

  Future<void> transfer({
    required String targetWalletId,
    required double amount,
  }) async {
    if (targetWalletId.trim().isEmpty) {
      throw ArgumentError('targetWalletId must not be empty');
    }
    if (amount <= 0 || amount.isNaN || amount.isInfinite) {
      throw ArgumentError('amount must be a positive finite number');
    }
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
    if (fromWalletId.trim().isEmpty) {
      throw ArgumentError('fromWalletId must not be empty');
    }
    if (amount <= 0 || amount.isNaN || amount.isInfinite) {
      throw ArgumentError('amount must be a positive finite number');
    }
    final callable = FirebaseFunctions.instance.httpsCallable('walletRequestTransfer');
    await callable.call({
      'fromWalletId': fromWalletId,
      'amount': amount,
    });
  }

  Future<void> addContact(String walletId) async {
    final id = walletId.trim();
    if (id.isEmpty) throw ArgumentError('walletId must not be empty');
    final callable = FirebaseFunctions.instance.httpsCallable('addWalletContact');
    await callable.call({'walletId': id});
  }
}
