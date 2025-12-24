import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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

  // Perfil
  String userName = 'Ioel Katz';
  String userEmail = 'ioelkatz@gmail.com';
  String? billingEmail;
  String? phoneNumber;
  String? mailingAddress;

  // Mis Pushkas
  final List<Map<String, String>> myPushkas = [
    {
      'name': 'Colel Chabad Pushkah',
      'id': 'colel-chabad-pushka',
    },
  ];

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFFF9500);
    const red = Color(0xFFE05A4F);
    const blue = Color(0xFF2F60C5);
    const purple = Color(0xFF9C27B0);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // GENERAL Section
          _buildSectionTitle('GENERAL'),
          const SizedBox(height: 12),

          // PUSHKA GOAL
          _buildLabel('META DE PUSHKA'),
          const SizedBox(height: 6),
          _buildInputField(
            value: '\$ ${pushkaGoal.toStringAsFixed(2)}',
            onTap: () => _showPushkaGoalDialog(),
            blue: blue,
          ),
          const SizedBox(height: 18),

          // PRESET AMOUNTS
          _buildLabel('MONTO PREESTABLECIDO'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _buildPresetButton(
                  '\$ 1.00',
                  selectedPreset == '1.00',
                  isPrimary: true,
                  onTap: () => setState(() => selectedPreset = '1.00'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildPresetButton(
                  '\$ 5.00',
                  selectedPreset == '5.00',
                  onTap: () => setState(() => selectedPreset = '5.00'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildPresetButton(
                  '\$ 10.00',
                  selectedPreset == '10.00',
                  onTap: () => setState(() => selectedPreset = '10.00'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // EMPTY PUSHKA
          _buildLabel('VACIAR PUSHKA'),
          const SizedBox(height: 6),
          _buildActionButton(
            'Vaciar Manualmente',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Vaciar Pushka manualmente')),
              );
            },
          ),
          const SizedBox(height: 18),

          // CURRENCY
          _buildLabel('MONEDA'),
          const SizedBox(height: 6),
          _buildCurrencySelector(
            country: selectedCountry,
            currency: '\$ $selectedCurrency',
            onTap: () => _showCurrencyDialog(),
          ),
          const SizedBox(height: 32),

          // SOUND
          _buildToggleRow(
            'SONIDO',
            soundEnabled,
            orange,
            onChanged: (value) => setState(() => soundEnabled = value),
          ),
          const SizedBox(height: 18),

          // COIN JINGLE
          _buildToggleRow(
            'SONIDO DE MONEDA',
            coinJingleEnabled,
            orange,
            onChanged: (value) => setState(() => coinJingleEnabled = value),
          ),
          const SizedBox(height: 18),

          // VIBRATION
          _buildToggleRow(
            'VIBRACIÓN',
            vibrationEnabled,
            orange,
            onChanged: (value) => setState(() => vibrationEnabled = value),
          ),
          const SizedBox(height: 18),

          // PARTIAL PAYMENTS
          _buildToggleRow(
            'PAGOS PARCIALES',
            partialPaymentsEnabled,
            Colors.grey,
            onChanged: (value) => setState(() => partialPaymentsEnabled = value),
          ),
          const SizedBox(height: 18),

          // ADDITIONAL PAYMENT OPTIONS
          _buildToggleRowWithSubtitle(
            'OPCIONES DE PAGO ADICIONALES',
            'Incluyendo cheque, transferencia, DAF',
            additionalPaymentOptionsEnabled,
            Colors.grey,
            onChanged: (value) => setState(() => additionalPaymentOptionsEnabled = value),
          ),
          const SizedBox(height: 18),

          // BIOMETRIC AUTHENTICATION
          _buildToggleRow(
            'AUTENTICACIÓN BIOMÉTRICA',
            biometricAuthenticationEnabled,
            Colors.grey,
            onChanged: (value) => setState(() => biometricAuthenticationEnabled = value),
          ),
          const SizedBox(height: 32),

          // MY PUSHKAS Section
          _buildSectionTitle('MIS PUSHKAS'),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(child: SizedBox()),
              ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Agregar nueva Pushka')),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  '+ AGREGAR PUSHKA',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...myPushkas.map((pushka) => _buildPushkaItem(pushka)),
          const SizedBox(height: 32),

          // PROFILE Section
          _buildSectionTitle('PERFIL'),
          const SizedBox(height: 12),
          _buildProfileField('NOMBRE', userName),
          const SizedBox(height: 16),
          _buildProfileField('CORREO ELECTRÓNICO', userEmail),
          const SizedBox(height: 16),
          _buildEditableField(
            'CORREO DE FACTURACIÓN',
            billingEmail ?? '-',
            onEdit: () => _showEditDialog('Correo de Facturación', billingEmail ?? '', (value) {
              setState(() => billingEmail = value.isEmpty ? null : value);
            }),
          ),
          const SizedBox(height: 16),
          _buildEditableField(
            'NÚMERO DE TELÉFONO',
            phoneNumber ?? '-',
            onEdit: () => _showEditDialog('Número de Teléfono', phoneNumber ?? '', (value) {
              setState(() => phoneNumber = value.isEmpty ? null : value);
            }),
          ),
          const SizedBox(height: 16),
          _buildEditableField(
            'DIRECCIÓN POSTAL',
            mailingAddress ?? '-',
            onEdit: () => _showEditDialog('Dirección Postal', mailingAddress ?? '', (value) {
              setState(() => mailingAddress = value.isEmpty ? null : value);
            }),
          ),
          const SizedBox(height: 32),

          // MANAGE ACCOUNT Section
          _buildSectionTitle('ADMINISTRAR CUENTA'),
          const SizedBox(height: 12),
          InkWell(
            onTap: () => _showDeleteAccountDialog(),
            child: Row(
              children: [
                Icon(Icons.delete_outline, color: purple, size: 20),
                const SizedBox(width: 8),
                Text(
                  '¿Eliminar cuenta?',
                  style: TextStyle(
                    fontSize: 16,
                    color: purple,
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
                side: const BorderSide(color: orange, width: 2),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'CERRAR SESIÓN',
                style: TextStyle(
                  color: orange,
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
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: Colors.black87,
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
    bool isPrimary = false,
    required VoidCallback onTap,
  }) {
    const blue = Color(0xFF2F60C5);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(
            color: isSelected ? blue : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            if (isPrimary && isSelected)
              Positioned(
                top: -8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: blue,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Principal',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? blue : Colors.black87,
                ),
              ),
            ),
          ],
        ),
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
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.blue.shade700,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Center(
                child: Text(
                  '🇺🇸',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
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
          activeColor: activeColor,
          activeTrackColor: activeColor.withOpacity(0.5),
        ),
      ],
    );
  }

  Widget _buildToggleRowWithSubtitle(
    String label,
    String subtitle,
    bool value,
    Color activeColor, {
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
                style: const TextStyle(
                  fontSize: 16,
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
          activeColor: activeColor,
          activeTrackColor: activeColor.withOpacity(0.5),
        ),
      ],
    );
  }

  Widget _buildPushkaItem(Map<String, String> pushka) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          // Icono de pushka
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(8),
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
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'ID: ${pushka['id']!}',
                  style: TextStyle(
                    fontSize: 12,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w400,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }

  Widget _buildEditableField(String label, String value, {required VoidCallback onEdit}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: Colors.black54,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              color: Colors.grey,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: onEdit,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w400,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }

  Future<void> _showEditDialog(String title, String currentValue, Function(String) onSave) async {
    final controller = TextEditingController(text: currentValue == '-' ? '' : currentValue);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Ingrese $title',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (result != null) {
      onSave(result);
    }
  }

  Future<void> _showDeleteAccountDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar Cuenta'),
        content: const Text(
          '¿Está seguro de que desea eliminar su cuenta? Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (result == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cuenta eliminada')),
      );
    }
  }

  Future<void> _showLogoutDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cerrar Sesión'),
        content: const Text('¿Está seguro de que desea cerrar sesión?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cerrar Sesión'),
          ),
        ],
      ),
    );

    if (result == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sesión cerrada')),
      );
    }
  }

  Future<void> _showPushkaGoalDialog() async {
    final controller = TextEditingController(
      text: pushkaGoal.toStringAsFixed(2),
    );

    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Meta de Pushka'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Monto',
            prefixText: '\$ ',
            hintText: 'Ej: 3600.00',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = double.tryParse(controller.text.replaceAll(',', '.'));
              if (value != null && value > 0) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (result != null) {
      setState(() => pushkaGoal = result);
    }
  }

  Future<void> _showCurrencyDialog() async {
    final currencies = [
      {'country': 'Estados Unidos', 'currency': 'USD', 'flag': '🇺🇸'},
      {'country': 'México', 'currency': 'MXN', 'flag': '🇲🇽'},
      {'country': 'España', 'currency': 'EUR', 'flag': '🇪🇸'},
      {'country': 'Argentina', 'currency': 'ARS', 'flag': '🇦🇷'},
    ];

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Seleccionar Moneda'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: currencies.map((currency) {
            return ListTile(
              leading: Text(currency['flag']!, style: const TextStyle(fontSize: 24)),
              title: Text(currency['country']!),
              subtitle: Text('\$ ${currency['currency']!}'),
              onTap: () => Navigator.pop(context, currency),
            );
          }).toList(),
        ),
      ),
    );

    if (result != null) {
      setState(() {
        selectedCountry = result['country']!;
        selectedCurrency = result['currency']!;
      });
    }
  }
}
