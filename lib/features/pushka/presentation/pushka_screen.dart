import 'package:flutter/material.dart';

class PushkaScreen extends StatefulWidget {
  const PushkaScreen({super.key});

  @override
  State<PushkaScreen> createState() => _PushkaScreenState();
}

class _PushkaScreenState extends State<PushkaScreen> {
  double pushkaAmount = 0;

  void addAmount(double amount) => setState(() => pushkaAmount += amount);
  void emptyPushka() => setState(() => pushkaAmount = 0);

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE05A4F);
    const blue = Color(0xFF2F60C5);

    return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
          child: Column(
            children: [
              const Text(
                "Colel Chabad - Sirviendo a los necesitados de Israel\nDesde 1788",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 10),

              Image.asset(
                'assets/images/jabad.png',
                height: 54,
                fit: BoxFit.contain,
              ),

              const SizedBox(height: 18),
              const Text(
                "¡Llénala!",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: blue,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                "Sigamos avanzando",
                style: TextStyle(color: Colors.black54, fontSize: 16),
              ),
              const SizedBox(height: 18),

              Expanded(
                child: Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        height: 390,
                        child: Image.asset(
                          'assets/images/pushka.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                      const Positioned(top: 16, child: _Coin()),
                      const Positioned(
                        left: 0,
                        child: Text("\$36.00", style: TextStyle(color: blue, fontSize: 14)),
                      ),
                      Positioned(
                        right: 0,
                        child: Text(
                          "-\$${pushkaAmount.toStringAsFixed(2)}",
                          style: const TextStyle(color: blue, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 10),

              Row(
                children: [
                  _moneyBtn('\$1', red, () => addAmount(1)),
                  const SizedBox(width: 10),
                  _moneyBtn('\$5', red, () => addAmount(5)),
                  const SizedBox(width: 10),
                  _moneyBtn('\$10', red, () => addAmount(10)),
                  const SizedBox(width: 10),
                  _moneyBtn('OTRO', red, _otherAmount),
                ],
              ),

              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Donar ahora')),
                      );
                    },
                    child: const Text(
                      'DONAR AHORA',
                      style: TextStyle(color: red, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(
                    onPressed: emptyPushka,
                    child: const Text(
                      'VACIAR PUSHKA',
                      style: TextStyle(color: red, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
  }

  Expanded _moneyBtn(String label, Color border, VoidCallback onTap) {
    return Expanded(
      child: SizedBox(
        height: 44,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: border, width: 2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            foregroundColor: border,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  Future<void> _otherAmount() async {
    final controller = TextEditingController();

    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Otro monto'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: 'Ej: 12.50'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () {
              final value = double.tryParse(controller.text.replaceAll(',', '.'));
              if (value == null || value <= 0) return;
              Navigator.pop(context, value);
            },
            child: const Text('Agregar'),
          ),
        ],
      ),
    );

    if (result != null) addAmount(result);
  }
}

class _Coin extends StatelessWidget {
  const _Coin();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 62,
      height: 62,
      decoration: const BoxDecoration(
        color: Color(0xFFF2B316),
        shape: BoxShape.circle,
      ),
    );
  }
}
