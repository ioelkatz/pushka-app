import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/router.dart';
import '../../../core/l10n/s.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../data/tenant_repository.dart';
import '../domain/tenant_config.dart';
import '../domain/tenant_summary.dart';

/// Provider that loads the discoverable tenant list once and caches it.
final _discoverableTenantsProvider = FutureProvider<List<TenantSummary>>((ref) {
  return ref.read(tenantRepositoryProvider).listDiscoverable();
});

class TenantCodeScreen extends ConsumerStatefulWidget {
  const TenantCodeScreen({super.key});

  @override
  ConsumerState<TenantCodeScreen> createState() => _TenantCodeScreenState();
}

class _TenantCodeScreenState extends ConsumerState<TenantCodeScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  bool _joining = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _joinTenant(String tenantId) async {
    setState(() => _joining = true);
    try {
      final repo = ref.read(tenantRepositoryProvider);
      await repo.joinTenant(tenantId);
      // Auto-switch the active tenant to the one the user just joined.
      // Without this, the user is added to `tenantIds` but the active
      // `tenantId` stays on whatever tenant they were previously in — they
      // would have to manually open the account switcher and pick the new
      // org, which makes "join" feel like it didn't do anything from the
      // home screen perspective. switchTenant is a no-op idempotent if the
      // user is already active on this tenant (e.g. first-ever join makes
      // it active automatically), so the extra call is safe.
      try {
        await repo.switchTenant(tenantId);
      } catch (e) {
        // Switch failure is non-fatal: the join succeeded, the user can
        // switch manually from the account-switcher sheet. Log so we can
        // diagnose if this becomes a chronic issue.
        debugPrint('joinTenant: auto-switch to $tenantId failed: $e');
      }
      ref.invalidate(tenantConfigProvider);
      ref.invalidate(tenantStateProvider);
      ref.invalidate(userTenantSummariesProvider);
      ref.invalidate(userProfileProvider);
      invalidateTenantCache();
      if (mounted) context.go('/');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).tenantJoinFailed),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _openCodeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _InviteCodeSheet(
        onJoin: _joinTenant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final tenantsAsync = ref.watch(_discoverableTenantsProvider);

    final filtered = tenantsAsync.maybeWhen(
      data: (list) {
        if (_query.isEmpty) return list;
        final q = _query.toLowerCase().trim();
        return list.where((t) => t.searchHaystack.contains(q)).toList();
      },
      orElse: () => const <TenantSummary>[],
    );

    return Scaffold(
      backgroundColor: AppTokens.surface,
      body: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.spaceXl,
                    AppTokens.spaceXl,
                    AppTokens.spaceXl,
                    AppTokens.spaceLg,
                  ),
                  sliver: SliverList.list(
                    children: [
                      Text(
                        'Bienvenido a Pushka',
                        style: tt.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTokens.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppTokens.spaceSm),
                      Text(
                        'Encontrá tu organización para empezar.',
                        style: tt.bodyMedium?.copyWith(
                          color: AppTokens.mutedText,
                        ),
                      ),
                      const SizedBox(height: AppTokens.spaceXl),
                      _SearchField(
                        controller: _searchController,
                        onChanged: (v) => setState(() => _query = v),
                      ),
                      const SizedBox(height: AppTokens.spaceMd),
                    ],
                  ),
                ),
                tenantsAsync.when(
                  loading: () => const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(AppTokens.spaceXl),
                      child: _ErrorBlock(
                        message: 'No pudimos cargar las organizaciones.',
                        onRetry: () => ref.invalidate(_discoverableTenantsProvider),
                      ),
                    ),
                  ),
                  data: (_) {
                    if (filtered.isEmpty) {
                      return SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppTokens.spaceXl,
                            vertical: AppTokens.spaceXl * 2,
                          ),
                          child: _EmptyResults(query: _query),
                        ),
                      );
                    }
                    return SliverList.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const Divider(
                        height: 1,
                        thickness: 1,
                        color: AppTokens.border,
                        indent: AppTokens.spaceXl,
                        endIndent: AppTokens.spaceXl,
                      ),
                      itemBuilder: (_, i) => _TenantTile(
                        tenant: filtered[i],
                        onTap: _joining ? null : () => _confirmJoin(filtered[i]),
                      ),
                    );
                  },
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.spaceXl,
                      AppTokens.spaceXl * 1.5,
                      AppTokens.spaceXl,
                      AppTokens.spaceXl,
                    ),
                    child: Column(
                      children: [
                        const Divider(color: AppTokens.border, thickness: 1),
                        const SizedBox(height: AppTokens.spaceLg),
                        Text(
                          '¿Tenés un código de invitación?',
                          style: tt.bodyMedium?.copyWith(
                            color: AppTokens.mutedText,
                          ),
                        ),
                        const SizedBox(height: AppTokens.spaceSm),
                        TextButton(
                          onPressed: _joining ? null : _openCodeSheet,
                          child: Text(S.of(context).tenantEnterCode),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (_joining)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x66FFFFFF),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmJoin(TenantSummary tenant) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _JoinConfirmSheet(tenant: tenant),
    );
    if (ok == true) {
      await _joinTenant(tenant.tenantId);
    }
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autocorrect: false,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Buscá tu organización',
        prefixIcon: const Icon(Icons.search_rounded, color: AppTokens.mutedText),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, color: AppTokens.mutedText),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: AppTokens.cardSilver,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: AppTokens.spaceMd,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          borderSide: BorderSide(color: AppTokens.primaryBlue, width: 1.5),
        ),
      ),
    );
  }
}

