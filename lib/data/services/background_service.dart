import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart';
import '../../core/statement_backlog.dart';
import '../../core/amount_sanity.dart';
import '../database/database.dart';
import '../repositories/app_repository.dart';
import 'imap_service.dart';
import 'gemini_service.dart';
import 'notification_service.dart';
import 'secure_vault.dart';
import 'statement_processor.dart';
import 'exit_rules_service.dart';
import 'reconciliation_service.dart';
import 'financial_health_service.dart';
import 'diagnostics_service.dart';

/// Background Service for automated statement processing and monitoring
class BackgroundService {
  static const String statementProcessingTask = 'statement_processing';
  static const String budgetCheckTask = 'budget_check';
  static const String sipReminderTask = 'sip_reminder';
  static const String exitRulesCheckTask = 'exit_rules_check';
  
  /// Initialize WorkManager
  static Future<void> initialize() async {
    await Workmanager().initialize(
      callbackDispatcher,
    );
  }
  
  /// Register periodic tasks
  static Future<void> registerTasks() async {
    // Statement processing - check every 6 hours
    await Workmanager().registerPeriodicTask(
      statementProcessingTask,
      statementProcessingTask,
      frequency: const Duration(hours: 6),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
    );
    
    // Budget check - check daily
    await Workmanager().registerPeriodicTask(
      budgetCheckTask,
      budgetCheckTask,
      frequency: const Duration(hours: 24),
      constraints: Constraints(
        requiresBatteryNotLow: true,
      ),
    );
    
    // SIP reminder - check daily at startup
    await Workmanager().registerPeriodicTask(
      sipReminderTask,
      sipReminderTask,
      frequency: const Duration(hours: 24),
      constraints: Constraints(
        requiresBatteryNotLow: true,
      ),
    );
    
    // Exit Rules check - check daily
    await Workmanager().registerPeriodicTask(
      exitRulesCheckTask,
      exitRulesCheckTask,
      frequency: const Duration(hours: 24),
      constraints: Constraints(
        requiresBatteryNotLow: true,
      ),
    );
  }
  
  /// Cancel all tasks
  static Future<void> cancelAllTasks() async {
    await Workmanager().cancelAll();
  }
  
  /// Execute a task immediately
  static Future<void> executeNow(String taskName) async {
    await Workmanager().registerOneOffTask(
      '${taskName}_immediate',
      taskName,
    );
  }

  /// Drain pending queue on the current isolate (Sync Now / catch-up).
  ///
  /// The foreground caller gets a longer deadline than the background worker:
  /// the user is watching and can see progress, whereas WorkManager will kill
  /// a job that overruns its execution window.
  static Future<void> processStatementQueueNow({
    int maxItems = StatementBacklog.drainBatchSize,
    Duration deadline = const Duration(minutes: 12),
    void Function(String status)? onProgress,
  }) =>
      _processStatementQueue(
          maxItems: maxItems, deadline: deadline, onProgress: onProgress);
}

/// Background task callback dispatcher
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // Every background run leaves a health report behind. The release build
    // cannot be inspected with `run-as`, and driving the UI is not always
    // possible, so this is how the ledger's state can be reviewed over ADB.
    try {
      final db = AppRepository.database ?? AppDatabase();
      await DiagnosticsService.dump(db, AppRepository.withDatabase(db));
    } catch (e) {
      debugPrint('Diagnostics dump skipped: $e');
    }
    try {
      switch (task) {
        case BackgroundService.statementProcessingTask:
          await _processStatementQueue();
          break;
        case BackgroundService.budgetCheckTask:
          await _checkBudgetAlerts();
          break;
        case BackgroundService.sipReminderTask:
          await _checkSipReminders();
          break;
        case BackgroundService.exitRulesCheckTask:
          await _checkExitRules();
          break;
        default:
          debugPrint('Unknown task: $task');
      }
      return true;
    } catch (e) {
      debugPrint('Background task error: $e');
      return false;
    }
  });
}

