import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'package:drift/drift.dart';
import '../database/database.dart';
import '../repositories/app_repository.dart';
import 'imap_service.dart';
import 'gemini_service.dart';
import 'notification_service.dart';
import 'secure_vault.dart';
import 'statement_processor.dart';
import 'exit_rules_service.dart';

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
}

/// Background task callback dispatcher
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
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
Future<void> _processStatementQueue() async {
  final db = AppDatabase();
  final repository = AppRepository.withDatabase(db);
  final notificationService = NotificationService();

  try {
    final emailAccounts = await SecureVault.getEmailAccounts();
    if (emailAccounts.isEmpty) {
      debugPrint('📧 No email accounts configured, skipping statement processing');
      return;
    }

    // Gemini must be configured & initialized before we can parse anything.
    if (!await SecureVault.hasGeminiApiKey()) {
      debugPrint('🤖 Gemini API key not configured, skipping statement processing');
      return;
    }
    final geminiReady = await GeminiService.initialize();
    if (!geminiReady) {
      debugPrint('❌ Could not initialize Gemini AI, skipping statement processing');
      return;
    }

    for (final emailAccount in emailAccounts) {
      final imapService = ImapService(account: emailAccount);
      final isConnected = await imapService.connect();
      if (!isConnected) {
        debugPrint('❌ Could not connect IMAP for ${emailAccount.email}, trying next account');
        continue;
      }

      try {
        // Get pending items from statement queue
        final queueItems = await (db.select(db.statementQueue)
          ..where((q) => q.status.equals('pending'))
          ..orderBy([(q) => OrderingTerm.asc(q.queuedAt)])
          ..limit(5)).get();

        if (queueItems.isEmpty) {
          // Discover and add new emails if queue is empty
          await _fetchNewStatementEmails(imapService, db);
        }

        // Re-fetch queue after potential additions
        final itemsToProcess = await (db.select(db.statementQueue)
          ..where((q) => q.status.equals('pending'))
          ..orderBy([(q) => OrderingTerm.asc(q.queuedAt)])
          ..limit(5)).get();

        // Process queue items
        for (final item in itemsToProcess) {
          try {
            await (db.update(db.statementQueue)
              ..where((q) => q.id.equals(item.id))).write(
              StatementQueueCompanion(status: const Value('processing')),
            );

            // Fetch full message by UID (emailId should contain UID)
            final uid = int.tryParse(item.emailId);
            final message = uid != null ? await imapService.fetchFullMessage(uid) : null;
            if (message == null) {
              // Not in this mailbox (or manual item) — leave for another
              // account/run instead of getting stuck in 'processing'.
              await (db.update(db.statementQueue)
                ..where((q) => q.id.equals(item.id))).write(
                StatementQueueCompanion(status: const Value('pending')),
              );
              continue;
            }

            // Extract PDF attachments
            final pdfs = await imapService.extractPdfAttachments(message);

            // Resolve which account these transactions belong to.
            final source = item.sourceId != null
                ? await repository.getStatementSource(item.sourceId!)
                : null;
            final accounts = await repository.getAllAccounts();
            final accountId = source?.accountId ?? accounts.firstOrNull?.id;

            int transactionCount = 0;
            if (accountId != null) {
              final processor = StatementProcessor(repository);
              final password = await SecureVault.getPdfPassword(item.sourceId ?? '');
              for (final pdf in pdfs) {
                transactionCount += await processor.processPdf(
                  bytes: pdf,
                  accountId: accountId,
                  pdfPassword: password,
                  statementId: item.id,
                );
              }
            } else {
              debugPrint('⚠️ No account available to attach imported transactions');
            }

            // Mark as completed
            await (db.update(db.statementQueue)
              ..where((q) => q.id.equals(item.id))).write(
              StatementQueueCompanion(
                status: const Value('completed'),
                processedAt: Value(DateTime.now()),
              ),
            );

            await notificationService.showStatementProcessed(
              bankName: item.sourceId ?? 'Unknown Bank',
              transactionCount: transactionCount,
            );
          } catch (e) {
            // Update queue status to failed
            await (db.update(db.statementQueue)
              ..where((q) => q.id.equals(item.id))).write(
              StatementQueueCompanion(
                status: const Value('failed'),
                errorMessage: Value(e.toString()),
              ),
            );

            await notificationService.showStatementError(
              bankName: item.sourceId ?? 'Unknown Bank',
              error: e.toString(),
            );
          }
        }
      } finally {
        await imapService.disconnect();
      }
    }
  } finally {
    await db.close();
  }
}

/// Fetch new statement emails using IMAP and add to queue
Future<void> _fetchNewStatementEmails(ImapService imapService, AppDatabase db) async {
  try {
    // Discover statement senders
    final sources = await imapService.discoverStatementSenders(daysBack: 730);
    
    // Get list of sender emails
    final senderEmails = sources.map((s) => s.senderEmail).toList();
    if (senderEmails.isEmpty) {
      debugPrint('📭 No statement senders discovered');
      return;
    }
    
    // Search for emails from discovered senders
    final headers = await imapService.searchStatementEmails(senderEmails, daysBack: 30);
    
    // Add to queue
    for (final header in headers) {
      final uid = header.uid?.toString() ?? '';
      if (uid.isEmpty) continue;
      
      // Check if already in queue
      final existing = await (db.select(db.statementQueue)
        ..where((q) => q.emailId.equals(uid))).getSingleOrNull();
      
      if (existing == null) {
        final fromAddress = header.from?.firstOrNull?.email ?? '';
        final sourceId = await _resolveSourceId(db, fromAddress);

        await db.into(db.statementQueue).insert(StatementQueueCompanion.insert(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          emailId: uid,
          sourceId: Value(sourceId),
          subject: header.decodeSubject() ?? 'Statement',
          emailDate: header.decodeDate() ?? DateTime.now(),
        ));
        debugPrint('📥 Queued statement from ${_detectBankName(fromAddress)}');
      }
    }
  } catch (e) {
    debugPrint('Error fetching statement emails: $e');
  }
}

/// Find an existing StatementSources row for [fromAddress] — or create one,
/// defaulting its destination account to the first account — and return its id.
/// This keeps StatementQueue.sourceId a real foreign key (not a bank name).
Future<String?> _resolveSourceId(AppDatabase db, String fromAddress) async {
  if (fromAddress.isEmpty) return null;
  final existing = await (db.select(db.statementSources)
    ..where((s) => s.senderEmail.equals(fromAddress))).getSingleOrNull();
  if (existing != null) return existing.id;

  final accounts = await db.select(db.accounts).get();
  final id = DateTime.now().millisecondsSinceEpoch.toString();
  await db.into(db.statementSources).insert(StatementSourcesCompanion.insert(
    id: id,
    senderEmail: fromAddress,
    bankName: _detectBankName(fromAddress),
    accountType: 'bank',
    accountId: Value(accounts.firstOrNull?.id),
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
  } finally {
    await db.close();
  }
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
