import 'dart:typed_data';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:country_picker/country_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../auth/providers/auth_controller.dart';
import '../../notifications/notification_service.dart';
import '../../notifications/web_platform_stub.dart'
    if (dart.library.html) '../../notifications/web_platform_web.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../tenant/data/tenant_repository.dart';
import '../../../core/format_utils.dart' show shortCurrencySymbol;
import '../../../core/l10n/locale_provider.dart';
import '../../../core/widgets/option_picker_sheet.dart';
import 'package:go_router/go_router.dart';

import 'auto_empty_action_row.dart';
import 'auto_empty_screen.dart';
import 'card_brand_box.dart';
import '../../../core/l10n/s.dart';
import '../../feedback/feedback_service.dart';
import '../../../core/pushka_style_provider.dart';
import '../../../core/theme_provider.dart';
import '../../../app/theme/app_tokens.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Valores de configuración
  double pushkaGoal = 3600.00;
  String selectedPreset = '1.00';
  bool soundEnabled = true;
  bool vibrationEnabled = true;
  bool ambientEnabled = false;
  bool partialPaymentsEnabled = false;
  bool biometricAuthenticationEnabled = false;
  String selectedCurrency = 'USD';
  String selectedCountry = 'Estados Unidos';
  String selectedFlag = '🇺🇸';
  bool _loadedProfile = false;
  bool _uploadingPhoto = false;
  bool _avatarLoadFailed = false;
  // Bump on every successful photo upload — appended as ?v=N query param
  // to the NetworkImage URL. Firebase Storage returns the same download URL
  // for the same path across uploads (the token is derived from the path),
  // so without this cache-bust Flutter serves the OLD bytes and the user
  // sees "photo updated!" toast + the old avatar still on screen.
  int _photoBustKey = 0;
  List<double>? _localPresets;
  // Tracks the tenant whose state seeded our local mirrors. When the user
  // switches tenants (AccountSwitcherSheet, invite link, etc.) the
  // userProfile emits with a different tenantId and we must re-sync the
  // pushka goal / currency / presets from the new tenant's state instead
  // of showing the old tenant's values until the screen remounts.
  String? _loadedForTenantId;

  // One persistent controller per preset slot — same pattern as the
  // Tzedaká config (Mi Pushka), so the field is ALWAYS a TextField (no
  // tap-to-toggle between display/edit container). Synced from the remote
  // value only when the field is NOT focused, then committed on blur or
  // submit so the user's typing is never stomped mid-edit.
  final List<TextEditingController> _presetCtrls = [
    TextEditingController(),
    TextEditingController(),
    TextEditingController(),
  ];
  final List<FocusNode> _presetFocusNodes = [FocusNode(), FocusNode(), FocusNode()];
  bool _presetCtrlsInited = false;

  // Inline editor for the pushka goal — replaces the prior tap-to-open
  // dialog. Synced with [pushkaGoal] when remote state arrives, but only
  // when the field is NOT focused so we don't stomp the user mid-type.
  // Saved on submit (Done on keyboard) or on blur.
  final TextEditingController _pushkaGoalCtrl = TextEditingController();
  final FocusNode _pushkaGoalFocus = FocusNode();
  bool _pushkaGoalCtrlInited = false;

  // Removed local map: use `shortCurrencySymbol()` from format_utils.
  // Old map ambiguously rendered MXN/ARS/CLP/COP as `$` (indistinguishable
  // from USD in a user's currency picker); the central one uses MX$/AR$/
  // CL$/CO$ so no user confuses their local currency with dollars.

  @override
  void initState() {
    super.initState();
    _pushkaGoalFocus.addListener(_onPushkaGoalFocusChange);
    for (var i = 0; i < _presetFocusNodes.length; i++) {
      final idx = i;
      _presetFocusNodes[i].addListener(() {
        if (!_presetFocusNodes[idx].hasFocus) _commitPreset(idx);
      });
    }
  }

  @override
  void dispose() {
    _pushkaGoalFocus.removeListener(_onPushkaGoalFocusChange);
    _pushkaGoalCtrl.dispose();
    _pushkaGoalFocus.dispose();
    for (final c in _presetCtrls) {
      c.dispose();
    }
    for (final f in _presetFocusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  /// Save-on-blur for the pushka goal field. Without this the user could
  /// type a new value, tap somewhere else, and the change would be lost
  /// (no Done press). Also re-syncs the controller text on blur in case
  /// the value couldn't parse → field re-shows the last valid amount.
  void _onPushkaGoalFocusChange() {
    if (_pushkaGoalFocus.hasFocus) return;
    _commitPushkaGoal();
  }

  void _commitPushkaGoal() {
    final raw = _pushkaGoalCtrl.text.trim().replaceAll(',', '.');
    final parsed = double.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      // Invalid → restore last valid value in the field, no save.
      _pushkaGoalCtrl.text = pushkaGoal % 1 == 0
          ? pushkaGoal.toInt().toString()
          : pushkaGoal.toStringAsFixed(2);
      return;
    }
    if (parsed == pushkaGoal) return;
    setState(() => pushkaGoal = parsed);
    _updateSettings(ref.read(currentUserProvider), pushkaGoal: parsed)
        .catchError((Object e) => debugPrint('pushkaGoal updateSettings error: $e'));
  }


  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    const red = Color(0xFFE05A4F);
    final blue = Theme.of(context).colorScheme.primary;

    final user = ref.watch(currentUserProvider);
    final userProfile = ref.watch(userProfileProvider).valueOrNull;
    final tenantState = ref.watch(tenantStateProvider).valueOrNull;

    String? getProfileString(String key) {
      if (userProfile == null) return null;
      final value = userProfile[key] as String?;
      if (value == null || value.trim().isEmpty) return null;
      return value;
    }

    double? getTenantDouble(String key) {
      final value = tenantState?[key];
      if (value is num) return value.toDouble();
      return null;
    }

    bool? getProfileBool(String key) {
      if (userProfile == null) return null;
      final value = userProfile[key];
      if (value is bool) return value;
      return null;
    }

    // Re-sync from remote when the active tenant changes (e.g. user
    // switched via AccountSwitcherSheet). Without this the local mirrors
    // (pushkaGoal, presets, currency) stay pinned to the previous tenant
    // until the settings screen is remounted.
    final activeTenantId = userProfile?['tenantId'] as String?;
    if (_loadedProfile &&
        activeTenantId != null &&
        activeTenantId.isNotEmpty &&
        activeTenantId != _loadedForTenantId) {
      _loadedProfile = false;
      _presetCtrlsInited = false;
      _pushkaGoalCtrlInited = false;
      _localPresets = null;
    }

    if (!_loadedProfile && userProfile != null && tenantState != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          pushkaGoal = getTenantDouble('pushkaGoal') ?? pushkaGoal;
          final preset = getTenantDouble('presetAmount');
          if (preset != null) {
            selectedPreset = preset.toStringAsFixed(2);
          }
          soundEnabled = getProfileBool('soundEnabled') ?? soundEnabled;
          vibrationEnabled =
              getProfileBool('vibrationEnabled') ?? vibrationEnabled;
          ambientEnabled =
              getProfileBool('ambientEnabled') ?? ambientEnabled;
          partialPaymentsEnabled =
              getProfileBool('partialPaymentsEnabled') ??
                  partialPaymentsEnabled;
          biometricAuthenticationEnabled =
              getProfileBool('biometricAuthenticationEnabled') ??
                  biometricAuthenticationEnabled;
          selectedCountry =
              getProfileString('currencyCountry') ?? selectedCountry;
          selectedCurrency =
              getProfileString('currencyCode') ?? selectedCurrency;
          // Flag must key off the currency code (source of truth): tenants
          // can persist arbitrary country strings like "CDMX" via
          // defaultCountry, which would fall through _flagForCurrency's
          // default. The currency code is always canonical (MXN/USD/...).
          selectedFlag = _flagForCurrency(selectedCurrency);
          _loadedProfile = true;
          _loadedForTenantId = activeTenantId;
        });
      });
    }

    final authDisplayName = user?.displayName?.trim();
    final userName = getProfileString('displayName') ??
        (authDisplayName != null && authDisplayName.isNotEmpty
            ? authDisplayName
            : tr.defaultUser);
    final userEmail = user?.email ?? tr.noEmail;
    final billingEmail = getProfileString('billingEmail') ?? '-';
    final phoneNumber = getProfileString('phoneNumber') ?? '-';
    final mailingAddress = getProfileString('mailingAddress') ?? '-';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // PROFILE NAME
          _buildProfileNameRow(userName, user?.uid, tr, getProfileString('photoURL')),
          const SizedBox(height: 24),

          // GENERAL Section
          _buildSectionTitle(tr.general),
          const SizedBox(height: 12),

          // PUSHKA GOAL — inline TextField. Sync the controller on every
          // build EXCEPT while the user is editing (focused), so external
          // tenant-state pushes don't stomp mid-type. Persist on blur or
          // submit via _commitPushkaGoal.
          _buildLabel(tr.pushkaGoalSetting),
          const SizedBox(height: 6),
          Builder(builder: (_) {
            if (!_pushkaGoalCtrlInited || (!_pushkaGoalFocus.hasFocus)) {
              final formatted = pushkaGoal % 1 == 0
                  ? pushkaGoal.toInt().toString()
                  : pushkaGoal.toStringAsFixed(2);
              if (_pushkaGoalCtrl.text != formatted) {
                _pushkaGoalCtrl.text = formatted;
              }
              _pushkaGoalCtrlInited = true;
            }
            final cs = Theme.of(context).colorScheme;
            return TextField(
              controller: _pushkaGoalCtrl,
              focusNode: _pushkaGoalFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _commitPushkaGoal(),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
              decoration: InputDecoration(
                prefixText: '${shortCurrencySymbol(selectedCurrency)} ',
                prefixStyle: TextStyle(
                  fontSize: 16,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                filled: true,
                fillColor: cs.surface,
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
            );
          }),
          const SizedBox(height: 18),

          // PRESET AMOUNTS
          _buildLabel(tr.presetAmount),
          const SizedBox(height: 8),
          _buildCurrentPresets(tenantState, blue, user),
          const SizedBox(height: 18),

          // SAVED CARD
          _buildLabel(tr.savedCards),
          const SizedBox(height: 6),
          _buildSavedCardPreview(userProfile, tr),
          const SizedBox(height: 18),

          // EMPTY PUSHKA
          _buildLabel(tr.emptyPushkaSetting),
          const SizedBox(height: 6),
          AutoEmptyActionRow(
            onTap: () {
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => const AutoEmptyScreen()),
              );
            },
          ),
          const SizedBox(height: 18),

          // RECURRING DONATIONS
          _buildLabel(tr.mySubscriptions),
          const SizedBox(height: 6),
          _buildActionButton(
            tr.mySubscriptions,
            onTap: () => context.go('/settings/donation-subs'),
          ),
          const SizedBox(height: 18),

          // CURRENCY
          _buildLabel(tr.currency),
          const SizedBox(height: 6),
          _buildCurrencySelector(
            currency: selectedCurrency,
            onTap: () => _showCurrencyDialog(),
          ),
          const SizedBox(height: 18),

          // LANGUAGE
          _buildLabel(tr.language),
          const SizedBox(height: 6),
          _buildLanguageSelector(),
          const SizedBox(height: 18),

          // PUSHKA STYLE
          _buildLabel(tr.pushkaStyleLabel),
          const SizedBox(height: 8),
          _buildPushkaStyleSelector(ref),
          const SizedBox(height: 18),

          // APPEARANCE
          Row(
            children: [
              Expanded(
                child: Text(
                  tr.appearance,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 8),
              _ThemeToggle(
                isDark: ref.watch(themeModeProvider) == ThemeMode.dark,
                onChanged: (dark) => ref.read(themeModeProvider.notifier).setMode(
                  dark ? ThemeMode.dark : ThemeMode.light,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // SOUND: gates audio + haptic. FeedbackService.init() now works
          // on web too (audioplayers_web); the first play() after cold-start
          // fails silently by browser autoplay policy, but any user-gesture-
          // triggered play (donate, coin drop) succeeds. Haptic APIs are
          // native-only — noop on web (transparent to the user).
          _buildToggleRow(
            tr.sound,
            soundEnabled,
            onChanged: (value) {
              setState(() {
                soundEnabled = value;
                vibrationEnabled = value;
              });
              _updateSettingsSilent(
                user,
                soundEnabled: value,
                vibrationEnabled: value,
              );
            },
          ),
          const SizedBox(height: 18),

          // AMBIENT MUSIC: still hidden on web — the loop pulls from
          // Firebase Storage via URL and needs CORS + HTMLAudioElement
          // playback that's unreliable without a persistent user gesture.
          // Native-only for now.
          if (!kIsWeb) ...[
            _buildToggleRow(
              tr.ambientMusic,
              ambientEnabled,
              onChanged: (value) {
                setState(() => ambientEnabled = value);
                FeedbackService.instance.updatePreferences(ambient: value);
                _updateSettingsSilent(user, ambientEnabled: value);
              },
            ),
            const SizedBox(height: 18),
          ],

          // PARTIAL PAYMENTS
          _buildToggleRow(
            tr.partialPayments,
            partialPaymentsEnabled,
            onChanged: (value) {
              setState(() => partialPaymentsEnabled = value);
              _updateSettingsSilent(user, partialPaymentsEnabled: value);
            },
          ),
          const SizedBox(height: 18),

          // Biometric: hidden entirely in PWA. local_auth has no web
          // implementation (WebAuthn/Passkey would be the equivalent — big
          // Stage TODO). Prevents the "your device does not support biometrics"
          // dialog from misleading users about their hardware.
          if (!kIsWeb) ...[
            _buildToggleRow(
              tr.biometricAuth,
              biometricAuthenticationEnabled,
              onChanged: (value) async {
                final messenger = ScaffoldMessenger.of(context);
                if (value) {
                  final success = await _authenticateWithBiometrics();
                  if (!success || !mounted) return;
                }
                setState(() => biometricAuthenticationEnabled = value);
                _updateSettingsSilent(user, biometricAuthenticationEnabled: value);
                if (value) {
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(content: Text(tr.biometricActivated)),
                  );
                }
              },
            ),
            if (biometricAuthenticationEnabled)
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 8, start: 4),
                child: FutureBuilder<List<BiometricType>>(
                  future: LocalAuthentication().getAvailableBiometrics(),
                  builder: (context, snapshot) {
                    final biometrics = snapshot.data ?? [];
                    if (biometrics.isEmpty) return const SizedBox.shrink();
                    return Wrap(spacing: 8, runSpacing: 6, children: [
                      if (biometrics.contains(BiometricType.fingerprint))
                        _biometricChip(Icons.fingerprint, tr.fingerprint),
                      if (biometrics.contains(BiometricType.face))
                        _biometricChip(Icons.face, tr.faceRecognition),
                      if (biometrics.contains(BiometricType.strong) || biometrics.contains(BiometricType.weak))
                        _biometricChip(Icons.lock_outline, tr.pinPattern),
                    ]);
                  },
                ),
              ),
            const SizedBox(height: 18),
          ],

          // Web push notifications — only shown in PWA. Native builds route
          // through the flutter_local_notifications channels above. The
          // toggle triggers a user-gesture-scoped permission prompt (browsers
          // reject requestPermission() without one).
          if (kIsWeb) ...[
            _buildWebPushToggle(user, tr),
            const SizedBox(height: 18),
          ],
          Container(
            height: 5,
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 22),

          // PROFILE Section
          _buildSectionTitle(tr.profileSection),
          const SizedBox(height: 12),
          _buildProfileField(tr.nameLabel, userName),
          const SizedBox(height: 16),
          _buildProfileField(tr.emailLabel, userEmail),
          const SizedBox(height: 16),
          _buildEditableField(
            tr.billingEmail,
            billingEmail,
            onEdit: () => _showEditDialog(
              tr.billingEmail,
              billingEmail == '-' ? '' : billingEmail,
              (value) => _updateProfileField(
                user,
                billingEmail: value,
              ), fieldKey: 'billingEmail',
            ),
          ),
          const SizedBox(height: 16),
          _buildEditableField(
            tr.phoneLabel,
            phoneNumber,
            onEdit: () => _showEditDialog(
              tr.phoneLabel,
              phoneNumber == '-' ? '' : phoneNumber,
              (value) => _updateProfileField(
                user,
                phoneNumber: value,
              ), fieldKey: 'phone',
            ),
          ),
          const SizedBox(height: 16),
          _buildEditableField(
            tr.mailingAddress,
            mailingAddress,
            onEdit: () => _showEditDialog(
              tr.mailingAddress,
              mailingAddress == '-' ? '' : mailingAddress,
              (value) => _updateProfileField(
                user,
                mailingAddress: value,
              ), fieldKey: 'mailingAddress',
            ),
          ),
          const SizedBox(height: 16),
          Container(
            height: 5,
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 22),

          // MANAGE ACCOUNT Section
          _buildSectionTitle(tr.manageAccount),
          const SizedBox(height: 12),
          InkWell(
            onTap: () => _showDeleteAccountDialog(),
            child: Row(
              children: [
                Icon(Icons.delete_outline, color: const Color(0xFF8B1A1A), size: 20),
                const SizedBox(width: 8),
                Text(
                  tr.deleteAccountQuestion,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xFF8B1A1A),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // LOGOUT Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _showLogoutDialog(),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: red, width: 2),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                tr.logout,
                style: TextStyle(
                  color: red,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Footer brand: just the tenant's appName / name. "Powered by Pushka"
          // was removed at Ioel's request.
          Center(
            child: Builder(builder: (_) {
              final cfg = ref.watch(tenantConfigProvider).valueOrNull;
              final footerBrand = cfg?.appName.isNotEmpty == true
                  ? cfg!.appName
                  : (cfg?.name.isNotEmpty == true ? cfg!.name : 'Pushka');
              return Text(
                footerBrand,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9E9E9E),
                  fontWeight: FontWeight.w400,
                ),
              );
            }),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Appends ?v={_photoBustKey} (or &v={_photoBustKey}) to the photo URL so
  /// Flutter's NetworkImage cache treats it as a distinct URL after each
  /// successful upload. When _photoBustKey == 0 (first render, never uploaded
  /// in this session) we return the raw URL to preserve CDN caching benefit.
  String _bustedPhotoUrl(String url) {
    if (_photoBustKey == 0) return url;
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}v=$_photoBustKey';
  }

  Widget _buildProfileNameRow(String name, String? uid, S tr, String? photoURL) {
    final blue = Theme.of(context).colorScheme.primary;
    final avatar = GestureDetector(
      onTap: uid == null ? null : () => _pickAndUploadPhoto(uid, tr),
      child: Stack(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: blue.withValues(alpha: 0.12),
            // Use foregroundImage so errorListener actually fires; backgroundImage
            // silently swallows network errors and leaves an empty avatar with no
            // letter fallback. Combine with onForegroundImageError to swap to
            // initial-letter mode if the URL 404s or the network fails.
            foregroundImage: (photoURL != null && photoURL.isNotEmpty && !_avatarLoadFailed)
                ? NetworkImage(_bustedPhotoUrl(photoURL))
                : null,
            onForegroundImageError: (photoURL != null && photoURL.isNotEmpty)
                ? (_, _) {
                    if (mounted && !_avatarLoadFailed) {
                      setState(() => _avatarLoadFailed = true);
                    }
                  }
                : null,
            child: (photoURL == null || photoURL.isEmpty || _avatarLoadFailed)
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: blue,
                    ),
                  )
                : null,
          ),
          if (_uploadingPhoto)
            const Positioned.fill(
              child: CircleAvatar(
                backgroundColor: Colors.black45,
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            )
          else
            PositionedDirectional(
              end: 0,
              bottom: 0,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: blue,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: const Icon(Icons.camera_alt, size: 10, color: Colors.white),
              ),
            ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Text(
                  tr.displayNameLabel,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            color: blue,
            tooltip: tr.editNameTooltip,
            onPressed: uid == null ? null : () => _showEditNameSheet(name, uid, tr),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndUploadPhoto(String uid, S tr) async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
    } catch (e) {
      debugPrint('pickImage error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr.couldNotUploadPhoto)),
        );
      }
      return;
    }
    if (picked == null || !mounted) return;
    Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (e) {
      debugPrint('readAsBytes error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr.couldNotUploadPhoto)),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _uploadingPhoto = true);
    try {
      final newUrl = await ref.read(userRepositoryProvider).uploadProfilePhoto(
        uid: uid,
        bytes: bytes,
      );
      // Evict the cached bytes for the old URL so subsequent renders that
      // read the same URL (before the Firestore snapshot propagates) still
      // fetch fresh. Also bump _photoBustKey so this render + all future
      // ones append ?v=N to the URL — bypasses Flutter's NetworkImage cache
      // because Firebase Storage returns the SAME download URL for the same
      // path across uploads. And reset _avatarLoadFailed in case a previous
      // upload had 404'd (would otherwise persist as the letter fallback).
      try { await NetworkImage(newUrl).evict(); } catch (_) {}
      if (!mounted) return;
      setState(() {
        _photoBustKey++;
        _avatarLoadFailed = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.photoUpdated)),
      );
    } on ProfilePhotoTooLargeException catch (e) {
      // BUG-046 fix: tell the user exactly WHY the upload failed instead of
      // the generic "no se pudo subir la foto" we used to show for every
      // error. 5MB ceiling is enforced both client-side (here) and
      // server-side (Storage rules).
      debugPrint('uploadProfilePhoto too large: $e');
      if (!mounted) return;
      final mb = (e.actualBytes / (1024 * 1024)).toStringAsFixed(1);
      final maxMb = (e.maxBytes / (1024 * 1024)).toStringAsFixed(0);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.imageTooLarge(mb, maxMb))),
      );
    } on ProfilePhotoEmptyException {
      debugPrint('uploadProfilePhoto empty bytes');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.couldNotUploadPhoto)),
      );
    } catch (e) {
      debugPrint('uploadProfilePhoto error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.couldNotUploadPhoto)),
      );
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _showEditNameSheet(String current, String uid, S tr) async {
    final ctrl = TextEditingController(text: current);
    String? error;
    try {
      await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSS) {
            final cs = Theme.of(ctx).colorScheme;
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: cs.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      tr.editProfileTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: tr.displayNameLabel,
                        labelStyle: const TextStyle(color: AppTokens.primaryBlue),
                        floatingLabelStyle: const TextStyle(color: AppTokens.primaryBlue),
                        hintText: tr.displayNameHint,
                        errorText: error,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: AppTokens.primaryBlue, width: 1.6),
                        ),
                      ),
                      onChanged: (_) {
                        if (error != null) setSS(() => error = null);
                      },
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTokens.primaryBlue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () async {
                          final name = ctrl.text.trim();
                          if (name.length < 2) {
                            setSS(() => error = tr.nameTooShort);
                            return;
                          }
                          try {
                            await ref.read(userRepositoryProvider).updateProfile(
                              uid: uid,
                              displayName: name,
                            );
                            if (!mounted || !ctx.mounted) return;
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr.profileUpdated)),
                            );
                          } catch (e) {
                            debugPrint('updateProfile displayName error: $e');
                            if (!mounted || !ctx.mounted) return;
                            setSS(() => error = tr.saveError);
                          }
                        },
                        child: Text(
                          tr.save,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    } finally {
      // Delay disposal so the sheet's close animation can finish referencing
      // the controller. Disposing immediately throws "controller used after
      // dispose" assertions in debug when the TextField is still in the
      // dismissal transition.
      Future.delayed(const Duration(milliseconds: 400), ctrl.dispose);
    }
  }

  /// Preview row for the user's default saved card. Renders the same
  /// brand-box (Visa navy with logo, Mastercard interlocking circles, etc.)
  /// as the dedicated saved-cards screen, so the settings glance matches
  /// what the user sees inside. Falls back to a generic credit-card icon
  /// + tr.noSavedCards label when the user has no default PaymentMethod.
  Widget _buildSavedCardPreview(Map<String, dynamic>? profile, S tr) {
    final cs = Theme.of(context).colorScheme;
    // Direct Charges: read default PM from tenantState (per-tenant scope),
    // NOT the deprecated user-doc fields. The user-doc profile is passed
    // in for backwards signature compat but ignored — the new schema is
    // `stripeConnectDefault*` on `users/{uid}/tenantState/{tid}`.
    final tenantState = ref.watch(tenantStateProvider).valueOrNull;
    final brand = tenantState?['stripeConnectDefaultPaymentMethodBrand'] as String?;
    final last4 = tenantState?['stripeConnectDefaultPaymentMethodLast4'] as String?;
    final hasCard = brand != null && brand.isNotEmpty && last4 != null && last4.isNotEmpty;

    return InkWell(
      onTap: () => context.go('/settings/saved-cards'),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (hasCard)
              cardBrandBox(brand)
            else
              Container(
                width: 40,
                height: 28,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.credit_card, size: 18, color: cs.onSurfaceVariant),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: hasCard
                  ? Text.rich(
                      TextSpan(
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurface,
                        ),
                        children: [
                          TextSpan(text: '${cardBrandLabel(brand)} '),
                          // 4 bullets (U+2022) for the card mask — already
                          // vertically centered in the system font, so we
                          // skip the WidgetSpan + Transform.translate hack
                          // that asterisks needed.
                          const TextSpan(text: '••••'),
                          TextSpan(text: ' $last4'),
                        ],
                      ),
                    )
                  : Text(
                      tr.noCardsShort,
                      // Match the visual weight of sibling rows like
                      // "Vaciar Manualmente" (built via _buildActionButton):
                      // fontSize 16, fontWeight 500, color onSurface.
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
            ),
            // Predeterminada tick removed by request — this preview is
            // a navigation row to Saved Cards, so the default-state
            // indicator belongs inside that screen, not here. Just the
            // chevron stays.
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildPushkaStyleSelector(WidgetRef ref) {
    final style = ref.watch(pushkaStyleProvider);
    final tr = S.of(context);
    final label = switch (style) {
      PushkaStyle.classic => tr.pushkaStyleClassic,
      PushkaStyle.building770 => tr.pushkaStyleBuilding770,
    };
    return _buildActionButton(
      label,
      trailingIcon: Icons.keyboard_arrow_down,
      onTap: () => _showPushkaStylePicker(ref, style),
    );
  }

  Future<void> _showPushkaStylePicker(
    WidgetRef ref,
    PushkaStyle current,
  ) async {
    final tr = S.of(context);
    final picked = await showOptionPickerSheet<PushkaStyle>(
      context: context,
      currentValue: current,
      options: [
        (value: PushkaStyle.classic, label: tr.pushkaStyleClassic),
        (value: PushkaStyle.building770, label: tr.pushkaStyleBuilding770),
      ],
    );
    if (picked != null && picked != current) {
      ref.read(pushkaStyleProvider.notifier).setStyle(picked);
    }
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  Widget _buildLabel(String label) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  List<double> _presetsForCurrency(String currency) {
    switch (currency.toLowerCase()) {
      case 'mxn': return [20, 100, 200];
      case 'ars': return [1000, 5000, 10000];
      case 'brl': return [5, 25, 50];
      case 'clp': return [1000, 5000, 10000];
      case 'cop': return [5000, 20000, 50000];
      case 'ils': return [5, 20, 40];
      case 'eur': return [1, 5, 10];
      case 'gbp': return [1, 5, 10];
      case 'cad': return [1, 5, 10];
      case 'uyu': return [50, 200, 500];
      case 'pen': return [5, 20, 50];
      case 'bob': return [10, 30, 50];
      case 'gtq': return [10, 30, 50];
      case 'dop': return [100, 300, 600];
      case 'aud': return [1, 5, 10];
      default: return [1, 5, 10];
    }
  }

  Widget _buildCurrentPresets(Map<String, dynamic>? profile, Color blue, User? user) {
    final rawPresets = profile?['presetAmounts'];
    final List<double> remotePresets;
    if (rawPresets is List && rawPresets.length >= 3) {
      final converted = rawPresets.whereType<num>().map((e) => e.toDouble()).toList();
      final valid = converted.where((v) => v > 0).toList();
      remotePresets = valid.length >= 3 ? valid.take(3).toList() : _presetsForCurrency(selectedCurrency);
    } else {
      remotePresets = _presetsForCurrency(selectedCurrency);
    }
    // Use local copy while editing so we can show pending changes instantly
    final presets = _localPresets ?? remotePresets;
    final sym = shortCurrencySymbol(selectedCurrency);
    final cs = Theme.of(context).colorScheme;

    // Sync controllers from the source-of-truth presets list, but only
    // when the field is NOT focused — otherwise the user's typing would
    // be stomped on every rebuild (Firestore stream tick, theme change,
    // etc.). First-time init is unconditional.
    for (var i = 0; i < 3; i++) {
      final formatted = _formatPresetVal(presets[i]);
      if (!_presetCtrlsInited || (!_presetFocusNodes[i].hasFocus && _presetCtrls[i].text != formatted)) {
        _presetCtrls[i].text = formatted;
      }
    }
    _presetCtrlsInited = true;

    return Row(
      children: List.generate(3, (idx) {
        return Expanded(
          child: Padding(
            padding: EdgeInsetsDirectional.only(end: idx < 2 ? 10 : 0),
            child: TextField(
              controller: _presetCtrls[idx],
              focusNode: _presetFocusNodes[idx],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              textInputAction: TextInputAction.done,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                prefixText: sym,
                prefixStyle: TextStyle(
                  fontSize: 15,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                filled: true,
                fillColor: cs.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
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
              onSubmitted: (_) => _commitPreset(idx),
            ),
          ),
        );
      }),
    );
  }

  /// Save-on-blur (or submit) for one preset slot. Mirrors the pushka-goal
  /// commit logic: parse, validate, fall back to the previous value if the
  /// input is invalid, persist via _updateSettings.
  void _commitPreset(int idx) {
    final raw = _presetCtrls[idx].text.trim().replaceAll(',', '.');
    final parsed = double.tryParse(raw);
    // Base MUST reflect the current source-of-truth for the OTHER two slots.
    // BUG (fixed): previously read presetAmounts from userProfileProvider
    // (root user doc). But presetAmounts is per-tenant → lives in
    // tenantStateProvider, not the root profile. Reading from the wrong
    // source returned null → basePresets fell back to currency defaults →
    // editing one slot silently reset the OTHER two to defaults.
    // Now correctly reads from tenantState.
    final rawPresets =
        ref.read(tenantStateProvider).valueOrNull?['presetAmounts'];
    List<double>? tenantPresets;
    if (rawPresets is List && rawPresets.length >= 3) {
      final converted = rawPresets.whereType<num>().map((e) => e.toDouble()).toList();
      final valid = converted.where((v) => v > 0).toList();
      if (valid.length >= 3) tenantPresets = valid.take(3).toList();
    }
    final basePresets =
        _localPresets ?? tenantPresets ?? _presetsForCurrency(selectedCurrency);
    if (parsed == null || parsed <= 0) {
      // Invalid → restore the controller text from the previous value
      _presetCtrls[idx].text = _formatPresetVal(basePresets[idx]);
      return;
    }
    if (parsed == basePresets[idx]) return;
    final updated = List<double>.of(basePresets);
    updated[idx] = parsed;
    setState(() => _localPresets = updated);
    _updateSettings(ref.read(currentUserProvider), presetAmounts: updated)
        .catchError((Object e) => debugPrint('preset save error: $e'));
  }

  Widget _buildActionButton(
    String label, {
    required VoidCallback onTap,
    IconData trailingIcon = Icons.chevron_right,
  }) {
    final cs2 = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs2.surface,
          border: Border.all(color: cs2.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            Icon(trailingIcon, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrencySelector({
    required String currency,
    required VoidCallback onTap,
  }) {
    final cs2 = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cs2.surface,
          border: Border.all(color: cs2.outline),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Text(_flagForCurrency(currency), style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                currency,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.keyboard_arrow_down, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildLanguageSelector() {
    final currentLocale = ref.watch(localeProvider);
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final languages = [
      {'label': tr.langSpanish, 'code': 'es'},
      {'label': tr.langEnglish, 'code': 'en'},
      {'label': tr.langFrench, 'code': 'fr'},
      {'label': tr.langHebrew, 'code': 'he'},
    ];
    final currentLabel = languages.firstWhere(
      (l) => l['code'] == currentLocale.languageCode,
      orElse: () => languages.first,
    )['label']!;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showLanguagePicker(languages, currentLocale.languageCode),
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
              child: Text(
                currentLabel,
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

  Future<void> _showLanguagePicker(
    List<Map<String, String>> languages,
    String currentCode,
  ) async {
    final picked = await showOptionPickerSheet<String>(
      context: context,
      currentValue: currentCode,
      options: [
        for (final lang in languages)
          (value: lang['code']!, label: lang['label']!),
      ],
    );
    if (picked == null || !mounted || picked == currentCode) return;
    ref.read(localeProvider.notifier).setLanguageCode(picked);
    final uid = ref.read(currentUserProvider)?.uid;
    if (uid != null) {
      ref.read(userRepositoryProvider).updateSettings(
        uid: uid,
        language: picked,
      ).catchError((Object e) => debugPrint('language updateSettings error: $e'));
    }
  }

  Widget _buildToggleRow(
    String label,
    bool value, {
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Switch(
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// Web push toggle: opts the user in/out of PWA push notifications. This
  /// is the ONLY place we invoke Notification.requestPermission() (browsers
  /// require a user gesture; cold-start calls would silently deny). iOS
  /// Safari has an extra constraint: push only works inside a standalone
  /// PWA (Add-to-Home-Screen'd), so if the user is browsing in Safari tab
  /// we surface an explanation instead of asking for permission.
  Widget _buildWebPushToggle(User? user, S tr) {
    final enabled = NotificationService.instance.webPushIsEnabled();
    final ua = kIsWeb ? _webUserAgent() : '';
    final isIOS = RegExp(r'iPad|iPhone|iPod').hasMatch(ua);
    // Safari standalone (Add-to-Home-Screen) sets navigator.standalone=true;
    // matchMedia display-mode:standalone also flags installed PWA on Chrome.
    final isStandalone = _webIsStandalone();
    // If the user is on iOS Safari NOT installed as PWA, push is impossible
    // — Apple only wires webpush inside the installed-PWA context.
    final iosBlocked = isIOS && !isStandalone;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToggleRow(
          tr.pushNotifications,
          enabled,
          onChanged: iosBlocked || user == null
              ? (_) {}
              : (value) => _onWebPushToggle(user, value, tr),
        ),
        const SizedBox(height: 6),
        Text(
          iosBlocked
              ? tr.pushRequiresInstalledPwa
              : tr.pushNotificationsSubtitle,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Future<void> _onWebPushToggle(User user, bool enable, S tr) async {
    final messenger = ScaffoldMessenger.of(context);
    if (enable) {
      final ok = await NotificationService.instance.enableWebPush(user.uid);
      if (!mounted) return;
      if (ok) {
        setState(() {}); // refresh toggle state from Hive
        messenger.showSnackBar(SnackBar(content: Text(tr.pushEnabled)));
      } else {
        messenger.showSnackBar(SnackBar(content: Text(tr.pushPermissionDenied)));
      }
    } else {
      await NotificationService.instance.disableWebPush(user.uid);
      if (!mounted) return;
      setState(() {});
    }
  }

  // Conditional-import helpers (see top of file): webUserAgent() +
  // webIsStandalonePwa() are stubs on native, real dart:html reads on web.
  String _webUserAgent() => webUserAgent();
  bool _webIsStandalone() => webIsStandalonePwa();

  Widget _buildProfileField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.6, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurface)),
        ],
      ),
    );
  }

  Widget _buildEditableField(String label, String value, {required VoidCallback onEdit}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.6, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurface)),
              ],
            )),
            Icon(Icons.edit_outlined, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Future<bool> _authenticateWithBiometrics() async {
    final tr = S.of(context);
    final auth = LocalAuthentication();
    // Show a DIALOG (not snackbar) with the specific failure reason. Snackbars
    // auto-dismiss in 4s and users miss them — critical to distinguish
    // "hardware missing" vs "no fingerprint enrolled" vs "user canceled" so
    // the donor knows what to do (enroll in system Settings vs contact support).
    Future<void> showBiometricError(String message) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(tr.biometricAuth),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(tr.commonUnderstood),
            ),
          ],
        ),
      );
    }

    try {
      final canCheck = await auth.canCheckBiometrics;
      final isSupported = await auth.isDeviceSupported();
      if (!canCheck && !isSupported) {
        await showBiometricError(tr.noBiometric);
        return false;
      }

      final biometrics = await auth.getAvailableBiometrics();
      if (biometrics.isEmpty) {
        // Hardware exists but no fingerprint/face enrolled. Common on S25 when
        // user never set up screen lock beyond a PIN, OR when only PIN is
        // enrolled without fingerprint. Direct them to system Settings.
        await showBiometricError(tr.configureDeviceSecurity);
        return false;
      }

      final ok = await auth.authenticate(
        localizedReason: tr.biometricReasonEnable,
      );
      if (!ok) {
        // User canceled the prompt or auth failed. Silent — no dialog needed;
        // user knows they hit cancel. Toggle stays off.
        return false;
      }
      return true;
    } catch (e, st) {
      debugPrint('_authenticateWithBiometrics error: $e\n$st');
      final msg = e.toString();
      final friendly = (msg.contains('NoCredentialSet') ||
              msg.contains('notEnrolled') ||
              msg.contains('notAvailable') ||
              msg.contains('LockedOut'))
          ? tr.configureDeviceSecurity
          : '${tr.authCouldNotComplete}\n\n(${msg.length > 200 ? msg.substring(0, 200) : msg})';
      await showBiometricError(friendly);
      return false;
    }
  }

  Widget _biometricChip(IconData icon, String label) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: cs.primary)),
      ]),
    );
  }

  Future<void> _showEditDialog(String title, String currentValue, Future<void> Function(String) onSave, {String fieldKey = ''}) async {
    final isPhone = fieldKey == 'phone';

    // Hoisted to function scope so the controller can be disposed in finally
    // — previously created inside the showDialog builder, where it leaked on
    // dialog dismissal.
    final controller = TextEditingController(text: currentValue == '-' ? '' : currentValue);
    String phonePrefix = '+1';
    String phoneFlag = '\u{1F1FA}\u{1F1F8}';

    if (isPhone) {
      final match = RegExp(r'^\+\d+').firstMatch(controller.text.trim());
      if (match != null) {
        phonePrefix = match.group(0) ?? '+1';
        controller.text = controller.text.trim().replaceFirst(phonePrefix, '').trim();
      }
    }

    String? result;
    try {
      result = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        String? errorText;

        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            scrollable: true,
            contentPadding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              if (isPhone) ...[
                Row(children: [
                  OutlinedButton(
                    onPressed: () {
                      showCountryPicker(context: ctx, showPhoneCode: true,
                        countryListTheme: CountryListThemeData(inputDecoration: InputDecoration(labelText: S.of(context).searchCountry, hintText: S.of(context).nameOrCode, prefixIcon: const Icon(Icons.search))),
                        onSelect: (Country country) { setDialogState(() { phonePrefix = '+${country.phoneCode}'; phoneFlag = country.flagEmoji; }); },
                      );
                    },
                    child: Text('$phoneFlag $phonePrefix'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(hintText: S.of(context).phoneHint, errorText: errorText,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                    ),
                    onChanged: (_) { if (errorText != null) setDialogState(() => errorText = null); },
                  )),
                ]),
              ] else ...[
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: _keyboardTypeForKey(fieldKey),
                  decoration: InputDecoration(hintText: S.of(context).enterField(title.toLowerCase()), errorText: errorText,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTokens.primaryBlue, width: 1.6)),
                  ),
                  onChanged: (_) { if (errorText != null) setDialogState(() => errorText = null); },
                ),
              ],
            ]),
            actions: [
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppTokens.primaryBlue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: () {
                  final typed = controller.text.trim();
                  // For phone, only prepend the country prefix when the user
                  // actually typed a number. Empty input must stay empty so
                  // the field can be cleared (not submitted as "+1").
                  final value = isPhone
                      ? (typed.isEmpty ? '' : '$phonePrefix $typed'.trim())
                      : typed;
                  final validationError = _validateByKey(fieldKey, value);
                  if (validationError != null) { setDialogState(() => errorText = validationError); return; }
                  Navigator.pop(ctx, value);
                },
                child: Text(S.of(context).save, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              )),
              SizedBox(width: double.infinity, height: 44, child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(S.of(context).cancel, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
              )),
            ],
          ),
        );
      },
    );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    }

    if (result != null) {
      try {
        await onSave(result);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).settingsSaved)),
          );
        }
      } catch (e) {
        debugPrint('_showEditDialog onSave error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).saveError)),
          );
        }
      }
    }
  }

  Future<void> _updateProfileField(
    User? user, {
    String? billingEmail,
    String? phoneNumber,
    String? mailingAddress,
  }) async {
    if (user == null) return;

    try {
      await ref.read(userRepositoryProvider).updateProfile(
            uid: user.uid,
            billingEmail: billingEmail,
            phoneNumber: phoneNumber,
            mailingAddress: mailingAddress,
          );
    } catch (e) {
      debugPrint('_updateProfileField error: $e');
      rethrow;
    }
  }

  Future<void> _updateSettings(
    User? user, {
    double? pushkaGoal,
    double? presetAmount,
    List<double>? presetAmounts,
    bool? soundEnabled,
    bool? vibrationEnabled,
    bool? ambientEnabled,
    bool? partialPaymentsEnabled,
    bool? biometricAuthenticationEnabled,
    String? currencyCountry,
    String? currencyCode,
  }) async {
    if (user == null) return;
    final repo = ref.read(userRepositoryProvider);
    final tenantId = ref.read(userProfileProvider).valueOrNull?['tenantId'] as String?;
    final futures = <Future<void>>[];

    // Per-tenant settings → tenantState subcollection
    if (tenantId != null && tenantId.isNotEmpty &&
        (pushkaGoal != null || presetAmount != null || presetAmounts != null)) {
      futures.add(repo.updateTenantState(
        uid: user.uid,
        tenantId: tenantId,
        pushkaGoal: pushkaGoal,
        presetAmount: presetAmount,
        presetAmounts: presetAmounts,
      ));
    }

    // User-level settings → root user doc
    if (soundEnabled != null ||
        vibrationEnabled != null || ambientEnabled != null ||
        partialPaymentsEnabled != null ||
        biometricAuthenticationEnabled != null ||
        currencyCountry != null || currencyCode != null) {
      futures.add(repo.updateSettings(
        uid: user.uid,
        soundEnabled: soundEnabled,
        vibrationEnabled: vibrationEnabled,
        ambientEnabled: ambientEnabled,
        partialPaymentsEnabled: partialPaymentsEnabled,
        biometricAuthenticationEnabled: biometricAuthenticationEnabled,
        currencyCountry: currencyCountry,
        currencyCode: currencyCode,
      ));
    }

    await Future.wait(futures);
  }

  /// Fire-and-forget wrapper for toggle switches. Logs errors silently.
  void _updateSettingsSilent(User? user, {
    bool? soundEnabled,
    bool? vibrationEnabled,
    bool? ambientEnabled,
    bool? partialPaymentsEnabled,
    bool? biometricAuthenticationEnabled,
  }) {
    _updateSettings(
      user,
      soundEnabled: soundEnabled,
      vibrationEnabled: vibrationEnabled,
      ambientEnabled: ambientEnabled,
      partialPaymentsEnabled: partialPaymentsEnabled,
      biometricAuthenticationEnabled: biometricAuthenticationEnabled,
    ).catchError((Object e) => debugPrint('toggle updateSettings error: $e'));
  }

  String _formatPresetVal(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  Future<void> _showDeleteAccountDialog() async {
    final confirmed = await _showDeleteConfirmationDialog();
    if (!confirmed || !mounted) return;

    // Force a fresh ID token: the deleteAccount CF requires auth_time within
    // the last 5 min. Re-auth refreshes auth_time AND surfaces wrong-password
    // errors here, in the dialog, instead of as a server-side rejection.
    final reAuthed = await _showReAuthDialog();
    if (!reAuthed || !mounted) return;

    try {
      // GDPR right-to-be-forgotten — call the server-side CF which cancels
      // Stripe subscriptions, deletes the Stripe customer (detaching saved
      // cards), recursively deletes every Firestore subcollection + the
      // user doc, deletes the profile photo from Storage, writes a tombstone
      // for compliance retention, then deletes the Firebase Auth user. The
      // client's `currentUser?.delete()` would only kill the Auth record,
      // leaving Firestore + Stripe data orphaned indefinitely.
      // Round-5 audit HIGH fix: client timeout must exceed the server's
      // timeoutSeconds (300s) so a user in ~15 tenants with active recurring
      // subs doesn't hit the client's 60s default while the server continues
      // to completion. Extended to 330s with margin.
      final callable = FirebaseFunctions.instance.httpsCallable(
        'deleteAccount',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 330)),
      );
      await callable.call();
      // Auth user is gone — GoRouter refresh stream detects sign-out and
      // redirects to /login. Force-reload to clear any in-memory Riverpod
      // state in case the listener races the navigation.
      try { await FirebaseAuth.instance.signOut(); } catch (_) { /* already gone */ }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final tr = S.of(context);
      final msg = e.code == 'failed-precondition'
          ? tr.requiresRecentLogin
          : tr.couldNotDeleteAccount;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).couldNotDeleteAccount)),
      );
    }
  }

  Future<bool> _showDeleteConfirmationDialog() async {
    final tr = S.of(context);
    final confirmWord = tr.deleteConfirmWord;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _DeleteConfirmDialog(
        confirmWord: confirmWord,
        title: tr.deleteAccountTitle,
        body: tr.deleteAccountBody,
        instruction: tr.deleteTypeInstruction(confirmWord),
        continueLabel: tr.continueLabel,
        cancelLabel: tr.cancel,
      ),
    );

    return result == true;
  }

  Future<bool> _showReAuthDialog() async {
    final tr = S.of(context);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    final providers = user.providerData.map((p) => p.providerId).toSet();
    final isGoogle = providers.contains('google.com');
    final isPassword = providers.contains('password');
    // Apple Sign-In is the third supported provider (see auth_controller
    // signInWithApple). Without an Apple re-auth branch, users who signed
    // up via Apple would be stuck with no way to satisfy deleteAccount's
    // recent-login requirement — the dialog would show only Google + a
    // password field they don't have. Only surface on non-web (Apple SDK
    // gated to iOS/macOS/Android WKWebView; sign_in_with_apple throws on
    // web with the plugin config we ship).
    final isApple = providers.contains('apple.com') && !kIsWeb;

    final ctrl = TextEditingController();
    String? errorText;
    bool loading = false;

    bool? result;
    try {
      result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSS) {
          final cs = Theme.of(ctx).colorScheme;
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr.verifyIdentityTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(tr.verifyIdentityBody, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant, height: 1.4)),
                if (isPassword) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: ctrl,
                    autofocus: !isGoogle && !isApple,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: tr.passwordField,
                      errorText: errorText,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppTokens.primaryBlue, width: 2),
                      ),
                    ),
                    onChanged: (_) { if (errorText != null) setSS(() => errorText = null); },
                    onSubmitted: (_) => _reAuthWithPassword(user, ctrl, tr, setSS, ctx, () => loading, (v) => loading = v, (v) => errorText = v),
                  ),
                ],
              ],
            ),
            actions: [
              if (isPassword)
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB91C1C),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    onPressed: loading ? null : () => _reAuthWithPassword(user, ctrl, tr, setSS, ctx, () => loading, (v) => loading = v, (v) => errorText = v),
                    child: loading && !isGoogle
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(tr.verifyAndDelete, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
              if (isGoogle) ...[
                if (isPassword) const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    icon: loading && isGoogle && !isPassword
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.login_rounded, size: 20),
                    label: Text(tr.continueGoogle, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: loading ? null : () async {
                      setSS(() => loading = true);
                      try {
                        // google_sign_in v7 (Credential Manager): singleton
                        // + authenticate() returns non-null or throws.
                        // GoogleSignIn.instance.initialize() ran at app boot
                        // (app_initializer._performDeferredInit).
                        final googleUser = await GoogleSignIn.instance.authenticate(
                          scopeHint: const ['email', 'profile'],
                        );
                        final googleAuth = googleUser.authentication;
                        final idToken = googleAuth.idToken;
                        if (idToken == null) {
                          if (ctx.mounted) setSS(() { loading = false; errorText = tr.reAuthFailed; });
                          return;
                        }
                        final credential = GoogleAuthProvider.credential(
                          // v7 exposes only idToken (accessToken split off
                          // to authorizationClient). Firebase Auth accepts
                          // idToken-only credentials.
                          idToken: idToken,
                        );
                        await user.reauthenticateWithCredential(credential);
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } on GoogleSignInException catch (e) {
                        // Silent on user cancel — match Apple re-auth pattern.
                        if (e.code == GoogleSignInExceptionCode.canceled) {
                          if (ctx.mounted) setSS(() => loading = false);
                          return;
                        }
                        if (ctx.mounted) setSS(() { loading = false; errorText = tr.reAuthFailed; });
                      } catch (_) {
                        if (ctx.mounted) setSS(() { loading = false; errorText = tr.reAuthFailed; });
                      }
                    },
                  ),
                ),
              ],
              if (isApple) ...[
                if (isPassword || isGoogle) const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    icon: loading && isApple && !isPassword && !isGoogle
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.apple, size: 22),
                    label: Text(tr.continueApple, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: loading ? null : () async {
                      setSS(() => loading = true);
                      try {
                        // Mirrors AuthController.signInWithApple: request an
                        // identity token from Apple, wrap it in an OAuth
                        // credential for the apple.com provider, and re-auth
                        // Firebase with it. This refreshes auth_time so the
                        // deleteAccount CF's recent-login gate passes.
                        final appleCredential = await SignInWithApple.getAppleIDCredential(
                          scopes: [
                            AppleIDAuthorizationScopes.email,
                            AppleIDAuthorizationScopes.fullName,
                          ],
                        );
                        final identityToken = appleCredential.identityToken;
                        if (identityToken == null) {
                          // Apple returned a credential without an identity
                          // token — cannot build a Firebase OAuth credential.
                          throw StateError('apple-reauth: missing identityToken');
                        }
                        final credential = OAuthProvider('apple.com').credential(
                          idToken: identityToken,
                          accessToken: appleCredential.authorizationCode,
                        );
                        await user.reauthenticateWithCredential(credential);
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } on SignInWithAppleAuthorizationException catch (e) {
                        // User taps Cancel on Apple's sheet → do NOT surface
                        // "verification failed". Just reset the button.
                        if (e.code == AuthorizationErrorCode.canceled) {
                          if (ctx.mounted) setSS(() => loading = false);
                          return;
                        }
                        debugPrint('apple re-auth error: ${e.code} ${e.message}');
                        if (ctx.mounted) setSS(() { loading = false; errorText = tr.reAuthFailed; });
                      } catch (e, st) {
                        debugPrint('apple re-auth error: $e\n$st');
                        if (ctx.mounted) setSS(() { loading = false; errorText = tr.reAuthFailed; });
                      }
                    },
                  ),
                ),
              ],
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: TextButton(
                  onPressed: loading ? null : () => Navigator.pop(ctx, false),
                  child: Text(tr.cancel, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
                ),
              ),
            ],
          );
        },
      ),
    );
    } finally {
      Future.delayed(const Duration(milliseconds: 400), ctrl.dispose);
    }
    return result == true;
  }

  Future<void> _reAuthWithPassword(
    User user,
    TextEditingController ctrl,
    S tr,
    StateSetter setSS,
    BuildContext ctx,
    bool Function() getLoading,
    void Function(bool) setLoading,
    void Function(String?) setError,
  ) async {
    // Do NOT .trim() — login_screen.dart doesn't trim either, and users with
    // legitimate leading/trailing whitespace in their password would get a
    // "wrong password" here while login works. Keep only the isEmpty guard
    // for the blank-field case, applied to the trimmed view.
    final password = ctrl.text;
    if (password.trim().isEmpty) { setSS(() => setError(tr.enterYourPassword)); return; }
    final email = user.email;
    if (email == null || email.isEmpty) {
      // Apple Sign-In hides the email after the first sign-in, so reauth via
      // EmailAuthProvider.credential is not possible. Surface a clear error
      // instead of crashing on the null-bang.
      setSS(() => setError(tr.reAuthFailed));
      return;
    }
    setSS(() { setLoading(true); setError(null); });
    try {
      final credential = EmailAuthProvider.credential(email: email, password: password);
      await user.reauthenticateWithCredential(credential);
      if (ctx.mounted) Navigator.pop(ctx, true);
    } on FirebaseAuthException catch (e) {
      setSS(() {
        setLoading(false);
        setError(e.code == 'wrong-password' || e.code == 'invalid-credential' ? tr.wrongPassword : tr.reAuthFailed);
      });
    } catch (_) {
      setSS(() { setLoading(false); setError(tr.reAuthFailed); });
    }
  }

  Future<void> _showLogoutDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.of(context).logoutTitle),
        content: Text(S.of(context).logoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.of(context).cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.of(context).logoutTitle),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        await ref.read(authControllerProvider).signOut();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).sessionClosed)),
        );
      } catch (e) {
        debugPrint('signOut error: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).saveError)),
        );
      }
    }
  }

  Future<void> _showCurrencyDialog() async {
    // Flag-per-currency map. MUST stay in sync with the server-side
    // SUPPORTED_CURRENCIES set (functions/index.js:105 CURRENCY_MINIMUMS
    // keys) — Round-4 audit fix: exposing UYU/PEN/BOB/GTQ/DOP/AUD here
    // let users pick a currency the server rejected on every subsequent
    // donation with a generic "Moneda no soportada" error. Add a currency
    // here ONLY after adding it to CURRENCY_MINIMUMS + CURRENCY_MAX_AMOUNTS
    // + defaultGoalForCurrency + buildCurrencySnapshot on the backend.
    const allCurrencies = <String, String>{
      'USD': '🇺🇸',
      'EUR': '🇪🇺',
      'ILS': '🇮🇱',
      'MXN': '🇲🇽',
      'ARS': '🇦🇷',
      'BRL': '🇧🇷',
      'CLP': '🇨🇱',
      'COP': '🇨🇴',
      'GBP': '🇬🇧',
      'CAD': '🇨🇦',
    };

    // Shortlist = USD + EUR + ILS (universally-relevant baseline) plus
    // two contextual additions:
    //   - the tenant's default currency (so the local org currency is
    //     always reachable from the picker)
    //   - the user's currently-selected currency (so switching away from
    //     a currency doesn't make it vanish from the list — they can
    //     switch back later)
    final cfg = ref.read(tenantConfigProvider).valueOrNull;
    final tenantCurrency = cfg?.defaultCurrency?.toUpperCase();
    final shortlist = <String>['USD', 'EUR', 'ILS'];
    if (tenantCurrency != null && !shortlist.contains(tenantCurrency)) {
      shortlist.add(tenantCurrency);
    }
    final currentUpper = selectedCurrency.toUpperCase();
    if (!shortlist.contains(currentUpper)) {
      shortlist.add(currentUpper);
    }

    final currencies = shortlist.map((code) {
      final flag = allCurrencies[code] ?? '🌐';
      return {
        'currency': code,
        'flag': flag,
      };
    }).toList();

    final selectedCode = await showOptionPickerSheet<String>(
      context: context,
      currentValue: selectedCurrency,
      options: [
        for (final c in currencies)
          (
            value: c['currency']!,
            label: '${c['flag']}  ${c['currency']!}',
          ),
      ],
    );

    if (selectedCode == null || !mounted) return;
    if (selectedCode == selectedCurrency) return;
    final selected = currencies.firstWhere((c) => c['currency'] == selectedCode);

    // Confirmation modal
    final tr = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.changeCurrencyTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              Row(
                children: [
                  // "From" — derive flag from currency at render time so it
                  // can never drift from selectedCurrency (previous bug: the
                  // state var selectedFlag could stay 🇺🇸 while
                  // selectedCurrency was 'EUR', producing a mismatched
                  // display and a confirm dialog showing the same flag on
                  // both sides after switching from EUR → USD).
                  Text(_flagForCurrency(selectedCurrency), style: const TextStyle(fontSize: 26)),
                  const SizedBox(width: 6),
                  Text(selectedCurrency, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(Icons.arrow_forward_rounded, size: 18, color: cs.onSurfaceVariant),
                  ),
                  Text(_flagForCurrency(selected['currency']!), style: const TextStyle(fontSize: 26)),
                  const SizedBox(width: 6),
                  Text(selected['currency']!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                tr.currencyChangeConfirmBody,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant, height: 1.4),
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr.continueLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr.cancel, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    final newCurrency = selected['currency']!;
    final newGoal = UserRepository.defaultGoalForCurrency(newCurrency);
    final newPresets = _presetsForCurrency(newCurrency);

    // Round-4 audit CRITICAL fix: snapshot previous state BEFORE mutating
    // so we can revert local UI if the atomic CF fails. The old flow
    // fired three fire-and-forget writes that could partially fail and
    // desync users/{uid}.currencyCode from tenantState top-off — cron
    // then charged in the wrong currency.
    final prevCountry = selectedCountry;
    final prevCurrency = selectedCurrency;
    final prevFlag = selectedFlag;
    final prevGoal = pushkaGoal;
    final prevPresets = _localPresets;

    setState(() {
      // selectedCountry kept as raw currency code for back-compat with the
      // persisted `currencyCountry` field; UI no longer surfaces it.
      selectedCountry = newCurrency;
      selectedCurrency = newCurrency;
      selectedFlag = selected['flag'] ?? _flagForCurrency(newCurrency);
      pushkaGoal = newGoal;
      _localPresets = newPresets; // show immediately, no stream dependency
      // Force the preset controllers to re-sync from the new currency's
      // defaults on the next build (otherwise the prior controller texts
      // would stick with the old-currency preset values).
      _presetCtrlsInited = false;
    });

    try {
      await FirebaseFunctions.instance
          .httpsCallable('changeUserCurrency')
          .call<Map<Object?, Object?>>({
        'currencyCode': newCurrency,
        'currencyCountry': newCurrency,
        'pushkaGoal': newGoal,
        'presetAmounts': newPresets,
      });
    } catch (e, st) {
      debugPrint('changeUserCurrency failed: $e\n$st');
      if (!mounted) return;
      // Revert local UI so it stays in lockstep with server state.
      setState(() {
        selectedCountry = prevCountry;
        selectedCurrency = prevCurrency;
        selectedFlag = prevFlag;
        pushkaGoal = prevGoal;
        _localPresets = prevPresets;
        _presetCtrlsInited = false;
      });
      final tr = S.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.saveError)),
      );
    }
  }


  String _flagForCurrency(String currency) {
    switch (currency.toUpperCase()) {
      case 'MXN': return '🇲🇽';
      case 'EUR': return '🇪🇺';
      case 'ILS': return '🇮🇱';
      case 'ARS': return '🇦🇷';
      case 'BRL': return '🇧🇷';
      case 'CLP': return '🇨🇱';
      case 'COP': return '🇨🇴';
      case 'GBP': return '🇬🇧';
      case 'CAD': return '🇨🇦';
      case 'UYU': return '🇺🇾';
      case 'PEN': return '🇵🇪';
      case 'BOB': return '🇧🇴';
      case 'GTQ': return '🇬🇹';
      case 'DOP': return '🇩🇴';
      case 'AUD': return '🇦🇺';
      case 'USD':
      default:    return '🇺🇸';
    }
  }

  TextInputType _keyboardTypeForKey(String key) {
    switch (key) {
      case 'billingEmail': return TextInputType.emailAddress;
      case 'phone': return TextInputType.phone;
      default: return TextInputType.text;
    }
  }

  String? _validateByKey(String key, String value) {
    // billingEmail / phone / mailingAddress are all OPTIONAL — an empty
    // submission is how the user clears the field. Only validate the format
    // when the user actually typed something.
    const optionalKeys = {'billingEmail', 'phone', 'mailingAddress'};
    if (value.isEmpty) {
      return optionalKeys.contains(key) ? null : S.of(context).fieldRequired;
    }
    switch (key) {
      case 'billingEmail':
        final isValid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
        return isValid ? null : S.of(context).invalidEmail;
      case 'phone':
        final isValid = RegExp(r'^[0-9+\-\s]{7,}$').hasMatch(value);
        return isValid ? null : S.of(context).invalidPhone;
      default:
        return null;
    }
  }
}

