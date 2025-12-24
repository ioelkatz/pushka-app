import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../history/providers/history_provider.dart';

class PushkaScreen extends ConsumerStatefulWidget {
  const PushkaScreen({super.key});

  @override
  ConsumerState<PushkaScreen> createState() => _PushkaScreenState();
}

class _PushkaScreenState extends ConsumerState<PushkaScreen> {
  double pushkaAmount = 0;
  final double pushkaGoal = 3600.00; // Meta de la pushka

  void addAmount(double amount) => setState(() => pushkaAmount += amount);
  
  void emptyPushka() {
    if (pushkaAmount > 0) {
      ref.read(historyProvider.notifier).addPushkaEmpty(pushkaAmount);
      setState(() => pushkaAmount = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pushka vaciada')),
      );
    }
  }
  
  void _donateNow() {
    if (pushkaAmount > 0) {
      ref.read(historyProvider.notifier).addTzedaka(pushkaAmount);
      setState(() => pushkaAmount = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('¡Donación realizada!')),
      );
    }
  }

  double get fillPercentage {
    if (pushkaGoal <= 0) return 0;
    final percentage = (pushkaAmount / pushkaGoal).clamp(0.0, 1.0);
    return percentage;
  }

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE05A4F);
    const blue = Color(0xFF2F60C5);
    const lightBlue = Color(0xFFE3F2FD);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
        child: Column(
          children: [
            // Banner de Streak
            _buildStreakBanner(lightBlue, blue),
            
            const SizedBox(height: 16),

            // Títulos
            const Text(
              "¡Llénala!",
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: blue,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Sigamos adelante",
              style: TextStyle(color: Colors.black54, fontSize: 16),
            ),
            const SizedBox(height: 24),

            // Pushka con efecto de llenado
            Expanded(
              child: Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Pushka con efecto de llenado
                    SizedBox(
                      height: 450,
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          // Imagen de la pushka
                          Image.asset(
                            'assets/images/pushka.png',
                            height: 450,
                            fit: BoxFit.contain,
                          ),
                          // Efecto de llenado (gradiente azul que sube)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: ClipRect(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                heightFactor: fillPercentage,
                                child: Container(
                                  height: 450,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      colors: [
                                        lightBlue.withOpacity(0.6),
                                        lightBlue.withOpacity(0.3),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Meta arriba a la izquierda
                    Positioned(
                      top: 20,
                      left: 0,
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: blue,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "\$${pushkaGoal.toStringAsFixed(2)}",
                            style: const TextStyle(
                              color: blue,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Monto actual abajo a la derecha
                    Positioned(
                      bottom: 20,
                      right: 0,
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: blue,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "\$${pushkaAmount.toStringAsFixed(2)}",
                            style: const TextStyle(
                              color: blue,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Botones de monto
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

            // Botones de acción
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _donateNow,
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
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.grey),
                  onPressed: () {
                    context.go('/settings');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreakBanner(Color lightBlue, Color blue) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: blue,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          // Hexágono con número
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: lightBlue,
              borderRadius: BorderRadius.circular(6),
            ),
            margin: const EdgeInsets.all(4),
            child: Center(
              child: Text(
                '1',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: blue,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Racha de Días de Semana',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
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
