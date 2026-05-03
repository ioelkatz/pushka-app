import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'card_brand_box.dart';

import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../../core/l10n/s.dart';

class AutoEmptyScreen extends ConsumerStatefulWidget {
  const AutoEmptyScreen({super.key});

  @override
  ConsumerState<AutoEmptyScreen> createState() => _AutoEmptyScreenState();
}

class _AutoEmptyScreenState extends ConsumerState<AutoEmptyScreen> {
  final _amountController = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  // The frequency value that was already saved in Firestore when the screen opened.
  // Used to decide whether to show the consent dialog (only when enabling for first time).
  String _savedFrequency = 'manual';

  String _frequency = 'manual';
  int _weekday = DateTime.monday;
  int _dayOfMonth = 1;
  bool _topOffEnabled = false;
  double? _topOffAmount;

  // Saved cards for the card picker
  List<Map<String, dynamic>> _cards = [];
  bool _loadingCards = false;
  String? _selectedCardId;  // null = use current default

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _loadCards() async {
    if (_loadingCards) return;
    setState(() => _loadingCards = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('listSavedCards');
      final result = await callable.call({});
      if (!mounted) return;
      final data = result.data as Map<dynamic, dynamic>;
      final rawCards = data['cards'] as List<dynamic>? ?? [];
      setState(() {
        _cards = rawCards.map((c) => Map<String, dynamic>.from(c as Map)).toList();
      });
    } catch (_) {
      // Si falla la carga de tarjetas, el selector simplemente no aparece.
    } finally {
      if (mounted) setState(() => _loadingCards = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final tenantState = ref.watch(tenantStateProvider).valueOrNull;

    // Without a saved card the cron's `processPushkaAutoEmpty` hits the
    // no_saved_card branch and silently advances the schedule each cycle —
    // the user thinks they're set up but no money ever moves. Surface the
    // requirement BEFORE save: inline banner + hard block in the save path.
    final hasSavedCard = ((profile?['stripeDefaultPaymentMethodId'] as String?) ?? '')
        .trim()
        .isNotEmpty;
    final needsCardWarning = _frequency != 'manual' && !hasSavedCard;

    if (!_loaded && tenantState != null) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _frequency = (tenantState['autoEmptyFrequency'] as String?) ?? 'manual';
          _savedFrequency = _frequency;
          _weekday = (tenantState['autoEmptyWeekday'] as num?)?.toInt() ?? DateTime.monday;
          _dayOfMonth = (tenantState['autoEmptyDayOfMonth'] as num?)?.toInt() ?? 1;
          _topOffEnabled = (tenantState['autoEmptyTopOffEnabled'] as bool?) ?? false;
          _topOffAmount = (tenantState['autoEmptyTopOffAmount'] as num?)?.toDouble();
          // Field is now ALWAYS visible (disabled when toggle is off). Show
          // the last saved amount if any, else default to "0" so the user
          // sees a concrete starting value instead of an empty field.
          _amountController.text = _topOffAmount?.toStringAsFixed(0) ?? '0';
          _selectedCardId = tenantState['autoEmptyPaymentMethodId'] as String?;
        });
        if (_frequency != 'manual') _loadCards();
      });
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final red = isDark ? cs.primary : const Color(0xFFE05A4F);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.autoEmpty),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr.autoEmptyLabel,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(initialValue: _frequency,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
                items: [
                  DropdownMenuItem(value: 'manual', child: Text(tr.manualEmpty)),
                  DropdownMenuItem(value: 'weekly', child: Text(tr.freqWeekly)),
                  DropdownMenuItem(value: 'monthly', child: Text(tr.freqMonthly)),
                  DropdownMenuItem(
                    value: 'erev_rosh_chodesh',
                    child: Text(tr.freqErevRosh),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  final wasManual = _frequency == 'manual';
                  setState(() {
                    _frequency = value;
                    if (_frequency == 'weekly') {
                      _topOffAmount ??= 18;
                    } else if (_frequency == 'monthly' ||
                        _frequency == 'erev_rosh_chodesh') {
                      _topOffAmount ??= 36;
                    }
                    _amountController.text =
                        _topOffAmount?.toStringAsFixed(0) ?? '';
                  });
                  if (wasManual && value != 'manual' && _cards.isEmpty) {
                    _loadCards();
                  }
                },
              ),
              const SizedBox(height: 16),
              if (needsCardWarning) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFED7AA), width: 1),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.credit_card_off_rounded,
                              color: Color(0xFFB45309), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              tr.noCardsYet,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF92400E),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr.noSavedCards,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF92400E),
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFB45309),
                            padding: const EdgeInsets.symmetric(horizontal: 0),
                          ),
                          icon: const Icon(Icons.add_card_rounded, size: 18),
                          label: Text(
                            tr.addCard,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          // Pop first: AutoEmptyScreen was pushed via
                          // Navigator.push(MaterialPageRoute(...)) so it sits
                          // ABOVE the GoRouter stack. context.go alone would
                          // change the route under it but leave this screen
                          // visible on top.
                          onPressed: () {
                            final goRouter = GoRouter.of(context);
                            Navigator.of(context).pop();
                            goRouter.go('/settings/saved-cards');
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  tr.autoEmptyInfo,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
              const SizedBox(height: 20),
              if (_frequency == 'weekly') ...[
                Text(
                  tr.dayOfWeek,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _buildSelectTile(
                  _weekdayLabel(_weekday),
                  _showWeeklyDialog,
                ),
                const SizedBox(height: 20),
              ],
              if (_frequency == 'monthly') ...[
                Text(
                  tr.dayOfMonth,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _buildSelectTile(
                  _dayOfMonth.toString(),
                  _showMonthlyDialog,
                ),
                const SizedBox(height: 20),
              ],
              if (_frequency != 'manual' && (_loadingCards || _cards.isNotEmpty)) ...[
                Text(
                  tr.cardForAutoEmpty,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _loadingCards
                    ? const Center(child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ))
                    : _buildCardSelector(tr),
                const SizedBox(height: 20),
              ],
              if (_frequency != 'manual') ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        tr.pushkaTopOff,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Switch(
                      value: _topOffEnabled,
                      onChanged: (value) {
                        setState(() => _topOffEnabled = value);
                        if (value && _topOffAmount == null) {
                          setState(() {
                            _topOffAmount =
                                _frequency == 'weekly' ? 18 : 36;
                            _amountController.text =
                                _topOffAmount!.toStringAsFixed(0);
                          });
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  tr.topOffDescription,
                  // Match the page's primary text color (theme onSurface =
                  // white in dark mode, near-black in light mode) so this
                  // hint reads with the same weight as the surrounding labels.
                  // Was hardcoded grey.shade700 → invisible against the dark
                  // background.
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                // Always render the amount field — disabled when the toggle
                // is off so the user can preview the configured amount but
                // not edit it. Re-enabling the toggle puts focus back on
                // editing without re-entering the amount from scratch.
                TextField(
                  controller: _amountController,
                  enabled: _topOffEnabled,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    prefixText: '\$ ',
                    filled: !_topOffEnabled,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onChanged: (value) {
                    final parsed =
                        double.tryParse(value.replaceAll(',', '.'));
                    _topOffAmount = parsed;
                  },
                ),
                const SizedBox(height: 24),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.grey.shade400),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(tr.cancelBtn),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: user == null || _saving
                          ? null
                          : () async {
                              // Hard block: enabling a non-manual schedule with no
                              // saved card creates a "configured but broken" state
                              // — the cron silently skips every cycle and the user
                              // never finds out. Surface a dialog with a CTA to
                              // /settings/saved-cards before any save attempt.
                              if (needsCardWarning) {
                                await _showAddCardRequiredDialog();
                                return;
                              }
                              if (_frequency != 'manual' &&
                                  _topOffEnabled &&
                                  (_topOffAmount == null || _topOffAmount! <= 0)) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(tr.enterValidAmount)),
                                );
                                return;
                              }
                              final messenger = ScaffoldMessenger.of(context);
                              final navigator = Navigator.of(context);
                              // Require explicit consent only when switching FROM manual
                              // (i.e., enabling auto-empty for the first time or re-enabling).
                              // No consent re-prompt when simply changing day/frequency of
                              // an already-active schedule.
                              if (_frequency != 'manual' && _savedFrequency == 'manual') {
                                final accepted = await _showConsentDialog();
                                if (!accepted || !mounted) return;
                              }
                              setState(() => _saving = true);
                              try {
                                await _saveConfig(user.uid);
                                if (!mounted) return;
                                navigator.pop();
                                messenger.showSnackBar(
                                  SnackBar(content: Text(tr.settingsSaved)),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                debugPrint('auto-empty save error: $e');
                                messenger.showSnackBar(
                                  SnackBar(content: Text(tr.saveError)),
                                );
                              } finally {
                                if (mounted) setState(() => _saving = false);
                              }
                            },
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: red, width: 2),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        tr.saveBtn,
                        style: TextStyle(
                          color: red,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardSelector(S tr) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: _cards.map((card) {
        final pmId = card['id'] as String;
        final brand = (card['brand'] as String? ?? 'card').toLowerCase();
        final last4 = card['last4'] as String? ?? '****';
        final isSelected = _selectedCardId == pmId ||
            (_selectedCardId == null && card['isDefault'] == true);
        return InkWell(
          onTap: () => setState(() => _selectedCardId = pmId),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? cs.primary : cs.outlineVariant,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: isSelected ? cs.primary : cs.outlineVariant,
                  size: 20,
                ),
                const SizedBox(width: 10),
                cardBrandBox(brand),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${cardBrandLabel(brand)}  ···· $last4',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (card['isDefault'] == true)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      tr.cardDefault,
                      style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSelectTile(String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  /// Shown when the user tries to save a non-manual schedule but has no
  /// `stripeDefaultPaymentMethodId`. The cron would silently skip every cycle
  /// — surface this hard before save, with a one-tap path to add the card.
  Future<void> _showAddCardRequiredDialog() async {
    final tr = S.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark
        ? Theme.of(context).colorScheme.primary
        : const Color(0xFFE05A4F);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.credit_card_off_rounded, color: accent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr.noCardsYet,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Text(
          tr.noSavedCards,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              tr.cancelBtn,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.add_card_rounded, size: 18),
            label: Text(
              tr.addCard,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            onPressed: () {
              // Capture both the screen-level navigator and GoRouter BEFORE
              // popping anything: after the dialog + screen pops, the original
              // BuildContext is dead and cannot be used for navigation.
              final screenNavigator = Navigator.of(context);
              final goRouter = GoRouter.of(context);
              Navigator.pop(ctx); // close dialog
              screenNavigator.pop(); // close AutoEmptyScreen (MaterialPageRoute)
              goRouter.go('/settings/saved-cards');
            },
          ),
        ],
      ),
    );
  }

  /// Returns true if the user accepted the auto-empty consent terms.
  /// Only shown when setting a non-manual frequency.
  Future<bool> _showConsentDialog() async {
    final tr = S.of(context);
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            title: Row(
              children: [
                Icon(Icons.verified_user_rounded,
                    color: Theme.of(ctx).brightness == Brightness.dark ? Theme.of(ctx).colorScheme.primary : const Color(0xFFE05A4F), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr.autoEmptyConsentTitle,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr.autoEmptyConsentBody,
                    style: const TextStyle(fontSize: 14, height: 1.55),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      // Use the theme's elevated-surface color so the bullets
                      // box reads as a subtle highlight in BOTH light and
                      // dark mode. The previous hardcoded cream background
                      // (#FFF7ED) was invisible in dark mode (light-on-light
                      // text). Bullet text inherits onSurface, matching the
                      // rest of the dialog body.
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Theme.of(ctx).colorScheme.outlineVariant,
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr.autoEmptyConsentBullet1,
                            style: TextStyle(
                              fontSize: 13, height: 1.5,
                              color: Theme.of(ctx).colorScheme.onSurface,
                            )),
                        const SizedBox(height: 6),
                        // Bullet about "balance < $5" was removed — the
                        // underlying skip-on-low-balance gate in
                        // processPushkaAutoEmpty was deleted by product
                        // decision; the user gets charged for any non-zero
                        // amount above Stripe's per-currency floor.
                        Text(tr.autoEmptyConsentBullet3,
                            style: TextStyle(
                              fontSize: 13, height: 1.5,
                              color: Theme.of(ctx).colorScheme.onSurface,
                            )),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).brightness == Brightness.dark ? Theme.of(ctx).colorScheme.primary : const Color(0xFFE05A4F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    tr.autoEmptyConsentAccept,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    tr.autoEmptyConsentCancel,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _saveConfig(String uid) async {
    final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    final repo = ref.read(userRepositoryProvider);
    final nextRunAt = _frequency == 'manual' ? null : _computeNextRunAt();
    await repo.updateTenantState(
      uid: uid,
      tenantId: tenantId,
      autoEmptyFrequency: _frequency,
      autoEmptyWeekday: _frequency == 'weekly' ? _weekday : null,
      autoEmptyDayOfMonth: _frequency == 'monthly' ? _dayOfMonth : null,
      autoEmptyTopOffEnabled: _frequency == 'manual' ? false : _topOffEnabled,
      autoEmptyTopOffAmount:
          _frequency == 'manual' ? null : (_topOffAmount ?? 0),
      autoEmptyNextRunAt: nextRunAt,
      autoEmptyClearNextRunAt: _frequency == 'manual',
      autoEmptyPaymentMethodId: _frequency != 'manual' ? _selectedCardId : null,
      autoEmptyClearPaymentMethodId: _frequency == 'manual',
    );
  }

  DateTime _computeNextRunAt() {
    final now = DateTime.now().toUtc();
    if (_frequency == 'weekly') {
      var next = DateTime.utc(now.year, now.month, now.day, 8, 0, 0);
      while (next.weekday != _weekday || !next.isAfter(now)) {
        next = next.add(const Duration(days: 1));
      }
      return next;
    }
    if (_frequency == 'monthly') {
      int clampDay(int year, int month) {
        final maxDay = DateTime.utc(year, month + 1, 0).day;
        return _dayOfMonth.clamp(1, maxDay);
      }
      var next = DateTime.utc(now.year, now.month, clampDay(now.year, now.month), 8, 0, 0);
      if (!next.isAfter(now)) {
        final nm = now.month == 12 ? 1 : now.month + 1;
        final ny = now.month == 12 ? now.year + 1 : now.year;
        next = DateTime.utc(ny, nm, clampDay(ny, nm), 8, 0, 0);
      }
      return next;
    }
    if (_frequency == 'erev_rosh_chodesh') {
      return _computeNextErevRoshChodesh(now);
    }
    return now.add(const Duration(days: 30));
  }

  DateTime _computeNextErevRoshChodesh(DateTime now) {
    // months are 0-indexed to match the Cloud Function table (JS convention)
    const table = <int, List<List<int>>>{
      2025: [[0,29],[1,27],[2,29],[3,27],[4,27],[5,25],[6,25],[7,23],[9,21],[10,20],[11,19]],
      2026: [[0,18],[1,16],[2,18],[3,16],[4,16],[5,14],[6,14],[7,12],[9,10],[10,9],[11,9]],
      2027: [[0,8],[1,6],[2,8],[3,7],[4,6],[5,5],[6,4],[7,3],[8,1],[9,30],[10,29],[11,29]],
      2028: [[0,28],[1,26],[2,27],[3,25],[4,25],[5,23],[6,23],[7,21],[9,19],[10,18],[11,17]],
      2029: [[0,16],[1,14],[2,16],[3,14],[4,14],[5,12],[6,12],[7,10],[9,8],[10,7],[11,6]],
      2030: [[0,4],[1,2],[2,4],[3,3],[4,2],[5,1],[5,30],[6,30],[7,28],[9,26],[10,25],[11,25]],
      2031: [[0,24],[1,22],[2,24],[3,22],[4,22],[5,20],[6,20],[7,18],[9,16],[10,15],[11,15]],
      2032: [[0,13],[1,12],[2,12],[3,11],[4,10],[5,9],[6,8],[7,7],[9,5],[10,3],[11,3]],
      2033: [[0,2],[1,1],[1,28],[2,30],[3,29],[4,28],[5,27],[6,26],[7,25],[9,22],[10,22],[11,21]],
      2034: [[0,21],[1,19],[2,21],[3,19],[4,19],[5,17],[6,17],[7,15],[9,13],[10,12],[11,12]],
      2035: [[0,10],[1,9],[2,11],[3,9],[4,9],[5,7],[6,7],[7,5],[9,3],[10,2],[11,1],[11,31]],
    };
    for (final year in [now.year, now.year + 1]) {
      final yearDates = table[year];
      if (yearDates == null) continue;
      for (final md in yearDates) {
        final candidate = DateTime.utc(year, md[0] + 1, md[1], 8, 0, 0);
        if (candidate.isAfter(now)) return candidate;
      }
    }
    return now.add(const Duration(days: 30));
  }

  Future<void> _showWeeklyDialog() async {
    final tr = S.of(context);
    final days = [
      {'label': tr.dayMonFull, 'value': DateTime.monday},
      {'label': tr.dayTueFull, 'value': DateTime.tuesday},
      {'label': tr.dayWedFull, 'value': DateTime.wednesday},
      {'label': tr.dayThuFull, 'value': DateTime.thursday},
      {'label': tr.dayFriFull, 'value': DateTime.friday},
      {'label': tr.daySatFull, 'value': DateTime.saturday},
      {'label': tr.daySunFull, 'value': DateTime.sunday},
    ];

    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: days.length,
            separatorBuilder: (_, _) =>
                Divider(height: 1, color: Colors.grey.shade200),
            itemBuilder: (context, index) {
              final item = days[index];
              return ListTile(
                title: Text(item['label'] as String),
                onTap: () => Navigator.pop(context, item['value'] as int),
              );
            },
          ),
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() => _weekday = result);
    }
  }

  Future<void> _showMonthlyDialog() async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            itemCount: 30,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemBuilder: (context, index) {
              final value = index + 1;
              return InkWell(
                onTap: () => Navigator.pop(context, value),
                child: Center(
                  child: Text(
                    value.toString(),
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() => _dayOfMonth = result);
    }
  }

  String _weekdayLabel(int weekday) {
    final tr = S.of(context);
    switch (weekday) {
      case DateTime.monday:
        return tr.dayMonFull;
      case DateTime.tuesday:
        return tr.dayTueFull;
      case DateTime.wednesday:
        return tr.dayWedFull;
      case DateTime.thursday:
        return tr.dayThuFull;
      case DateTime.friday:
        return tr.dayFriFull;
      case DateTime.saturday:
        return tr.daySatFull;
      case DateTime.sunday:
        return tr.daySunFull;
      default:
        return tr.selectHint;
    }
  }
}


