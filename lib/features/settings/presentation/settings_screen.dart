import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Valores de configuración
  double pushkaGoal = 3600.00;
  String selectedPreset = '1.00'; // Primary preset
  bool soundEnabled = true;
  bool coinJingleEnabled = true;
  bool vibrationEnabled = true;
  bool partialPaymentsEnabled = false;
  String selectedCurrency = 'USD';
  String selectedCountry = 'Estados Unidos';

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFFF9500); // Color naranja para toggles activos
    const blue = Color(0xFF2F60C5);
    const grey = Color(0xFFF0F0F0);

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

  Widget _buildInputField({required String value, required VoidCallback onTap}) {
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
                value,
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
            // Bandera (usando emoji o icono)
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
            const Icon(Icons.chevron_down, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleRow(
    String label,
    bool value,
    Color activeColor,
    {required ValueChanged<bool> onChanged},
  ) {
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
