import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/transaction.dart';
import '../providers/transactions_provider.dart';

enum _HistoryFilter {
  all,
  tzedaka,
  pushkaEmpty,
  walletFill,
}

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  _HistoryFilter selectedFilter = _HistoryFilter.all;

  @override
  Widget build(BuildContext context) {
    final transactionsAsync = ref.watch(userTransactionsProvider);

    const blue = Color(0xFF2F60C5);

    return Column(
      children: [
        // Filtro dropdown
        Container(
          margin: const EdgeInsets.fromLTRB(18, 14, 18, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: PopupMenuButton<_HistoryFilter>(
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
                value: _HistoryFilter.tzedaka,
                child: const Text('Mi Tzedaka'),
              ),
              PopupMenuItem(
                value: _HistoryFilter.pushkaEmpty,
                child: const Text('Pushka Vacía'),
              ),
              PopupMenuItem(
                value: _HistoryFilter.walletFill,
                child: const Text('Billetera Rellena'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: _HistoryFilter.all,
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
          child: transactionsAsync.when(
            data: (transactions) {
              final filtered = transactions.where((t) {
                switch (selectedFilter) {
                  case _HistoryFilter.all:
                    return true;
                  case _HistoryFilter.tzedaka:
                    return t.type == TransactionType.tzedaka;
                  case _HistoryFilter.pushkaEmpty:
                    return t.type == TransactionType.pushkaEmpty;
                  case _HistoryFilter.walletFill:
                    return t.type == TransactionType.walletFill;
                }
              }).toList();

              if (filtered.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: 54,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'No hay transacciones',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final transaction = filtered[index];
                  return _buildTransactionItem(transaction, blue);
                },
              );
            },
            loading: () => const Center(
              child: CircularProgressIndicator(),
            ),
            error: (error, _) => Center(
              child: Text(
                'Error cargando historial',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _getFilterLabel() {
    switch (selectedFilter) {
      case _HistoryFilter.tzedaka:
        return 'Mi Tzedaka';
      case _HistoryFilter.pushkaEmpty:
        return 'Pushka Vacía';
      case _HistoryFilter.walletFill:
        return 'Billetera Rellena';
      case _HistoryFilter.all:
        return 'Todos';
    }
  }

  Widget _buildTransactionItem(Transaction transaction, Color blue) {
    final amount = transaction.amount;
    final amountLabel = amount < 0
        ? '-\$${amount.abs().toStringAsFixed(2)}'
        : '\$${amount.toStringAsFixed(2)}';
    final amountColor = amount < 0 ? const Color(0xFFE05A4F) : blue;

    final showMethodBadge = transaction.paymentMethod != PaymentMethod.card;
    final showStatusBadge = transaction.isPending;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: transaction.isPending ? Colors.orange.shade200 : Colors.grey.shade200),
      ),
      child: Row(
        children: [
          _buildPushkaIcon(),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transaction.formattedDate,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Colors.black87),
                ),
                if (showMethodBadge || showStatusBadge) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    if (showMethodBadge)
                      _buildBadge(transaction.paymentMethodLabel, _iconForMethod(transaction.paymentMethod), const Color(0xFF2F60C5)),
                    if (showMethodBadge && showStatusBadge) const SizedBox(width: 6),
                    if (showStatusBadge)
                      _buildBadge('Pendiente', Icons.schedule, Colors.orange.shade700),
                  ]),
                ],
              ],
            ),
          ),
          Text(amountLabel, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: amountColor)),
        ],
      ),
    );
  }

  Widget _buildBadge(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  IconData _iconForMethod(PaymentMethod method) {
    switch (method) {
      case PaymentMethod.card:
        return Icons.credit_card;
      case PaymentMethod.check:
        return Icons.mail_outline;
      case PaymentMethod.transfer:
        return Icons.account_balance;
      case PaymentMethod.daf:
        return Icons.volunteer_activism;
    }
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
