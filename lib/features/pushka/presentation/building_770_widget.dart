import 'package:flutter/material.dart';

class Building770Widget extends StatelessWidget {
  final double fillFraction; // 0.0 – 1.0 (reserved for future fill animation)

  const Building770Widget({super.key, required this.fillFraction});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/building_770.png',
      fit: BoxFit.contain,
    );
  }
}
