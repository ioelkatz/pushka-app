import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/app_version.dart';
import '../../../core/l10n/s.dart';
import '../../pushka/presentation/building_770_widget.dart';
import '../../tenant/data/tenant_repository.dart';

// Audit Round 4 BUG-001/011: previously hardcoded `jymmexico@gmail.com`
// + branding "Colel Chabad / Jabad en Campus" — broken for any tenant
// other than Jabad en Campus. Now reads tenant.appName/name +
// tenant.contactEmail/Phone from tenantConfigProvider with a Pushka
// fallback so the support screen stays multi-tenant correct.
const String _fallbackSupportEmail = 'support@pushkaapp.com';
// Note: "Conoce más" link is hidden when the tenant has no privacyPolicyUrl
// configured (instead of falling back to a hardcoded URL). When the rab
// publishes his org's site, set it in the admin web → Branding → "URL de
// privacidad" and the link appears automatically.

class SupportScreen extends ConsumerWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Fixed link color: sky blue in dark mode (same as toggles), platform blue in light mode.
    // NOT derived from tenant primaryColor so it can't be overridden by branding.
    final linkColor = isDark ? const Color(0xFF60A5FA) : AppTokens.primaryBlue;

    final tenantConfig = ref.watch(tenantConfigProvider).valueOrNull;
    final brandName = tenantConfig?.appName.isNotEmpty == true
        ? tenantConfig!.appName
        : (tenantConfig?.name.isNotEmpty == true ? tenantConfig!.name : tr.colelJabad);
    final supportEmail = tenantConfig?.contactEmail ?? _fallbackSupportEmail;
    final supportPhone = tenantConfig?.contactPhone;
    // null when the tenant has no public URL configured — the "Conoce más"
    // link is hidden in that case (previously fell back to pushkapp.cc which
    // didn't exist, generating 404s).
    final learnMoreUrl = (tenantConfig?.privacyPolicyUrl != null &&
            tenantConfig!.privacyPolicyUrl!.isNotEmpty)
        ? tenantConfig.privacyPolicyUrl!
        : null;
    // city/country were previously rendered here (BUG-005 fix). Ioel
    // requested removing the location line from the support screen — the
    // fields stay in the admin web (for internal use / future features)
    // but the donor-facing screen no longer surfaces them.

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 12),

          // Branding header — uses tenant brand instead of hardcoded "Jabad en Campus"
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                brandName,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: cs.onSurface, letterSpacing: 0.5),
              ),
              const SizedBox(height: 4),
              Text(
                tr.tagline1788,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant, fontWeight: FontWeight.w400),
              ),
              const SizedBox(height: 16),
              // Tenant logo if available, otherwise fallback to the bundled
              // Jabad en Campus rab photo (default tenant identity).
              if (tenantConfig?.logoUrl != null && tenantConfig!.logoUrl!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    tenantConfig.logoUrl!,
                    height: 112,
                    fit: BoxFit.contain,
                    // Decode at 2x the 112px display size for retina crispness
                    // without holding a full-resolution logo (some tenant
                    // logos ship at 2000px+) in memory.
                    cacheWidth: 224,
                    cacheHeight: 224,
                    errorBuilder: (_, _, _) => _defaultRabHeader(),
                  ),
                )
              else
                _defaultRabHeader(),
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
            ref
                .watch(appVersionProvider)
                .maybeWhen(data: (v) => v, orElse: () => ''),
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

          // Email — dynamic per tenant
          InkWell(
            onTap: () => _launchSafe(context, Uri.parse('mailto:$supportEmail')),
            child: Text(
              supportEmail,
              style: TextStyle(fontSize: 16, color: linkColor),
            ),
          ),

          if (supportPhone != null && supportPhone.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _launchSafe(
                context,
                Uri.parse('tel:${supportPhone.replaceAll(RegExp(r'[^+0-9]'), '')}'),
              ),
              child: Text(
                supportPhone,
                style: TextStyle(fontSize: 16, color: linkColor),
              ),
            ),
          ],


          const SizedBox(height: 32),

          // Learn More Link — only rendered when the tenant has a public
          // privacyPolicyUrl set. Label uses the brand resolved above so a
          // non-Jabad tenant doesn't see "Learn more about Chabad on Campus".
          if (learnMoreUrl != null)
            InkWell(
              onTap: () => _launchSafe(
                context,
                Uri.parse(learnMoreUrl),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(
                tr.learnMoreAbout(brandName),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: linkColor),
              ),
            ),

          const SizedBox(height: 32),

          // Developer Section — always Pushka (constant)
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
            style: GoogleFonts.ibmPlexSans(
              fontSize: 18,
              fontWeight: FontWeight.w300,
              color: cs.onSurface,
            ),
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _defaultRabHeader() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset(
        'assets/images/mendy_meer.png',
        height: 112,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
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
}