class _TenantTile extends StatelessWidget {
  const _TenantTile({required this.tenant, required this.onTap});

  final TenantSummary tenant;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final hasLocation = tenant.locationLabel.isNotEmpty;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceXl,
          vertical: AppTokens.spaceLg,
        ),
        child: Row(
          children: [
            _Logo(tenant: tenant, size: 44),
            const SizedBox(width: AppTokens.spaceLg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tenant.appName.isNotEmpty ? tenant.appName : tenant.name,
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppTokens.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hasLocation) ...[
                    const SizedBox(height: 2),
                    Text(
                      tenant.locationLabel,
                      style: tt.bodySmall?.copyWith(color: AppTokens.mutedText),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppTokens.mutedText,
            ),
          ],
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.tenant, required this.size});

  final TenantSummary tenant;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bg = tenant.primaryColor ?? AppTokens.primaryBlue;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size / 4.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: tenant.logoUrl != null
          ? Image.network(
              tenant.logoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _LogoFallback(name: tenant.name, size: size),
            )
          : _LogoFallback(name: tenant.name, size: size),
    );
  }
}

class _LogoFallback extends StatelessWidget {
  const _LogoFallback({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return Center(
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Column(
      children: [
        const Icon(Icons.search_off_rounded, size: 48, color: AppTokens.mutedText),
        const SizedBox(height: AppTokens.spaceMd),
        Text(
          query.isEmpty
              ? 'Todavía no hay organizaciones disponibles.'
              : 'No encontramos organizaciones para "$query".',
          textAlign: TextAlign.center,
          style: tt.bodyMedium?.copyWith(color: AppTokens.mutedText),
        ),
      ],
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Column(
      children: [
        const Icon(Icons.cloud_off_rounded, size: 48, color: AppTokens.mutedText),
        const SizedBox(height: AppTokens.spaceMd),
        Text(
          message,
          style: tt.bodyMedium?.copyWith(color: AppTokens.mutedText),
        ),
        const SizedBox(height: AppTokens.spaceLg),
        OutlinedButton(onPressed: onRetry, child: Text(S.of(context).retry)),
      ],
    );
  }
}

class _JoinConfirmSheet extends StatelessWidget {
  const _JoinConfirmSheet({required this.tenant});

  final TenantSummary tenant;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      decoration: const BoxDecoration(
        color: AppTokens.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.radiusXl)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceXl,
        AppTokens.spaceLg,
        AppTokens.spaceXl,
        AppTokens.spaceXl,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTokens.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppTokens.spaceXl),
            _Logo(tenant: tenant, size: 64),
            const SizedBox(height: AppTokens.spaceLg),
            Text(
              tenant.appName.isNotEmpty ? tenant.appName : tenant.name,
              style: tt.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppTokens.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            if (tenant.locationLabel.isNotEmpty) ...[
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                tenant.locationLabel,
                style: tt.bodyMedium?.copyWith(color: AppTokens.mutedText),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: AppTokens.spaceXl),
            SizedBox(
              width: double.infinity,
              height: AppTokens.buttonHeight,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(S.of(context).tenantJoin),
              ),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(S.of(context).tenantCancel),
            ),
          ],
        ),
      ),
    );
  }
}

