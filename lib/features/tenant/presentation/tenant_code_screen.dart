import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_tokens.dart';
import '../data/tenant_repository.dart';
import '../domain/tenant_config.dart';

class TenantCodeScreen extends ConsumerStatefulWidget {
  const TenantCodeScreen({super.key});

  @override
  ConsumerState<TenantCodeScreen> createState() => _TenantCodeScreenState();
}

class _TenantCodeScreenState extends ConsumerState<TenantCodeScreen> {
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
      setState(() { _preview = config; });
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _error = e.code == 'not-found'
            ? 'Código no encontrado. Verificá que sea correcto.'
            : 'Error al validar el código. Intentá de nuevo.';
      });
    } catch (_) {
      setState(() { _error = 'Error al validar el código. Intentá de nuevo.'; });
    } finally {
      setState(() { _loading = false; });
    }
  }

  Future<void> _confirm() async {
    final config = _preview;
    if (config == null) return;

    setState(() { _loading = true; _error = null; });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Not logged in');

      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        {'tenantId': config.tenantId, 'uid': uid},
        SetOptions(merge: true),
      );

      // Invalidate tenant config so app.dart reloads with new branding
      ref.invalidate(tenantConfigProvider);

      if (mounted) context.go('/');
    } catch (_) {
      setState(() { _error = 'No se pudo guardar la organización. Intentá de nuevo.'; });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Ingresar a tu organización')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Text(
                'Ingresá el código de tu organización',
                style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Tu administrador te lo compartió al invitarte.',
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        labelText: 'Código de organización',
                        hintText: 'ej: chabadmexico',
                        errorText: _error,
                      ),
                      autocorrect: false,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _validate(),
                      onChanged: (_) {
                        if (_preview != null || _error != null) {
                          setState(() { _preview = null; _error = null; });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _validate,
                      child: _loading
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Buscar'),
                    ),
                  ),
                ],
              ),
              if (_preview != null) ...[
                const SizedBox(height: 28),
                _OrgPreviewCard(config: _preview!),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _loading ? null : _confirm,
                  child: const Text('Unirme a esta organización'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OrgPreviewCard extends StatelessWidget {
  const _OrgPreviewCard({required this.config});

  final TenantConfig config;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(color: cs.outline),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: config.primaryColor ?? cs.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: config.logoUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(config.logoUrl!, fit: BoxFit.cover),
                  )
                : const Icon(Icons.business_rounded, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  config.appName,
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (config.name.isNotEmpty && config.name != config.appName)
                  Text(
                    config.name,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          Icon(Icons.check_circle_rounded, color: AppTokens.success, size: 26),
        ],
      ),
    );
  }
}
