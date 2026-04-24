import 'dart:typed_data';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../auth/providers/auth_controller.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../wallet/data/wallet_service.dart';
import '../../../core/format_utils.dart';
import '../../../core/l10n/locale_provider.dart';
import 'package:go_router/go_router.dart';

import 'auto_empty_screen.dart';
import '../../../core/l10n/s.dart';
import '../../../core/pushka_style_provider.dart';
import '../../../core/theme_provider.dart';

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
  bool coinJingleEnabled = true;
  bool vibrationEnabled = true;
  bool partialPaymentsEnabled = false;
  bool additionalPaymentOptionsEnabled = false;
  bool biometricAuthenticationEnabled = false;
  String selectedCurrency = 'USD';
  String selectedCountry = 'Estados Unidos';
  String selectedFlag = '🇺🇸';
  bool _loadedProfile = false;
  bool _uploadingPhoto = false;

  Stream<QuerySnapshot<Map<String, dynamic>>> _pushkasStream(String uid) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('walletContacts')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  String _normalizeWalletId(String raw) {
    final value = raw.trim().replaceAll(RegExp(r'\s'), '');
    if (value.isEmpty) return '';
    // Wallet IDs are always exactly 8 numeric digits
    if (RegExp(r'^\d{8}$').hasMatch(value)) return value;
    return '';
  }

  String _currencySymbol(String code) {
    const symbols = {
      'usd': 'US\$', 'eur': '€', 'gbp': '£', 'cad': 'CA\$',
      'mxn': 'MX\$', 'ars': 'ARS\$', 'brl': 'R\$', 'ils': '₪',
      'clp': 'CL\$', 'cop': 'CO\$',
    };
    return symbols[code.toLowerCase()] ?? '\$';
  }

  Future<void> _addPushkaByWalletId(String rawWalletId) async {
    final walletId = _normalizeWalletId(rawWalletId);
    if (walletId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).invalidPushkaId)),
      );
      return;
    }
    try {
      await WalletService.instance.addContact(walletId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).pushkaAdded)),
      );
    } catch (e) {
      if (!mounted) return;
      final String msg;
      if (e is FirebaseFunctionsException) {
        msg = switch (e.code) {
          'not-found' => S.of(context).walletUserNotFound,
          'invalid-argument' => S.of(context).invalidPushkaId,
          _ => S.of(context).couldNotAddContact,
        };
      } else {
        msg = S.of(context).couldNotAddContact;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _openPushkaScanFlow() async {
    final result = await Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(builder: (_) => const _SettingsQrScannerScreen()),
    );
    if (result == null || result.isEmpty || !mounted) return;
    await _addPushkaByWalletId(result);
  }

  Future<void> _showAddPushkaDialog() async {
    bool showManualEntry = false;
    String? error;

    final manualWalletId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                child: SafeArea(top: false, child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
                      Text(S.of(context).addNewPushka, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 18),
                      SizedBox(height: 52, child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: () => Navigator.of(ctx).pop(''),
                        child: Text(S.of(context).scanQrCode, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      )),
                      const SizedBox(height: 12),
                      if (!showManualEntry)
                        SizedBox(height: 52, child: OutlinedButton(
                          style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFE05A4F), side: const BorderSide(color: Color(0xFFE05A4F), width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          onPressed: () { setSheetState(() { showManualEntry = true; error = null; }); },
                          child: Text(S.of(context).enterPushkaId, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        )),
                      if (showManualEntry) ...[
                        TextField(
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          onChanged: (value) { if (error != null) setSheetState(() => error = null); },
                          onSubmitted: (value) {
                            if (_normalizeWalletId(value).isEmpty) { setSheetState(() => error = S.of(context).enterValidId); return; }
                            Navigator.of(ctx).pop(value);
                          },
                          decoration: InputDecoration(
                            hintText: S.of(context).pushkaIdHint, errorText: error,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6)),
                          ),
                        ),
                      ],
                    ],
                  ),
                )),
              ),
            );
          },
        );
      },
    );

    if (manualWalletId == null) return;
    if (manualWalletId.isEmpty) {
      await _openPushkaScanFlow();
      return;
    }
    await _addPushkaByWalletId(manualWalletId);
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    const red = Color(0xFFE05A4F);
    final blue = Theme.of(context).colorScheme.primary;

    final user = ref.watch(currentUserProvider);
    final userProfile = ref.watch(userProfileProvider).valueOrNull;

    String? getProfileString(String key) {
      if (userProfile == null) return null;
      final value = userProfile[key] as String?;
      if (value == null || value.trim().isEmpty) return null;
      return value;
    }

    double? getProfileDouble(String key) {
      if (userProfile == null) return null;
      final value = userProfile[key];
      if (value is num) return value.toDouble();
      return null;
    }

    bool? getProfileBool(String key) {
      if (userProfile == null) return null;
      final value = userProfile[key];
      if (value is bool) return value;
      return null;
    }

    if (!_loadedProfile && userProfile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          pushkaGoal = getProfileDouble('pushkaGoal') ?? pushkaGoal;
          final preset = getProfileDouble('presetAmount');
          if (preset != null) {
            selectedPreset = preset.toStringAsFixed(2);
          }
          soundEnabled = getProfileBool('soundEnabled') ?? soundEnabled;
          coinJingleEnabled =
              getProfileBool('coinJingleEnabled') ?? coinJingleEnabled;
          vibrationEnabled =
              getProfileBool('vibrationEnabled') ?? vibrationEnabled;
          partialPaymentsEnabled =
              getProfileBool('partialPaymentsEnabled') ??
                  partialPaymentsEnabled;
          additionalPaymentOptionsEnabled =
              getProfileBool('additionalPaymentOptionsEnabled') ??
                  additionalPaymentOptionsEnabled;
          biometricAuthenticationEnabled =
              getProfileBool('biometricAuthenticationEnabled') ??
                  biometricAuthenticationEnabled;
          selectedCountry =
              getProfileString('currencyCountry') ?? selectedCountry;
          selectedCurrency =
              getProfileString('currencyCode') ?? selectedCurrency;
          selectedFlag = _flagForCountry(selectedCountry);
          _loadedProfile = true;
        });
      });
    }

    final userName = getProfileString('displayName') ??
        (user?.displayName?.trim().isNotEmpty == true
            ? user!.displayName!
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

          // PUSHKA GOAL
          _buildLabel(tr.pushkaGoalSetting),
          const SizedBox(height: 6),
          _buildInputField(
            value: formatMoney(pushkaGoal),
            onTap: () => _showPushkaGoalDialog(),
            blue: blue,
          ),
          const SizedBox(height: 18),

          // PRESET AMOUNTS
          _buildLabel(tr.presetAmount),
          const SizedBox(height: 8),
          _buildCurrentPresets(userProfile, blue, onTap: () {
            final rawPresets = userProfile?['presetAmounts'];
            final List<double> current;
            if (rawPresets is List && rawPresets.length >= 3) {
              final c = rawPresets.whereType<num>().map((e) => e.toDouble()).toList();
              current = c.length >= 3 ? c.take(3).toList() : [1.0, 5.0, 10.0];
            } else {
              current = [1.0, 5.0, 10.0];
            }
            _showEditPresetsDialog(user, current);
          }),
          const SizedBox(height: 18),

          // EMPTY PUSHKA
          _buildLabel(tr.emptyPushkaSetting),
          const SizedBox(height: 6),
          _buildActionButton(
            switch (getProfileString('autoEmptyFrequency') ?? 'manual') {
              'weekly'           => tr.freqWeekly,
              'monthly'          => tr.freqMonthly,
              'erev_rosh_chodesh'=> tr.freqErevRosh,
              _                  => tr.manualEmpty,
            },
            onTap: () {
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => const AutoEmptyScreen()),
              );
            },
          ),
          const SizedBox(height: 18),

          // SAVED CARD
          _buildLabel(tr.savedCards),
          const SizedBox(height: 6),
          _buildActionButton(
            _savedCardLabel(userProfile, tr),
            onTap: () => context.go('/settings/saved-cards'),
          ),
          const SizedBox(height: 18),

          // CURRENCY
          _buildLabel(tr.currency),
          const SizedBox(height: 6),
          _buildCurrencySelector(
            country: selectedCountry,
            currency: '\$ $selectedCurrency',
            onTap: () => _showCurrencyDialog(),
          ),
          const SizedBox(height: 18),

          // LANGUAGE
          _buildLabel(tr.language),
          const SizedBox(height: 6),
          _buildLanguageSelector(),
          const SizedBox(height: 18),

          // APPEARANCE
          _buildLabel('Apariencia'),
          const SizedBox(height: 8),
          _buildThemeSelector(),
          const SizedBox(height: 32),

          // SOUND
          _buildToggleRow(
            tr.sound,
            soundEnabled,
            onChanged: (value) {
              setState(() => soundEnabled = value);
              _updateSettingsSilent(user, soundEnabled: value);
            },
          ),
          const SizedBox(height: 18),

          // COIN JINGLE
          _buildToggleRow(
            tr.coinJingle,
            coinJingleEnabled,
            onChanged: (value) {
              setState(() => coinJingleEnabled = value);
              _updateSettingsSilent(user, coinJingleEnabled: value);
            },
          ),
          const SizedBox(height: 18),

          // VIBRATION
          _buildToggleRow(
            tr.vibration,
            vibrationEnabled,
            onChanged: (value) {
              setState(() => vibrationEnabled = value);
              _updateSettingsSilent(user, vibrationEnabled: value);
            },
          ),
          const SizedBox(height: 18),

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

          // ADDITIONAL PAYMENT OPTIONS
          _buildToggleRowWithSubtitle(
            tr.additionalPaymentOptions,
            tr.additionalPaymentOptionsSub,
            additionalPaymentOptionsEnabled,
            labelFontSize: 14,
            onChanged: (value) {
              setState(() => additionalPaymentOptionsEnabled = value);
              _updateSettingsSilent(user, additionalPaymentOptionsEnabled: value);
            },
          ),
          const SizedBox(height: 18),

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

          // PUSHKA STYLE
          _buildLabel('Estilo de pantalla principal'),
          const SizedBox(height: 8),
          _buildPushkaStyleSelector(ref),
          const SizedBox(height: 18),
          Container(
            height: 5,
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 22),

          // MY PUSHKAS Section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                tr.myPushkaSection.toUpperCase(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _showAddPushkaDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: red,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: Text(
                  tr.addPushkaBtn,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (user == null)
            Text(tr.signInToSeePushkas)
          else
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _pushkasStream(user.uid),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(tr.errorLoadingPushkas);
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return _buildPushkaItem({
                    'name': tr.defaultPushkaName,
                    'id': 'colel-chabad-pushka',
                  });
                }
                return Column(
                  children: docs.map((doc) {
                    final data = doc.data();
                    return _buildPushkaItem({
                      'name': (data['displayName'] as String?)?.trim().isNotEmpty == true
                          ? data['displayName'] as String
                          : 'Pushka',
                      'id': (data['walletId'] as String?) ?? doc.id,
                    });
                  }).toList(),
                );
              },
            ),
          const SizedBox(height: 18),
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
                side: const BorderSide(color: red, width: 2),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
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
          const SizedBox(height: 24),
        ],
      ),
    );
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
            backgroundImage: (photoURL != null && photoURL.isNotEmpty)
                ? NetworkImage(photoURL)
                : null,
            child: (photoURL == null || photoURL.isEmpty)
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
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
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
      await ref.read(userRepositoryProvider).uploadProfilePhoto(
        uid: uid,
        bytes: bytes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.photoUpdated)),
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
                        hintText: tr.displayNameHint,
                        errorText: error,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: cs.primary, width: 1.6),
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
                          backgroundColor: cs.primary,
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
  }

  String _savedCardLabel(Map<String, dynamic>? profile, S tr) {
    final brand = profile?['stripeDefaultPaymentMethodBrand'] as String?;
    final last4 = profile?['stripeDefaultPaymentMethodLast4'] as String?;
    if (brand != null && brand.isNotEmpty && last4 != null && last4.isNotEmpty) {
      final brandLabel = brand[0].toUpperCase() + brand.substring(1);
      return '$brandLabel •••• $last4';
    }
    return tr.noSavedCards.split('\n').first;
  }

  Widget _buildThemeSelector() {
    final mode = ref.watch(themeModeProvider);
    final cs = Theme.of(context).colorScheme;
    // Normalize legacy 'system' value to 'light'
    final effectiveMode = mode == ThemeMode.system ? ThemeMode.light : mode;
    return SegmentedButton<ThemeMode>(
      segments: const [
        ButtonSegment(value: ThemeMode.light, label: Text('Claro'), icon: Icon(Icons.light_mode_outlined, size: 16)),
        ButtonSegment(value: ThemeMode.dark, label: Text('Oscuro'), icon: Icon(Icons.dark_mode_outlined, size: 16)),
      ],
      selected: {effectiveMode},
      onSelectionChanged: (selection) {
        ref.read(themeModeProvider.notifier).setMode(selection.first);
      },
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: cs.primary,
        selectedForegroundColor: cs.onPrimary,
        foregroundColor: cs.onSurface,
      ),
    );
  }

  Widget _buildPushkaStyleSelector(WidgetRef ref) {
    final style = ref.watch(pushkaStyleProvider);
    final cs = Theme.of(context).colorScheme;
    return SegmentedButton<PushkaStyle>(
      segments: const [
        ButtonSegment(value: PushkaStyle.classic, label: Text('Pushka')),
        ButtonSegment(value: PushkaStyle.building770, label: Text('Edificio 770')),
      ],
      selected: {style},
      onSelectionChanged: (selection) {
        ref.read(pushkaStyleProvider.notifier).setStyle(selection.first);
      },
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: cs.primary,
        selectedForegroundColor: cs.onPrimary,
        foregroundColor: cs.onSurface,
      ),
    );
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

  Widget _buildInputField({
    required String value,
    required VoidCallback onTap,
    required Color blue,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentPresets(Map<String, dynamic>? profile, Color blue, {VoidCallback? onTap}) {
    final rawPresets = profile?['presetAmounts'];
    final List<double> presets;
    if (rawPresets is List && rawPresets.length >= 3) {
      final converted = rawPresets.whereType<num>().map((e) => e.toDouble()).toList();
      presets = converted.length >= 3 ? converted.take(3).toList() : [1.0, 5.0, 10.0];
    } else {
      presets = [1.0, 5.0, 10.0];
    }
    final sym = _currencySymbol(selectedCurrency);
    return Row(
      children: presets.asMap().entries.map((entry) {
        final idx = entry.key;
        final amt = entry.value;
        final label = '$sym${amt == amt.roundToDouble() ? amt.toInt() : amt.toStringAsFixed(2)}';
        return Expanded(
          child: Padding(
            padding: EdgeInsetsDirectional.only(end: idx < 2 ? 10 : 0),
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border.all(color: Theme.of(context).colorScheme.outline),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildActionButton(String label, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
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
            Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrencySelector({
    required String country,
    required String currency,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(selectedFlag, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    country,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    currency,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
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
    final languages = [
      {'label': tr.langSpanish, 'code': 'es'},
      {'label': tr.langEnglish, 'code': 'en'},
      {'label': tr.langFrench, 'code': 'fr'},
      {'label': tr.langHebrew, 'code': 'he'},
    ];

    return Theme(
      data: Theme.of(context).copyWith(
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
      ),
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonFormField<String>(
        initialValue: currentLocale.languageCode,
        focusColor: Colors.transparent,
        dropdownColor: Theme.of(context).colorScheme.surface,
        decoration: const InputDecoration(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 12),
        ),
        icon: Icon(Icons.keyboard_arrow_down, color: Theme.of(context).colorScheme.onSurfaceVariant),
        isExpanded: true,
        items: languages
            .map((lang) => DropdownMenuItem<String>(
                  value: lang['code'],
                  child: Text(
                    lang['label']!,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ))
            .toList(),
        onChanged: (value) {
          if (value == null) return;
          // Save to Hive immediately (persists across restarts) then sync Firestore
          ref.read(localeProvider.notifier).setLanguageCode(value);
          final uid = ref.read(currentUserProvider)?.uid;
          if (uid != null) {
            ref.read(userRepositoryProvider).updateSettings(
              uid: uid,
              language: value,
            ).catchError((Object e) => debugPrint('language updateSettings error: $e'));
          }
        },
      ),
      ),
    );
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

  Widget _buildToggleRowWithSubtitle(
    String label,
    String subtitle,
    bool value, {
    double labelFontSize = 16,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: labelFontSize,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildPushkaItem(Map<String, String> pushka) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          // Icono de pushka
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Theme.of(context).colorScheme.outline, width: 1.5),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: 2,
                      left: 8,
                      right: 8,
                      child: Container(
                        height: 2,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                    const Center(
                      child: Text(
                        'צדקה',
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                        textDirection: TextDirection.rtl,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pushka['name']!,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'ID: ${pushka['id']!}',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
      borderRadius: BorderRadius.circular(8),
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
    try {
      final canAuth = await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (!canAuth) {
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr.noBiometric)),
        );
        return false;
      }

      final biometrics = await auth.getAvailableBiometrics();
      if (biometrics.isEmpty) {
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr.configureDeviceSecurity),
              duration: const Duration(seconds: 4)),
        );
        return false;
      }

      return await auth.authenticate(
        localizedReason: tr.biometricReasonEnable,
      );
    } catch (e) {
      final msg = e.toString();
      if (!mounted) return false;
      if (msg.contains('NoCredentialSet') || msg.contains('notEnrolled') || msg.contains('notAvailable')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr.configureDeviceSecurity),
              duration: const Duration(seconds: 4)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr.authCouldNotComplete)),
        );
      }
      return false;
    }
  }

  Widget _biometricChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9500).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: const Color(0xFFFF9500)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFFFF9500))),
      ]),
    );
  }

  Future<void> _showEditDialog(String title, String currentValue, Future<void> Function(String) onSave, {String fieldKey = ''}) async {
    final isPhone = fieldKey == 'phone';

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final controller = TextEditingController(text: currentValue == '-' ? '' : currentValue);
        String? errorText;
        String phonePrefix = '+1';
        String phoneFlag = '\u{1F1FA}\u{1F1F8}';

        if (isPhone) {
          final match = RegExp(r'^\+\d+').firstMatch(controller.text.trim());
          if (match != null) {
            phonePrefix = match.group(0) ?? '+1';
            controller.text = controller.text.trim().replaceFirst(phonePrefix, '').trim();
          }
        }

        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            scrollable: true,
            contentPadding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
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
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6)),
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
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6)),
                  ),
                  onChanged: (_) { if (errorText != null) setDialogState(() => errorText = null); },
                ),
              ],
            ]),
            actions: [
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: () {
                  final value = isPhone ? '$phonePrefix ${controller.text.trim()}'.trim() : controller.text.trim();
                  final validationError = _validateByKey(fieldKey, value);
                  if (validationError != null) { setDialogState(() => errorText = validationError); return; }
                  Navigator.pop(ctx, value);
                },
                child: Text(S.of(context).save, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              )),
              SizedBox(width: double.infinity, height: 44, child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(S.of(context).cancel, style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
              )),
            ],
          ),
        );
      },
    );

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
    bool? coinJingleEnabled,
    bool? vibrationEnabled,
    bool? partialPaymentsEnabled,
    bool? additionalPaymentOptionsEnabled,
    bool? biometricAuthenticationEnabled,
    String? currencyCountry,
    String? currencyCode,
  }) async {
    if (user == null) return;
    await ref.read(userRepositoryProvider).updateSettings(
      uid: user.uid,
      pushkaGoal: pushkaGoal,
      presetAmount: presetAmount,
      presetAmounts: presetAmounts,
      soundEnabled: soundEnabled,
      coinJingleEnabled: coinJingleEnabled,
      vibrationEnabled: vibrationEnabled,
      partialPaymentsEnabled: partialPaymentsEnabled,
      additionalPaymentOptionsEnabled: additionalPaymentOptionsEnabled,
      biometricAuthenticationEnabled: biometricAuthenticationEnabled,
      currencyCountry: currencyCountry,
      currencyCode: currencyCode,
    );
  }

  /// Fire-and-forget wrapper for toggle switches. Logs errors silently.
  void _updateSettingsSilent(User? user, {
    bool? soundEnabled,
    bool? coinJingleEnabled,
    bool? vibrationEnabled,
    bool? partialPaymentsEnabled,
    bool? additionalPaymentOptionsEnabled,
    bool? biometricAuthenticationEnabled,
  }) {
    _updateSettings(
      user,
      soundEnabled: soundEnabled,
      coinJingleEnabled: coinJingleEnabled,
      vibrationEnabled: vibrationEnabled,
      partialPaymentsEnabled: partialPaymentsEnabled,
      additionalPaymentOptionsEnabled: additionalPaymentOptionsEnabled,
      biometricAuthenticationEnabled: biometricAuthenticationEnabled,
    ).catchError((Object e) => debugPrint('toggle updateSettings error: $e'));
  }

  Future<void> _showEditPresetsDialog(
    User? user,
    List<double> current,
  ) async {
    if (user == null) return;
    final tr = S.of(context);
    final sym = _currencySymbol(selectedCurrency);
    final c1 = TextEditingController(text: _formatPresetVal(current[0]));
    final c2 = TextEditingController(text: _formatPresetVal(current[1]));
    final c3 = TextEditingController(text: _formatPresetVal(current[2]));
    String? err;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
          actionsPadding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr.presetAmount,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                tr.editQuickAmountHint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 20),
              if (err != null) ...[
                Text(err!, style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
                const SizedBox(height: 8),
              ],
              Row(
                children: [c1, c2, c3].asMap().entries.map((e) {
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(end: e.key < 2 ? 8 : 0),
                      child: TextField(
                        controller: e.value,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          prefixText: sym,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Theme.of(ctx).colorScheme.primary, width: 1.8),
                          ),
                        ),
                        onChanged: (_) { if (err != null) setSS(() => err = null); },
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () async {
                  final p1 = double.tryParse(c1.text.replaceAll(',', '.')) ?? 0;
                  final p2 = double.tryParse(c2.text.replaceAll(',', '.')) ?? 0;
                  final p3 = double.tryParse(c3.text.replaceAll(',', '.')) ?? 0;
                  if (p1 <= 0 || p2 <= 0 || p3 <= 0) {
                    setSS(() => err = tr.allAmountsMustBePositive);
                    return;
                  }
                  try {
                    await _updateSettings(user, presetAmounts: [p1, p2, p3]);
                    if (!mounted || !ctx.mounted) return;
                    Navigator.pop(ctx);
                  } catch (e) {
                    debugPrint('presetAmounts save error: $e');
                    if (!mounted || !ctx.mounted) return;
                    setSS(() => err = tr.saveError);
                  }
                },
                child: Text(tr.save, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );

  }

  String _formatPresetVal(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  Future<void> _showDeleteAccountDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.of(context).deleteAccountTitle),
        content: Text(
          S.of(context).deleteAccountBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.of(context).cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text(S.of(context).delete),
          ),
        ],
      ),
    );

    if (result != true) return;
    if (!mounted) return;

    try {
      await FirebaseAuth.instance.currentUser?.delete();
      // GoRouter refresh stream detects auth state change and redirects to /login
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final msg = e.code == 'requires-recent-login'
          ? S.of(context).requiresRecentLogin
          : S.of(context).couldNotDeleteAccount;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).couldNotDeleteAccount)),
      );
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

  Future<void> _showPushkaGoalDialog() async {
    final result = await showDialog<double>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final controller = TextEditingController(
          text: pushkaGoal.toStringAsFixed(2),
        );
        String? errorText;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            scrollable: true,
            contentPadding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(S.of(context).pushkaGoalDialog, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                  if (value != null && value > 0) Navigator.pop(ctx, value);
                },
                decoration: InputDecoration(
                  labelText: S.of(context).amount, prefixText: '\$ ', hintText: S.of(context).exampleGoalHint, errorText: errorText,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE05A4F), width: 1.6)),
                ),
                onChanged: (_) { if (errorText != null) setDialogState(() => errorText = null); },
              ),
            ]),
            actions: [
              SizedBox(width: double.infinity, height: 48, child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE05A4F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: () {
                  final value = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                  if (value == null || value <= 0) { setDialogState(() => errorText = S.of(context).enterValidAmount); return; }
                  Navigator.pop(ctx, value);
                },
                child: Text(S.of(context).save, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              )),
              SizedBox(width: double.infinity, height: 44, child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(S.of(context).cancel, style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
              )),
            ],
          ),
        );
      },
    );

    if (result != null && mounted) {
      setState(() => pushkaGoal = result);
      _updateSettings(ref.read(currentUserProvider), pushkaGoal: result)
          .catchError((Object e) => debugPrint('pushkaGoal updateSettings error: $e'));
    }
  }

  Future<void> _showCurrencyDialog() async {
    final profile = ref.read(userProfileProvider).valueOrNull;
    final currentAmount = (profile?['pushkaAmount'] as num?)?.toDouble() ?? 0;
    if (currentAmount > 0) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.savings_outlined, color: Color(0xFFFF9500), size: 30),
              ),
              const SizedBox(height: 16),
              Text(
                S.of(context).emptyPushkaFirst,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                S.of(context).currencyChangeBody,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700, height: 1.4),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity, height: 46,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE05A4F),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(S.of(context).understood, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ),
        ),
      );
      return;
    }

    final currencies = [
      {'country': 'Estados Unidos', 'currency': 'USD', 'flag': '🇺🇸'},
      {'country': 'México', 'currency': 'MXN', 'flag': '🇲🇽'},
      {'country': 'España', 'currency': 'EUR', 'flag': '🇪🇸'},
      {'country': 'Argentina', 'currency': 'ARS', 'flag': '🇦🇷'},
      {'country': 'Brasil', 'currency': 'BRL', 'flag': '🇧🇷'},
      {'country': 'Israel', 'currency': 'ILS', 'flag': '🇮🇱'},
      {'country': 'Chile', 'currency': 'CLP', 'flag': '🇨🇱'},
      {'country': 'Colombia', 'currency': 'COP', 'flag': '🇨🇴'},
      {'country': 'Reino Unido', 'currency': 'GBP', 'flag': '🇬🇧'},
      {'country': 'Canadá', 'currency': 'CAD', 'flag': '🇨🇦'},
    ];

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.of(context).selectCurrency),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.55,
            maxWidth: 360,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: currencies.map((currency) {
                return ListTile(
                  leading: Text(currency['flag']!, style: const TextStyle(fontSize: 24)),
                  title: Text(currency['country']!),
                  subtitle: Text('${_currencySymbol(currency['currency']!)} ${currency['currency']!}'),
                  onTap: () => Navigator.pop(context, currency),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );

    if (result != null && mounted) {
      final newCurrency = result['currency']!;
      final newGoal = UserRepository.defaultGoalForCurrency(newCurrency);
      setState(() {
        selectedCountry = result['country']!;
        selectedCurrency = newCurrency;
        selectedFlag = result['flag'] ?? _flagForCountry(selectedCountry);
        pushkaGoal = newGoal;
      });
      _updateSettings(
        ref.read(currentUserProvider),
        currencyCountry: result['country']!,
        currencyCode: newCurrency,
        pushkaGoal: newGoal,
        presetAmounts: <double>[],
      ).catchError((Object e) => debugPrint('currency updateSettings error: $e'));
    }
  }


  String _flagForCountry(String country) {
    switch (country) {
      case 'México':
        return '🇲🇽';
      case 'España':
        return '🇪🇸';
      case 'Argentina':
        return '🇦🇷';
      case 'Brasil':
        return '🇧🇷';
      case 'Israel':
        return '🇮🇱';
      case 'Chile':
        return '🇨🇱';
      case 'Colombia':
        return '🇨🇴';
      case 'Reino Unido':
        return '🇬🇧';
      case 'Canadá':
        return '🇨🇦';
      case 'Estados Unidos':
      default:
        return '🇺🇸';
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
    if (value.isEmpty) return S.of(context).fieldRequired;
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

class _SettingsQrScannerScreen extends StatefulWidget {
  const _SettingsQrScannerScreen();

  @override
  State<_SettingsQrScannerScreen> createState() => _SettingsQrScannerScreenState();
}

class _SettingsQrScannerScreenState extends State<_SettingsQrScannerScreen> {
  bool _handled = false;
  bool _torchOn = false;
  late final MobileScannerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Use the same strict 8-digit rule as the manual-entry normalizer elsewhere.
  String _normalizeWalletId(String raw) {
    final value = raw.trim().replaceAll(RegExp(r'\s'), '');
    final match = RegExp(r'\b(\d{8})\b').firstMatch(value);
    return match?.group(1) ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of(context).scanQrCode),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_handled) return;
              final raw = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
              if (raw == null || raw.trim().isEmpty) return;
              final normalized = _normalizeWalletId(raw);
              if (normalized.isEmpty) return;
              _handled = true;
              Navigator.of(context).pop(normalized);
            },
          ),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
          Positioned.fill(
            child: Center(
              child: Container(
                width: 260,
                height: 2,
                color: const Color(0xFFE84324),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: IconButton(
              onPressed: () {
                _controller.toggleTorch();
                setState(() => _torchOn = !_torchOn);
              },
              iconSize: 28,
              icon: Icon(
                _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
