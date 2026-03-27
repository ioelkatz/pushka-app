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

  String get typeLabel {
    switch (type) {
      case TransactionType.tzedaka:
        return 'Mi Tzedaka';
      case TransactionType.pushkaEmpty:
        return 'Pushka Vacía';
      case TransactionType.walletFill:
        return 'Billetera Rellena';
    }
  }

  String get statusLabel {
    switch (status) {
      case PaymentStatus.completed:
        return 'Completado';
      case PaymentStatus.pending:
        return 'Pendiente';
      case PaymentStatus.confirmed:
        return 'Confirmado';
    }
  }

  String get paymentMethodLabel {
    switch (paymentMethod) {
      case PaymentMethod.card:
        return 'Tarjeta';
      case PaymentMethod.check:
        return 'Cheque';
      case PaymentMethod.transfer:
        return 'Transferencia';
      case PaymentMethod.daf:
        return 'DAF';
      case PaymentMethod.auto:
        return 'Auto';
    }
  }

  bool get isPending => status == PaymentStatus.pending;

  String get formattedDate {
    const months = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
                    'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];
    final month = months[dateTime.month - 1];
    final day = dateTime.day;
    final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final period = dateTime.hour < 12 ? 'AM' : 'PM';
    return '$month. $day - $hour:$minute$period';
  }
}

