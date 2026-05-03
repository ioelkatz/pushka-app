import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';

class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final red = isDark ? cs.primary : const Color(0xFFE05A4F);
    const green = Color(0xFF25D366);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 12),

          // Logo y branding de Colel Jabad
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 360;
              final textBlock = Column(
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
                  // Colel Jabad
                  Text(
                    tr.colelJabad,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Tagline
                  Text(
                    tr.tagline1788,
                    style: TextStyle(
                      fontSize: 14,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              );

              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    textBlock,
                    const SizedBox(height: 16),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: _buildPushkaIllustration(),
                    ),
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: textBlock),
                  const SizedBox(width: 16),
                  _buildPushkaIllustration(),
                ],
              );
            },
          ),

          const SizedBox(height: 32),

          // App Version
          Text(
            tr.appVersionSection,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppTokens.appVersion,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),

          const SizedBox(height: 28),

          // Support Section
          Text(
            tr.supportSection,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 16),

          // Email
          InkWell(
            onTap: () => _launchEmail(context),
            child: Text(
              'app@colelchabad.org',
              style: TextStyle(
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
                onTap: () => _launchPhone(context),
                child: Text(
                  '+1 (718) 774-5446',
                  style: TextStyle(
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
            onTap: () => _launchWhatsApp(context),
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

          const SizedBox(height: 32),

          // Learn More Link
          InkWell(
            onTap: () => _launchLearnMore(context),
            child: Text(
              tr.learnMoreColel,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: cs.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),

          const SizedBox(height: 32),

          // Developer Section
          Text(
            tr.developedBy,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: cs.onSurface,
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
              Text(
                'GorinSystems',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
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

  Future<void> _launchSafe(BuildContext context, Uri uri,
      {LaunchMode mode = LaunchMode.platformDefault}) async {
    final tr = S.of(context);
    try {
      final ok = await launchUrl(uri, mode: mode);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr.couldNotOpenLink)),
        );
      }
    } on PlatformException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr.errorWithMessage(e.message ?? ''))));
      }
    }
  }

  Future<void> _launchEmail(BuildContext context) async {
    await _launchSafe(context, Uri.parse('mailto:app@colelchabad.org'));
  }

  Future<void> _launchPhone(BuildContext context) async {
    await _launchSafe(context, Uri.parse('tel:+17187745446'));
  }

  Future<void> _launchWhatsApp(BuildContext context) async {
    await _launchSafe(context, Uri.parse('https://wa.me/17187745446'),
        mode: LaunchMode.externalApplication);
  }

  Future<void> _launchLearnMore(BuildContext context) async {
    await _launchSafe(context, Uri.parse('https://www.colelchabad.org'),
        mode: LaunchMode.externalApplication);
  }
}
