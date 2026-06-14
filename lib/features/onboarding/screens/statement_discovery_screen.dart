import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/models/discovered_source.dart';
import '../../../data/services/imap_service.dart';
import 'password_collection_screen.dart';

/// Screen showing discovered statement sources after email scan
class StatementDiscoveryScreen extends StatefulWidget {
  const StatementDiscoveryScreen({super.key});

  @override
  State<StatementDiscoveryScreen> createState() => _StatementDiscoveryScreenState();
}

class _StatementDiscoveryScreenState extends State<StatementDiscoveryScreen> {
  final ImapService _imapService = ImapService();
  List<DiscoveredSource> _sources = [];
  bool _isLoading = true;
  String _statusMessage = 'Connecting to your email...';
  String? _error;

  @override
  void initState() {
    super.initState();
    _discoverSources();
  }

  Future<void> _discoverSources() async {
    try {
      setState(() {
        _isLoading = true;
        _statusMessage = 'Connecting to your email...';
        _error = null;
      });

      final connected = await _imapService.connect();
      if (!connected) {
        setState(() {
          _error = 'Failed to connect to email. Please check your credentials.';
          _isLoading = false;
        });
        return;
      }

      setState(() => _statusMessage = 'Scanning your inbox for statements...');

      final sources = await _imapService.discoverStatementSenders(daysBack: 730);

      await _imapService.disconnect();

      if (!mounted) return;

      setState(() {
        _sources = sources;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Discovery failed: $e';
          _isLoading = false;
        });
      }
    }
  }

  int get _selectedCount => _sources.where((s) => s.isSelected).length;
  int get _totalStatements => _sources.where((s) => s.isSelected).fold(0, (sum, s) => sum + s.statementCount);

  void _continue() {
    final selectedSources = _sources.where((s) => s.isSelected).toList();
    if (selectedSources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one source')),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => PasswordCollectionScreen(sources: selectedSources),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      body: SafeArea(
        child: _isLoading ? _buildLoadingState() : (_error != null ? _buildErrorState() : _buildDiscoveryResults()),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 80,
            height: 80,
            child: CircularProgressIndicator(
              color: WoColors.gold,
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            _statusMessage,
            style: WoText.title(),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'This may take a minute...',
            style: WoText.body(),
          ),
        ],
      ).animate().fadeIn(),
    );
  }

  Widget _buildErrorState() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            WoIconBubble(Icons.error_outline, color: WoColors.red, size: 84),
            const SizedBox(height: 24),
            Text(
              'Discovery Failed',
              style: WoText.display(),
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? 'Unknown error occurred',
              style: WoText.body(),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _discoverSources,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
              style: WoButtons.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveryResults() {
    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  WoIconBubble(Icons.check_circle, color: WoColors.mint, size: 54),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'We Found Your Statements!',
                          style: WoText.title(),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$_totalStatements statements from $_selectedCount sources',
                          style: GoogleFonts.inter(color: WoColors.gold, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Select the accounts you want to import:',
                style: WoText.body(),
              ),
            ],
          ),
        ).animate().fadeIn().slideY(begin: -0.1),

        // Sources List
        Expanded(
          child: _sources.isEmpty
              ? _buildNoSourcesFound()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _sources.length,
                  itemBuilder: (context, index) {
                    return _buildSourceCard(_sources[index], index);
                  },
                ),
        ),

        // Continue Button
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
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _selectedCount > 0 ? _continue : null,
                style: WoButtons.primary,
                child: Text(
                  _selectedCount > 0 ? 'Continue with $_selectedCount Sources' : 'Select Sources to Continue',
                ),
              ),
            ),
          ),
        ).animate().fadeIn().slideY(begin: 0.2),
      ],
    );
  }

  Widget _buildNoSourcesFound() {
    return const WoEmptyState(
      icon: Icons.inbox_outlined,
      title: 'No Statement Sources Found',
      hint: 'We couldn\'t find recurring emails with PDF attachments.\nCheck if your bank sends e-statements.',
    ).animate().fadeIn(duration: 400.ms);
  }

  Widget _buildSourceCard(DiscoveredSource source, int index) {
    final iconData = _getIconForSource(source.iconName);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: source.isSelected
          ? woCard(radius: 18, goldGlow: true, tint: WoColors.gold)
          : woCard(radius: 18),
      child: InkWell(
        onTap: () {
          setState(() => source.isSelected = !source.isSelected);
        },
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Icon
              WoIconBubble(iconData, color: _getColorForSource(source.senderName), size: 46),
              const SizedBox(width: 16),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.senderName,
                      style: WoText.subtitle(),
                    ),
                    Text(
                      source.senderEmail,
                      style: WoText.caption(color: WoColors.textLo),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    WoChip('${source.statementCount} statements', color: WoColors.gold),
                  ],
                ),
              ),
              // Checkbox
              Checkbox(
                value: source.isSelected,
                onChanged: (val) {
                  setState(() => source.isSelected = val ?? false);
                },
                activeColor: WoColors.gold,
                checkColor: Colors.black,
                side: BorderSide(color: WoColors.borderHi),
              ),
            ],
          ),
        ),
      ),
    ).animate(delay: Duration(milliseconds: index * 50)).fadeIn().slideX(begin: 0.1);
  }

  IconData _getIconForSource(String iconName) {
    switch (iconName) {
      case 'account_balance': return Icons.account_balance;
      case 'trending_up': return Icons.trending_up;
      case 'credit_card': return Icons.credit_card;
      case 'payment': return Icons.payment;
      default: return Icons.email;
    }
  }

  Color _getColorForSource(String name) {
    final hash = name.hashCode;
    final colors = [
      WoColors.blue,
      WoColors.mint,
      WoColors.red,
      WoColors.indigo,
      WoColors.orange,
      WoColors.teal,
    ];
    return colors[hash.abs() % colors.length];
  }
}
