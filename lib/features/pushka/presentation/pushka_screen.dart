import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class PushkaScreen extends StatefulWidget {
  const PushkaScreen({super.key});

  @override
  State<PushkaScreen> createState() => _PushkaScreenState();
}

class _PushkaScreenState extends State<PushkaScreen> {
  double pushkaAmount = 0;

  void addAmount(double amount) {
    setState(() {
      pushkaAmount += amount;
    });
  }

  void emptyPushka() {
    setState(() {
      pushkaAmount = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Text(
              'My Pushka',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),

            // Pushka "visual"
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '\$${pushkaAmount.toStringAsFixed(2)}',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Placeholder “pushka”
                    Container(
                      width: 180,
                      height: 240,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.grey.shade400),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'PUSHKA\n(placeholder)',
                        textAlign: TextAlign.center,
                      ),
                    )
                        // mini “shake” animation each rebuild (por ahora simple)
                        .animate()
                        .shake(duration: 250.ms, hz: 3, offset: const Offset(3, 0)),
                  ],
                ),
              ),
            ),

            // Preset buttons
            Row(
              children: [
                _amountButton('\$1', () => addAmount(1)),
                const SizedBox(width: 10),
                _amountButton('\$5', () => addAmount(5)),
                const SizedBox(width: 10),
                _amountButton('\$10', () => addAmount(10)),
                const SizedBox(width: 10),
                _amountButton('OTHER', _otherAmount),
              ],
            ),

            const SizedBox(height: 14),

            // Bottom actions
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      // por ahora solo demo
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Donate Now (demo)')),
                      );
                    },
                    child: const Text('DONATE NOW'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: emptyPushka,
                    child: const Text('EMPTY PUSHKA'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Expanded _amountButton(String label, VoidCallback onTap) {
    return Expanded(
      child: OutlinedButton(
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }

  Future<void> _otherAmount() async {
    final controller = TextEditingController();

    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Other amount'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: 'e.g. 12.50'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = double.tryParse(controller.text.replaceAll(',', '.'));
              if (value == null || value <= 0) return;
              Navigator.pop(context, value);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != null) addAmount(result);
  }
}
