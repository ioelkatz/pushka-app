import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../users/presentation/user_profile_provider.dart';
import '../data/reminder_repository.dart';
import '../domain/reminder.dart';

final userRemindersProvider = StreamProvider<List<Reminder>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return const Stream.empty();
  final repo = ref.watch(reminderRepositoryProvider);
  return repo.watchReminders(user.uid);
});
