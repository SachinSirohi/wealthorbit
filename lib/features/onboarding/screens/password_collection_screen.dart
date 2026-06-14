import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:enough_mail/enough_mail.dart' show MimeMessage;
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/models/discovered_source.dart';
import '../../../data/services/imap_service.dart';
import '../../../data/services/pdf_extraction_service.dart';
import '../../../data/services/secure_vault.dart';
import 'extraction_progress_screen.dart';

/// Screen for collecting PDF passwords per sender
class PasswordCollectionScreen extends StatefulWidget {
  final List<DiscoveredSource> sources;
  
  const PasswordCollectionScreen({super.key, required this.sources});

  @override
  State<PasswordCollectionScreen> createState() => _PasswordCollectionScreenState();
}

class _PasswordCollectionScreenState extends State<PasswordCollectionScreen> {
  final ImapService _imapService = ImapService();
  final TextEditingController _passwordController = TextEditingController();
  
  int _currentSourceIndex = 0;
  bool _isLoading = false;
  bool _isTesting = false;
  String _statusMessage = '';
  String _emailSubject = '';
  String _emailBody = '';
  String? _emailHtml;
  Uint8List? _samplePdf;
  MimeMessage? _currentMessage; // held so the PDF sample is extracted lazily (on Test), not on load
  bool _testPassed = false;
  String? _errorMessage;
  
  // Store collected passwords
  final Map<String, String> _passwords = {};

  @override
  void initState() {
    super.initState();
    _connectAndLoadEmail();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _imapService.disconnect();
    super.dispose();
  }

  DiscoveredSource get _currentSource => widget.sources[_currentSourceIndex];