/// Process statement queue using IMAP across ALL connected email accounts.
Future<void> _processStatementQueue({
  int maxItems = StatementBacklog.drainBatchSize,
  Duration deadline = const Duration(minutes: 8),
  void Function(String status)? onProgress,
}) async {
  // Extraction is slow (a statement window is ~100s against this LLM), so a
  // full batch can easily outlast the window WorkManager gives a job. Stop
  // starting new items near the deadline and leave the rest `pending` — the
  // next run picks up exactly where this one stopped.
  final startedAt = DateTime.now();
  bool outOfTime() => DateTime.now().difference(startedAt) >= deadline;
  final existing = AppRepository.database;
  final ownsDb = existing == null;
  final db = existing ?? AppDatabase();
  final repository = ownsDb
      ? AppRepository.withDatabase(db)
      : await AppRepository.getInstance();
  final notificationService = NotificationService();

  try {
    final emailAccounts = await SecureVault.getEmailAccounts();
    if (emailAccounts.isEmpty) {
      debugPrint('📧 No email accounts configured, skipping statement processing');
      return;
    }

    await GeminiService.seedDefaultKey();
    if (!await SecureVault.hasAnyLlmKey()) {
      debugPrint('🤖 AI API key not configured, skipping statement processing');
      return;
    }
    if (!await GeminiService.initialize()) {
      debugPrint('❌ Could not initialize AI, skipping statement processing');
      return;
    }

    // Items left in 'processing' after a killed worker block the queue forever.
    await (db.update(db.statementQueue)
          ..where((q) => q.status.equals('processing')))
        .write(StatementQueueCompanion(status: const Value('pending')));

    // Give transient failures (timeouts, dropped connections) another go on
    // an exponential backoff, so one bad night of connectivity does not
    // leave a permanent hole waiting for someone to notice and tap Retry.
    await repository.requeueRetryableFailures();

    // Keyed by mailbox: a queue row is fetched from the account it was
    // discovered in, never from whichever client happens to answer first.
    final clients = <String, ImapService>{};
    for (final emailAccount in emailAccounts) {
      final imap = ImapService(account: emailAccount);
      if (await imap.connect()) {
        clients[emailAccount.email.toLowerCase()] = imap;
      } else {
        debugPrint('❌ Could not connect IMAP for ${emailAccount.email}');
      }
    }
    if (clients.isEmpty) return;

    await _enqueueHistoricalBacklog(clients, db, repository, onProgress);

    int imported = 0;
    int completed = 0;
    int emptied = 0;
    int failed = 0;
    final reasons = <String, int>{};
    void noteReason(String r) => reasons[r] = (reasons[r] ?? 0) + 1;

    try {
      var remaining = maxItems;
      while (remaining > 0 && !outOfTime()) {
        var batch = await (db.select(db.statementQueue)
              ..where((q) => q.status.equals('pending'))
              ..orderBy([
                (q) => OrderingTerm.desc(q.emailDate),
                (q) => OrderingTerm.asc(q.queuedAt),
              ])
              ..limit(remaining))
            .get();

        if (batch.isEmpty) {
          await _fetchNewStatementEmails(clients, db);
          batch = await (db.select(db.statementQueue)
                ..where((q) => q.status.equals('pending'))
                ..orderBy([
                  (q) => OrderingTerm.desc(q.emailDate),
                  (q) => OrderingTerm.asc(q.queuedAt),
                ])
                ..limit(remaining))
              .get();
          if (batch.isEmpty) break;
        }

        for (final item in batch) {
          if (outOfTime()) {
            debugPrint('⏱️ Drain deadline reached — '
                '${completed + emptied + failed} handled, rest stay queued');
            remaining = 0;
            break;
          }
          remaining--;
          onProgress?.call(
              '${completed + emptied + failed + 1}/$maxItems · ${item.subject}');
          await Future<void>.delayed(Duration.zero);

          if (isNonBankStatementSubject(item.subject)) {
            await (db.update(db.statementQueue)
                  ..where((q) => q.id.equals(item.id)))
                .write(StatementQueueCompanion(
                  status: const Value('failed'),
                  errorMessage: const Value('Skipped: not a bank statement'),
                  processedAt: Value(DateTime.now()),
                ));
            failed++;
            noteReason('not a bank statement');
            debugPrint('⏭️ Non-bank subject skipped: ${item.subject}');
            continue;
          }

          try {
            await (db.update(db.statementQueue)
                  ..where((q) => q.id.equals(item.id)))
                .write(StatementQueueCompanion(status: const Value('processing')));

            // Fetch from the OWNING mailbox. Falling back to "any client that
            // returns something" meant a UID from one account could resolve to
            // an unrelated email in another.
            MimeMessage? message;
            ImapService? owner;
            if (item.emailId != 'manual_upload') {
              final uid = int.tryParse(item.emailId);
              if (uid != null) {
                final owned = item.accountEmail?.toLowerCase();
                final candidates = owned != null && clients.containsKey(owned)
                    ? [clients[owned]!]
                    // Legacy rows predate mailbox tracking; only then do we
                    // search every mailbox.
                    : (owned == null ? clients.values.toList() : const <ImapService>[]);
                for (final imap in candidates) {
                  message = await imap.fetchFullMessage(uid);
                  if (message != null) {
                    owner = imap;
                    break;
                  }
                }
              }
            }

            if (message == null) {
              final retries = item.retryCount + 1;
              final giveUp = retries >= 2;
              await (db.update(db.statementQueue)
                    ..where((q) => q.id.equals(item.id)))
                  .write(StatementQueueCompanion(
                    status: Value(giveUp ? 'failed' : 'pending'),
                    retryCount: Value(retries),
                    errorMessage: Value(
                      giveUp
                          ? 'Email UID ${item.emailId} is no longer in '
                              '${item.accountEmail ?? 'any connected mailbox'}'
                          : item.errorMessage,
                    ),
                    processedAt: giveUp ? Value(DateTime.now()) : const Value.absent(),
                  ));
              if (giveUp) {
                failed++;
                noteReason('email no longer in the mailbox');
                debugPrint('⏭️ Dropped stale queue item ${item.subject} (UID ${item.emailId})');
              }
              continue;
            }

            final pdfs = await (owner ?? clients.values.first)
                .extractPdfAttachments(message);
            // Rows queued before their sender was mapped carry a null
            // sourceId. Recover it from the message itself rather than
            // failing the statement for want of a mapping we can derive.
            var sourceId = item.sourceId;
            sourceId ??= await _resolveSourceId(
                db, message.from?.firstOrNull?.email ?? '');
            if (sourceId != null && sourceId != item.sourceId) {
              await (db.update(db.statementQueue)
                    ..where((q) => q.id.equals(item.id)))
                  .write(StatementQueueCompanion(sourceId: Value(sourceId)));
            }
            final source = sourceId != null
                ? await repository.getStatementSource(sourceId)
                : null;

            if (pdfs.isEmpty) {
              await repository.updateStatementQueueStatus(item.id, 'empty',
                  errorMessage: 'This email had no PDF attachment.');
              emptied++;
              noteReason('no PDF attached');
              continue;
            }

            // NEVER guess the destination account. Writing an INR statement
            // into whichever account happened to be first relabelled every
            // amount with that account's currency and multiplied it by that
            // account's FX rate.
            final accountId = await _resolveAccountId(repository, source);
            if (accountId == null) {
              await repository.updateStatementQueueStatus(item.id, 'failed',
                  errorMessage:
                      'No account mapped for ${source?.bankName ?? source?.senderEmail ?? 'this sender'}. '
                      'Map it to an account, then retry.');
              failed++;
              noteReason('sender not mapped to an account');
              continue;
            }

            final processor = StatementProcessor(repository);
            final password = await SecureVault.resolvePdfPassword(
              sourceId: sourceId,
              senderEmail: source?.senderEmail,
              bankName: source?.bankName,
            );
            final brokerage = isBrokerageSender(
                '${source?.bankName ?? ''} ${source?.senderEmail ?? ''} ${item.subject}');

            int transactionCount = 0;
            String? emptyReason;
            for (final pdf in pdfs) {
              final result = brokerage
                  ? await processor.processBrokeragePdf(
                      bytes: pdf,
                      accountId: accountId,
                      pdfPassword: password,
                      bankName: source?.bankName,
                      sourceId: sourceId,
                      senderEmail: source?.senderEmail,
                    )
                  : await processor.processPdf(
                      bytes: pdf,
                      accountId: accountId,
                      pdfPassword: password,
                      statementId: item.id,
                      sourceId: sourceId,
                      senderEmail: source?.senderEmail,
                      statementDate: item.emailDate,
                    );
              transactionCount += result.imported;
              emptyReason ??= result.emptyReason;
            }

            if (transactionCount == 0) {
              // "Completed with nothing imported" is not success. Recording
              // it as `empty` with the reason keeps it visible and retryable
              // instead of vanishing into the completed pile.
              await repository.updateStatementQueueStatus(item.id, 'empty',
                  errorMessage: emptyReason ?? 'No transactions were imported.');
              emptied++;
              noteReason(emptyReason ?? 'nothing to import');
              debugPrint('⚪️ Queue item ${item.subject} → 0 txns · $emptyReason');
              continue;
            }

            await (db.update(db.statementQueue)
                  ..where((q) => q.id.equals(item.id)))
                .write(StatementQueueCompanion(
                  status: const Value('completed'),
                  errorMessage: const Value(null),
                  processedAt: Value(DateTime.now()),
                ));
            imported += transactionCount;
            completed++;
            debugPrint(
                '✅ Queue item ${item.subject} → $transactionCount txns (${completed + emptied + failed} this run)');
          } catch (e) {
            failed++;
            noteReason(_reasonFromError(e));
            await (db.update(db.statementQueue)
                  ..where((q) => q.id.equals(item.id)))
                .write(StatementQueueCompanion(
                  status: const Value('failed'),
                  errorMessage: Value(e.toString()),
                  processedAt: Value(DateTime.now()),
                ));
            debugPrint('❌ Queue item ${item.subject}: $e');
          }
        }
      }

      if (completed + emptied + failed > 0) {
        try {
          onProgress?.call('Matching transfers…');
          final recon = await ReconciliationService(repository).run();
          debugPrint('🤝 $recon');
        } catch (e) {
          debugPrint('Reconciliation after drain failed: $e');
        }
        try {
          final existing =
              await repository.getCoachReport(DateTime.now().year, DateTime.now().month);
          final coach =
              await FinancialHealthService(repository).ensureCurrentMonthReport();
          if (coach != null && existing == null) {
            await notificationService.showCoachReportReady(
              monthLabel: _monthName(coach.month),
              score: coach.score.round(),
            );
          }
        } catch (e) {
          debugPrint('Coach after drain failed: $e');
        }
        try {
          String? dominant;
          if (reasons.isNotEmpty) {
            final top = reasons.entries
                .reduce((a, b) => a.value >= b.value ? a : b);
            dominant = '${top.value} statement(s): ${top.key}. '
                'Open Statements & Automation to fix.';
          }
          await notificationService.showSyncSummary(
            imported: imported,
            succeeded: completed,
            failed: failed,
            empty: emptied,
            dominantReason: dominant,
          );
        } catch (e) {
          debugPrint('Notification after queue drain failed: $e');
        }
      }
    } finally {
      for (final imap in clients.values) {
        await imap.disconnect();
      }
    }
  } finally {
    if (ownsDb) await db.close();
  }
}