class _InviteCodeSheet extends ConsumerStatefulWidget {
  const _InviteCodeSheet({required this.onJoin});

  final Future<void> Function(String tenantId) onJoin;

  @override
  ConsumerState<_InviteCodeSheet> createState() => _InviteCodeSheetState();
}

class _InviteCodeSheetState extends ConsumerState<_InviteCodeSheet> {
  final _controller = TextEditingController();
  bool _loading = false;
  TenantConfig? _preview;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _validate() async {
    final slug = _controller.text.trim().toLowerCase();
    if (slug.isEmpty) return;
    setState(() { _loading = true; _error = null; _preview = null; });
    try {
      final config = await ref.read(tenantRepositoryProvider).validateSlug(slug);
      setState(() => _preview = config);
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _error = e.code == 'not-found'
            ? 'Código no encontrado. Verificá que sea correcto.'
            : 'Error al validar el código. Intentá de nuevo.';
      });
    } catch (_) {
      setState(() => _error = 'Error al validar el código. Intentá de nuevo.');
    } finally {
      setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Container(
      decoration: const BoxDecoration(
        color: AppTokens.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.radiusXl)),
      ),
      padding: EdgeInsets.fromLTRB(
        AppTokens.spaceXl,
        AppTokens.spaceLg,
        AppTokens.spaceXl,
        AppTokens.spaceXl + viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTokens.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceXl),
            Text(
              'Código de invitación',
              style: tt.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppTokens.textPrimary,
              ),
            ),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              'Tu administrador te lo compartió por mensaje o link.',
              style: tt.bodySmall?.copyWith(color: AppTokens.mutedText),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            TextField(
              controller: _controller,
              autofocus: true,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _validate(),
              onChanged: (_) {
                if (_preview != null || _error != null) {
                  setState(() { _preview = null; _error = null; });
                }
              },
              decoration: InputDecoration(
                labelText: 'Código',
                hintText: 'ej: chabadmexico',
                errorText: _error,
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            if (_preview == null)
              SizedBox(
                height: AppTokens.buttonHeight,
                child: ElevatedButton(
                  onPressed: _loading ? null : _validate,
                  child: _loading
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(S.of(context).tenantSearch),
                ),
              )
            else ...[
              _PreviewCard(config: _preview!),
              const SizedBox(height: AppTokens.spaceLg),
              SizedBox(
                height: AppTokens.buttonHeight,
                child: ElevatedButton(
                  onPressed: _loading
                      ? null
                      : () async {
                          setState(() => _loading = true);
                          final nav = Navigator.of(context);
                          await widget.onJoin(_preview!.tenantId);
                          if (!mounted) return;
                          nav.pop();
                        },
                  child: Text(S.of(context).tenantJoin),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.config});

  final TenantConfig config;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      decoration: BoxDecoration(
        color: AppTokens.cardSilver,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: config.primaryColor ?? AppTokens.primaryBlue,
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: (config.logoUrl != null && config.logoUrl!.isNotEmpty)
                ? Image.network(config.logoUrl!, fit: BoxFit.cover,
                    errorBuilder: (ctx, err, st) => const Icon(
                      Icons.business_rounded, color: Colors.white, size: 26,
                    ))
                : const Icon(Icons.business_rounded, color: Colors.white, size: 26),
          ),
          const SizedBox(width: AppTokens.spaceLg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  config.appName,
                  style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTokens.textPrimary,
                  ),
                ),
                if (config.name.isNotEmpty && config.name != config.appName)
                  Text(
                    config.name,
                    style: tt.bodySmall?.copyWith(color: AppTokens.mutedText),
                  ),
              ],
            ),
          ),
          Icon(Icons.check_circle_rounded, color: AppTokens.success, size: 24),
        ],
      ),
    );
  }
}
