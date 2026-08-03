import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/format_utils.dart' show shortCurrencySymbol;
import '../../../core/hive_cache.dart';
import 'card_brand_box.dart';

import '../../../core/keyboard_safe_sheet.dart';
import '../../auth/biometric_service.dart';
import '../../../core/widgets/option_picker_sheet.dart';
import '../../payments/donation_reason_picker.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../../core/l10n/s.dart';

class AutoEmptyScreen extends ConsumerStatefulWidget {
  /// When true, the save handler pops twice — once to close this screen and
  /// once to dismiss the underlying "Vaciar Pushka" sheet that pushed it.
  /// Default false matches the Settings → Auto Vaciar entry path where the
  /// screen sits directly on the root navigator with no sheet underneath.
  const AutoEmptyScreen({super.key, this.popExtra = false});

  final bool popExtra;

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

  // Optional donation designación (per-tenant). null = "Sin designación".
  // Persisted to tenantState.autoEmptyDonationReason so the cron can stamp
  // it on PaymentIntent.metadata for each scheduled charge.
  String? _selectedDonationReason;

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
        // Sync `_selectedCardId` with the visible "selected" card. The card
        // selector UI falls back to the default-flagged card (or first in
        // list) when _selectedCardId is null — without this sync, that
        // fallback is purely visual. _saveConfig sends `_selectedCardId`
        // unchanged into updateTenantState, which only writes the field
        // when it's non-null. Result before this fix: opening the screen
        // with no pin set + tapping Guardar (or even just changing
        // frequency) stored `autoEmptyPaymentMethodId: null` instead of
        // the visible card. Now the visible card IS the saved card.
        if (_selectedCardId == null && _frequency != 'manual' && _cards.isNotEmpty) {
          final defaultCard = _cards.firstWhere(
            (c) => c['isDefault'] == true,
            orElse: () => _cards.first,
          );
          _selectedCardId = defaultCard['id'] as String?;
        }
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

