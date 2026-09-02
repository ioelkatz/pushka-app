import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opportunistic network status.
///
/// Design: don't guess connectivity from browser APIs (navigator.onLine and
/// friends lie constantly — false negatives when a tab suspends, false
/// positives when connected to WiFi with no internet). Instead, reflect the
/// app's REAL experience with the network via feedback from actual requests.
///
/// Sources of truth:
///   - Cloud Function callables report success/failure via NetworkStatusReporter
///   - Firestore reads/writes report the same
///
/// Debounce: a single failure doesn't flip us to offline (blips happen). We
/// require 2 failures within a 30s rolling window. A single success from any
/// source flips us back to online immediately.
///
/// The banner (OfflineBanner) reads shouldShowBanner — offline AND not
/// dismissed by user. Dismiss is soft: it hides the current banner but a
/// FRESH offline transition (after a subsequent success) will re-show it.
class NetworkStatusNotifier extends StateNotifier<NetworkStatusState> {
  NetworkStatusNotifier() : super(const NetworkStatusState.unknown());

  static const _failuresToTriggerOffline = 2;
  static const _failureWindow = Duration(seconds: 30);

  int _consecutiveFailures = 0;
  DateTime? _firstFailureAt;

  /// Call after any real network operation succeeds (Firestore read/write,
  /// CF response OK, webhook post, etc). Resets the failure counter.
  void recordSuccess() {
    _consecutiveFailures = 0;
    _firstFailureAt = null;
    if (state.status != NetworkStatus.online) {
      state = const NetworkStatusState.online();
    }
  }

  /// Call ONLY when a network-class error is detected (not for auth errors,
  /// validation errors, etc). Use `isNetworkError(e)` to filter first.
  void recordFailure() {
    final now = DateTime.now();
    final firstAt = _firstFailureAt;
    if (firstAt == null || now.difference(firstAt) > _failureWindow) {
      _consecutiveFailures = 1;
      _firstFailureAt = now;
    } else {
      _consecutiveFailures++;
    }
    if (_consecutiveFailures >= _failuresToTriggerOffline) {
      // Preserve the dismissed flag ONLY if we're transitioning from an
      // already-dismissed offline state. A fresh transition (unknown/online
      // → offline) resets dismissed to false so the user sees the banner.
      final preserveDismissed = state.status == NetworkStatus.offline && state.dismissed;
      state = NetworkStatusState.offline(dismissed: preserveDismissed);
    }
  }

  /// User tapped X on the banner. Hide it but keep tracking. If a subsequent
  /// success + fresh failure cycle occurs, banner reappears.
  void dismissBanner() {
    if (state.status == NetworkStatus.offline && !state.dismissed) {
      state = const NetworkStatusState.offline(dismissed: true);
    }
  }
}

/// Coarse network state exposed by [NetworkStatusState].
enum NetworkStatus { unknown, online, offline }

class NetworkStatusState {
  final NetworkStatus status;
  final bool dismissed;

  const NetworkStatusState._(this.status, {this.dismissed = false});
  const NetworkStatusState.unknown() : this._(NetworkStatus.unknown);
  const NetworkStatusState.online() : this._(NetworkStatus.online);
  const NetworkStatusState.offline({bool dismissed = false})
      : this._(NetworkStatus.offline, dismissed: dismissed);

  bool get isOnline => status == NetworkStatus.online;
  bool get isOffline => status == NetworkStatus.offline;
  bool get isUnknown => status == NetworkStatus.unknown;
  bool get shouldShowBanner => isOffline && !dismissed;
}

final networkStatusProvider =
    StateNotifierProvider<NetworkStatusNotifier, NetworkStatusState>(
  (ref) {
    final notifier = NetworkStatusNotifier();
    // Register globally so non-Widget code (StripeService, repositories) can
    // report without holding a Ref. The reporter is a singleton and idempotent
    // to re-register — the last one wins.
    NetworkStatusReporter._register(notifier);
    return notifier;
  },
);

/// Convenience for widgets / gates. Returns true when we've CONFIRMED offline
/// AND the user hasn't dismissed the banner. Prefer `networkStatusProvider`
/// directly if you need the finer-grained state.
final isOfflineProvider = Provider<bool>((ref) {
  return ref.watch(networkStatusProvider).isOffline;
});

/// Whether the banner should currently be visible (isOffline AND not dismissed).
final shouldShowOfflineBannerProvider = Provider<bool>((ref) {
  return ref.watch(networkStatusProvider).shouldShowBanner;
});

// ---------------------------------------------------------------------------
// Static reporter — for use from non-Widget code (services, repositories) that
// don't hold a WidgetRef. The notifier is registered on first read of the
// provider (see the provider factory above).
// ---------------------------------------------------------------------------

class NetworkStatusReporter {
  static NetworkStatusNotifier? _notifier;

  static void _register(NetworkStatusNotifier notifier) {
    _notifier = notifier;
  }

  /// Record a successful network round-trip. Safe to call from anywhere.
  static void recordSuccess() {
    _notifier?.recordSuccess();
  }

  /// Record an operation failure. Only flips the notifier if the error is a
  /// network-class error (via isNetworkError). Other errors are ignored.
  static void recordMaybeNetworkFailure(Object error) {
    if (_notifier == null) return;
    if (isNetworkError(error)) {
      _notifier!.recordFailure();
    }
  }
}

/// Heuristic: is this error a network-class error we should treat as
/// evidence the user is offline? Very conservative — many things look like
/// network failures but aren't (auth token expired, permission denied, etc).
///
/// Only returns true for signals that RELIABLY indicate the network is
/// unreachable. Better to have a false negative (offline but not banner)
/// than a false positive (online but banner).
bool isNetworkError(Object err) {
  if (err is FirebaseFunctionsException) {
    if (err.code == 'unavailable') return true;
    if (err.code == 'deadline-exceeded') return true;
    // 'internal' with an obvious network hint in the message
    if (err.code == 'internal') {
      final msg = (err.message ?? '').toLowerCase();
      if (msg.contains('network') ||
          msg.contains('socket') ||
          msg.contains('connection') ||
          msg.contains('timeout')) {
        return true;
      }
    }
    return false;
  }
  if (err is FirebaseException) {
    if (err.code == 'unavailable') return true;
    if (err.code == 'deadline-exceeded') return true;
    if (err.code == 'network-request-failed') return true;
    return false;
  }
  if (err is TimeoutException) return true;
  final s = err.toString().toLowerCase();
  if (s.contains('socketexception')) return true;
  if (s.contains('failed host lookup')) return true;
  if (s.contains('connection reset')) return true;
  if (s.contains('connection refused')) return true;
  if (s.contains('network is unreachable')) return true;
  if (s.contains('err_internet_disconnected')) return true;
  return false;
}
