import 'package:flutter/material.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE05A4F);
    const blue = Color(0xFF2F60C5);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // texto superior
          Text(
            'Aparta fondos ahora para vaciar tu Pushka después',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black.withOpacity(.55)),
          ),
          const SizedBox(height: 6),
          Text(
            'Aprender más',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: blue,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationThickness: 1.2,
            ),
          ),

          const SizedBox(height: 18),

          // Wallet ID pill
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 18),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: const [
                Text(
                  'Tu ID de billetera',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 6),
                Text(
                  '220-988',
                  style: TextStyle(
                    color: blue,
                    fontSize: 28,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 26),

          // Balance
          const Text(
            'SALDO',
            textAlign: TextAlign.center,
            style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          const Text(
            r'$0.00',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: blue,
              fontSize: 64,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 18),

          // Add funds button
          SizedBox(
            height: 50,
            child: OutlinedButton(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Agregar fondos (próximamente)')),
                );
              },
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: red, width: 2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                foregroundColor: red,
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              child: const Text('+ AGREGAR FONDOS'),
            ),
          ),

          const SizedBox(height: 22),

          // Cards
          _WalletCard(
            icon: Icons.swap_vert,
            iconBg: red,
            title: 'Enviar / Solicitar entre billeteras',
            subtitle: 'Empodera a familia y amigos con tzedaká',
          ),
          const SizedBox(height: 14),
          _WalletCard(
            icon: Icons.settings,
            iconBg: red,
            title: 'Administrar recarga automática',
            subtitle: 'RECARGA AUTOMÁTICA INACTIVA',
          ),
          const SizedBox(height: 14),
          _WalletCard(
            icon: Icons.receipt_long,
            iconBg: red,
            title: 'Historial de transacciones',
            subtitle: '',
          ),
        ],
      ),
    );
  }
}

class _WalletCard extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final String title;
  final String subtitle;

  const _WalletCard({
    required this.icon,
    required this.iconBg,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F3F3),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.black.withOpacity(.55)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
