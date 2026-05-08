import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../data/legal_content.dart';

/// In-app Privacy Policy + Terms of Service. Single scrollable page with
/// both documents stacked. Initial scroll target ("privacy" or "terms")
/// determined by the `section` constructor argument so the About row "Privacy"
/// lands the donor at the top of the privacy section, while "Terms" jumps
/// straight to the Terms heading further down. Back arrow returns to About.
///
/// Content lives in `legal_content.dart` (4 languages). NOT pulled from the
/// network — having it in-app means stores reviewers see the actual text we
/// promised in the listing without depending on a public website. Content can
/// only change with an app update, which is the right cadence for legal text.
class LegalScreen extends ConsumerStatefulWidget {
  const LegalScreen({super.key, this.section = LegalSectionTarget.privacy});

  final LegalSectionTarget section;

  @override
  ConsumerState<LegalScreen> createState() => _LegalScreenState();
}

enum LegalSectionTarget { privacy, terms }

class _LegalScreenState extends ConsumerState<LegalScreen> {
  final _scrollController = ScrollController();
  final _privacyAnchor = GlobalKey();
  final _termsAnchor = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Scroll after first frame so the GlobalKey contexts are mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.section == LegalSectionTarget.terms) {
        _scrollTo(_termsAnchor);
      }
      // Privacy is at the top by default; no scroll needed.
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollTo(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final lang = (profile?['language'] as String?) ?? 'es';
    final content = legalContentFor(lang);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.legalTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        ),
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Quick-jump pills so the donor can land on either section
            // without scrolling. Mirrors the section anchors we registered.
            Row(
              children: [
                Expanded(
                  child: _JumpPill(
                    label: tr.privacyPolicy,
                    icon: Icons.privacy_tip_outlined,
                    onTap: () => _scrollTo(_privacyAnchor),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _JumpPill(
                    label: tr.termsOfService,
                    icon: Icons.description_outlined,
                    onTap: () => _scrollTo(_termsAnchor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ─── Privacy ─────────────────────────────────────────────────
            Container(key: _privacyAnchor),
            _DocView(doc: content.privacy),

            const SizedBox(height: 40),
            Divider(color: cs.outline.withValues(alpha: 0.4), height: 32),
            const SizedBox(height: 8),

            // ─── Terms ───────────────────────────────────────────────────
            Container(key: _termsAnchor),
            _DocView(doc: content.terms),

            const SizedBox(height: 40),
            // Disclosure: in-app text is the canonical version. Donors who
            // need a printed copy get a clear pointer to email support.
            Center(
              child: Text(
                tr.legalContactFooter,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JumpPill extends StatelessWidget {
  const _JumpPill({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Static color (not tied to tenant primaryColor) so the legal page reads
    // as a Pushka surface, not a tenant-branded one. Light mode → app blue,
    // dark mode → sky blue (matches the rest of the app's accent system).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppTokens.skyBlue : AppTokens.primaryBlue;
    return Material(
      color: accent.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DocView extends StatelessWidget {
  const _DocView({required this.doc});
  final LegalDoc doc;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          doc.title,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          doc.lastUpdated,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          doc.intro,
          style: TextStyle(
            fontSize: 15,
            height: 1.6,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 24),
        ...doc.sections.map((s) => _SectionView(section: s)),
      ],
    );
  }
}

class _SectionView extends StatelessWidget {
  const _SectionView({required this.section});
  final LegalSection section;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          ...section.paragraphs.map(
            (p) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                p,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.6,
                  color: cs.onSurface.withValues(alpha: 0.92),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
