/// How first-time signup and ongoing sync queue bank-statement emails.
///
/// First signup scans the last [lookbackDays] of mail. The newest
/// [onboardImmediatePerSource] statements per bank are extracted immediately
/// so the dashboard is usable. Everything else is inserted into
/// `statement_queue` (newest first) and drained [drainBatchSize] at a time
/// by background sync / Sync Now. Incremental sync only looks back
/// [incrementalFetchDays] so we do not re-queue the whole history.
class StatementBacklog {
  static const int lookbackYears = 3;
  static const int lookbackDays = 1095; // 3 × 365
  static const int onboardImmediatePerSource = 2;
  /// Statements per drain. Sized for Gemini, which answers a window in
  /// seconds; the self-hosted fallback took ~100s each, which is why this
  /// was 8. The wall-clock deadline in the drain is the real guard, so a
  /// generous batch simply means fewer taps to clear a backlog.
  static const int drainBatchSize = 200;
  static const int incrementalFetchDays = 45;

  /// App-settings flag: full historical enqueue already ran for this install.
  static const String enqueuedFlagKey = 'historical_backlog_enqueued_v1';
}
