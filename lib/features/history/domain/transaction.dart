enum TransactionType {
  tzedaka,      // Mi Tzedaka
  pushkaEmpty,  // Pushka Vacía
  walletFill,   // Billetera Rellena
}

class Transaction {
  final String id;
  final TransactionType type;
  final double amount;
  final DateTime dateTime;
  final String? description;

  Transaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.dateTime,
    this.description,
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

  String get formattedDate {
    final months = [
      'Ene',
      'Feb',
      'Mar',
      'Abr',
      'May',
      'Jun',
      'Jul',
      'Ago',
      'Sep',
      'Oct',
      'Nov',
      'Dic'
    ];
    final month = months[dateTime.month - 1];
    final day = dateTime.day;
    final hour = dateTime.hour;
    final minute = dateTime.minute;
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$month. $day - ${displayHour}:${minute.toString().padLeft(2, '0')}$period';
  }
}