    // Direct Charges: default PM lives per-tenant now.
    // BUG #12 fix: also accept ANY saved card as valid — a user can have
    // cards in the connected account but no default yet cached in
    // tenantState (setDefault CF hasn't run since the card was added).
    // Previously blocked those users from saving an auto-empty schedule
    // even though the schedule can pin any pmId (state.autoEmptyPaymentMethodId).
    // Read via HiveCache — same source the SavedCards screen uses — so
    // there's no extra CF roundtrip on this screen.
    final hasDefault = ((tenantState?['stripeConnectDefaultPaymentMethodId'] as String?) ?? '')
        .trim()
        .isNotEmpty;
    final uid = user?.uid;
    final tid = tenantState?['tenantId'] as String?;
    final cachedCards = (uid != null)
        ? HiveCache.instance.loadSavedCards(uid, tenantId: tid)
        : null;
    final hasAnyCard = (cachedCards?.cards.isNotEmpty ?? false);
    final hasSavedCard = hasDefault || hasAnyCard;
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
          // Default the designación to the tenant's first reason when no
          // saved value exists and the schedule is active. Donors prefer
          // an opinionated default over having to opt in to a destination.
          final savedReason = tenantState['autoEmptyDonationReason'] as String?;
          final defaults = tr.defaultDonationReasons;
          _selectedDonationReason = savedReason ??
              (_frequency != 'manual' ? defaults.first : null);
        });
        if (_frequency != 'manual') _loadCards();
      });
    }

    final cs = Theme.of(context).colorScheme;

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
              _buildSelectTile(
                _frequencyLabel(tr, _frequency),
                () => _showFrequencyPicker(tr),
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
              // Hint card only when the user hasn't activated auto-empty
              // yet (frequency == 'manual'). Once they pick a schedule the
              // explanation is redundant and the schedule fields take over.
              if (_frequency == 'manual') ...[
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
              ],
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
              if (_frequency != 'manual') _buildDonationReasonPicker(tr),
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
                        setState(() {
                          _topOffEnabled = value;
                          // Re-arming the toggle: seed amount with the
                          // user's pushka goal if no prior value exists
                          // (matches the "first-time activation" behavior
                          // of switching from manual to a schedule).
                          if (value && _topOffAmount == null) {
                            final goal = (ref.read(tenantStateProvider).valueOrNull
                                ?['pushkaGoal'] as num?)?.toDouble();
                            _topOffAmount = goal ??
                                (_frequency == 'weekly' ? 18 : 36);
                            _amountController.text =
                                _topOffAmount!.toStringAsFixed(0);
                          }
                        });
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
                // Amount field is shown only while top-off is enabled;
                // hiding it removes visual noise and matches the user's
                // mental model of "off = not in play."
                if (_topOffEnabled) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      // Show the user's currency symbol, not a hardcoded '$'.
                      // Reads currencyCode from the user profile and maps to a
                      // short glyph via _shortCurrencySymbol.
                      prefixText: '${shortCurrencySymbol((profile?['currencyCode'] as String?) ?? 'USD')} ',
                      prefixStyle: TextStyle(
                        fontSize: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surface,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: cs.outline),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppTokens.primaryBlue, width: 2),
                      ),
                    ),
                    onChanged: (value) {
                      final parsed =
                          double.tryParse(value.replaceAll(',', '.'));
                      _topOffAmount = parsed;
                    },
                  ),
                ],
                const SizedBox(height: 24),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
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
                              if (_biometricEnabled()) {
                                final authenticated = await BiometricService.instance.authenticate(
                                  reason: tr.biometricReasonEmpty,
                                );
                                if (!authenticated) {
                                  if (!mounted) return;
                                  messenger.showSnackBar(
                                    SnackBar(content: Text(tr.authRequired)),
                                  );
                                  return;
                                }
                                if (!mounted) return;
                              }
                              setState(() => _saving = true);
                              try {
                                await _saveConfig(user.uid);
                                if (!mounted) return;
                                navigator.pop();
                                // When this screen was pushed on top of the
                                // Vaciar Pushka sheet, also dismiss the sheet
                                // so the user lands back on Mi Pushka home
                                // instead of the half-filled sheet.
                                if (widget.popExtra && navigator.canPop()) {
                                  navigator.pop();
                                }
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
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTokens.primaryBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        tr.saveBtn,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Designación picker for the auto-empty schedule. Tap-to-open row that
  /// pops the shared bottom sheet with the tenant's reasons (or locale
  /// defaults when the tenant hasn't configured custom ones).
  Widget _buildDonationReasonPicker(S tr) {
    // Same tenant-first fallback used across the donation flow so admin-web
    // designation edits propagate to every picker instance.
    final tenantReasons = ref.read(tenantConfigProvider).valueOrNull?.donationReasons ?? const <String>[];
    final reasons = tenantReasons.isNotEmpty ? tenantReasons : tr.defaultDonationReasons;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr.donationReasonTitle,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              final picked = await showDonationReasonPicker(
                context: context,
                reasons: reasons,
                currentSelection: _selectedDonationReason,
              );
              if (picked is DonationReasonSelected && mounted) {
                setState(() => _selectedDonationReason = picked.reason);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border.all(color: cs.outline),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(
                    _selectedDonationReason ?? tr.donationReasonNone,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: _selectedDonationReason == null
                          ? cs.onSurfaceVariant
                          : cs.onSurface,
                    ),
                  ),
                ),
                Icon(Icons.keyboard_arrow_down, color: cs.onSurfaceVariant),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact one-row card selector — shows the currently configured card
  /// + chevron. Tap opens a bottom sheet with the rest of the saved cards
  /// (same UX pattern as the donation reason picker).
  Widget _buildCardSelector(S tr) {
    final cs = Theme.of(context).colorScheme;
    if (_cards.isEmpty) return const SizedBox.shrink();

    Map<String, dynamic> resolveSelected() {
      if (_selectedCardId != null) {
        final hit = _cards.where((c) => c['id'] == _selectedCardId).toList();
        if (hit.isNotEmpty) return hit.first;
      }
      // Fall back to default-flagged card, or first in the list.
      final defaults = _cards.where((c) => c['isDefault'] == true).toList();
      return defaults.isNotEmpty ? defaults.first : _cards.first;
    }

    final selected = resolveSelected();
    final brand = (selected['brand'] as String? ?? 'card').toLowerCase();
    final last4 = selected['last4'] as String? ?? '••••';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _cards.length > 1 ? () => _showCardPickerSheet(tr) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outline),
        ),
        child: Row(
          children: [
            cardBrandBox(brand),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${cardBrandLabel(brand)}  •••• $last4',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            // Predeterminada indicator removed by request — within
            // Auto Vaciar the row is already showing the chosen card,
            // so the "default" state is implicit and the extra tick
            // adds visual noise. Saved Cards keeps it (that's where the
            // user actually chooses which card is default).
            if (_cards.length > 1)
              Icon(Icons.keyboard_arrow_down, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// Bottom sheet that lists ALL saved cards as outlined tiles, same
  /// History-filter style used by the donation reason picker. Tapping a
  /// row updates `_selectedCardId` and closes the sheet.
  Future<void> _showCardPickerSheet(S tr) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      barrierColor: const Color(0xDD000000),
      builder: (sheetCtx) {
        final cs = Theme.of(sheetCtx).colorScheme;
        final selectedId = _selectedCardId ??
            (_cards.firstWhere(
              (c) => c['isDefault'] == true,
              orElse: () => _cards.first,
            )['id'] as String);
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36, height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                for (var i = 0; i < _cards.length; i++) ...[
                  _buildCardTile(sheetCtx, _cards[i], selectedId, tr),
                  if (i < _cards.length - 1) const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _selectedCardId = picked);
    }
  }

  Widget _buildCardTile(BuildContext ctx, Map<String, dynamic> card, String selectedId, S tr) {
    final cs = Theme.of(ctx).colorScheme;
    final pmId = card['id'] as String;
    final brand = (card['brand'] as String? ?? 'card').toLowerCase();
    final last4 = card['last4'] as String? ?? '••••';
    final isSelected = pmId == selectedId;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.pop(ctx, pmId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? AppTokens.primaryBlue.withValues(alpha: 0.12) : cs.surface,
          border: Border.all(color: isSelected ? AppTokens.primaryBlue : cs.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            cardBrandBox(brand),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${cardBrandLabel(brand)}  •••• $last4',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (card['isDefault'] == true && !isSelected)
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
            if (isSelected)
              Icon(Icons.check, color: AppTokens.primaryBlue, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectTile(String value, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outline),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
              ),
            ),
            Icon(Icons.keyboard_arrow_down, color: cs.onSurfaceVariant),
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
    const accent = AppTokens.primaryBlue;

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
              style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
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
    return await showKeyboardSafeSheet<bool>(
          context: context,
          builder: (ctx, _) {
            final cs = Theme.of(ctx).colorScheme;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/secure_shield.png',
                        width: 26,
                        height: 26,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        tr.autoEmptyConsentTitle,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  tr.autoEmptyConsentBody,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.55, color: cs.onSurface),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTokens.primaryBlue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(
                      tr.autoEmptyConsentAccept,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  bool _biometricEnabled() {
    final profile = ref.read(userProfileProvider).valueOrNull;
    return (profile?['biometricAuthenticationEnabled'] as bool?) ?? false;
  }

  Future<void> _saveConfig(String uid) async {
    final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    if (tenantId == null || tenantId.isEmpty) return;
    final repo = ref.read(userRepositoryProvider);
    final nextRunAt = _frequency == 'manual' ? null : _computeNextRunAt();

    // Defensive sanity check: nextRunAt is computed using the device clock.
    // A user with a badly-skewed clock (set to year 2099, or stuck in 1980)
    // would otherwise write a `nextRunAt` that the cron either fires
    // immediately on or never fires on. Bound to "within the next 18 months"
    // (covers monthly/erev-rosh-chodesh max gap of ~30-60 days with margin)
    // and refuse to save otherwise — better to surface a clock issue early
    // than silently break their auto-empty schedule for years.
    if (nextRunAt != null) {
      final now = DateTime.now().toUtc();
      final maxFuture = now.add(const Duration(days: 540));
      if (nextRunAt.isBefore(now) || nextRunAt.isAfter(maxFuture)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(S.of(context).deviceClockSkewError),
            ),
          );
        }
        return;
      }
    }

    // Round-4 audit CRITICAL fix: stamp the currency the top-off was
    // configured in so the server cron can detect drift after a currency
    // change and refuse to charge in the wrong currency.
    final activeCurrency =
        (ref.read(userProfileProvider).valueOrNull?['currencyCode'] as String?) ??
            'USD';
    await repo.updateTenantState(
      uid: uid,
      tenantId: tenantId,
      autoEmptyFrequency: _frequency,
      autoEmptyWeekday: _frequency == 'weekly' ? _weekday : null,
      autoEmptyDayOfMonth: _frequency == 'monthly' ? _dayOfMonth : null,
      autoEmptyTopOffEnabled: _frequency == 'manual' ? false : _topOffEnabled,
      autoEmptyTopOffAmount:
          _frequency == 'manual' ? null : (_topOffAmount ?? 0),
      autoEmptyTopOffCurrency:
          _frequency == 'manual' ? null : activeCurrency,
      autoEmptyNextRunAt: nextRunAt,
      autoEmptyClearNextRunAt: _frequency == 'manual',
      autoEmptyPaymentMethodId: _frequency != 'manual' ? _selectedCardId : null,
      autoEmptyClearPaymentMethodId: _frequency == 'manual',
      autoEmptyDonationReason: _frequency != 'manual' ? _selectedDonationReason : null,
      autoEmptyClearDonationReason: _frequency == 'manual' || _selectedDonationReason == null,
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

  String _frequencyLabel(S tr, String value) {
    switch (value) {
      case 'weekly':
        return tr.freqWeekly;
      case 'monthly':
        return tr.freqMonthly;
      case 'erev_rosh_chodesh':
        return tr.freqErevRosh;
      default:
        return tr.manualEmpty;
    }
  }

  Future<void> _showFrequencyPicker(S tr) async {
    final picked = await showOptionPickerSheet<String>(
      context: context,
      currentValue: _frequency,
      options: [
        (value: 'manual', label: tr.manualEmpty),
        (value: 'weekly', label: tr.freqWeekly),
        (value: 'monthly', label: tr.freqMonthly),
        (value: 'erev_rosh_chodesh', label: tr.freqErevRosh),
      ],
    );
    if (picked == null || !mounted || picked == _frequency) return;
    final wasManual = _frequency == 'manual';
    setState(() {
      _frequency = picked;
      // First-time activation (manual → any schedule): turn on top-off
      // and seed the amount with the user's pushka goal so the schedule
      // is "complete" out of the box. The user can flip the toggle off
      // if they don't want top-off.
      if (wasManual && picked != 'manual') {
        _topOffEnabled = true;
        final goal = (ref.read(tenantStateProvider).valueOrNull
            ?['pushkaGoal'] as num?)?.toDouble();
        _topOffAmount = goal ?? _topOffAmount ?? 18;
        // Seed the designación to the tenant's first reason so the
        // schedule starts with a concrete destination instead of the
        // empty/Sin designación state.
        if (_selectedDonationReason == null) {
          final cfgReasons = ref.read(tenantConfigProvider).valueOrNull
                  ?.donationReasons ?? const <String>[];
          if (cfgReasons.isNotEmpty) {
            _selectedDonationReason = cfgReasons.first;
          }
        }
      }
      _amountController.text = _topOffAmount?.toStringAsFixed(0) ?? '';
    });
    if (wasManual && picked != 'manual' && _cards.isEmpty) {
      _loadCards();
    }
  }

  Future<void> _showWeeklyDialog() async {
    final tr = S.of(context);
    final picked = await showOptionPickerSheet<int>(
      context: context,
      currentValue: _weekday,
      options: [
        (value: DateTime.monday, label: tr.dayMonFull),
        (value: DateTime.tuesday, label: tr.dayTueFull),
        (value: DateTime.wednesday, label: tr.dayWedFull),
        (value: DateTime.thursday, label: tr.dayThuFull),
        (value: DateTime.friday, label: tr.dayFriFull),
        (value: DateTime.saturday, label: tr.daySatFull),
        (value: DateTime.sunday, label: tr.daySunFull),
      ],
    );
    if (picked != null && mounted) {
      setState(() => _weekday = picked);
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
            // Allow day 1-31. Months without day 31 (or 30, or 29 in Feb) are
            // handled server-side by processPushkaAutoEmpty in
            // functions/index.js: it clamps the configured day to the actual
            // month length, so picking 31 fires on the 30th in April / 28th in
            // February. The picker should not silently forbid the user's
            // legitimate choice.
            itemCount: 31,
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

  // Removed — using `shortCurrencySymbol()` from format_utils.dart directly.

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



