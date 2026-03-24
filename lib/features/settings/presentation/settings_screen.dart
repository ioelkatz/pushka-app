import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../auth/providers/auth_controller.dart';
import '../../users/data/user_repository.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../../wallet/data/wallet_service.dart';
import '../../../core/format_utils.dart';
import '../../../core/l10n/locale_provider.dart';
import 'auto_empty_screen.dart';
import '../../../core/l10n/s.dart';

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

  Stream<QuerySnapshot<Map<String, dynamic>>> _pushkasStream(String uid) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('walletContacts')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  String _normalizeWalletId(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final match = RegExp(r'[A-Za-z0-9-]{4,20}').firstMatch(value);
    return (match?.group(0) ?? value).trim();
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
      final msg = e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
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
    String manualValue = '';
    String? error;

    final manualWalletId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
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
                          onChanged: (value) { manualValue = value; if (error != null) setSheetState(() => error = null); },
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
    await _addPushkaByWalletId(manualWalletId.isEmpty ? manualValue : manualWalletId);
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    const orange = Color(0xFFFF9500);
    const red = Color(0xFFE05A4F);
    const blue = Color(0xFF2F60C5);

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
    final userEmail = user?.email ?? 'sin-correo';
    final billingEmail = getProfileString('billingEmail') ?? '-';
    final phoneNumber = getProfileString('phoneNumber') ?? '-';
    final mailingAddress = getProfileString('mailingAddress') ?? '-';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _buildPresetButton(
                  '\$1.00',
                  selectedPreset == '1.00',
                  onTap: () => _selectPreset(user, 1.00),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildPresetButton(
                  '\$5.00',
                  selectedPreset == '5.00',
                  onTap: () => _selectPreset(user, 5.00),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildPresetButton(
                  '\$10.00',
                  selectedPreset == '10.00',
                  onTap: () => _selectPreset(user, 10.00),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // EMPTY PUSHKA
          _buildLabel(tr.emptyPushkaSetting),
          const SizedBox(height: 6),
          _buildActionButton(
            tr.manualEmpty,
            onTap: () {
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => const AutoEmptyScreen()),
              );
            },
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
          const SizedBox(height: 32),

          // SOUND
          _buildToggleRow(
            tr.sound,
            soundEnabled,
            orange,
            onChanged: (value) {
              setState(() => soundEnabled = value);
              _updateSettings(user, soundEnabled: value);
            },
          ),
          const SizedBox(height: 18),

          // COIN JINGLE
          _buildToggleRow(
            tr.coinJingle,
            coinJingleEnabled,
            orange,
            onChanged: (value) {
              setState(() => coinJingleEnabled = value);
              _updateSettings(user, coinJingleEnabled: value);
            },
          ),
          const SizedBox(height: 18),

          // VIBRATION
          _buildToggleRow(
            tr.vibration,
            vibrationEnabled,
            orange,
            onChanged: (value) {
              setState(() => vibrationEnabled = value);
              _updateSettings(user, vibrationEnabled: value);
            },
          ),
          const SizedBox(height: 18),

          // PARTIAL PAYMENTS
          _buildToggleRow(
            tr.partialPayments,
            partialPaymentsEnabled,
            orange,
            onChanged: (value) {
              setState(() => partialPaymentsEnabled = value);
              _updateSettings(user, partialPaymentsEnabled: value);
            },
          ),
          const SizedBox(height: 18),

          // ADDITIONAL PAYMENT OPTIONS
          _buildToggleRowWithSubtitle(
            tr.additionalPaymentOptions,
            tr.additionalPaymentOptionsSub,
            additionalPaymentOptionsEnabled,
            orange,
            labelFontSize: 14,
            onChanged: (value) {
              setState(() => additionalPaymentOptionsEnabled = value);
              _updateSettings(user, additionalPaymentOptionsEnabled: value);
            },
          ),
          const SizedBox(height: 18),

          _buildToggleRow(
            tr.biometricAuth,
            biometricAuthenticationEnabled,
            orange,
            onChanged: (value) async {
              if (value) {
                final success = await _authenticateWithBiometrics();
                if (!success || !mounted) return;
              }
              setState(() => biometricAuthenticationEnabled = value);
              _updateSettings(user, biometricAuthenticationEnabled: value);
              if (value && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr.biometricActivated)),
                );
              }
            },
          ),
          if (biometricAuthenticationEnabled)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
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
          Container(
            height: 10,
            width: double.infinity,
            color: const Color(0xFFF1F1F1),
          ),
          const SizedBox(height: 22),

          // MY PUSHKAS Section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                tr.myPushkaSection,
                style: TextStyle(
                  fontSize: 40 / 2,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: Color(0xFF101010),
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
            height: 10,
            width: double.infinity,
            color: const Color(0xFFF1F1F1),
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
            height: 10,
            width: double.infinity,
            color: const Color(0xFFF1F1F1),
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

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 40 / 2,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        color: Color(0xFF101010),
      ),
    );
  }

  Widget _buildLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: Colors.black54,
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
          color: Colors.white,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(
              '\$ ',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: blue,
              ),
            ),
            Expanded(
              child: Text(
                value.replaceFirst('\$ ', ''),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetButton(
    String label,
    bool isSelected, {
    required VoidCallback onTap,
  }) {
    const blue = Color(0xFF2F60C5);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            height: 56,
            decoration: BoxDecoration(
              color: isSelected ? blue.withValues(alpha: 0.06) : Colors.white,
              border: Border.all(
                color: isSelected ? blue : Colors.grey.shade300,
                width: isSelected ? 2 : 1.2,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isSelected ? blue : Colors.black87,
              ),
            ),
          ),
          if (isSelected)
            Positioned(
              top: -9,
              left: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: blue,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  S.of(context).principalBadge,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActionButton(String label, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
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
            const Icon(Icons.chevron_right, color: Colors.grey),
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
          color: Colors.white,
          border: Border.all(color: Colors.grey.shade300),
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
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
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
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonFormField<String>(
        value: currentLocale.languageCode,
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 12),
        ),
        icon: const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
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
          ref.read(localeProvider.notifier).setLanguageCode(value);
        },
      ),
    );
  }

  Widget _buildToggleRow(
    String label,
    bool value,
    Color activeColor, {
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: activeColor,
          activeTrackColor: activeColor.withValues(alpha: 0.45),
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: Colors.grey.shade300,
        ),
      ],
    );
  }

  Widget _buildToggleRowWithSubtitle(
    String label,
    String subtitle,
    bool value,
    Color activeColor, {
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
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: activeColor,
          activeTrackColor: activeColor.withValues(alpha: 0.45),
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: Colors.grey.shade300,
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
              color: const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8E8E8),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade400, width: 1.5),
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
                          color: Colors.grey.shade600,
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
                    color: Colors.grey.shade600,
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
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.6, color: Color(0xFF888888))),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF111111))),
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
                Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.6, color: Color(0xFF888888))),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF111111))),
              ],
            )),
            Icon(Icons.edit_outlined, size: 18, color: Colors.grey.shade500),
          ],
        ),
      ),
    );
  }

  Future<bool> _authenticateWithBiometrics() async {
    final auth = LocalAuthentication();
    try {
      final canAuth = await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (!canAuth) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).noBiometric)),
          );
        }
        return false;
      }

      final biometrics = await auth.getAvailableBiometrics();
      if (biometrics.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(
              S.of(context).configureDeviceSecurity,
            ), duration: const Duration(seconds: 4)),
          );
        }
        return false;
      }

      return await auth.authenticate(
        localizedReason: S.of(context).biometricReasonEnable,
        biometricOnly: false,
      );
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('NoCredentialSet') || msg.contains('notEnrolled') || msg.contains('notAvailable')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(
              S.of(context).configureDeviceSecurity,
            ), duration: const Duration(seconds: 4)),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).authCouldNotComplete)),
          );
        }
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

  Future<void> _showEditDialog(String title, String currentValue, Function(String) onSave, {String fieldKey = ''}) async {
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
      onSave(result);
    }
  }

  Future<void> _updateProfileField(
    User? user, {
    String? billingEmail,
    String? phoneNumber,
    String? mailingAddress,
  }) async {
    if (user == null) return;

    await ref.read(userRepositoryProvider).updateProfile(
          uid: user.uid,
          billingEmail: billingEmail,
          phoneNumber: phoneNumber,
          mailingAddress: mailingAddress,
        );
  }

  void _selectPreset(User? user, double amount) {
    setState(() => selectedPreset = amount.toStringAsFixed(2));
    _updateSettings(user, presetAmount: amount);
  }

  Future<void> _updateSettings(
    User? user, {
    double? pushkaGoal,
    double? presetAmount,
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

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).accountDeleted)),
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
      await ref.read(authControllerProvider).signOut();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).sessionClosed)),
      );
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
      _updateSettings(ref.read(currentUserProvider), pushkaGoal: result);
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

    if (result != null) {
      setState(() {
        selectedCountry = result['country']!;
        selectedCurrency = result['currency']!;
        selectedFlag = result['flag'] ?? _flagForCountry(selectedCountry);
      });
      _updateSettings(
        ref.read(currentUserProvider),
        currencyCountry: result['country']!,
        currencyCode: result['currency']!,
      );
      final user = ref.read(currentUserProvider);
      if (user != null) {
        ref.read(userRepositoryProvider).updateSettings(
              uid: user.uid,
              presetAmounts: <double>[],
            );
      }
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
  bool _torchEnabled = false;

  String _normalizeWalletId(String raw) {
    final value = raw.trim();
    final match = RegExp(r'[A-Za-z0-9-]{4,20}').firstMatch(value);
    return (match?.group(0) ?? value).trim();
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
            controller: MobileScannerController(torchEnabled: _torchEnabled),
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
              onPressed: () => setState(() => _torchEnabled = !_torchEnabled),
              iconSize: 28,
              icon: Icon(
                _torchEnabled ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
