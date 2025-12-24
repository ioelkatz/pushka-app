import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE05A4F);
    const green = Color(0xFF25D366); // Color de WhatsApp

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 20),

          // Logo y branding de Colel Chabad
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Texto principal
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Texto hebreo
                  const Text(
                    'צדקת רבי מאיר בעל הנס',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.right,
                  ),
                  const SizedBox(height: 4),
                  // Colel Chabad
                  const Text(
                    'Colel Chabad',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Tagline
                  Text(
                    'Cuidando a los necesitados de Israel desde 1788',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              // Ilustración de Pushka
              _buildPushkaIllustration(),
            ],
          ),

          const SizedBox(height: 40),

          // App Version
          const Text(
            'VERSIÓN DE LA APP',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '3.3.1',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),

          const SizedBox(height: 32),

          // Support Section
          const Text(
            'SOPORTE',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 16),

          // Email
          InkWell(
            onTap: () => _launchEmail(),
            child: Text(
              'app@colelchabad.org',
              style: const TextStyle(
                fontSize: 16,
                color: red,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Phone
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(
                onTap: () => _launchPhone(),
                child: Text(
                  '+1 (718) 774-5446',
                  style: const TextStyle(
                    fontSize: 16,
                    color: red,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // WhatsApp Icon
          InkWell(
            onTap: () => _launchWhatsApp(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: green,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.chat,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),

          const SizedBox(height: 40),

          // Learn More Link
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: () => _launchLearnMore(),
              child: const Text(
                'Aprende más sobre Colel Chabad y la Pushka de Colel Chabad.',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),

          const SizedBox(height: 40),

          // Developer Section
          const Text(
            'DESARROLLADO POR',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 16),

          // GorinSystems Logo
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo S estilizado
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF6B46C1), // Púrpura
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Center(
                  child: Text(
                    'S',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'GorinSystems',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildPushkaIllustration() {
    return Container(
      width: 60,
      height: 80,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300, width: 1),
      ),
      child: Stack(
        children: [
          // Cuerpo de la pushka
          Positioned(
            bottom: 0,
            left: 8,
            right: 8,
            child: Container(
              height: 60,
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
                border: Border.all(color: Colors.grey.shade300, width: 1.5),
              ),
              child: Stack(
                children: [
                  // Ranura en la parte superior
                  Positioned(
                    top: 4,
                    left: 12,
                    right: 12,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade500,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Texto hebreo "צדקה" vertical con colores
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildColoredLetter('צ', Colors.blue),
                        _buildColoredLetter('ד', Colors.yellow.shade700),
                        _buildColoredLetter('ק', Colors.orange),
                        _buildColoredLetter('ה', Colors.red),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Tapa superior
          Positioned(
            top: 0,
            left: 10,
            right: 10,
            child: Container(
              height: 12,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColoredLetter(String letter, Color color) {
    return Text(
      letter,
      style: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w700,
        color: color,
        height: 0.9,
      ),
      textDirection: TextDirection.rtl,
    );
  }

  Future<void> _launchEmail() async {
    final uri = Uri.parse('mailto:app@colelchabad.org');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _launchPhone() async {
    final uri = Uri.parse('tel:+17187745446');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _launchWhatsApp() async {
    final uri = Uri.parse('https://wa.me/17187745446');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _launchLearnMore() async {
    final uri = Uri.parse('https://www.colelchabad.org');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
