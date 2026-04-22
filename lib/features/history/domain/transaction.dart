enum TransactionType {
  tzedaka,
  pushkaEmpty,
  walletFill,
}

enum PaymentMethod {
  card,
  check,
  transfer,
  daf,
  auto,
}

enum PaymentStatus {
  completed,
  pending,
  confirmed,
}

class Transaction {
  final String id;
  final TransactionType type;
  final double amount;
  final DateTime dateTime;
  final String? description;
  final PaymentMethod paymentMethod;
  final PaymentStatus status;
  final String currencyCode;

  Transaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.dateTime,
    this.description,
    this.paymentMethod = PaymentMethod.card,
    this.status = PaymentStatus.completed,
    this.currencyCode = 'USD',
  });

  bool get isPending => status == PaymentStatus.pending;
}

