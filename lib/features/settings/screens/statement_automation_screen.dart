import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/cupertino.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:drift/drift.dart' show Value;
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/statement_backlog.dart';
import '../../../core/amount_sanity.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../navigation/app_router.dart';
import '../../../data/services/secure_vault.dart';
import '../../../data/services/imap_service.dart';
import '../../../data/services/statement_processor.dart';
import '../../../data/services/gemini_service.dart';
import '../../../data/services/background_service.dart';
import '../../../data/services/backup_service.dart';
import '../../../data/services/reconciliation_service.dart';
import '../../../data/services/financial_health_service.dart';
import '../../onboarding/screens/statement_discovery_screen.dart';
import 'package:permission_handler/permission_handler.dart';

class StatementAutomationScreen extends StatefulWidget {
  const StatementAutomationScreen({super.key});

  @override
  State<StatementAutomationScreen> createState() => _StatementAutomationScreenState();
}

class _StatementAutomationScreenState extends State<StatementAutomationScreen> {
  AppRepository? _repo;
  List<StatementSource> _sources = [];
  List<StatementQueueData> _queue = [];
  List<StatementQueueData> _failed = [];
  List<Account> _accounts = [];
  List<EmailAccount> _emailAccounts = [];
  bool _isLoading = true;
  bool _isGmailConnected = false;
  bool _automationEnabled = false;
  bool _appLockEnabled = false;
  bool _isSyncing = false;
  String _syncMessage = '';

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    try {
      _repo = await AppRepository.getInstance();
      if (!mounted) return;
      await _loadData();
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadData({bool showSpinner = true}) async {
    if (!mounted) return;
    if (showSpinner) setState(() => _isLoading = true);
    
    try {
      await _repo!.resetStuckProcessing();
      final sources = await _repo!.getAllStatementSources();
      if (!mounted) return;
      final queue = await _repo!.getPendingStatementQueue();
      if (!mounted) return;
      final failed = await _repo!.getFailedStatementQueue();
      if (!mounted) return;
      final accounts = await _repo!.getAllAccounts();
      if (!mounted) return;

      final emailAccounts = await SecureVault.getEmailAccounts();
      final automation = await _repo!.getBoolSetting('automation_enabled');
      final appLock = await _repo!.getBoolSetting('biometric_enabled');

      if (!mounted) return;
      setState(() {
        _sources = sources;
        _queue = queue;
        _failed = failed
            .where((f) => !isNonBankStatementSubject(f.subject))
            .toList();
        _accounts = accounts;
        _emailAccounts = emailAccounts;
        _isGmailConnected = emailAccounts.isNotEmpty;
        _automationEnabled = automation;
        _appLockEnabled = appLock;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      appBar: AppBar(
        backgroundColor: WoColors.bg,
        elevation: 0,
        title: Text('Statement Automation', style: WoText.title()),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: WoColors.textHi),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: WoColors.gold))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   _buildGmailIntegrationCard(),
                   const SizedBox(height: 16),
                   _buildGeminiCard(),
                   const SizedBox(height: 24),
                   _buildQueueSection(),
                   const SizedBox(height: 24),
                   _buildFailedQueueSection(),
                   const SizedBox(height: 24),
                   _buildSourcesSection(),
                   const SizedBox(height: 24),
                   _buildAppearanceCard(),
                   const SizedBox(height: 16),
                   _buildSecurityCard(),
                   const SizedBox(height: 100),
                ],
              ),
            ),
    );
  }
  
  Widget _buildGmailIntegrationCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: _isGmailConnected ? woCard(tint: WoColors.blue) : woCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  WoIconBubble(Icons.email_outlined,
                      color: _isGmailConnected ? WoColors.blue : WoColors.textMid, size: 44),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Email Sync', style: WoText.title()),
                      Text(
                        _isGmailConnected
                            ? '${_emailAccounts.length} account${_emailAccounts.length == 1 ? '' : 's'} connected'
                            : 'Not Connected',
                        style: WoText.caption(),
                      ),
                    ],
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: _showAddEmailSheet,
                icon: Icon(Icons.add, color: WoColors.gold, size: 18),
                label: Text('Add', style: GoogleFonts.poppins(color: WoColors.gold, fontWeight: FontWeight.w600)),
                style: TextButton.styleFrom(
                  backgroundColor: WoColors.goldDim.withValues(alpha: 0.12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: WoColors.gold.withValues(alpha: 0.3), width: 0.8),
                  ),
                ),
              ),
            ],
          ),
          if (_isGmailConnected) ...[
            const SizedBox(height: 12),
            ..._emailAccounts.map((a) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.envelope_fill, color: WoColors.textMid, size: 14),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(a.email,
                            style: GoogleFonts.inter(color: WoColors.textHi, fontSize: 13),
                            overflow: TextOverflow.ellipsis),
                      ),
                      InkWell(
                        onTap: () => _removeEmailAccount(a.email),
                        child: Icon(Icons.close, color: WoColors.textLo, size: 16),
                      ),
                    ],
                  ),
                )),
            Divider(color: WoColors.borderHi),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _automationEnabled,
              onChanged: (v) => _setAutomation(v),
              activeThumbColor: WoColors.gold,
              activeTrackColor: WoColors.goldDim,
              title: Text('Auto-sync in background',
                  style: GoogleFonts.poppins(color: WoColors.textHi, fontSize: 14)),
              subtitle: Text('Check email & extract statements every 6 hours',
                  style: WoText.caption()),
            ),
            TextButton.icon(
              onPressed: _isSyncing ? null : _syncEmails,
              icon: _isSyncing
                  ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: WoColors.gold))
                  : Icon(Icons.sync, color: WoColors.gold),
              label: Text(
                _isSyncing
                    ? (_syncMessage.isEmpty ? 'Syncing…' : _syncMessage)
                    : 'Sync Now',
                style: GoogleFonts.poppins(color: WoColors.gold),
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.1);
  }

  Widget _buildQueueSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title and count on their own line: three buttons alongside an
        // Expanded header squeezed it until "Processing Queue" wrapped to
        // one letter per line.
        Row(
          children: [
            Expanded(child: WoSectionHeader('Processing Queue', padding: EdgeInsets.zero)),
            if (_queue.isNotEmpty)
              WoChip('${_queue.length} pending', color: WoColors.gold),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _queueAction(
              icon: CupertinoIcons.chart_bar_alt_fill,
              label: 'Data health',
              onPressed: () => context.push(AppRoutes.dataHealth),
            ),
            _queueAction(
              icon: Icons.upload_file,
              label: 'Upload PDF',
              onPressed: _uploadManualStatement,
            ),
            _queueAction(
              icon: CupertinoIcons.arrow_2_circlepath,
              label: 'Re-extract processed',
              onPressed: _reExtractProcessed,
              muted: true,
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (_queue.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: woCard(),
            child: Column(
              children: [
                 Icon(CupertinoIcons.checkmark_circle, color: WoColors.mint, size: 40),
                 const SizedBox(height: 12),
                 Text('All caught up!', style: WoText.subtitle()),
                 Text('No pending statements to process', style: WoText.caption()),
              ],
            ),
          )
        else ...[
          if (_queue.length > StatementBacklog.drainBatchSize)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '${_queue.length} statements queued from the last '
                '${StatementBacklog.lookbackYears} years, newest first. '
                'Sync Now works through them until it runs out of time, then '
                'picks up where it left off.',
                style: WoText.caption(),
              ),
            ),
          ..._queue.take(StatementBacklog.drainBatchSize).map((item) {
            final waiting = item.status != 'processing';
            final dateLabel = DateFormat.yMMMd().format(item.emailDate.toLocal());
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: woCard(radius: 16),
              child: Row(
                children: [
                  WoIconBubble(Icons.picture_as_pdf, color: WoColors.red, size: 36),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.subject, style: WoText.bodyHi(), maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Text(
                          waiting ? 'Queued · $dateLabel' : 'Processing · $dateLabel',
                          style: GoogleFonts.inter(
                            color: waiting ? WoColors.textMid : WoColors.gold,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _buildFailedQueueSection() {
    if (_failed.isEmpty) return const SizedBox.shrink();

    final passwordFails = _failed
        .where((f) => (f.errorMessage ?? '').toLowerCase().contains('password'))
        .length;
    final timeouts = _failed
        .where((f) => (f.errorMessage ?? '').toLowerCase().contains('timeout'))
        .length;
    // Statements that ran cleanly but produced no transactions. These used
    // to be filed as `completed` and disappeared from view entirely.
    final emptyResults = _failed.where((f) => f.status == 'empty').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: WoSectionHeader('Failed statements', padding: EdgeInsets.zero),
            ),
            WoChip('${_failed.length}', color: WoColors.red),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          [
            if (passwordFails > 0) '$passwordFails need a PDF password',
            if (timeouts > 0) '$timeouts timed out (retryable)',
            if (emptyResults > 0) '$emptyResults imported nothing',
            if (passwordFails == 0 && timeouts == 0 && emptyResults == 0)
              'Tap an item to fix or retry',
          ].where((s) => s.isNotEmpty).join(' · '),
          style: WoText.caption(),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (timeouts > 0)
              TextButton.icon(
                onPressed: _isSyncing ? null : () => _retryFailed(timeoutsOnly: true),
                icon: Icon(Icons.refresh, color: WoColors.gold, size: 16),
                label: Text('Retry timeouts',
                    style: GoogleFonts.inter(color: WoColors.gold, fontSize: 12.5)),
              ),
            TextButton.icon(
              onPressed: _isSyncing ? null : () => _retryFailed(timeoutsOnly: false),
              icon: Icon(Icons.replay, color: WoColors.gold, size: 16),
              label: Text('Retry all',
                  style: GoogleFonts.inter(color: WoColors.gold, fontSize: 12.5)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._failed.take(12).map((item) {
          final err = item.errorMessage ?? 'Failed';
          final needsPassword = err.toLowerCase().contains('password');
          final dateLabel = DateFormat.yMMMd().format(item.emailDate.toLocal());
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: woCard(radius: 16, tint: WoColors.red),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.subject,
                    style: WoText.bodyHi(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('$dateLabel · $err',
                    style: GoogleFonts.inter(color: WoColors.textMid, fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (needsPassword && item.sourceId != null)
                      TextButton(
                        onPressed: () => _fixFailedPassword(item),
                        child: Text('Set password & retry',
                            style: GoogleFonts.inter(
                                color: WoColors.gold,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600)),
                      )
                    else
                      TextButton(
                        onPressed: () async {
                          await _repo!.requeueStatementItem(item.id);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Re-queued — tap Sync Now')),
                            );
                            await _loadData(showSpinner: false);
                          }
                        },
                        child: Text('Retry',
                            style: GoogleFonts.inter(
                                color: WoColors.gold,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600)),
                      ),
                    TextButton(
                      onPressed: () async {
                        await _repo!.deleteStatementQueueItem(item.id);
                        await _loadData(showSpinner: false);
                      },
                      child: Text('Dismiss',
                          style: GoogleFonts.inter(
                              color: WoColors.textMid, fontSize: 12.5)),
                    ),
                  ],
                ),
              ],
            ),
          );
        }),
        if (_failed.length > 12)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('+ ${_failed.length - 12} more failed',
                style: WoText.caption()),
          ),
      ],
    );
  }

  /// Re-run statements already marked processed. Import guards have wrongly
  /// rejected real lines before, and a completed statement is never looked at
  /// again — this is the way to recover them. Dedupe means nothing already
  /// imported comes back twice.
  Future<void> _reExtractProcessed() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WoColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
        title: Text('Re-extract processed statements', style: WoText.title()),
        content: Text(
          'Runs every already-processed statement through extraction again, so '
          'lines an earlier version wrongly skipped can be recovered. '
          'Transactions you already have are not duplicated.\n\n'
          'This re-queues a lot of work — Sync Now handles a batch at a time.',
          style: WoText.body(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.poppins(color: WoColors.textMid)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: WoButtons.primary,
            child: const Text('Re-extract'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final n = await _repo!.requeueCompletedStatements();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Re-queued $n statements — tap Sync Now')),
    );
    await _loadData(showSpinner: false);
  }

  Future<void> _retryFailed({required bool timeoutsOnly}) async {
    final n = await _repo!.requeueFailedStatements(timeoutsOnly: timeoutsOnly);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Re-queued $n statements — tap Sync Now')),
    );
    await _loadData(showSpinner: false);
  }

  /// What this particular institution protects its PDFs with. Brokers and
  /// depositories in India use the PAN almost universally; banks vary, so
  /// they get the general list. Saves guessing on the one that matters most.
  String _passwordHint(String bankName, String senderEmail) {
    final hay = '$bankName $senderEmail'.toLowerCase();
    if (isBrokerageSender(hay)) {
      return 'Brokers and depositories (Zerodha, CDSL, NSDL, CAMS, NPS) use your '
          'PAN in CAPITALS — e.g. ABCDE1234F. Entered once, it is reused for the '
          'others automatically.';
    }
    return 'Banks state the format in the statement email — usually date of '
        'birth (DDMMYYYY), PAN, or the last 4 digits of the account or card.';
  }

  Future<void> _fixFailedPassword(StatementQueueData item) async {
    // A statement with no mapped source used to return here, so the button
    // opened nothing and said nothing — you could tap "Set password & retry"
    // all day and the statement would keep failing. Those are exactly the
    // items that need a password most, so they get the dialog too: the key
    // is stored against the queue row, and extraction tries every saved
    // password before giving up, so it still reaches this PDF.
    final sourceId = item.sourceId;
    final source =
        sourceId == null ? null : _sources.where((s) => s.id == sourceId).firstOrNull;
    final controller = TextEditingController(
      // Resolve across every key space, not just the source id, or a
      // password saved during onboarding looks absent here.
      text: await SecureVault.resolvePdfPassword(
            sourceId: sourceId,
            senderEmail: source?.senderEmail,
            bankName: source?.bankName,
          ) ??
          '',
    );
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WoColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
        title: Text(
          '${source?.bankName ?? 'Statement'} PDF password',
          style: WoText.title(),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.subject, style: WoText.caption(), maxLines: 2),
            const SizedBox(height: 10),
            Text(_passwordHint(source?.bankName ?? '', source?.senderEmail ?? ''),
                style: WoText.caption(color: WoColors.textMid)),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              obscureText: true,
              style: GoogleFonts.inter(color: WoColors.textHi),
              decoration: woInput('Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.poppins(color: WoColors.textMid)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: WoButtons.primary,
            child: const Text('Save & retry'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    await SecureVault.setPdfPasswordForSource(
      // With no source, key it to the queue row — the known-password sweep
      // during extraction will still find and try it.
      sourceId: sourceId ?? item.id,
      senderEmail: source?.senderEmail,
      password: controller.text.trim(),
    );
    await _repo!.requeueStatementItem(item.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password saved — tap Sync Now to process')),
    );
    await _loadData(showSpinner: false);
  }

  Widget _buildSourcesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: WoSectionHeader('Email Sources', padding: EdgeInsets.zero)),
            TextButton.icon(
              onPressed: _discoverMoreSources,
              icon: Icon(CupertinoIcons.search, color: WoColors.gold, size: 15),
              label: Text('Discover',
                  style: GoogleFonts.inter(color: WoColors.gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            IconButton(
              tooltip: 'Add a source manually',
              onPressed: _showAddSourceSheet,
              icon: Icon(Icons.add_circle, color: WoColors.gold),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_sources.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: woCard(),
            child: Column(
              children: [
                 Icon(Icons.mark_email_unread_outlined, color: WoColors.textLo, size: 40),
                 const SizedBox(height: 12),
                 Text('No sources configured', style: WoText.subtitle()),
                 Text('Add bank email addresses to auto-detect statements', style: WoText.caption()),
              ],
            ),
          )
        else
          ..._sources.map((source) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: woCard(radius: 16),
            child: Row(
              children: [
                WoIconBubble(Icons.account_balance, color: WoColors.blue, size: 40),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(source.bankName, style: WoText.subtitle()),
                      Text(source.senderEmail, style: WoText.caption()),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'PDF password',
                  icon: Icon(CupertinoIcons.lock_shield, color: WoColors.gold, size: 20),
                  onPressed: () => _showPdfPasswordDialog(source),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: WoColors.textLo, size: 20),
                  onPressed: () async {
                    await _repo!.deleteStatementSource(source.id);
                    _loadData();
                  },
                ),
              ],
            ),
          )),
      ],
    );
  }

  Widget _buildAppearanceCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: woCard(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              WoIconBubble(
                WoTheme.isDark ? CupertinoIcons.moon_fill : CupertinoIcons.sun_max_fill,
                color: WoColors.indigo,
                size: 38,
              ),
              const SizedBox(width: 12),
              Text('Appearance', style: WoText.title()),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: WoThemeMode.values.map((m) {
              final selected = WoTheme.mode == m;
              final label = switch (m) {
                WoThemeMode.system => 'System',
                WoThemeMode.light => 'Light',
                WoThemeMode.dark => 'Dark',
              };
              return Expanded(
                child: GestureDetector(
                  onTap: () async {
                    WoTheme.apply(
                      m,
                      WidgetsBinding.instance.platformDispatcher.platformBrightness,
                    );
                    await _repo!.setAppSetting('theme_mode', m.name);
                    if (mounted) setState(() {});
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(
                      color: selected ? WoColors.gold : WoColors.inputFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: selected ? WoColors.gold : WoColors.border),
                    ),
                    child: Center(
                      child: Text(
                        label,
                        style: GoogleFonts.inter(
                          color: selected
                              ? (WoTheme.isDark ? Colors.black : Colors.white)
                              : WoColors.textMid,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityCard() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: woCard(),
          child: SwitchListTile(
            value: _appLockEnabled,
            activeThumbColor: WoColors.gold,
            activeTrackColor: WoColors.goldDim,
            onChanged: (v) async {
              await _repo!.setAppSetting('biometric_enabled', v ? 'true' : 'false');
              if (mounted) setState(() => _appLockEnabled = v);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(v ? 'App lock enabled — applies next launch' : 'App lock disabled')),
                );
              }
            },
            secondary: Icon(CupertinoIcons.lock_shield, color: WoColors.gold),
            title: Text('App Lock (Biometric)', style: WoText.subtitle()),
            subtitle: Text('Require Face/fingerprint to open the app', style: WoText.caption()),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: woCard(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  WoIconBubble(CupertinoIcons.arrow_down_doc, color: WoColors.gold, size: 42),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Phone transfer', style: WoText.subtitle()),
                        Text(
                          'Encrypted backup of accounts, transactions, PDF passwords, and mail passwords. Only WealthOrbit can open the file.',
                          style: WoText.caption(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => BackupService.showExportFlow(context),
                      icon: const Icon(CupertinoIcons.share, size: 16),
                      label: const Text('Export'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => BackupService.showImportFlow(context),
                      icon: const Icon(CupertinoIcons.tray_arrow_down, size: 16),
                      label: const Text('Restore'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _queueAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool muted = false,
  }) {
    final color = muted ? WoColors.textMid : WoColors.gold;
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        visualDensity: VisualDensity.compact,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, color: color, size: 15),
      label: Text(label,
          style: GoogleFonts.inter(
              color: color, fontSize: 12.5, fontWeight: FontWeight.w600)),
    );
  }

  /// Which engines are configured. Gemini leads and Qwen backs it up, so
  /// both matter to what this card should say.
  Future<({bool any, bool gemini})> _llmKeyState() async => (
        any: await SecureVault.hasAnyLlmKey(),
        gemini: await SecureVault.hasGeminiApiKey(),
      );

  /// AI engine status + key management. Extraction can't run without a key,
  /// so its state must be visible at a glance.
  Widget _buildGeminiCard() {
    return FutureBuilder<({bool any, bool gemini})>(
      future: _llmKeyState(),
      builder: (context, snap) {
        final configured = snap.data?.any ?? false;
        final hasGemini = snap.data?.gemini ?? false;
        return InkWell(
          onTap: _showGeminiKeyDialog,
          borderRadius: BorderRadius.circular(WoRadius.card),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: configured
                ? woCard()
                : woCard(tint: WoColors.orange).copyWith(
                    border: Border.all(color: WoColors.orange.withValues(alpha: 0.55), width: 1),
                  ),
            child: Row(
              children: [
                WoIconBubble(CupertinoIcons.sparkles, color: WoColors.indigo, size: 42),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('WealthOrbit AI', style: WoText.subtitle()),
                      Text(
                        !configured
                            ? 'No API key — statements cannot be extracted. Tap to add.'
                            : hasGemini
                                // Gemini leads; Qwen only picks up calls it
                                // cannot serve, one at a time.
                                ? 'Gemini, with Qwen as fallback · ${GeminiService.activeEngine}'
                                : 'qwen-14b only — add a Gemini key for faster extraction',
                        style: GoogleFonts.inter(
                          color: !configured
                              ? WoColors.orange
                              : hasGemini
                                  ? WoColors.textMid
                                  : WoColors.gold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  configured ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.exclamationmark_circle_fill,
                  color: configured ? WoColors.mint : WoColors.orange,
                  size: 22,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Both engines, each with its own field.
  ///
  /// This was a single unlabelled "AI API Key" box whose description named
  /// only qwen-14b. Pasting a Google key did the right thing — keys are
  /// filed by shape — but nothing said so, so there was no way to discover
  /// that Gemini could be configured at all.
  Future<void> _showGeminiKeyDialog() async {
    final geminiController =
        TextEditingController(text: await SecureVault.getGeminiApiKey() ?? '');
    final qwenController =
        TextEditingController(text: await SecureVault.getQwenApiKey() ?? '');
    if (!mounted) return;

    bool saving = false;
    String? error;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: WoSheet(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI engines', style: WoText.title()),
                const SizedBox(height: 6),
                Text(
                  'Statements are read by Gemini first. Qwen picks up any '
                  'single request Gemini cannot serve, then the next one goes '
                  'back to Gemini.',
                  style: WoText.caption(),
                ),
                const SizedBox(height: 20),

                _engineField(
                  label: 'Gemini · primary',
                  hint: 'AIza…',
                  controller: geminiController,
                  blurb: 'Faster and more accurate. Free key from '
                      'aistudio.google.com/apikey — the free tier is enough; '
                      'the app paces requests and rotates models to stay in it.',
                  accent: WoColors.gold,
                ),
                const SizedBox(height: 18),
                _engineField(
                  label: 'Qwen · fallback',
                  hint: 'sk-…',
                  controller: qwenController,
                  blurb: 'Self-hosted, slower, no quota. Used only when '
                      'Gemini is rate-limited or unreachable.',
                  accent: WoColors.indigo,
                ),

                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!,
                      style: GoogleFonts.inter(color: WoColors.red, fontSize: 12)),
                ],
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: WoButtons.primary,
                    onPressed: saving
                        ? null
                        : () async {
                            setSheetState(() {
                              saving = true;
                              error = null;
                            });
                            final problem = await _saveEngineKeys(
                              gemini: geminiController.text.trim(),
                              qwen: qwenController.text.trim(),
                            );
                            if (problem != null) {
                              setSheetState(() {
                                saving = false;
                                error = problem;
                              });
                              return;
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) setState(() {});
                          },
                    child: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black))
                        : const Text('Validate & save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _engineField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required String blurb,
    required Color accent,
  }) {
    final configured = controller.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                  color: accent, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 8),
            Text(label, style: WoText.subtitle()),
            const SizedBox(width: 8),
            WoChip(configured ? 'Set' : 'Not set',
                color: configured ? WoColors.mint : WoColors.textLo),
          ],
        ),
        const SizedBox(height: 6),
        Text(blurb, style: WoText.caption(color: WoColors.textLo)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: true,
          style: GoogleFonts.inter(color: WoColors.textHi),
          decoration: woInput(hint),
        ),
      ],
    );
  }

  /// Validate whichever keys were supplied and store each in its own slot.
  /// An empty field clears nothing — it just means "leave this engine as is".
  Future<String?> _saveEngineKeys({
    required String gemini,
    required String qwen,
  }) async {
    if (gemini.isEmpty && qwen.isEmpty) {
      return 'Enter at least one key.';
    }
    if (gemini.isNotEmpty) {
      if (!SecureVault.looksLikeGeminiKey(gemini)) {
        return 'That does not look like a Google API key — they start with '
            '"AIza". Paste a Qwen key in the field below instead.';
      }
      final problem = await GeminiService.validateAndStoreKey(gemini);
      if (problem != null) return problem.split('\n').first;
    }
    if (qwen.isNotEmpty) {
      if (SecureVault.looksLikeGeminiKey(qwen)) {
        return 'That is a Google key — put it in the Gemini field above.';
      }
      final problem = await GeminiService.validateAndStoreKey(qwen);
      if (problem != null) return problem.split('\n').first;
    }
    return null;
  }


  /// View/update the PDF password used to open this source's statements.
  Future<void> _showPdfPasswordDialog(StatementSource source) async {
    final controller = TextEditingController(
      text: await SecureVault.resolvePdfPassword(
            sourceId: source.id,
            senderEmail: source.senderEmail,
            bankName: source.bankName,
          ) ??
          '',
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WoColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
        title: Text('${source.bankName} PDF password', style: WoText.title()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_passwordHint(source.bankName, source.senderEmail),
                style: WoText.caption()),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              style: GoogleFonts.inter(color: WoColors.textHi),
              decoration: woInput('Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.poppins(color: WoColors.textMid)),
          ),
          ElevatedButton(
            onPressed: () async {
              await SecureVault.setPdfPasswordForSource(
                sourceId: source.id,
                senderEmail: source.senderEmail,
                password: controller.text,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            style: WoButtons.primary,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeEmailAccount(String email) async {
    await SecureVault.removeEmailAccount(email);
    final remaining = await SecureVault.getEmailAccounts();
    if (remaining.isEmpty) await _setAutomation(false);
    _loadData();
  }

  void _showAddEmailSheet() {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    String provider = 'gmail';
    bool testing = false;
    String? error;

    InputDecoration deco(String label, {String? hint}) => woInput(label, hint: hint);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Container(
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
          decoration: BoxDecoration(
            color: WoColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const WoSheetHandle(),
                Text('Connect Email Account', style: WoText.display()),
                const SizedBox(height: 8),
                Text(
                  'Use an app password — not your normal password. '
                  'Gmail: myaccount.google.com → Security → App passwords.',
                  style: WoText.caption(),
                ),
                const SizedBox(height: 20),
                InputDecorator(
                  decoration: deco('Provider'),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: provider,
                      isExpanded: true,
                      dropdownColor: WoColors.surfaceHi,
                      onChanged: (v) => setSheetState(() => provider = v ?? 'gmail'),
                      items: [
                        DropdownMenuItem(value: 'gmail', child: Text('Gmail', style: TextStyle(color: WoColors.textHi))),
                        DropdownMenuItem(value: 'outlook', child: Text('Outlook / Hotmail', style: TextStyle(color: WoColors.textHi))),
                        DropdownMenuItem(value: 'yahoo', child: Text('Yahoo', style: TextStyle(color: WoColors.textHi))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  style: GoogleFonts.inter(color: WoColors.textHi),
                  decoration: deco('Email address', hint: 'you@gmail.com'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  style: GoogleFonts.inter(color: WoColors.textHi),
                  decoration: deco('App password'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  WoNotice(error!, color: WoColors.red, icon: Icons.error_outline),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: testing
                        ? null
                        : () async {
                            final email = emailController.text.trim();
                            final password = passwordController.text;
                            if (email.isEmpty || password.isEmpty) {
                              setSheetState(() => error = 'Enter email and app password');
                              return;
                            }
                            setSheetState(() {
                              testing = true;
                              error = null;
                            });
                            // Verify the credentials with a real IMAP login.
                            final probe = ImapService(
                              account: EmailAccount(email: email, password: password, provider: provider),
                            );
                            final ok = await probe.connect();
                            await probe.disconnect();
                            if (!ok) {
                              setSheetState(() {
                                testing = false;
                                error = 'Could not sign in. Check the email and app password.';
                              });
                              return;
                            }
                            await SecureVault.addEmailAccount(email, password, provider);
                            if (sheetContext.mounted) Navigator.pop(sheetContext);
                            _loadData();
                          },
                    style: WoButtons.primary,
                    child: testing
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Text('Verify & Connect'),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _setAutomation(bool enabled) async {
    await _repo!.setAppSetting('automation_enabled', enabled ? 'true' : 'false');
    try {
      if (enabled) {
        await Permission.ignoreBatteryOptimizations.request();
        await BackgroundService.initialize();
        await BackgroundService.registerTasks();
      } else {
        await BackgroundService.cancelAllTasks();
      }
    } catch (_) {}
    if (mounted) setState(() => _automationEnabled = enabled);
  }

  Future<String?> _pickAccount() async {
    if (_accounts.length == 1) return _accounts.first.id;
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: WoColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
        title: Text('Import into which account?', style: WoText.title()),
        children: _accounts
            .map((a) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, a.id),
                  child: Text('${a.name} (${a.currencyCode})', style: GoogleFonts.poppins(color: WoColors.textHi)),
                ))
            .toList(),
      ),
    );
  }

  Future<void> _uploadManualStatement() async {
    if (_accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add an account first to import into')),
      );
      return;
    }
    final geminiError = await StatementProcessor.ensureGeminiReady();
    if (geminiError != null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(geminiError)));
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
      );
      if (result == null) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not read file')));
        return;
      }

      final accountId = await _pickAccount();
      if (accountId == null) return;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⏳ Extracting statement…')));
      }

      final statementId = DateTime.now().millisecondsSinceEpoch.toString();
      final imported = await StatementProcessor(_repo!).processPdf(
        bytes: bytes,
        accountId: accountId,
        statementId: statementId,
      );

      // Record the outcome for history — `empty` when nothing was imported,
      // so the reason stays visible in the failed list.
      await _repo!.insertStatementQueueItem(StatementQueueCompanion.insert(
        id: statementId,
        emailId: 'manual_upload',
        subject: 'Manual Upload: ${result.files.single.name}',
        emailDate: DateTime.now(),
        status: Value(imported.isEmpty ? 'empty' : 'completed'),
        errorMessage: Value(imported.emptyReason),
        processedAt: Value(DateTime.now()),
      ));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(imported.imported > 0
              ? '✅ Imported ${imported.imported} transactions'
              : imported.emptyReason ?? 'No transactions found in statement')),
        );
      }
      _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  /// Re-run inbox discovery to add NEW sources from the already-connected
  /// mailbox (the flow that was previously only reachable in onboarding).
  void _discoverMoreSources() {
    if (_emailAccounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect an email account first')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const StatementDiscoveryScreen()),
    ).then((_) => _loadData());
  }

  void _showAddSourceSheet() {
    final emailController = TextEditingController();
    final bankController = TextEditingController();
    String? selectedAccountId = _accounts.isNotEmpty ? _accounts.first.id : null;

    InputDecoration deco(String label, {String? hint}) => woInput(label, hint: hint);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          decoration: BoxDecoration(
            color: WoColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const WoSheetHandle(),
                Text('Add Statement Source', style: WoText.display()),
                const SizedBox(height: 24),
                TextField(controller: bankController, style: GoogleFonts.inter(color: WoColors.textHi), decoration: deco('Bank Name')),
                const SizedBox(height: 16),
                TextField(controller: emailController, style: GoogleFonts.inter(color: WoColors.textHi), decoration: deco('Sender Email', hint: 'e.g., no-reply@bank.com')),
                const SizedBox(height: 16),
                if (_accounts.isEmpty)
                  WoNotice(
                    'Add an account first so imports have somewhere to go.',
                    color: WoColors.orange,
                    icon: Icons.info_outline,
                  )
                else
                  InputDecorator(
                    decoration: deco('Import into account'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedAccountId,
                        isExpanded: true,
                        dropdownColor: WoColors.surfaceHi,
                        icon: Icon(CupertinoIcons.chevron_down, size: 14, color: WoColors.textMid),
                        onChanged: (v) => setSheetState(() => selectedAccountId = v),
                        items: _accounts
                            .map((a) => DropdownMenuItem(
                                  value: a.id,
                                  child: Text('${a.name} (${a.currencyCode})', style: GoogleFonts.poppins(color: WoColors.textHi, fontSize: 14)),
                                ))
                            .toList(),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (bankController.text.isNotEmpty && emailController.text.isNotEmpty) {
                        await _repo!.insertStatementSource(StatementSourcesCompanion(
                          id: Value(DateTime.now().millisecondsSinceEpoch.toString()),
                          bankName: Value(bankController.text),
                          senderEmail: Value(emailController.text),
                          accountType: const Value('bank'),
                          accountId: Value(selectedAccountId),
                        ));
                        if (context.mounted) Navigator.pop(context);
                        _loadData();
                      }
                    },
                    style: WoButtons.primary,
                    child: const Text('Add Source'),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Future<void> _syncEmails() async {
    final geminiError = await StatementProcessor.ensureGeminiReady();
    if (geminiError != null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(geminiError)));
      return;
    }
    if (_accounts.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add an account first to import into')),
        );
      }
      return;
    }
    final sources = await _repo!.getAllStatementSources();
    if (sources.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add an email source first (＋ under Email Sources)')),
        );
      }
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncMessage = 'Starting queue…';
    });
    final processor = StatementProcessor(_repo!);
    final emailAccounts = await SecureVault.getEmailAccounts();
    int totalImported = 0;
    int failures = 0;
    final syncedSources = <String>{};
    final unmappedSources = <String>{};
    try {
      // Drain the IMAP queue first. Sync used to only fetch the latest email
      // per sender, which left a 2-year backlog sitting as "pending".
      await BackgroundService.processStatementQueueNow(
        maxItems: StatementBacklog.drainBatchSize,
        onProgress: (msg) {
          if (!mounted) return;
          setState(() => _syncMessage = msg);
          _loadData(showSpinner: false);
        },
      );
      await _loadData(showSpinner: false);
      final stillQueued = _queue.length;
      if (stillQueued > StatementBacklog.drainBatchSize) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Processed a batch. $stillQueued still queued — tap Sync Now again.'),
          ));
        }
        return;
      }
      setState(() => _syncMessage = 'Checking latest per bank…');
      // Search every connected mailbox; a source's statements may live in any.
      for (final emailAccount in emailAccounts) {
        final imap = ImapService(account: emailAccount);
        try {
          final connected = await imap.connect();
          if (!connected) {
            failures++;
            continue;
          }
          // Prime the header cache so per-sender lookups work.
          await imap.discoverStatementSenders(
            daysBack: StatementBacklog.incrementalFetchDays,
          );

          for (final source in sources) {
            if (syncedSources.contains(source.id)) continue;
            await Future<void>.delayed(Duration.zero); // yield so the UI stays responsive
            final message = await imap.fetchLatestMessageForSender(source.senderEmail);
            if (message == null) continue;

            // Statement-level dedupe: skip if this exact email was already
            // extracted (transaction-level dedupe still backstops overlaps).
            final uid = message.uid;
            if (uid != null && source.lastProcessedUid != null && uid <= source.lastProcessedUid!) {
              debugPrint('⏭️ ${source.bankName}: statement UID $uid already processed');
              syncedSources.add(source.id);
              continue;
            }

            final pdfs = await imap.extractPdfAttachments(message);
            // Resolve across every key space onboarding and settings write to.
            final password = await SecureVault.resolvePdfPassword(
              sourceId: source.id,
              senderEmail: source.senderEmail,
              bankName: source.bankName,
            );
            // Never fall back to "the first account": that relabels this
            // bank's amounts with another account's currency.
            final accountId = source.accountId;
            if (accountId == null) {
              failures++;
              unmappedSources.add(source.bankName);
              debugPrint('⏭️ ${source.bankName}: no account mapped — skipped');
              continue;
            }
            final brokerage = isBrokerageSender('${source.bankName} ${source.senderEmail}');
            try {
              for (final pdf in pdfs) {
                final result = brokerage
                    ? await processor.processBrokeragePdf(
                        bytes: pdf,
                        accountId: accountId,
                        pdfPassword: password,
                        bankName: source.bankName,
                        sourceId: source.id,
                        senderEmail: source.senderEmail,
                      )
                    : await processor.processPdf(
                        bytes: pdf,
                        accountId: accountId,
                        pdfPassword: password,
                        statementId: source.id,
                        sourceId: source.id,
                        senderEmail: source.senderEmail,
                      );
                totalImported += result.imported;
                if (result.isEmpty && result.emptyReason != null) {
                  debugPrint('⚪️ ${source.bankName}: ${result.emptyReason}');
                }
              }
              syncedSources.add(source.id);
              if (uid != null) await _repo!.setSourceLastProcessedUid(source.id, uid);
              await _repo!.updateStatementSource(
                source.id,
                StatementSourcesCompanion(lastSyncAt: Value(DateTime.now())),
              );
            } catch (e) {
              failures++;
              debugPrint('Statement processing failed for ${source.bankName}: $e');
            }
          }
        } finally {
          await imap.disconnect();
        }
      }

      // Post-import smart pass: AI transfer matching + budgets.
      try {
        final reconMsg = await ReconciliationService(_repo!).run();
        final budgets = await _repo!.autoPopulateBudgets();
        debugPrint('🤝 $reconMsg, created $budgets budgets');
        await FinancialHealthService(_repo!).ensureCurrentMonthReport();
      } catch (e) {
        debugPrint('Post-sync reconciliation failed: $e');
      }

      if (mounted) {
        final unmapped = unmappedSources.isEmpty
            ? ''
            : ' Map ${unmappedSources.join(', ')} to an account.';
        final msg = totalImported > 0
            ? '✅ Imported $totalImported transactions'
                '${failures > 0 ? ' ($failures need attention)' : ''}$unmapped'
            : failures > 0
                ? '⚠️ Nothing imported — $failures statement(s) need attention.$unmapped'
                : 'No new statement transactions found';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncMessage = '';
        });
      }
      _loadData();
    }
  }
}
