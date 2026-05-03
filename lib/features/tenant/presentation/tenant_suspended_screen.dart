import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/s.dart';
import '../../auth/providers/auth_controller.dart';

class TenantSuspendedScreen extends ConsumerWidget {
  const TenantSuspendedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final tr = S.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.block_rounded, size: 72, color: cs.error),
              const SizedBox(height: 24),
              Text(
                tr.tenantSuspendedTitle,
                style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                tr.tenantSuspendedBody,
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              OutlinedButton(
                onPressed: () async {
                  await ref.read(authControllerProvider).signOut();
                  if (context.mounted) context.go('/login');
                },
                child: Text(tr.logout),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
