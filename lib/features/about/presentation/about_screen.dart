import 'package:flutter/material.dart';
import '../../../app/theme/app_tokens.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),

          // Breadcrumb
          Text(
            'Acerca de | Colel Jabad',
            style: TextStyle(
              fontSize: 13,
              color: AppTokens.mutedText,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 24),

          // Título principal
          const Text(
            'Colel Jabad',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: AppTokens.textPrimary,
              letterSpacing: 0.5,
            ),
          ),

          const SizedBox(height: 26),

          // Sección "Acerca de"
          const Text(
            'Acerca de',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppTokens.textPrimary,
            ),
          ),

          const SizedBox(height: 18),

          // Párrafo 1
          const Text(
            'Bienvenido a Colel Jabad. Somos la organización benéfica en funcionamiento continuo más antigua de Israel, dedicada a brindar asistencia a quienes la necesitan sin importar su origen.',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: AppTokens.textPrimary,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 20),

          // Párrafo 2
          const Text(
            'Nuestra misión es alimentar a los hambrientos, apoyar a viudas y huérfanos, y elevar comunidades a través de una variedad de programas arraigados en los valores atemporales de compasión y dignidad.',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: AppTokens.textPrimary,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 20),

          // Párrafo 3
          const Text(
            'Desde nuestra fundación en 1788, Colel Jabad ha expandido sus servicios en todo Israel, operando bancos de alimentos, comedores comunitarios, programas de asistencia médica y más.',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: AppTokens.textPrimary,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 30),

          // Copyright
          Center(
            child: Text(
              '© 2025 Colel Jabad. Todos los derechos reservados.',
              style: TextStyle(
                fontSize: 14,
                color: AppTokens.mutedText,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}