import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/l10n/s.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),

          // Breadcrumb
          Text(
            tr.aboutBreadcrumb,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 24),

          // Título principal
          Text(
            tr.aboutTitle,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
              letterSpacing: 0.5,
            ),
          ),

          const SizedBox(height: 26),

          // Sección "Acerca de"
          Text(
            tr.aboutSection,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),

          const SizedBox(height: 18),

          // Párrafo 1
          Text(
            tr.aboutP1,
            style: const TextStyle(
              fontSize: 16,
              height: 1.6,
              color: Colors.black87,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 20),

          // Párrafo 2
          Text(
            tr.aboutP2,
            style: const TextStyle(
              fontSize: 16,
              height: 1.6,
              color: Colors.black87,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 20),

          // Párrafo 3
          Text(
            tr.aboutP3,
            style: const TextStyle(
              fontSize: 16,
              height: 1.6,
              color: Colors.black87,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 30),

          // Legal links
          _LegalLink(
            icon: Icons.privacy_tip_outlined,
            label: tr.privacyPolicy,
            url: 'https://www.pushkaapp.com/privacy',
          ),
          const SizedBox(height: 12),
          _LegalLink(
            icon: Icons.description_outlined,
            label: tr.termsOfService,
            url: 'https://www.pushkaapp.com/terms',
          ),
          const SizedBox(height: 30),

          // Copyright
          Center(
            child: Text(
              tr.copyright,
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

class _LegalLink extends StatelessWidget {
  const _LegalLink({required this.icon, required this.label, required this.url});
  final IconData icon;
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final uri = Uri.parse(url);
        try {
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        } catch (_) {}
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF2563EB)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A1A),
                ),
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 20),
          ],
        ),
      ),
    );
  }
}