class _DeleteConfirmDialog extends StatefulWidget {
  final String confirmWord;
  final String title;
  final String body;
  final String instruction;
  final String continueLabel;
  final String cancelLabel;

  const _DeleteConfirmDialog({
    required this.confirmWord,
    required this.title,
    required this.body,
    required this.instruction,
    required this.continueLabel,
    required this.cancelLabel,
  });

  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(widget.body, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: 16),
          Text(widget.instruction, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            autofocus: true,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: widget.confirmWord,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTokens.primaryBlue, width: 2),
              ),
            ),
          ),
        ],
      ),
      actions: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _ctrl,
          builder: (_, value, _) {
            final matches = value.text.trim() == widget.confirmWord;
            return SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: matches ? const Color(0xFFB91C1C) : cs.surfaceContainerHighest,
                  foregroundColor: matches ? Colors.white : cs.onSurfaceVariant,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: matches ? () => Navigator.pop(context, true) : null,
                child: Text(widget.continueLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.cancelLabel, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
          ),
        ),
      ],
    );
  }
}


class _ThemeToggle extends StatefulWidget {
  final bool isDark;
  final ValueChanged<bool> onChanged;
  const _ThemeToggle({required this.isDark, required this.onChanged});

  @override
  State<_ThemeToggle> createState() => _ThemeToggleState();
}

