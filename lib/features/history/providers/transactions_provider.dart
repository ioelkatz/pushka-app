import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../users/presentation/user_profile_provider.dart';
import '../data/transaction_repository.dart';
import '../domain/transaction.dart';

final userTransactionsProvider = StreamProvider<List<Transaction>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value(<Transaction>[]);
  final repository = ref.watch(transactionRepositoryProvider);
  return repository.watchTransactions(user.uid);
});
