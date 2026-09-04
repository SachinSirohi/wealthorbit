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
  static const int drainBatchSize = 8;
  static const int incrementalFetchDays = 45;

  /// App-settings flag: full historical enqueue already ran for this install.
  static const String enqueuedFlagKey = 'historical_backlog_enqueued_v1';
}
