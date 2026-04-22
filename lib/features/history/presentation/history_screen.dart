import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format_utils.dart';
import '../../../core/l10n/s.dart';
import '../../../core/widgets/shimmer_list.dart';
import '../../../core/widgets/empty_state.dart';
import '../data/transaction_repository.dart';
import '../domain/transaction.dart';
import '../providers/transactions_provider.dart';
import '../../users/presentation/user_profile_provider.dart';
import 'donation_chart.dart';

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
  bool _chartExpanded = false;
  late S _tr;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tr = S.of(context);
  }

  String _currencySymbol(String code) {
    const symbols = {
      'usd': 'US\$', 'eur': '€', 'gbp': '£', 'cad': 'CA\$',
      'mxn': 'MX\$', 'ars': 'ARS\$', 'brl': 'R\$', 'ils': '₪',
      'clp': 'CL\$', 'cop': 'CO\$',
    };
    return symbols[code.toLowerCase()] ?? '\$';
  }

  @override
  Widget build(BuildContext context) {
    final transactionsAsync = ref.watch(userTransactionsProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final currencySymbol = _currencySymbol(
      ((profile?['currencyCode'] as String?) ?? 'USD').toLowerCase(),
    );

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
                child: Text(_tr.filterTzedaka),
              ),
              PopupMenuItem(
                value: _HistoryFilter.pushkaEmpty,
                child: Text(_tr.filterPushkaEmpty),
              ),
              PopupMenuItem(
                value: _HistoryFilter.walletFill,
                child: Text(_tr.filterWalletFill),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: _HistoryFilter.all,
                child: Text(_tr.filterAll),
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

              return Column(
                children: [
                  // Chart accordion header
                  GestureDetector(
                    onTap: () => setState(() => _chartExpanded = !_chartExpanded),
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.bar_chart_rounded, size: 20, color: Color(0xFF2F60C5)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _chartExpanded ? _tr.chartHideGraph : _tr.chartShowGraph,
                              style: const TextStyle(
                                color: Color(0xFF2F60C5),
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          AnimatedRotation(
                            turns: _chartExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 250),
                            child: const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Collapsible chart
                  AnimatedCrossFade(
                    firstChild: const SizedBox.shrink(),
                    secondChild: DonationChart(transactions: transactions),
                    crossFadeState: _chartExpanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    duration: const Duration(milliseconds: 280),
                    sizeCurve: Curves.easeInOut,
                  ),
                  if (filtered.isEmpty)
                    Expanded(
                      child: EmptyState(
                        icon: Icons.volunteer_activism_rounded,
                        iconColor: const Color(0xFF2563EB),
                        title: _tr.noTransactions,
                        subtitle: _tr.noTransactionsSubtitle,
                      ),
                    )
                  else
                    Expanded(
                      child: RefreshIndicator(
                        color: const Color(0xFF2563EB),
                        onRefresh: () async =>
                            ref.invalidate(userTransactionsProvider),
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                          itemCount: filtered.length +
                              // Show footer only when the full unfiltered page
                              // hit the cap — not when a filter is narrowing.
                              (selectedFilter == _HistoryFilter.all &&
                                      transactions.length >= TransactionRepository.pageSize
                                  ? 1
                                  : 0),
                          itemBuilder: (context, index) {
                            final showFooter = selectedFilter == _HistoryFilter.all &&
                                transactions.length >= TransactionRepository.pageSize;
                            if (showFooter && index == filtered.length) {
                              // Footer notice: data may be truncated
                              return Padding(
                                padding: const EdgeInsets.only(top: 8, bottom: 4),
                                child: Text(
                                  _tr.showingLastN(TransactionRepository.pageSize),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              );
                            }
                            return GestureDetector(
                              onTap: () => _showTransactionDetail(
                                  context, filtered[index], currencySymbol),
                              child: _buildTransactionItem(filtered[index], blue, currencySymbol),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              );
            },
            loading: () => const ShimmerTileList(count: 8),
            error: (error, _) => Center(
              child: Text(
                _tr.errorLoadingHistory,
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showTransactionDetail(BuildContext context, Transaction t, String currencySymbol) {
    final blue = const Color(0xFF2F60C5);
    final amount = t.amount;
    final isNeg = amount < 0;
    final amountLabel = isNeg
        ? '-${formatMoney(amount.abs(), symbol: currencySymbol)}'
        : formatMoney(amount, symbol: currencySymbol);
    final amountColor = isNeg ? const Color(0xFFE05A4F) : blue;

    final (typeIcon, typeColor) = switch (t.type) {
      TransactionType.tzedaka     => (Icons.volunteer_activism_rounded, const Color(0xFF2563EB)),
      TransactionType.pushkaEmpty => (Icons.monetization_on_rounded,            const Color(0xFF059669)),
      TransactionType.walletFill  => amount >= 0
          ? (Icons.arrow_downward_rounded, const Color(0xFF059669))
          : (Icons.arrow_upward_rounded,   const Color(0xFFE05A4F)),
    };

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              // Icon
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(typeIcon, size: 32, color: typeColor),
              ),
              const SizedBox(height: 16),
              // Amount
              Text(
                amountLabel,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: amountColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _typeLabel(t.type),
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              // Details rows
              _detailRow(_tr.historyDate, _formatDate(t.dateTime)),
              if (t.description != null && t.description!.isNotEmpty)
                _detailRow(_tr.historyDescription, t.description!),
              _detailRow(_tr.historyMethod, _methodLabel(t.paymentMethod)),
              _detailRow(
                _tr.historyStatus,
                t.isPending ? _tr.pending : _tr.statusCompleted,
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  String _getFilterLabel() {
    switch (selectedFilter) {
      case _HistoryFilter.tzedaka:
        return _tr.filterTzedaka;
      case _HistoryFilter.pushkaEmpty:
        return _tr.filterPushkaEmpty;
      case _HistoryFilter.walletFill:
        return _tr.filterWalletFill;
      case _HistoryFilter.all:
        return _tr.filterAll;
    }
  }

  Widget _buildTransactionItem(Transaction transaction, Color blue, String currencySymbol) {
    final amount = transaction.amount;
    final amountLabel = amount < 0
        ? '-${formatMoney(amount.abs(), symbol: currencySymbol)}'
        : formatMoney(amount, symbol: currencySymbol);
    final amountColor = amount < 0 ? const Color(0xFFE05A4F) : blue;

    final showMethodBadge = transaction.paymentMethod != PaymentMethod.card &&
        transaction.paymentMethod != PaymentMethod.auto;
    final showStatusBadge = transaction.isPending;

    final (typeIcon, typeColor) = switch (transaction.type) {
      TransactionType.tzedaka      => (Icons.volunteer_activism_rounded, const Color(0xFF2563EB)),
      TransactionType.pushkaEmpty  => (Icons.monetization_on_rounded,            const Color(0xFF059669)),
      TransactionType.walletFill   => amount >= 0
          ? (Icons.arrow_downward_rounded, const Color(0xFF059669))
          : (Icons.arrow_upward_rounded,   const Color(0xFFE05A4F)),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: transaction.isPending ? Colors.orange.shade200 : Colors.grey.shade200,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: typeColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(typeIcon, size: 22, color: typeColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _typeLabel(transaction.type),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatDate(transaction.dateTime),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                if (showMethodBadge || showStatusBadge) ...[
                  const SizedBox(height: 5),
                  Row(children: [
                    if (showMethodBadge)
                      _buildBadge(
                        _methodLabel(transaction.paymentMethod),
                        _iconForMethod(transaction.paymentMethod),
                        const Color(0xFF2F60C5),
                      ),
                    if (showMethodBadge && showStatusBadge) const SizedBox(width: 6),
                    if (showStatusBadge)
                      _buildBadge(_tr.pending, Icons.schedule, Colors.orange.shade700),
                  ]),
                ],
              ],
            ),
          ),
          Text(
            amountLabel,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: amountColor),
          ),
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

  String _formatDate(DateTime dt) {
    final months = [
      _tr.monthJan, _tr.monthFeb, _tr.monthMar, _tr.monthApr,
      _tr.monthMay, _tr.monthJun, _tr.monthJul, _tr.monthAug,
      _tr.monthSep, _tr.monthOct, _tr.monthNov, _tr.monthDec,
    ];
    final month = months[dt.month - 1];
    final hour = dt.hour;
    final minute = dt.minute;
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '$month. ${dt.day} - $displayHour:${minute.toString().padLeft(2, '0')}$period';
  }

  String _typeLabel(TransactionType type) {
    switch (type) {
      case TransactionType.tzedaka:
        return _tr.filterTzedaka;
      case TransactionType.pushkaEmpty:
        return _tr.filterPushkaEmpty;
      case TransactionType.walletFill:
        return _tr.filterWalletFill;
    }
  }

  String _methodLabel(PaymentMethod method) {
    switch (method) {
      case PaymentMethod.card:
        return _tr.methodCard;
      case PaymentMethod.check:
        return _tr.methodCheck;
      case PaymentMethod.transfer:
        return _tr.methodTransfer;
      case PaymentMethod.daf:
        return _tr.methodDaf;
      case PaymentMethod.auto:
        return _tr.methodAuto;
    }
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
      case PaymentMethod.auto:
        return Icons.autorenew;
    }
  }

}
