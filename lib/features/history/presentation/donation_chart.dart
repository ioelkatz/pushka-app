import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/format_utils.dart';
import '../../../core/l10n/s.dart';
import '../domain/transaction.dart';

class DonationChart extends StatefulWidget {
  final List<Transaction> transactions;

  const DonationChart({super.key, required this.transactions});

  @override
  State<DonationChart> createState() => _DonationChartState();
}

class _DonationChartState extends State<DonationChart> {
  int? _touchedIndex;

  /// Aggregates donations into the last 6 calendar months.
  List<_MonthBucket> _buildBuckets(S tr) {
    final now = DateTime.now();
    final months = <_MonthBucket>[];

    for (int i = 5; i >= 0; i--) {
      final dt = DateTime(now.year, now.month - i, 1);
      final label = _monthLabel(dt.month, tr);
      months.add(_MonthBucket(month: dt.month, year: dt.year, label: label));
    }

    for (final t in widget.transactions) {
      if (t.type != TransactionType.tzedaka &&
          t.type != TransactionType.pushkaEmpty) { continue; }
      for (final b in months) {
        if (t.dateTime.month == b.month && t.dateTime.year == b.year) {
          b.total += t.amount;
          break;
        }
      }
    }

    return months;
  }

  String _monthLabel(int month, S tr) {
    final all = [
      tr.monthJan, tr.monthFeb, tr.monthMar, tr.monthApr,
      tr.monthMay, tr.monthJun, tr.monthJul, tr.monthAug,
      tr.monthSep, tr.monthOct, tr.monthNov, tr.monthDec,
    ];
    return all[month - 1];
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final buckets = _buildBuckets(tr);
    final maxVal = buckets.fold<double>(
      1,
      (prev, b) => b.total > prev ? b.total : prev,
    );
    final hasData = buckets.any((b) => b.total > 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
          child: Text(
            tr.chartTitle,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: AppTokens.textPrimary,
            ),
          ),
        ),
        if (!hasData)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
            child: Text(
              tr.chartNoData,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            ),
          )
        else
          SizedBox(
            height: 160,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
              child: BarChart(
                BarChartData(
                  maxY: maxVal * 1.25,
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => AppTokens.primaryBlue,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final b = buckets[group.x];
                        return BarTooltipItem(
                          '${b.label}\n${formatMoney(b.total)}',
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        );
                      },
                    ),
                    touchCallback: (event, response) {
                      setState(() {
                        _touchedIndex =
                            response?.spot?.touchedBarGroupIndex;
                      });
                    },
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 22,
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx < 0 || idx >= buckets.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              buckets[idx].label,
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade500,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: maxVal / 4,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: Colors.grey.shade200,
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: buckets.asMap().entries.map((e) {
                    final i = e.key;
                    final b = e.value;
                    final isTouched = _touchedIndex == i;
                    return BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: b.total,
                          color: isTouched
                              ? AppTokens.primaryBlue
                              : AppTokens.primaryBlue.withValues(alpha: 0.55),
                          width: 20,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        Divider(height: 1, thickness: 1, color: Colors.grey.shade200),
      ],
    );
  }
}

class _MonthBucket {
  final int month;
  final int year;
  final String label;
  double total = 0;

  _MonthBucket({
    required this.month,
    required this.year,
    required this.label,
  });
}
