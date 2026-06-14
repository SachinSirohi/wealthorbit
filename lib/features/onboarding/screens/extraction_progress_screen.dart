import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/models/discovered_source.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/imap_service.dart';
import '../../../data/services/secure_vault.dart';
import '../../../data/services/statement_processor.dart';
import '../../../data/services/notification_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:go_router/go_router.dart';

/// Screen showing extraction progress - user cannot skip until complete
class ExtractionProgressScreen extends StatefulWidget {
  final List<DiscoveredSource> sources;
  final Map<String, String> passwords;

  const ExtractionProgressScreen({
    super.key,
    required this.sources,
    required this.passwords,
  });

  @override
  State<ExtractionProgressScreen> createState() => _ExtractionProgressScreenState();
}

class _ExtractionProgressScreenState extends State<ExtractionProgressScreen> {
  final ImapService _imapService = ImapService();
  
  int _totalStatements = 0;
  int _processedStatements = 0;
  int _sourceNum = 0; // 1-based index of the bank currently being processed
  int get _totalSources => widget.sources.length;
  int _successfulExtractions = 0;
  int _failedExtractions = 0;
  int _importedTransactions = 0;
  String _currentSource = '';
  String _currentStatus = 'Initializing...';
  bool _isComplete = false;
  bool _hasError = false;
  String? _errorMessage;
  
  // Time tracking
  DateTime? _startTime;
  
  @override
  void initState() {
    super.initState();
    _startExtraction();
  }

  @override
  void dispose() {
    _imapService.disconnect();
    // Clear the ongoing progress notification if the screen goes away mid-run.
    NotificationService().cancelExtractionProgress();
    super.dispose();
  }

