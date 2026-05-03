/// Pure decision logic for ProgressSyncService.
///
/// Extracted so the math can be unit-tested without mocking ApiService,
/// SharedPreferences, or Connectivity. Behavior must match the inline code
/// in `progress_sync_service.dart` exactly. Change one, change both.
class SyncLogic {
  /// Hard upper bound on retry delay. Matches `_maxRetryDelay` in
  /// ProgressSyncService.
  static const Duration maxRetryDelay = Duration(minutes: 5);

  /// Exponential backoff used between retry attempts when flushing pending
  /// syncs. Schedule:
  ///
  ///   0 failures  ->  250 ms (initial fast retry)
  ///   1 failure   ->    5 s
  ///   2 failures  ->   10 s
  ///   3 failures  ->   20 s
  ///   4 failures  ->   40 s
  ///   5 failures  ->   80 s
  ///   6 failures  ->  160 s
  ///   7+ failures ->  300 s (capped at maxRetryDelay)
  static Duration backoffDelay(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return const Duration(milliseconds: 250);
    final raw = Duration(
      seconds: 5 * (1 << (consecutiveFailures - 1)).clamp(1, 60),
    );
    return raw > maxRetryDelay ? maxRetryDelay : raw;
  }

  /// Decide whether to pull server progress or push local progress when
  /// flushing a pending sync.
  ///
  /// Returns `true` to pull server (server is authoritative for this item),
  /// `false` to push local (local is authoritative).
  ///
  /// Rules:
  ///   - If local timestamp is newer or equal, always push local.
  ///   - If server timestamp is newer:
  ///       - If server position is at or ahead of local position, pull server.
  ///       - Else if there is offline listening time accumulated locally,
  ///         push local (offline progress would otherwise be lost).
  ///       - Else pull server.
  static bool shouldPullServer({
    required int serverTimestamp,
    required double serverTime,
    required int localTimestamp,
    required double localTime,
    required bool hasOfflineListening,
  }) {
    if (serverTimestamp <= localTimestamp) return false;
    return serverTime >= localTime || !hasOfflineListening;
  }
}
