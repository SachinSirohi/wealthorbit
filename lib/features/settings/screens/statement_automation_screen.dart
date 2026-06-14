import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:drift/drift.dart' show Value;
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/secure_vault.dart';
import '../../../data/services/imap_service.dart';
import '../../../data/services/statement_processor.dart';
import '../../../data/services/gemini_service.dart';
import '../../../data/services/background_service.dart';
import '../../onboarding/screens/statement_discovery_screen.dart';

class StatementAutomationScreen extends StatefulWidget {
  const StatementAutomationScreen({super.key});

  @override
  State<StatementAutomationScreen> createState() => _StatementAutomationScreenState();
}

class _StatementAutomationScreenState extends State<StatementAutomationScreen> {
  AppRepository? _repo;
  List<StatementSource> _sources = [];
  List<StatementQueueData> _queue = [];
  List<Account> _accounts = [];
  List<EmailAccount> _emailAccounts = [];
  bool _isLoading = true;
  bool _isGmailConnected = false;
  bool _automationEnabled = false;
  bool _appLockEnabled = false;
  bool _isSyncing = false;

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

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    try {
      final sources = await _repo!.getAllStatementSources();
      if (!mounted) return;
      final queue = await _repo!.getPendingStatementQueue();
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
              label: Text(_isSyncing ? 'Syncing…' : 'Sync Now', style: GoogleFonts.poppins(color: WoColors.gold)),
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
        Row(
          children: [
            Expanded(child: WoSectionHeader('Processing Queue', padding: EdgeInsets.zero)),
            if (_queue.isNotEmpty)
              WoChip('${_queue.length} Pending', color: WoColors.gold),
            TextButton.icon(
              onPressed: _uploadManualStatement,
              icon: Icon(Icons.upload_file, color: WoColors.gold, size: 16),
              label: Text('Upload PDF',
                  style: GoogleFonts.inter(color: WoColors.gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 16),
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
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _queue.length > 3 ? 3 : _queue.length,
            itemBuilder: (context, index) {
              final item = _queue[index];
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
                          Row(
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2, color: WoColors.gold),
                              ),
                              const SizedBox(width: 8),
                              Text('Processing...', style: GoogleFonts.inter(color: WoColors.gold, fontSize: 11)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
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
    return Container(
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
    );
  }

  /// Gemini AI status + key management. Extraction can't run without a key,
  /// so its state must be visible at a glance.
  Widget _buildGeminiCard() {
    return FutureBuilder<bool>(
      future: SecureVault.hasGeminiApiKey(),
      builder: (context, snap) {
        final configured = snap.data ?? false;
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
                      Text('Gemini AI', style: WoText.subtitle()),
                      Text(
                        configured
                            ? 'API key configured — extraction enabled'
                            : 'No API key — statements cannot be extracted. Tap to add.',
                        style: GoogleFonts.inter(
                          color: configured ? WoColors.textMid : WoColors.orange,
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

  Future<void> _showGeminiKeyDialog() async {
    final controller = TextEditingController(text: await SecureVault.getGeminiApiKey() ?? '');
    if (!mounted) return;
    bool validating = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: WoColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
          title: Text('Gemini API Key', style: WoText.title()),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Free key from aistudio.google.com → "Get API key". Used on-device to read your statement PDFs.',
                style: WoText.caption(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                obscureText: true,
                style: GoogleFonts.inter(color: WoColors.textHi),
                decoration: woInput('API key'),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: GoogleFonts.inter(color: WoColors.red, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: GoogleFonts.poppins(color: WoColors.textMid)),
            ),
            ElevatedButton(
              onPressed: validating
                  ? null
                  : () async {
                      final key = controller.text.trim();
                      if (key.isEmpty) return;
                      setDialogState(() {
                        validating = true;
                        error = null;
                      });
                      final validationError = await GeminiService.validateApiKey(key);
                      if (validationError != null) {
                        setDialogState(() {
                          validating = false;
                          error = validationError.split('\n').first;
                        });
                        return;
                      }
                      await SecureVault.setGeminiApiKey(key);
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) setState(() {});
                    },
              style: WoButtons.primary,
              child: validating
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Text('Validate & Save'),
            ),
          ],
        ),
      ),
    );
  }

  /// View/update the PDF password used to open this source's statements.
  Future<void> _showPdfPasswordDialog(StatementSource source) async {
    final controller = TextEditingController(
      text: await SecureVault.getPdfPassword(source.id) ?? '',
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
            Text(
              'Banks usually mention the password format in the statement email '
              '(e.g. date of birth + last 4 card digits).',
              style: WoText.caption(),
            ),
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
              await SecureVault.setPdfPassword(source.id, controller.text);
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
      final count = await StatementProcessor(_repo!).processPdf(
        bytes: bytes,
        accountId: accountId,
        statementId: statementId,
      );

      // Record a completed queue entry for history.
      await _repo!.insertStatementQueueItem(StatementQueueCompanion.insert(
        id: statementId,
        emailId: 'manual_upload',
        subject: 'Manual Upload: ${result.files.single.name}',
        emailDate: DateTime.now(),
        status: const Value('completed'),
        processedAt: Value(DateTime.now()),
      ));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(count > 0 ? '✅ Imported $count transactions' : 'No transactions found in statement')),
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

    setState(() => _isSyncing = true);
    final processor = StatementProcessor(_repo!);
    final defaultAccountId = _accounts.first.id;
    final emailAccounts = await SecureVault.getEmailAccounts();
    int totalImported = 0;
    int failures = 0;
    final syncedSources = <String>{};
    try {
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
          await imap.discoverStatementSenders(daysBack: 730);

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
            final password = await SecureVault.getPdfPassword(source.id);
            final accountId = source.accountId ?? defaultAccountId;
            final brokerage = isBrokerageSender('${source.bankName} ${source.senderEmail}');
            try {
              for (final pdf in pdfs) {
                totalImported += brokerage
                    ? await processor.processBrokeragePdf(
                        bytes: pdf,
                        accountId: accountId,
                        pdfPassword: password,
                        bankName: source.bankName,
                      )
                    : await processor.processPdf(
                        bytes: pdf,
                        accountId: accountId,
                        pdfPassword: password,
                        statementId: source.id,
                      );
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

      // Post-import smart pass: collapse own-account transfer pairs and
      // seed this month's 50/30/20 budgets from detected income.
      if (totalImported > 0) {
        final transfers = await _repo!.detectInterAccountTransfers();
        final budgets = await _repo!.autoPopulateBudgets();
        debugPrint('🤝 Auto-detected $transfers transfers, created $budgets budgets');
      }

      if (mounted) {
        final msg = totalImported > 0
            ? '✅ Imported $totalImported transactions'
                '${failures > 0 ? ' ($failures failed — check PDF passwords)' : ''}'
            : failures > 0
                ? '⚠️ Sync finished with $failures failures — check PDF passwords & connection'
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
      if (mounted) setState(() => _isSyncing = false);
      _loadData();
    }
  }
}