/// Short, user-facing reason for a thrown extraction error.
String _reasonFromError(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('password')) return 'need a PDF password';
  if (s.contains('timeout') || s.contains('timed out')) return 'the AI timed out';
  if (s.contains('socket') || s.contains('connection')) return 'connection problem';
  return 'could not be read';
}

/// The account a source's transactions belong to.
///
/// Returns null rather than defaulting to the first account in the table.
/// That fallback is what put rupee statements into an AED account, where
/// every amount was relabelled AED and multiplied by the AED rate.
Future<String?> _resolveAccountId(
  AppRepository repository,
  StatementSource? source,
) async {
  if (source == null) return null;
  if (source.accountId != null) {
    // Guard against a mapping that points at a deleted account.
    if (await repository.getAccount(source.accountId!) != null) {
      return source.accountId;
    }
  }
  // Adopt an existing account with the same institution name before giving up.
  final accounts = await repository.getAllAccounts();
  final bank = source.bankName.trim().toLowerCase();
  if (bank.isNotEmpty && bank != 'unknown bank') {
    for (final a in accounts) {
      if (a.name.trim().toLowerCase() == bank) {
        await repository.updateStatementSource(
            source.id, StatementSourcesCompanion(accountId: Value(a.id)));
        return a.id;
      }
    }
  }
  return null;
}

