import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../core/l10n/s.dart';
import '../../auth/providers/auth_controller.dart';
import '../../users/presentation/user_profile_provider.dart';
import '../data/tenant_repository.dart';
import '../domain/tenant_config.dart';
import 'tenant_switch_reset.dart';

class JoinViaLinkScreen extends ConsumerStatefulWidget {
  const JoinViaLinkScreen({super.key, required this.slug});

  final String slug;

  @override
  ConsumerState<JoinViaLinkScreen> createState() => _JoinViaLinkScreenState();
}

class _JoinViaLinkScreenState extends ConsumerState<JoinViaLinkScreen> {
  _State _state = const _Loading();

  @override
  void initState() {
    super.initState();
    _validate();
  }

  Future<void> _validate() async {
    setState(() => _state = const _Loading());
    final tr = S.of(context);
    try {
      final config = await ref.read(tenantRepositoryProvider).validateSlug(widget.slug);
      if (!mounted) return;
      setState(() => _state = _Preview(config));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _state = _Error(
        e.code == 'not-found'
            ? tr.tenantSlugNotFound(widget.slug)
            : tr.tenantSlugVerifyError,
      ));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _Error(tr.tenantSlugVerifyError));
    }
  }

  Future<void> _join(TenantConfig config) async {
    final tr = S.of(context);
    // Snapshot BEFORE the first await so we don't cross a BuildContext over
    // an async gap. ProviderContainer is owned by the root ProviderScope and
    // survives even if this widget disposes mid-flow.
    final container = ProviderScope.containerOf(context);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final outgoingTenantId = container
        .read(userProfileProvider)
        .valueOrNull?['tenantId'] as String?;
    setState(() => _state = const _Joining());
    // Round-9 regression fix (LOW #3): split join vs switch so a
    // switchTenant failure after a successful joinTenant doesn't leave
    // the user membership-in-limbo (joined but still pointing at the old
    // active tenant, with no snackbar hint that switching failed).
    final repo = ref.read(tenantRepositoryProvider);
    try {
      await repo.joinTenant(config.tenantId);
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _Preview(config));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.tenantJoinFailed)),
      );
      return;
    }
    try {
      await repo.switchTenant(config.tenantId);
      // Round-2 audit fix: shared reset — invalidates userProfile / history /
      // transactions providers too so the History tab doesn't briefly show
      // the previous tenant's rows after the redirect to "/".
      await resetTenantScopedState(
        container,
        uid: uid,
        outgoingTenantId: outgoingTenantId,
      );
      invalidateTenantCache();
      if (!mounted) return;
      context.go('/');
    } catch (_) {
      // Join succeeded, switch failed. Membership is persisted server-side
      // so the user can activate it later from the account switcher —
      // don't roll back the join, just tell them clearly and go home.
      if (!mounted) return;
      setState(() => _state = _Preview(config));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.tenantJoinedSwitchFailed)),
      );
    }
  }

  /// Escotilla de salida. En el dominio productivo el redirect del router
  /// manda a `/join/<slug>` a todo usuario sin tenant, asi que "Cancelar" e "Ir
  /// al inicio" rebotaban contra esta misma pantalla y no habia forma de
  /// salir sin borrar los datos del navegador. Audit de producto 2026-09-04.
  ///
  /// Va por authController y no por FirebaseAuth.instance directo, para que se
  /// revoque el token de notificaciones de este dispositivo antes de cerrar la
  /// sesion: despues del signOut las reglas rechazan el borrado y el telefono
  /// se queda recibiendo push del usuario anterior.
  Future<void> _signOutAndBack() async {
    try {
      await ref.read(authControllerProvider).signOut();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final tr = S.of(context);
    final s = _state;

    return Scaffold(
      backgroundColor: AppTokens.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTokens.spaceXl),
            child: switch (s) {
              _Loading() => const CircularProgressIndicator(),
              _Joining() => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: AppTokens.spaceLg),
                    Text(tr.tenantJoining, style: tt.bodyMedium?.copyWith(color: AppTokens.mutedText)),
                  ],
                ),
              _Error(:final message) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 56, color: AppTokens.mutedText),
                    const SizedBox(height: AppTokens.spaceLg),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: tt.bodyMedium?.copyWith(color: AppTokens.mutedText),
                    ),
                    const SizedBox(height: AppTokens.spaceXl),
                    OutlinedButton(onPressed: _validate, child: Text(tr.retry)),
                    const SizedBox(height: AppTokens.spaceMd),
                    TextButton(
                      onPressed: () => context.go('/tenant-setup'),
                      child: Text(tr.goHome),
                    ),
                    TextButton(
                      onPressed: _signOutAndBack,
                      child: Text(tr.logout),
                    ),
                  ],
                ),
              _Preview(:final config) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _OrgLogo(config: config, size: 80),
                    const SizedBox(height: AppTokens.spaceLg),
                    Text(
                      config.appName.isNotEmpty ? config.appName : config.name,
                      style: tt.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppTokens.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (config.name.isNotEmpty && config.name != config.appName) ...[
                      const SizedBox(height: AppTokens.spaceXs),
                      Text(
                        config.name,
                        style: tt.bodyMedium?.copyWith(color: AppTokens.mutedText),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    // BUG-004 fix: render the tenant's welcomeText if set.
                    // Pre-fix the field was write-only (admin could edit but
                    // nothing displayed it). The join-link preview is the
                    // most natural place to surface a custom welcome line.
                    if (config.welcomeText != null && config.welcomeText!.isNotEmpty) ...[
                      const SizedBox(height: AppTokens.spaceMd),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
                        child: Text(
                          config.welcomeText!,
                          style: tt.bodyMedium?.copyWith(
                            color: AppTokens.textPrimary,
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppTokens.spaceXl * 1.5),
                    SizedBox(
                      width: double.infinity,
                      height: AppTokens.buttonHeight,
                      child: ElevatedButton(
                        onPressed: () => _join(config),
                        child: Text(tr.tenantJoin),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceSm),
                    TextButton(
                      onPressed: () => context.go('/tenant-setup'),
                      child: Text(tr.cancel),
                    ),
                    TextButton(
                      onPressed: _signOutAndBack,
                      child: Text(tr.logout),
                    ),
                  ],
                ),
            },
          ),
        ),
      ),
    );
  }
}

class _OrgLogo extends StatelessWidget {
  const _OrgLogo({required this.config, required this.size});

  final TenantConfig config;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bg = config.primaryColor ?? AppTokens.primaryBlue;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size / 4),
      ),
      clipBehavior: Clip.antiAlias,
      child: (config.logoUrl != null && config.logoUrl!.isNotEmpty)
          ? CachedNetworkImage(
              imageUrl: config.logoUrl!,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _initial(config.appName.isNotEmpty ? config.appName : config.name, size),
              placeholder: (_, _) => _initial(config.appName.isNotEmpty ? config.appName : config.name, size),
            )
          : _initial(config.appName.isNotEmpty ? config.appName : config.name, size),
    );
  }

  Widget _initial(String name, double size) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return Center(
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}

// ---- State sealed classes ----

sealed class _State {
  const _State();
}

class _Loading extends _State {
  const _Loading();
}

class _Joining extends _State {
  const _Joining();
}

class _Preview extends _State {
  const _Preview(this.config);
  final TenantConfig config;
}

class _Error extends _State {
  const _Error(this.message);
  final String message;
}
