import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../app/theme/app_tokens.dart';
import '../data/tenant_repository.dart';
import '../domain/tenant_config.dart';

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
    try {
      final config = await ref.read(tenantRepositoryProvider).validateSlug(widget.slug);
      if (!mounted) return;
      setState(() => _state = _Preview(config));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _state = _Error(
        e.code == 'not-found'
            ? 'El código "${ widget.slug }" no corresponde a ninguna organización.'
            : 'No se pudo verificar el código. Intentá de nuevo.',
      ));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const _Error('No se pudo verificar el código. Intentá de nuevo.'));
    }
  }

  Future<void> _join(TenantConfig config) async {
    setState(() => _state = const _Joining());
    try {
      await ref.read(tenantRepositoryProvider).joinTenant(config.tenantId);
      ref.invalidate(tenantConfigProvider);
      ref.invalidate(tenantStateProvider);
      ref.invalidate(userTenantSummariesProvider);
      invalidateTenantCache();
      if (!mounted) return;
      context.go('/');
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _Preview(config));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo unirte a la organización. Intentá de nuevo.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
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
                    Text('Uniéndote...', style: tt.bodyMedium?.copyWith(color: AppTokens.mutedText)),
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
                    OutlinedButton(onPressed: _validate, child: const Text('Reintentar')),
                    const SizedBox(height: AppTokens.spaceMd),
                    TextButton(
                      onPressed: () => context.go('/'),
                      child: const Text('Ir al inicio'),
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
                    const SizedBox(height: AppTokens.spaceXl * 1.5),
                    SizedBox(
                      width: double.infinity,
                      height: AppTokens.buttonHeight,
                      child: ElevatedButton(
                        onPressed: () => _join(config),
                        child: const Text('Unirme'),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceSm),
                    TextButton(
                      onPressed: () => context.go('/'),
                      child: const Text('Cancelar'),
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
          ? Image.network(
              config.logoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _initial(config.appName.isNotEmpty ? config.appName : config.name, size),
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