/// One-shot: enqueue every statement email in the 3-year window that is not
/// already in `statement_queue`. Onboarding does this too; this covers installs
/// that already had a 2-year backlog before the 3-year queue existed.
Future<void> _enqueueHistoricalBacklog(
  Map<String, ImapService> clients,
  AppDatabase db,
  AppRepository repository,
  void Function(String status)? onProgress,
) async {
  if (await repository.getAppSetting(StatementBacklog.enqueuedFlagKey) == 'true') {
    return;
  }
  final existingSources = await db.select(db.statementSources).get();
  if (existingSources.isEmpty) return;
  onProgress?.call(
      'Queuing last ${StatementBacklog.lookbackYears} years of statements…');
  try {
    for (final entry in clients.entries) {
      final mailbox = entry.key;
      final imap = entry.value;
      await imap.discoverStatementSenders(daysBack: StatementBacklog.lookbackDays);
      final sources = await db.select(db.statementSources).get();
      final senders = sources.map((s) => s.senderEmail).where((e) => e.isNotEmpty).toList();
      if (senders.isEmpty) continue;
      final headers = await imap.searchStatementEmails(
        senders,
        daysBack: StatementBacklog.lookbackDays,
      );
      for (final header in headers) {
        final uid = header.uid?.toString() ?? '';
        if (uid.isEmpty) continue;
        final fromAddress = header.from?.firstOrNull?.email ?? '';
        final sourceId = await _resolveSourceId(db, fromAddress);
        await repository.recordQueuedEmail(
          emailId: uid,
          subject: header.decodeSubject() ?? 'Statement',
          emailDate: header.decodeDate() ?? DateTime.now(),
          sourceId: sourceId,
          accountEmail: mailbox,
        );
      }
    }
    await repository.setAppSetting(StatementBacklog.enqueuedFlagKey, 'true');
    debugPrint('📥 Historical 3-year statement backlog queued');
  } catch (e) {
    debugPrint('⚠️ Historical backlog enqueue failed: $e');
  }
}

