import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_version.dart';
import '../../../core/l10n/s.dart';
import '../../legal/presentation/legal_screen.dart';
import '../../tenant/data/tenant_repository.dart';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    // Round-5 audit HIGH fix: use tenant appName instead of hardcoded
    // "Jabad en Campus" brand in the copyright line.
    final tenantAppName =
        ref.watch(tenantConfigProvider).valueOrNull?.appName ?? tr.colelJabad;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 18),

          // Párrafo 1
          Text(
            tr.aboutP1,
            textAlign: TextAlign.center,
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
            textAlign: TextAlign.center,
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
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: cs.onSurface,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 30),

          // Legal links — open the in-app LegalScreen scrolled to the right
          // anchor. Both rows route to the same screen; `section` only changes
          // the initial scroll target so "Privacy" lands at the top and
          // "Terms" jumps straight to the Terms heading.
          _LegalLink(
            icon: Icons.privacy_tip_outlined,
            label: tr.privacyPolicy,
            section: LegalSectionTarget.privacy,
          ),
          const SizedBox(height: 12),
          _LegalLink(
            icon: Icons.description_outlined,
            label: tr.termsOfService,
            section: LegalSectionTarget.terms,
          ),
          const SizedBox(height: 30),

          // Copyright — parameterized on tenant brand (Round-5 audit fix).
          Center(
            child: Text(
              tr.copyrightFor(tenantAppName),
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),

          const SizedBox(height: 6),

          // Versión instalada. Discreta, pero imprescindible en sideload para
          // poder preguntar "¿qué versión tenés?" y que la respuesta sirva.
          Center(
            child: Text(
              ref
                  .watch(appVersionProvider)
                  .maybeWhen(data: (v) => tr.versionLabel(v), orElse: () => ''),
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
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
  const _LegalLink({
    required this.icon,
    required this.label,
    required this.section,
  });
  final IconData icon;
  final String label;
  final LegalSectionTarget section;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          // In-app navigation (rootNavigator: true) so the legal screen takes
          // over with its own AppBar + back arrow that returns to About.
          // Goes through the root navigator to escape any nested nav stacks.
          Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(builder: (_) => LegalScreen(section: section)),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
