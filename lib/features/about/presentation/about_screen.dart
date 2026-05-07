import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/l10n/s.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),

          Text(
            tr.aboutTitle,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
              letterSpacing: 0.5,
            ),
          ),

          const SizedBox(height: 18),

          // Párrafo 1
          Text(
            tr.aboutP1,
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: cs.onSurface,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 20),

          // Párrafo 2
          Text(
            tr.aboutP2,
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: cs.onSurface,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 20),

          // Párrafo 3
          Text(
            tr.aboutP3,
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: cs.onSurface,
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
                color: cs.onSurfaceVariant,
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
    return Semantics(
      button: true,
      link: true,
      label: label,
      child: InkWell(
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
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