/// Fetch new statement emails from EVERY connected mailbox and add them to
/// the queue. This used to run against `clients.first` only, so statements
/// arriving in any account other than the first were never picked up.
Future<void> _fetchNewStatementEmails(
  Map<String, ImapService> clients,
  AppDatabase db,
) async {
  final repository = AppRepository.withDatabase(db);
  for (final entry in clients.entries) {
    final mailbox = entry.key;
    final imapService = entry.value;
    try {
      final sources = await imapService.discoverStatementSenders(
        daysBack: StatementBacklog.incrementalFetchDays,
      );

      // Get list of sender emails
      final senderEmails = sources.map((s) => s.senderEmail).toList();
      if (senderEmails.isEmpty) {
        debugPrint('📭 No statement senders discovered in $mailbox');
        continue;
      }

      final headers = await imapService.searchStatementEmails(
        senderEmails,
        daysBack: StatementBacklog.incrementalFetchDays,
      );

      for (final header in headers) {
        final uid = header.uid?.toString() ?? '';
        if (uid.isEmpty) continue;
        final fromAddress = header.from?.firstOrNull?.email ?? '';
        final sourceId = await _resolveSourceId(db, fromAddress);
        await repository.recordQueuedEmail(
          emailId: uid,
          subject: header.decodeSubject() ?? 'Statement',
          emailDate: header.decodeDate() ?? DateTime.now(),
          sourceId: sourceId,
          accountEmail: mailbox,
        );
      }
    } catch (e) {
      debugPrint('Error fetching statement emails from $mailbox: $e');
    }
  }
}

/// Find an existing StatementSources row for [fromAddress], or create one,
/// and return its id. This keeps StatementQueue.sourceId a real foreign key
/// (not a bank name).
///
/// A newly minted source is left UNMAPPED unless an account with the same
/// institution name already exists. It used to default to `accounts.first`,
/// which silently routed every unrecognised bank's statements into one
/// account and relabelled their amounts with that account's currency.
Future<String?> _resolveSourceId(AppDatabase db, String fromAddress) async {
  if (fromAddress.isEmpty) return null;
  final existing = await (db.select(db.statementSources)
    ..where((s) => s.senderEmail.equals(fromAddress))).getSingleOrNull();
  if (existing != null) return existing.id;

  final bankName = _detectBankName(fromAddress);
  final accounts = await db.select(db.accounts).get();
  String? matchedAccountId;
  for (final a in accounts) {
    if (a.name.trim().toLowerCase() == bankName.trim().toLowerCase()) {
      matchedAccountId = a.id;
      break;
    }
  }

  final id = 'src_${DateTime.now().millisecondsSinceEpoch}';
  await db.into(db.statementSources).insert(StatementSourcesCompanion.insert(
    id: id,
    senderEmail: fromAddress,
    bankName: bankName,
    accountType: isBrokerageSender('$bankName $fromAddress') ? 'brokerage' : 'bank',
    accountId: Value(matchedAccountId),
  ));
  return id;
}

