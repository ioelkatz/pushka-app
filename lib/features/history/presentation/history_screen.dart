import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/transaction.dart';
import '../providers/history_provider.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  TransactionType? selectedFilter;

  @override
  Widget build(BuildContext context) {
    final transactions = ref.watch(historyProvider);
    final filteredTransactions = selectedFilter == null
        ? transactions
        : transactions.where((t) => t.type == selectedFilter).toList();

    const blue = Color(0xFF2F60C5);

    return Column(
      children: [
        // Filtro dropdown
        Container(
          margin: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: PopupMenuButton<TransactionType?>(
            offset: const Offset(0, 50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Text(
                    _getFilterLabel(),
                    style: TextStyle(
                      color: blue,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
                ],
              ),
            ),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: TransactionType.tzedaka,
                child: const Text('Mi Tzedaka'),
              ),
              PopupMenuItem(
                value: TransactionType.pushkaEmpty,
                child: const Text('Pushka Vacía'),
              ),
              PopupMenuItem(
                value: TransactionType.walletFill,
                child: const Text('Billetera Rellena'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: null,
                child: Text('Todos'),
              ),
            ],
            onSelected: (value) {
              setState(() {
                selectedFilter = value;
              });
            },
          ),
        ),

        // Lista de transacciones
        Expanded(
          child: filteredTransactions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history,
                        size: 64,
                        color: Colors.grey.shade300,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No hay transacciones',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  itemCount: filteredTransactions.length,
                  itemBuilder: (context, index) {
                    final transaction = filteredTransactions[index];
                    return _buildTransactionItem(transaction, blue);
                  },
                ),
        ),
      ],
    );
  }

  String _getFilterLabel() {
    switch (selectedFilter) {
      case TransactionType.tzedaka:
        return 'Mi Tzedaka';
      case TransactionType.pushkaEmpty:
        return 'Pushka Vacía';
      case TransactionType.walletFill:
        return 'Billetera Rellena';
      case null:
        return 'Mi Tzedaka';
    }
  }

  Widget _buildTransactionItem(Transaction transaction, Color blue) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          // Icono de Pushka
          _buildPushkaIcon(),
          const SizedBox(width: 16),
          // Fecha y hora
          Expanded(
            child: Text(
              transaction.formattedDate,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w400,
                color: Colors.black87,
              ),
            ),
          ),
          // Monto
          Text(
            '\$${transaction.amount.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: blue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPushkaIcon() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200, width: 1),
      ),
      child: Center(
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.grey.shade300, width: 1.5),
          ),
          child: Stack(
            children: [
              // Ranura en la parte superior
              Positioned(
                top: 3,
                left: 10,
                right: 10,
                child: Container(
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade500,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
              // Texto hebreo "צדקה" vertical con colores arcoíris
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildColoredLetter('צ', Colors.red),
                    _buildColoredLetter('ד', Colors.orange),
                    _buildColoredLetter('ק', Colors.yellow.shade700),
                    _buildColoredLetter('ה', Colors.green),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColoredLetter(String letter, Color color) {
    return Text(
      letter,
      style: TextStyle(
        fontSize: 7,
        fontWeight: FontWeight.w700,
        color: color,
        height: 0.9,
      ),
      textDirection: TextDirection.rtl,
    );
  }
}
