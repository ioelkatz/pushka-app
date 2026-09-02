import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../app/theme/app_tokens.dart';
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

  // Round-7 regression fix: delegate to the shared shortCurrencySymbol so
  // the tx list uses the SAME symbol table as the rest of the app. The
  // old local map covered only 10 currencies (mislabelling ARS as 'ARS$'
  // — one S redundant with the 'AR$' convention used everywhere else)
  // and let AUD/NZD/UYU/JPY/CNY/KRW/INR/RUB/TRY/CHF fall through to a
  // plain '$' which lied about the currency.
  String _currencySymbol(String code) => shortCurrencySymbol(code);

  @override
  Widget build(BuildContext context) {
    final transactionsAsync = ref.watch(userTransactionsProvider);
    // Symbol per-tx is derived from `transaction.currencyCode` inside the
    // row/detail builders — the user's ACTIVE currency is irrelevant to
    // historical transactions (a USD donation from yesterday must stay
    // "$1.00 USD" today even if the user just switched to MXN).
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Filter trigger — opens a bottom sheet (consistent with other
        // pickers in the app; replaces the prior PopupMenu that dropped
        // down underneath the row and felt out of place).
        Container(
          margin: const EdgeInsets.fromLTRB(18, 14, 18, 10),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outline),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _showFilterSheet,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Text(
                    _getFilterLabel(),
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.keyboard_arrow_down, color: cs.onSurfaceVariant),
                ],
              ),
            ),
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
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: cs.outline),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.bar_chart_rounded, size: 20, color: cs.onSurface),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _chartExpanded ? _tr.chartHideGraph : _tr.chartShowGraph,
                              style: TextStyle(
                                color: cs.onSurface,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          AnimatedRotation(
                            turns: _chartExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 250),
                            child: Icon(Icons.keyboard_arrow_down, color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Collapsible chart.
                  // We previously used AnimatedCrossFade here, but its
                  // default layoutBuilder puts both children in a Stack
                  // sized to the topChild — when the topChild is
                  // SizedBox.shrink (0 width), the bottomChild (chart)
                  // gets a 0-width constraint via Positioned(left:0,
                  // right:0) and the chart title "DONACIONES POR MES"
                  // wraps every character onto its own line, leaving a
                  // permanent vertical-letter strip below the toggle.
                  // AnimatedSize doesn't have that problem: the active
                  // child renders at its natural width and the parent's
                  // size animates between the two states. The chart
                  // appears/disappears instantly (no fade) but cleanly.
                  ClipRect(
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeInOut,
                      alignment: Alignment.topCenter,
                      child: _chartExpanded
                          ? DonationChart(
                              transactions: transactions,
                              activeCurrency: (ref
                                      .watch(userProfileProvider)
                                      .valueOrNull?['currencyCode'] as String?) ??
                                  'USD',
                            )
                          : const SizedBox(width: double.infinity),
                    ),
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
                        child: Builder(
                          builder: (_) {
                            final currentLimit = ref.watch(historyLimitProvider);
                            // Round-8 audit HIGH fix: previously the "Cargar
                            // más" affordance was hidden whenever ANY filter
                            // was active — a user with only Tzedakah txs on
                            // this page but more Pushka-empty behind it saw
                            // no way to expand. Now we ALWAYS show the button
                            // when the underlying stream has reached the
                            // current page limit; pagination is per-stream,
                            // not per-filter-view.
                            final showLoadMore = transactions.length >= currentLimit;
                            return ListView.builder(
                              padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                              itemCount: filtered.length + (showLoadMore ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (showLoadMore && index == filtered.length) {
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 12, bottom: 12),
                                    child: Center(
                                      child: OutlinedButton.icon(
                                        icon: const Icon(Icons.expand_more, size: 18),
                                        label: Text(_tr.loadMore),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppTokens.primaryBlue,
                                          side: const BorderSide(color: AppTokens.primaryBlue),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                        ),
                                        onPressed: () {
                                          // Bump the stream's limit by another
                                          // page. The StreamProvider re-listens
                                          // on the new query; existing items
                                          // remain rendered while the older
                                          // ones stream in.
                                          ref.read(historyLimitProvider.notifier).state =
                                              currentLimit + TransactionRepository.pageSize;
                                        },
                                      ),
                                    ),
                                  );
                                }
                                return GestureDetector(
                                  onTap: () => _showTransactionDetail(
                                      context, filtered[index]),
                                  child: _buildTransactionItem(filtered[index], cs.onSurface),
                                );
                              },
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
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_rounded, size: 48, color: cs.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Text(
                      _tr.errorLoadingHistory,
                      style: TextStyle(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(_tr.retry),
                      // Invalidate forces the StreamProvider to re-subscribe
                      // to Firestore. The old stream's error state is
                      // cleared and the loading shimmer paints while the
                      // new connection settles. Without this, a transient
                      // network failure leaves the user stuck on the error
                      // pane until they manually navigate away.
                      onPressed: () {
                        ref.invalidate(userTransactionsProvider);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showTransactionDetail(BuildContext context, Transaction t) {
    final cs = Theme.of(context).colorScheme;
    final amount = t.amount;
    final isNeg = amount < 0;
    // Per-tx currency: never renormalize a historical donation to the
    // user's CURRENT currency. Amount + code stay as they were charged.
    final currencySymbol = _currencySymbol(t.currencyCode.toLowerCase());
    final amountLabel = isNeg
        ? '-${formatMoney(amount.abs(), symbol: currencySymbol)} ${t.currencyCode.toUpperCase()}'
        : '${formatMoney(amount, symbol: currencySymbol)} ${t.currencyCode.toUpperCase()}';
    final amountColor = isNeg ? const Color(0xFFE05A4F) : cs.onSurface;

    final (typeIcon, typeColor) = switch (t.type) {
      TransactionType.tzedaka     => (Icons.volunteer_activism_rounded, const Color(0xFF2563EB)),
      TransactionType.pushkaEmpty => (Icons.monetization_on_rounded,            const Color(0xFF059669)),
    };

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final sheetCs = Theme.of(ctx).colorScheme;
        return Container(
          decoration: BoxDecoration(
            color: sheetCs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: sheetCs.outlineVariant,
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
                style: TextStyle(fontSize: 16, color: sheetCs.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              // Details rows
              _detailRow(_tr.historyDate, _formatDate(t.dateTime)),
              // Descripción slot: prefer the donor's message when they wrote
              // one (real signal), otherwise hide the row entirely. The
              // backend-default "Donación Stripe"/"Vaciado de Pushka (Stripe)"
              // is redundant with the type label rendered under the amount.
              if (t.donorMessage != null && t.donorMessage!.isNotEmpty)
                // maxLines=5 + ellipsis prevents a pathological long donor
                // message from stretching the bottom sheet past the screen
                // (Flexible only widens; without maxLines it wraps
                // unbounded). 5 lines matches the visual weight of the other
                // detail rows.
                _detailRow(
                  _tr.historyDescription,
                  t.donorMessage!,
                  maxLines: 5,
                ),
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

  Widget _detailRow(String label, String value, {int? maxLines}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: maxLines,
              overflow: maxLines != null ? TextOverflow.ellipsis : null,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface),
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
      case _HistoryFilter.all:
        return _tr.filterAll;
    }
  }

  Future<void> _showFilterSheet() async {
    final result = await showModalBottomSheet<_HistoryFilter>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      barrierColor: const Color(0xDD000000),
      builder: (sheetCtx) {
        final cs = Theme.of(sheetCtx).colorScheme;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(2)))),
                _filterTile(sheetCtx, _HistoryFilter.all, _tr.filterAll),
                const SizedBox(height: 8),
                _filterTile(sheetCtx, _HistoryFilter.tzedaka, _tr.filterTzedaka),
                const SizedBox(height: 8),
                _filterTile(sheetCtx, _HistoryFilter.pushkaEmpty, _tr.filterPushkaEmpty),
              ],
            ),
          ),
        );
      },
    );
    if (result != null && mounted) {
      setState(() => selectedFilter = result);
    }
  }

  Widget _filterTile(BuildContext ctx, _HistoryFilter value, String label) {
    final cs = Theme.of(ctx).colorScheme;
    final selected = selectedFilter == value;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.pop(ctx, value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppTokens.primaryBlue.withValues(alpha: 0.12) : cs.surface,
          border: Border.all(color: selected ? AppTokens.primaryBlue : cs.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check, color: AppTokens.primaryBlue, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionItem(Transaction transaction, Color primaryColor) {
    final cs = Theme.of(context).colorScheme;
    final amount = transaction.amount;
    // Per-tx currency (see _showTransactionDetail comment). The tx row
    // shows the original amount + code, e.g. "US$1.00 USD" even if the
    // user has since switched their active currency to MXN.
    final currencySymbol = _currencySymbol(transaction.currencyCode.toLowerCase());
    final amountLabel = amount < 0
        ? '-${formatMoney(amount.abs(), symbol: currencySymbol)} ${transaction.currencyCode.toUpperCase()}'
        : '${formatMoney(amount, symbol: currencySymbol)} ${transaction.currencyCode.toUpperCase()}';
    final amountColor = amount < 0 ? const Color(0xFFE05A4F) : primaryColor;

    final showMethodBadge = transaction.paymentMethod != PaymentMethod.card &&
        transaction.paymentMethod != PaymentMethod.auto;
    final showStatusBadge = transaction.isPending;

    final (typeIcon, typeColor) = switch (transaction.type) {
      TransactionType.tzedaka      => (Icons.volunteer_activism_rounded, const Color(0xFF2563EB)),
      TransactionType.pushkaEmpty  => (Icons.monetization_on_rounded,            const Color(0xFF059669)),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: transaction.isPending ? Colors.orange.shade200 : cs.outline,
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
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatDate(transaction.dateTime),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                if (showMethodBadge || showStatusBadge) ...[
                  const SizedBox(height: 5),
                  Row(children: [
                    if (showMethodBadge)
                      _buildBadge(
                        _methodLabel(transaction.paymentMethod),
                        _iconForMethod(transaction.paymentMethod),
                        cs.onSurfaceVariant,
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
    // Locale-aware time. Was hardcoded English "AM"/"PM", which read wrong
    // in French/Hebrew/Spanish and forced a 12-hour clock even where 24h is
    // standard. DateFormat.jm picks 12h vs 24h per locale.
    final locale = Localizations.localeOf(context).toString();
    final timeStr = DateFormat.jm(locale).format(dt);
    return '$month. ${dt.day} - $timeStr';
  }

  String _typeLabel(TransactionType type) {
    switch (type) {
      case TransactionType.tzedaka:
        return _tr.filterTzedaka;
      case TransactionType.pushkaEmpty:
        return _tr.filterPushkaEmpty;
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