/// Detect bank name from email address
String _detectBankName(String email) {
  final domain = email.split('@').lastOrNull?.toLowerCase() ?? '';
  
  final bankMap = {
    'emirates': 'Emirates NBD',
    'enbd': 'Emirates NBD',
    'adcb': 'ADCB',
    'mashreq': 'Mashreq',
    'fab': 'First Abu Dhabi Bank',
    'dib': 'Dubai Islamic Bank',
    'cbd': 'Commercial Bank of Dubai',
    'rakbank': 'RAK Bank',
    'hsbc': 'HSBC',
    'citi': 'Citibank',
    'sc.com': 'Standard Chartered',
    'standardchartered': 'Standard Chartered',
    'hdfc': 'HDFC Bank',
    'icici': 'ICICI Bank',
    'sbi': 'State Bank of India',
    'axis': 'Axis Bank',
    'kotak': 'Kotak Mahindra',
  };
  
  for (final entry in bankMap.entries) {
    if (domain.contains(entry.key)) {
      return entry.value;
    }
  }
  
  return 'Unknown Bank';
}

/// Check budget alerts
Future<void> _checkBudgetAlerts() async {
  final db = AppDatabase();
  final repository = AppRepository.withDatabase(db);
  final notificationService = NotificationService();
  
  try {
    final alerts = await repository.checkBudgetThresholds();
    
    for (final alert in alerts) {
      await notificationService.showBudgetWarning(
        categoryName: alert['categoryName'] as String,
        percentUsed: (alert['percentUsed'] as double).round(),
      );
    }

    // Monthly coach: generate once when this month has no report yet.
    final now = DateTime.now();
    final existing = await repository.getCoachReport(now.year, now.month);
    if (existing == null) {
      try {
        final coach =
            await FinancialHealthService(repository).ensureCurrentMonthReport();
        if (coach != null) {
          await notificationService.showCoachReportReady(
            monthLabel: _monthName(coach.month),
            score: coach.score.round(),
          );
        }
      } catch (e) {
        debugPrint('Monthly coach generation failed: $e');
      }
    }
  } finally {
    await db.close();
  }
}

String _monthName(int month) {
  const names = [
    '', 'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  if (month < 1 || month > 12) return 'This month';
  return names[month];
}

/// Check SIP reminders
Future<void> _checkSipReminders() async {
  final db = AppDatabase();
  final notificationService = NotificationService();
  
  try {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    
    // Get SIPs due tomorrow
    final sips = await (db.select(db.sipRecords)
      ..where((s) => s.isActive.equals(true))
      ..where((s) => s.dayOfMonth.equals(tomorrow.day))).get();
    
    for (final sip in sips) {
      await notificationService.showSipReminderDue(
        sipName: sip.name,
        amount: sip.amount,
        currency: sip.currencyCode,
      );
    }
    
    // Also check EMI due dates
    final liabilities = await (db.select(db.liabilities)
      ..where((l) => l.isActive.equals(true))).get();
    
    for (final liability in liabilities) {
      // Assume EMI due on the same day of month as start date
      if (liability.startDate.day == tomorrow.day + 3) { // 3 days notice
        await notificationService.showEmiDueReminder(
          loanName: liability.name,
          amount: liability.emi,
          currency: liability.currencyCode,
        );
      }
    }
  } finally {
    await db.close();
  }
}

/// Check Exit Rules for real estate properties
Future<void> _checkExitRules() async {
  final db = AppDatabase();
  final repository = AppRepository.withDatabase(db);
  final notificationService = NotificationService();
  
  try {
    final exitRulesService = ExitRulesService(repository);
    final alerts = await exitRulesService.evaluateAllRules();
    
    for (final alert in alerts) {
      await notificationService.showExitRuleTriggered(
        propertyName: alert.assetName,
        message: alert.message,
      );
    }
    
    if (alerts.isNotEmpty) {
      debugPrint('🏠 ${alerts.length} exit rule(s) triggered');
    }
  } catch (e) {
    debugPrint('Error checking exit rules: $e');
  } finally {
    await db.close();
  }
}
