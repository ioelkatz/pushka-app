import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/s.dart';
import '../../tenant/data/tenant_repository.dart';

/// Shared row that summarizes the active auto-empty schedule.
/// Used by both Settings and Wallet so the two screens stay in sync.
///
/// Renders as: "Semanal · Miércoles 12 Abril" — frequency, then the
/// next-run date when one is scheduled. The "·" separator uses a
/// `WidgetSpan` so it sits on the visual midline rather than the
/// cap-height (where U+00B7 would otherwise float high).
class AutoEmptyActionRow extends ConsumerWidget {
  const AutoEmptyActionRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final tenantState = ref.watch(tenantStateProvider).valueOrNull;

    final freq = (tenantState?['autoEmptyFrequency'] as String?) ?? 'manual';
    final freqLabel = switch (freq) {
      'weekly' => tr.freqWeekly,
      'monthly' => tr.freqMonthly,
      'erev_rosh_chodesh' => tr.freqErevRosh,
      _ => tr.manualEmpty,
    };

    final nextRunRaw = tenantState?['autoEmptyNextRunAt'];
    final nextRun = nextRunRaw is DateTime
        ? nextRunRaw
        : (nextRunRaw?.toDate?.call() as DateTime?);
    final nextRunLabel = (nextRun != null && freq != 'manual')
        ? _formatNextRun(nextRun, tr.locale.languageCode)
        : null;

    // El ultimo cobro automatico fallo y todavia no hubo uno bueno despues.
    // Lo estampa el webhook (payment_intent.payment_failed con
    // purpose=pushka_auto_empty) y lo borra el primer cobro exitoso.
    //
    // Sin esto la fila decia "Mensual · 12 de octubre" aunque el cobro llevara
    // meses fallando: el donante seguia metiendo monedas en su pushka creyendo
    // que se vaciaba sola. Audit de producto del 2026-09-04.
    final hasFailure = tenantState?['autoEmptyLastFailureAt'] != null;

    final textStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: cs.onSurface,
    );

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                TextSpan(
                  style: textStyle,
                  children: [
                    TextSpan(text: freqLabel),
                    if (nextRunLabel != null) ...[
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Container(
                            width: 3,
                            height: 3,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                      ),
                      TextSpan(text: nextRunLabel),
                    ],
                  ],
                ),
              ),
                  if (hasFailure) ...[
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(Icons.error_outline, size: 15, color: cs.error),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            tr.autoEmptyLastChargeFailed,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: cs.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// "Miércoles 12 Abril" in es; falls back to "Wed 12 Apr" style elsewhere.
  String _formatNextRun(DateTime when, String locale) {
    final w = _weekdays[locale]?[when.weekday - 1] ??
        _weekdays['en']![when.weekday - 1];
    final m = _months[locale]?[when.month - 1] ??
        _months['en']![when.month - 1];
    return '$w ${when.day} $m';
  }

  static const Map<String, List<String>> _weekdays = {
    'es': ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'],
    'en': ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
    'fr': ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'],
    'he': ['שני', 'שלישי', 'רביעי', 'חמישי', 'שישי', 'שבת', 'ראשון'],
  };

  static const Map<String, List<String>> _months = {
    'es': ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
           'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'],
    'en': ['January', 'February', 'March', 'April', 'May', 'June',
           'July', 'August', 'September', 'October', 'November', 'December'],
    'fr': ['Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
           'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'],
    'he': ['ינואר', 'פברואר', 'מרץ', 'אפריל', 'מאי', 'יוני',
           'יולי', 'אוגוסט', 'ספטמבר', 'אוקטובר', 'נובמבר', 'דצמבר'],
  };
}