  /// Connect to IMAP and load the first email
  Future<void> _connectAndLoadEmail() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Connecting to email...';
      _emailSubject = '';
      _emailBody = ''; _emailHtml = null;
      _samplePdf = null;
      _currentMessage = null;
      _testPassed = false;
      _errorMessage = null;
      _passwordController.clear();
    });

    try {
      // Connect to IMAP
      final connected = await _imapService.connect();
      if (!connected) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to connect to email server';
        });
        return;
      }

      // Prime the header cache once so every per-sender lookup below is a
      // fast, reliable cache hit (this is the same scan discovery ran).
      setState(() => _statusMessage = 'Scanning inbox...');
      await _imapService.discoverStatementSenders();

      await _fetchEmailFromSender();

    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error: ${e.toString().split('\n').first}';
      });
    }
  }

  /// Fetch an email from the current sender
  Future<void> _fetchEmailFromSender() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Searching for emails...';
      _emailSubject = '';
      _emailBody = ''; _emailHtml = null;
      _samplePdf = null;
      _currentMessage = null;
      _testPassed = false;
      _errorMessage = null;
      _passwordController.clear();
    });

    try {
      if (!_imapService.isConnected) {
        final connected = await _imapService.connect();
        if (!connected) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Connection lost. Please try again.';
          });
          return;
        }
      }

      // Search for emails from this sender using IMAP SEARCH
      setState(() => _statusMessage = 'Searching for ${_currentSource.senderName}...');
      
      final senderEmail = _currentSource.senderEmail;
      debugPrint('🔍 Searching for emails from: $senderEmail');
      
      // Fetch latest high-fidelity message (cache-first, then server search)
      final email = await _imapService.fetchLatestMessageForSender(senderEmail);

      if (email == null) {
        setState(() {
          _isLoading = false;
          _emailSubject = 'No emails found';
          _emailBody =
              'Could not load an email from ${_currentSource.senderName}. '
              'You can still enter the PDF password below — it will be used when statements are extracted.';
          _testPassed = true; // Allow skip
        });
        return;
      }
      await _processEmail(email);

    } catch (e) {
      debugPrint('❌ Error fetching email: $e');
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error: ${e.toString().split('\n').first}';
      });
    }
  }

  /// Process a single email — the message handed in is ALREADY the full
  /// body fetch (fetchLatestMessageForSender → fetchFullMessageFor). Never
  /// re-fetch by UID here: sequence-fetched messages have uid == null and a
  /// UID gate would silently discard a perfectly good message.
  Future<void> _processEmail(MimeMessage fullMessage) async {
    // Keep this LIGHT: heavy work (PDF attachment decode + syncfusion open)
    // used to run here on every source load and blocked the UI thread → ANR.
    // We now only show the subject + a short text snippet, hold the message,
    // and defer all PDF work to _testPassword (a user-initiated action).
    final subject = fullMessage.decodeSubject() ?? 'No Subject';
    final body = _imapService.getEmailBody(fullMessage);
    final html = _imapService.getEmailHtml(fullMessage);

    setState(() {
      _currentMessage = fullMessage;
      _emailSubject = subject;
      _emailBody = body.length > 1500 ? '${body.substring(0, 1500)}…' : body;
      // Safe preview: strip heavy/remote parts and cap size so HtmlWidget
      // layout never blocks the UI thread (the ANR cause). Falls back to the
      // plain-text body when there's nothing safe to render.
      _emailHtml = _safeHtml(html);
      _isLoading = false;
      _statusMessage = '';
      // Password is optional — user can Test it or just continue; it's applied
      // at extraction time either way.
      _testPassed = true;
    });
  }

  /// Sanitize an email HTML body into a lightweight, safe preview: strip
  /// scripts, styles, head and (crucially) remote images — which HtmlWidget
  /// would otherwise fetch + decode on the UI thread — then cap the size.
  /// Returns null when there's nothing worth rendering (caller shows text).
  String? _safeHtml(String? html) {
    if (html == null || html.trim().isEmpty) return null;
    try {
      var h = html
          .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<head[\s\S]*?</head>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<img[^>]*>', caseSensitive: false), '')
          .replaceAll(RegExp(r'\son\w+\s*=\s*"[^"]*"', caseSensitive: false), '');
      if (h.length > 4000) h = '${h.substring(0, 4000)}…';
      return h.trim().isEmpty ? null : h;
    } catch (_) {
      return null; // any issue → caller shows plain text
    }
  }

  /// Lazily pull the first PDF attachment from the held message (done on Test,
  /// not on screen load, to keep the UI responsive).
  Future<Uint8List?> _ensureSamplePdf() async {
    if (_samplePdf != null) return _samplePdf;
    final msg = _currentMessage;
    if (msg == null) return null;
    await Future<void>.delayed(Duration.zero); // let the tap's frame paint first
    final pdfs = await _imapService.extractPdfAttachments(msg);
    if (pdfs.isEmpty) return null;
    _samplePdf = pdfs.first;
    debugPrint('📎 Lazily extracted sample PDF (${_samplePdf!.length} bytes)');
    return _samplePdf;
  }

  /// Test the entered password
  Future<void> _testPassword() async {
    final password = _passwordController.text.trim();

    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a password')),
      );
      return;
    }

    setState(() {
      _isTesting = true;
      _statusMessage = 'Loading statement…';
      _errorMessage = null;
    });

    try {
      // Pull the sample PDF now (deferred from screen load so the UI never
      // blocked). If there's no attachment, just save the password for later.
      final sample = await _ensureSamplePdf();
      if (sample == null) {
        await SecureVault.setPdfPassword(_currentSource.senderEmail, password);
        _passwords[_currentSource.senderEmail] = password;
        setState(() {
          _isTesting = false;
          _testPassed = true;
          _statusMessage = '';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Password saved — it\'ll be used at extraction.'),
            backgroundColor: Colors.green,
          ));
        }
        return;
      }

      setState(() => _statusMessage = 'Testing password...');
      // Test if we can open the PDF
      final canOpen = await PdfExtractionService.testPassword(sample, password);
      
      if (canOpen) {
        // SUCCESS - password worked!
        setState(() {
          _isTesting = false;
          _testPassed = true;
          _statusMessage = '';
        });
        
        // Save password
        _passwords[_currentSource.senderEmail] = password;
        await SecureVault.setPdfPassword(_currentSource.senderEmail, password);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Password verified!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // FAILED - password wrong
        setState(() {
          _isTesting = false;
          _testPassed = false;
          _errorMessage = '❌ Wrong password. Please try again.';
        });
      }
    } catch (e) {
      setState(() {
        _isTesting = false;
        _testPassed = false;
        _errorMessage = '❌ Could not verify password. Error: ${e.toString().split('\n').first}';
      });
    }
  }

  /// Save the typed password without verification (used when no sample PDF
  /// could be loaded — it will be applied at extraction time).
  Future<void> _savePasswordWithoutTest() async {
    final password = _passwordController.text.trim();
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a password to save (or just continue)')),
      );
      return;
    }
    _passwords[_currentSource.senderEmail] = password;
    await SecureVault.setPdfPassword(_currentSource.senderEmail, password);
    if (!mounted) return;
    setState(() => _testPassed = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('🔒 Password saved — it will be used during extraction'), backgroundColor: Colors.green),
    );
  }

  /// HARD GATE: before moving on, prove that statement content actually
  /// extracts from this source's PDF with the current password. If it
  /// doesn't, the user must Retry (fix the password) or explicitly Skip —
  /// we never silently carry a source forward that cannot be read.
  Future<void> _validateAndNext() async {
    final typed = _passwordController.text.trim();

    // No sample PDF could be loaded (no email / no attachment): nothing to
    // validate against — save any typed password and continue.
    setState(() {
      _isTesting = true;
      _statusMessage = 'Loading statement…';
      _errorMessage = null;
    });

    try {
      // Pull the sample PDF now (deferred from screen load to keep the UI
      // responsive). No attachment → just save any typed password and advance.
      final sample = await _ensureSamplePdf();
      if (sample == null) {
        if (typed.isNotEmpty) {
          _passwords[_currentSource.senderEmail] = typed;
          await SecureVault.setPdfPassword(_currentSource.senderEmail, typed);
        }
        if (mounted) setState(() => _isTesting = false);
        _advance();
        return;
      }

      setState(() => _statusMessage = 'Validating extraction…');
      final needsPassword = await PdfExtractionService.isPasswordProtected(sample);
      final password = typed.isNotEmpty ? typed : _passwords[_currentSource.senderEmail];

      if (needsPassword && (password == null || password.isEmpty)) {
        setState(() {
          _isTesting = false;
          _statusMessage = '';
          _errorMessage =
              '🔒 This statement is password-protected. Enter the password (check the email above for the format) and retry, or skip this source.';
          _testPassed = false;
        });
        return;
      }

      // The real test: does TEXT actually come out of this PDF?
      final text = await PdfExtractionService.extractText(
        sample,
        password: needsPassword ? password : null,
      );

      if (text == null || text.trim().length < 40) {
        setState(() {
          _isTesting = false;
          _statusMessage = '';
          _testPassed = false;
          _errorMessage = needsPassword
              ? '❌ Could not read the statement with that password. Check the email above for the password format, update it and retry — or skip this source.'
              : '❌ This PDF appears to contain no readable text (it may be scanned). You can skip this source and add transactions manually.';
        });
        return;
      }

      // Validated — persist the working password and advance.
      if (needsPassword && password != null && password.isNotEmpty) {
        _passwords[_currentSource.senderEmail] = password;
        await SecureVault.setPdfPassword(_currentSource.senderEmail, password);
      }
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _statusMessage = '';
        _testPassed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Verified — ${text.trim().length} characters extracted from ${_currentSource.senderName}'),
          backgroundColor: Colors.green,
        ),
      );
      _advance();
    } catch (e) {
      setState(() {
        _isTesting = false;
        _statusMessage = '';
        _testPassed = false;
        _errorMessage = '❌ Extraction failed: ${e.toString().split('\n').first}. Retry with a different password or skip.';
      });
    }
  }

  void _advance() {
    if (_currentSourceIndex < widget.sources.length - 1) {
      setState(() {
        _currentSourceIndex++;
      });
      _fetchEmailFromSender();
    } else {
      // All done, go to extraction
      _startExtraction();
    }
  }

  void _skipSource() {
    widget.sources.removeAt(_currentSourceIndex);
    
    if (widget.sources.isEmpty) {
      Navigator.pop(context);
      return;
    }
    
    if (_currentSourceIndex >= widget.sources.length) {
      _currentSourceIndex = widget.sources.length - 1;
    }
    
    _fetchEmailFromSender();
  }

  void _startExtraction() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ExtractionProgressScreen(
          sources: widget.sources,
          passwords: _passwords,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      body: SafeArea(
        child: _isLoading ? _buildLoadingState() : _buildPasswordForm(),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: WoColors.gold),
          const SizedBox(height: 24),
          Text(
            _statusMessage,
            style: WoText.subtitle(),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _currentSource.senderName,
            style: WoText.caption(),
          ),
        ],
      ),
    );
  }

  Widget _headerChip(String label, {bool highlight = false}) {
    return WoChip(label, color: highlight ? WoColors.gold : WoColors.textMid);
  }

  Widget _buildPasswordForm() {
    return Column(
      children: [
        // Progress indicator
        Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: List.generate(widget.sources.length, (index) {
              return Expanded(
                child: Container(
                  height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: index <= _currentSourceIndex
                        ? WoColors.gold
                        : WoColors.borderHi,
                  ),
                ),
              );
            }),
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header — monogram avatar + chips
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: woCard(radius: 18, goldGlow: true),
                      alignment: Alignment.center,
                      child: Text(
                        _currentSource.senderName.isNotEmpty
                            ? _currentSource.senderName[0].toUpperCase()
                            : '?',
                        style: GoogleFonts.poppins(
                            color: WoColors.gold, fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _currentSource.senderName,
                            style: GoogleFonts.poppins(color: WoColors.textHi, fontSize: 19, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              _headerChip('${_currentSourceIndex + 1} of ${widget.sources.length}'),
                              const SizedBox(width: 8),
                              _headerChip('${_currentSource.statementCount} statement${_currentSource.statementCount == 1 ? '' : 's'}',
                                  highlight: true),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ).animate().fadeIn(),
                const SizedBox(height: 24),

                // Email Preview Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: woCard(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.email, color: WoColors.textLo, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            'EMAIL PREVIEW',
                            style: WoText.label(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _emailSubject.isEmpty ? 'Loading...' : _emailSubject,
                        style: WoText.subtitle(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_emailHtml != null) ...[
                        Divider(color: WoColors.border, height: 24),
                        Text('Latest email — look here for the password format',
                            style: WoText.caption(color: WoColors.gold)),
                        const SizedBox(height: 8),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 280),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SingleChildScrollView(
                            child: Builder(builder: (_) {
                              // Safe render: if HtmlWidget chokes on this markup,
                              // fall back to the plain-text body instead of breaking.
                              try {
                                return HtmlWidget(
                                  _emailHtml!,
                                  textStyle: const TextStyle(color: Colors.black87, fontSize: 13),
                                  onErrorBuilder: (_, __, ___) => Text(
                                    _emailBody.isNotEmpty ? _emailBody : 'Preview unavailable — enter the password below.',
                                    style: const TextStyle(color: Colors.black87, fontSize: 13),
                                  ),
                                );
                              } catch (_) {
                                return Text(
                                  _emailBody.isNotEmpty ? _emailBody : 'Preview unavailable — enter the password below.',
                                  style: const TextStyle(color: Colors.black87, fontSize: 13),
                                );
                              }
                            }),
                          ),
                        ),
                      ] else if (_emailBody.isNotEmpty) ...[
                        Divider(color: WoColors.border, height: 24),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 240),
                          child: SingleChildScrollView(
                            child: Text(
                              _emailBody,
                              style: GoogleFonts.inter(color: WoColors.textMid, fontSize: 12.5, height: 1.5),
                            ),
                          ),
                        ),
                      ],
                      if (_samplePdf != null) ...[
                        const SizedBox(height: 12),
                        WoChip(
                          'PDF Attachment (${(_samplePdf!.length / 1024).toStringAsFixed(0)} KB)',
                          color: WoColors.red,
                          icon: Icons.picture_as_pdf,
                        ),
                      ],
                    ],
                  ),
                ).animate().fadeIn().slideY(begin: 0.1),
                const SizedBox(height: 20),

                // Success indicator
                if (_testPassed) ...[
                  WoNotice(
                    'Ready to continue',
                    color: WoColors.mint,
                    icon: Icons.check_circle,
                  ),
                  const SizedBox(height: 16),
                ],

                // Error/Info message
                if (_errorMessage != null && !_testPassed) ...[
                  WoNotice(
                    _errorMessage!,
                    color: WoColors.orange,
                    icon: Icons.warning_amber,
                  ),
                  const SizedBox(height: 16),
                ],

                // Password input — ALWAYS available, so the password can be
                // captured even when no sample PDF could be loaded.
                if (!_passwords.containsKey(_currentSource.senderEmail)) ...[
                  Text(
                    _currentMessage != null ? 'Enter PDF Password' : 'PDF Password (optional)',
                    style: WoText.subtitle(),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    style: GoogleFonts.inter(color: WoColors.textHi, fontSize: 16),
                    decoration: woInput('Password', icon: Icons.lock_outline),
                    onSubmitted: (_) => _currentMessage != null ? _testPassword() : _savePasswordWithoutTest(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Common: DOB (DDMMYYYY), PAN, Last 4 digits of account',
                    style: WoText.caption(color: WoColors.textLo),
                  ),
                  const SizedBox(height: 16),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isTesting
                          ? null
                          : (_currentMessage != null ? _testPassword : _savePasswordWithoutTest),
                      icon: _isTesting
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                          : Icon(_currentMessage != null ? Icons.vpn_key : Icons.save_outlined, size: 18),
                      label: Text(_isTesting
                          ? 'Testing...'
                          : (_currentMessage != null ? 'Test Password' : 'Save Password')),
                      style: WoButtons.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Bottom buttons
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: WoColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
            boxShadow: WoShadows.navBar,
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _skipSource,
                    style: WoButtons.ghost,
                    child: const Text('Skip'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    // Always tappable: tapping runs the extraction validation
                    // gate. It only advances when text really extracts; on
                    // failure the user is told to retry the password or skip.
                    onPressed: _isTesting ? null : _validateAndNext,
                    style: WoButtons.primary,
                    child: _isTesting
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : Text(
                            _errorMessage != null && _currentMessage != null
                                ? 'Retry'
                                : (_currentSourceIndex < widget.sources.length - 1
                                    ? 'Verify & Next'
                                    : 'Verify & Extract'),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