class _ThemeToggleState extends State<_ThemeToggle> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late bool _showDark;

  @override
  void initState() {
    super.initState();
    _showDark = widget.isDark;
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  }

  @override
  void didUpdateWidget(_ThemeToggle old) {
    super.didUpdateWidget(old);
    if (!_ctrl.isAnimating && old.isDark != widget.isDark) {
      setState(() => _showDark = widget.isDark);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_ctrl.isAnimating) return;
    final newDark = !_showDark;
    bool flipped = false;

    _ctrl.reset();
    void listener() {
      if (!flipped && _ctrl.value >= 0.5) {
        flipped = true;
        setState(() => _showDark = newDark);
      }
    }

    _ctrl.addListener(listener);
    _ctrl.forward().then((_) {
      _ctrl.removeListener(listener);
      widget.onChanged(newDark);
    });
  }

  @override
  Widget build(BuildContext context) {
    const trackW = 52.0;
    const trackH = 32.0;
    const thumbD = 24.0;
    const pad = 4.0;
    const travel = trackW - thumbD - pad * 2;

    // Colores idénticos al SwitchTheme activo definido en AppTheme
    const orange = Color(0xFFFF9500);
    const skyBlue = Color(0xFF60A5FA);
    final trackColor = _showDark
        ? skyBlue.withValues(alpha: 0.45)
        : orange.withValues(alpha: 0.45);
    final thumbColor = _showDark ? skyBlue : orange;

    return GestureDetector(
      onTap: _toggle,
      child: SizedBox(
        width: 60,
        height: 48,
        child: Center(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) {
              final t = _ctrl.value;
              // 1 → 0 → 1: sale a la izq y vuelve a la der
              final pos = t < 0.5 ? 1.0 - t * 2.0 : (t - 0.5) * 2.0;
              return SizedBox(
                width: trackW,
                height: trackH,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(trackH / 2),
                          color: trackColor,
                        ),
                      ),
                    ),
                    Positioned(
                      left: pad + pos * travel,
                      top: pad,
                      child: Container(
                        width: thumbD,
                        height: thumbD,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: thumbColor,
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                          ],
                        ),
                        child: Icon(
                          _showDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

