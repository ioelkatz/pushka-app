enum TransactionType {
  tzedaka,
  pushkaEmpty,
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
  final String? tenantId;
  /// Optional message the donor wrote at payment time. Stamped on the
  /// Stripe PaymentIntent metadata and persisted by the webhook.
  final String? donorMessage;

  Transaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.dateTime,
    this.description,
    this.paymentMethod = PaymentMethod.card,
    this.status = PaymentStatus.completed,
    this.currencyCode = 'USD',
    this.tenantId,
    this.donorMessage,
  });

  bool get isPending => status == PaymentStatus.pending;
}

