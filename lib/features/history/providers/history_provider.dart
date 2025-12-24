import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/transaction.dart';

class HistoryNotifier extends StateNotifier<List<Transaction>> {
  HistoryNotifier() : super(_getInitialTransactions());

  static List<Transaction> _getInitialTransactions() {
    final now = DateTime.now();
    return [
      Transaction(
        id: '1',
        type: TransactionType.tzedaka,
        amount: 10.00,
        dateTime: now.subtract(const Duration(days: 2, hours: 5)),
      ),
      Transaction(
        id: '2',
        type: TransactionType.tzedaka,
        amount: 25.00,
        dateTime: now.subtract(const Duration(days: 5, hours: 2)),
      ),
      Transaction(
        id: '3',
        type: TransactionType.pushkaEmpty,
        amount: 50.00,
        dateTime: now.subtract(const Duration(days: 7)),
      ),
      Transaction(
        id: '4',
        type: TransactionType.walletFill,
        amount: 100.00,
        dateTime: now.subtract(const Duration(days: 10)),
      ),
    ];
  }

  void addTransaction(Transaction transaction) {
    state = [transaction, ...state];
  }

  void addTzedaka(double amount, {String? description}) {
    final transaction = Transaction(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: TransactionType.tzedaka,
      amount: amount,
      dateTime: DateTime.now(),
      description: description,
    );
    addTransaction(transaction);
  }

  void addPushkaEmpty(double amount) {
    final transaction = Transaction(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: TransactionType.pushkaEmpty,
      amount: amount,
      dateTime: DateTime.now(),
    );
    addTransaction(transaction);
  }

  void addWalletFill(double amount) {
    final transaction = Transaction(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: TransactionType.walletFill,
      amount: amount,
      dateTime: DateTime.now(),
    );
    addTransaction(transaction);
  }

  List<Transaction> getFilteredTransactions(TransactionType? filter) {
    if (filter == null) return state;
    return state.where((t) => t.type == filter).toList();
  }
}

final historyProvider = StateNotifierProvider<HistoryNotifier, List<Transaction>>(
  (ref) => HistoryNotifier(),
);

