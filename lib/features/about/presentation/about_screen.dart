import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),

          // Breadcrumb
          Text(
            'Acerca de | Colel Chabad',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 32),

          // Título principal
          const Text(
            'Colel Chabad',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
              letterSpacing: 0.5,
            ),
          ),

          const SizedBox(height: 32),

          // Sección "Acerca de"
          const Text(
            'Acerca de',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),

          const SizedBox(height: 24),

          // Párrafo 1
          const Text(
            'Bienvenido a Colel Chabad. Somos la organización benéfica en funcionamiento continuo más antigua de Israel, dedicada a brindar asistencia a quienes la necesitan sin importar su origen.',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: Colors.black87,
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
              color: Colors.black87,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 20),

          // Párrafo 3
          const Text(
            'Desde nuestra fundación en 1788, Colel Chabad ha expandido sus servicios en todo Israel, operando bancos de alimentos, comedores comunitarios, programas de asistencia médica y más.',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: Colors.black87,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 40),

          // Copyright
          Center(
            child: Text(
              '© 2025 Colel Chabad. Todos los derechos reservados.',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
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
