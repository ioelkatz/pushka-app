import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../pushka/presentation/building_770_widget.dart';

class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Fixed link color: sky blue in dark mode (same as toggles), platform blue in light mode.
    // NOT derived from tenant primaryColor so it can't be overridden by branding.
    final linkColor = isDark ? const Color(0xFF60A5FA) : AppTokens.primaryBlue;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 12),

          // Branding header
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr.colelJabad,
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: cs.onSurface, letterSpacing: 0.5),
              ),
              const SizedBox(height: 4),
              Text(
                tr.tagline1788,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant, fontWeight: FontWeight.w400),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  'assets/images/mendy_meer.png',
                  height: 112,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                ),
              ),
              const SizedBox(height: 40),
              const Center(
                child: SizedBox(width: 80, height: 80, child: Building770Widget(fillFraction: 0)),
              ),
            ],
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
              'jymmexico@gmail.com',
              style: TextStyle(fontSize: 16, color: linkColor),
            ),
          ),

          const SizedBox(height: 32),

          // Learn More Link
          InkWell(
            onTap: () => _launchLearnMore(context),
            child: Text(
              tr.learnMoreColel,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: linkColor),
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
          const SizedBox(height: 12),
          Text(
            'Ioel Katz',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),

          const SizedBox(height: 20),
        ],
      ),
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
    await _launchSafe(context, Uri.parse('mailto:jymmexico@gmail.com'));
  }

  Future<void> _launchLearnMore(BuildContext context) async {
    await _launchSafe(context, Uri.parse('https://jabad.mx'),
        mode: LaunchMode.externalApplication);
  }
}
