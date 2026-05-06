import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../users/presentation/user_profile_provider.dart';
import '../data/transaction_repository.dart';
import '../domain/transaction.dart';

/// Caps the history stream's `limit`. Starts at the default page size; the
/// History UI bumps this up by `pageSize` whenever the user taps "Cargar más".
/// Reset on tenant switch via the existing `userTransactionsProvider`
/// invalidation chain (the StateProvider rebuilds back to its default).
final historyLimitProvider = StateProvider<int>(
  (ref) => TransactionRepository.pageSize,
);

final userTransactionsProvider = StreamProvider<List<Transaction>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value(<Transaction>[]);
  final profile = ref.watch(userProfileProvider).valueOrNull;
  final tenantId = profile?['tenantId'] as String?;
  final limit = ref.watch(historyLimitProvider);
  final repository = ref.watch(transactionRepositoryProvider);
  return repository.watchTransactions(
    user.uid,
    tenantId: tenantId,
    limit: limit,
  );
});
