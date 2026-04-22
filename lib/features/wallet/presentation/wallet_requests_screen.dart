import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../users/presentation/user_profile_provider.dart';
import '../../../core/format_utils.dart';
import '../../../core/l10n/s.dart';

class WalletRequestsScreen extends ConsumerWidget {
  const WalletRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = S.of(context);
    final uid = ref.watch(currentUserProvider)?.uid;
    const blue = Color(0xFF2F60C5);
    const red = Color(0xFFE05A4F);

    if (uid == null) {
      return Scaffold(
        body: Center(child: Text(tr.signInForContacts)),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('walletRequests')
              .where('status', isEqualTo: 'pending')
              .orderBy('createdAt', descending: true)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    tr.errorLoadingHistory,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              );
            }

            final docs = snapshot.data?.docs ?? [];

            if (docs.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline, size: 60, color: Colors.grey.shade300),
                    const SizedBox(height: 16),
                    Text(
                      tr.noPendingRequests,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              itemCount: docs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final doc = docs[index];
                final data = doc.data();
                final fromWalletId = data['fromWalletId'] as String? ?? '--------';
                final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
                final ts = data['createdAt'] as Timestamp?;
                final date = ts != null
                    ? '${ts.toDate().day.toString().padLeft(2, '0')}/${ts.toDate().month.toString().padLeft(2, '0')}/${ts.toDate().year}'
                    : '';

                return _RequestCard(
                  requestId: doc.id,
                  uid: uid,
                  fromWalletId: fromWalletId,
                  amount: amount,
                  date: date,
                  blue: blue,
                  red: red,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _RequestCard extends StatefulWidget {
  final String requestId;
  final String uid;
  final String fromWalletId;
  final double amount;
  final String date;
  final Color blue;
  final Color red;

  const _RequestCard({
    required this.requestId,
    required this.uid,
    required this.fromWalletId,
    required this.amount,
    required this.date,
    required this.blue,
    required this.red,
  });

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  bool _processing = false;

  Future<void> _accept() async {
    final tr = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(tr.confirmAcceptRequest),
        content: Text(tr.confirmAcceptBody(
          widget.amount.toStringAsFixed(2),
          widget.fromWalletId,
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancelBtn),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2F60C5),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(tr.acceptRequest),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _processing = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('acceptWalletRequest');
      await callable.call({'requestId': widget.requestId});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.requestAccepted)),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final msg = e.code == 'failed-precondition'
          ? tr.insufficientFunds
          : e.message ?? tr.couldNotTransfer;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.couldNotTransfer)),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _reject() async {
    final tr = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(tr.rejectRequest),
        content: Text(tr.confirmRejectBody(
          widget.amount.toStringAsFixed(2),
          widget.fromWalletId,
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancelBtn),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(tr.rejectRequest),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _processing = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('rejectWalletRequest');
      await callable.call({'requestId': widget.requestId});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.requestRejected)),
      );
    } on FirebaseFunctionsException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr.couldNotTransfer)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.couldNotTransfer)),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: widget.blue.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.request_page_outlined, size: 20, color: widget.blue),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr.requestFrom(widget.fromWalletId),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.date,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
              Text(
                formatMoney(widget.amount),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: widget.blue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_processing)
            const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _reject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey.shade700,
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: Text(tr.rejectRequest, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _accept,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.blue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: Text(tr.acceptRequest, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Stream provider for pending wallet requests count (for badge).
final pendingWalletRequestsProvider = StreamProvider.autoDispose<int>((ref) {
  final uid = ref.watch(currentUserProvider)?.uid;
  if (uid == null) return Stream.value(0);
  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('walletRequests')
      .where('status', isEqualTo: 'pending')
      .snapshots()
      .map((snap) => snap.docs.length);
});