  Future<void> _startExtraction() async {
    _startTime = DateTime.now();

    final repo = await AppRepository.getInstance();
    final processor = StatementProcessor(repo);
    final geminiReady = (await StatementProcessor.ensureGeminiReady()) == null;

    // Calculate total statements
    _totalStatements = widget.sources.fold(0, (sum, s) => sum + s.statementCount);
    
    setState(() {
      _currentStatus = 'Connecting to email...';
    });

    try {
      // Connect to IMAP
      final connected = await _imapService.connect();
      if (!connected) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Failed to connect to email server';
        });
        return;
      }

      // First, discover emails to populate cache
      setState(() => _currentStatus = 'Scanning emails...');
      await _imapService.discoverStatementSenders();

      // Process each source
      for (int i = 0; i < widget.sources.length; i++) {
        final source = widget.sources[i];
        
        setState(() {
          _sourceNum = i + 1;
          _currentSource = source.senderName;
          _currentStatus = 'Processing ${source.senderName}...';
        });

        // Get password for this source
        final password = widget.passwords[source.senderEmail] ??
                         await SecureVault.getPdfPassword(source.senderEmail);

        // Reuse one account per bank (several sender addresses → one bank),
        // and tag it with the bank's real reporting currency so ₹ statements
        // aren't read as AED.
        final currency = CurrencyUtils.currencyForBank('${source.senderName} ${source.senderEmail}');
        final accountType = CurrencyUtils.isCreditCardHint('${source.senderName} ${source.senderEmail}')
            ? 'credit_card'
            : 'bank';
        final existingAccounts = await repo.getAllAccounts();
        final existing = existingAccounts
            .where((a) => a.name.toLowerCase() == source.senderName.toLowerCase())
            .firstOrNull;
        final accountId = existing?.id ?? 'acct_${DateTime.now().millisecondsSinceEpoch}_$i';
        if (existing == null) {
          await repo.insertAccount(AccountsCompanion.insert(
            id: accountId,
            name: source.senderName,
            type: accountType,
            currencyCode: currency,
          ));
        } else if (existing.currencyCode != currency) {
          await repo.updateAccountCurrency(existing.id, currency);
        }
        final sourceId = 'src_${DateTime.now().millisecondsSinceEpoch}_$i';
        await repo.insertStatementSource(StatementSourcesCompanion.insert(
          id: sourceId,
          senderEmail: source.senderEmail,
          bankName: source.senderName,
          accountType: 'bank',
          accountId: Value(accountId),
        ));
        if (password != null && password.isNotEmpty) {
          await SecureVault.setPdfPassword(sourceId, password);
        }

        // Get emails from this sender (uses cached headers, newest first).
        // Cap to the most recent few — processing dozens of old emails per
        // bank through AI is slow and rarely adds new statements.
        final allEmails = await _imapService.searchStatementEmails(
          [source.senderEmail],
        );
        const maxPerSource = 6;
        final emails = allEmails.length > maxPerSource
            ? allEmails.sublist(0, maxPerSource)
            : allEmails;

        debugPrint('📧 Found ${allEmails.length} emails from ${source.senderEmail}; processing ${emails.length}');

        // Process each email
        for (int j = 0; j < emails.length; j++) {
          final email = emails[j];

          setState(() {
            _currentStatus = '${source.senderName}: ${j + 1}/${emails.length}';
          });

          try {
            // Fetch full message with attachments. Works with UID when the
            // server provided one, or falls back to the mailbox sequence
            // number — never silently skip a discovered statement.
            final fullMessage = await _imapService.fetchFullMessageFor(email);
            if (fullMessage == null) {
              debugPrint('⚠️ Could not fetch message uid=${email.uid} seq=${email.sequenceId}');
              _failedExtractions++;
              _processedStatements++;
              continue;
            }

            // Extract PDF attachments
            final pdfs = await _imapService.extractPdfAttachments(fullMessage);
            
            if (pdfs.isEmpty) {
              // No PDF attachments - not a failure, just skip
              _processedStatements++;
              continue;
            }

            // Parse & save the first PDF's transactions into the account.
            final pdfBytes = pdfs.first;
            try {
              if (geminiReady) {
                final brokerage = isBrokerageSender('${source.senderName} ${source.senderEmail}');
                final count = brokerage
                    ? await processor.processBrokeragePdf(
                        bytes: pdfBytes,
                        accountId: accountId,
                        pdfPassword: password,
                        bankName: source.senderName,
                      )
                    : await processor.processPdf(
                        bytes: pdfBytes,
                        accountId: accountId,
                        pdfPassword: password,
                        statementId: sourceId,
                      );
                _importedTransactions += count;
                _successfulExtractions++;
                // Dedupe cursor: remember the newest extracted statement.
                final uid = email.uid;
                if (uid != null) {
                  await repo.setSourceLastProcessedUid(sourceId, uid);
                }
                debugPrint('✅ Imported $count transactions from ${source.senderName}');
              } else {
                // No Gemini key yet — sources are still configured for later sync.
                _successfulExtractions++;
              }
            } catch (e) {
              _failedExtractions++;
              debugPrint('❌ PDF processing failed: $e');
            }

          } catch (e) {
            _failedExtractions++;
            debugPrint('❌ Error processing email uid=${email.uid} seq=${email.sequenceId}: $e');
          }

          setState(() {
            _processedStatements++;
          });
          // Ongoing notification so progress is visible even if the user
          // switches apps mid-extraction.
          NotificationService().showExtractionProgress(
            current: _sourceNum,
            total: _totalSources,
            bankName: source.senderName,
          );

          // Small delay to prevent overwhelming the server
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }

      // Post-import smart pass: merge per-sender duplicate accounts,
      // collapse own-account transfers, seed 50/30/20 budgets from income.
      setState(() => _currentStatus = 'Organizing your finances…');
      try {
        await repo.mergeDuplicateAccounts();
        final transfers = await repo.detectInterAccountTransfers();
        final budgets = await repo.autoPopulateBudgets();
        debugPrint('🤝 Auto-detected $transfers transfers, created $budgets budgets');
      } catch (e) {
        debugPrint('⚠️ Post-import pass failed: $e');
      }

      // Mark onboarding as complete
      await SecureVault.setOnboardingComplete(true);
      await NotificationService().completeExtractionProgress(imported: _importedTransactions);

      setState(() {
        _isComplete = true;
        if (!geminiReady) {
          _currentStatus =
              'Sources saved — add your Gemini API key in Settings to extract transactions.';
        } else if (_failedExtractions > 0) {
          _currentStatus =
              'Done: $_importedTransactions transactions imported · $_failedExtractions statement(s) failed (check PDF passwords in Settings).';
        } else {
          _currentStatus = 'Extraction complete! $_importedTransactions transactions imported.';
        }
      });

    } catch (e) {
      debugPrint('❌ Extraction error: $e');
      setState(() {
        _hasError = true;
        _errorMessage = 'Extraction failed: ${e.toString().split('\n').first}';
      });
    } finally {
      await _imapService.disconnect();
    }
  }

  String get _timeElapsed {
    if (_startTime == null) return '0:00';
    final elapsed = DateTime.now().difference(_startTime!);
    final minutes = elapsed.inMinutes;
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _goToDashboard() {
    context.go('/');
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _errorMessage = null;
      _processedStatements = 0;
      _successfulExtractions = 0;
      _failedExtractions = 0;
      _importedTransactions = 0;
    });
    _startExtraction();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Never allow a raw pop — popping into the disposed onboarding stack
      // showed a black screen. Intercept Back: route to the dashboard when
      // done, and block it (stay put) while extraction is still running.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isComplete) _goToDashboard();
      },
      child: Scaffold(
        backgroundColor: WoColors.bg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                
                // Main progress indicator
                _buildProgressIndicator(),
                
                const SizedBox(height: 48),
                
                // Stats
                _buildStats(),
                
                const SizedBox(height: 32),
                
                // Current status
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: woCard(radius: 16),
                  child: Row(
                    children: [
                      if (!_isComplete && !_hasError)
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: WoColors.gold),
                        ),
                      if (_isComplete)
                        Icon(Icons.check_circle, color: WoColors.mint, size: 20),
                      if (_hasError)
                        Icon(Icons.error, color: WoColors.red, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _hasError ? (_errorMessage ?? 'Error occurred') : _currentStatus,
                          style: WoText.bodyHi(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Warning message
                if (!_isComplete && !_hasError)
                  WoNotice(
                    'Please keep the app open. You can minimize but don\'t close.',
                    color: WoColors.orange,
                    icon: Icons.info_outline,
                  ),
                
                const Spacer(),
                
                // Continue button (only when complete)
                if (_isComplete)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _goToDashboard,
                      style: WoButtons.primary,
                      child: const Text('Go to Dashboard'),
                    ),
                  ).animate().fadeIn().slideY(begin: 0.2),

                if (_hasError)
                  Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _retry,
                          style: WoButtons.primary,
                          child: const Text('Retry'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () async {
                          await SecureVault.setOnboardingComplete(true);
                          _goToDashboard();
                        },
                        child: Text(
                          'Skip & Continue to Dashboard',
                          style: WoText.body(),
                        ),
                      ),
                    ],
                  ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressIndicator() {
    // Progress by BANK (not by historical statement count) so it moves clearly
    // 0→100% and always completes — counting every old statement made it look
    // stuck near 0%.
    final progress = _isComplete
        ? 1.0
        : (_totalSources > 0 ? _sourceNum / _totalSources : 0.0);
    
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 200,
              height: 200,
              decoration: woCard(radius: 100, goldGlow: _isComplete),
            ),
            SizedBox(
              width: 180,
              height: 180,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 8,
                backgroundColor: WoColors.borderHi,
                valueColor: AlwaysStoppedAnimation(
                  _isComplete ? WoColors.mint : WoColors.gold,
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${(progress * 100).toInt()}%',
                  style: WoText.hero(),
                ),
                if (_currentSource.isNotEmpty)
                  Text(
                    _currentSource,
                    style: WoText.caption(),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          _isComplete ? 'Extraction Complete!' : 'Extracting Statements...',
          style: WoText.display(),
        ),
        const SizedBox(height: 8),
        Text(
          _isComplete
              ? '$_importedTransactions transactions imported'
              : 'Bank $_sourceNum of $_totalSources · $_importedTransactions imported so far',
          style: WoText.body(),
        ),
      ],
    );
  }

  Widget _buildStats() {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            icon: Icons.timer_outlined,
            label: 'Time',
            value: _timeElapsed,
            color: WoColors.blue,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            icon: Icons.check_circle_outline,
            label: 'Success',
            value: '$_successfulExtractions',
            color: WoColors.mint,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            icon: Icons.receipt_long,
            label: 'Imported',
            value: '$_importedTransactions',
            color: WoColors.gold,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: woCard(radius: 16, tint: color),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          Text(
            value,
            style: WoText.num(size: 18),
          ),
          Text(
            label,
            style: WoText.caption(color: WoColors.textLo),
          ),
        ],
      ),
    );
  }
}
