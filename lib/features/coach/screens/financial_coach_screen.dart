import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/financial_health_service.dart';
import '../../../data/services/gemini_service.dart';
import '../../ai/screens/ai_chat_screen.dart';

/// Monthly Financial Health Coach — Google Health-style wrap over cleaned books.
class FinancialCoachScreen extends StatefulWidget {
  const FinancialCoachScreen({super.key});

  @override
  State<FinancialCoachScreen> createState() => _FinancialCoachScreenState();
}

class _FinancialCoachScreenState extends State<FinancialCoachScreen> {
  AppRepository? _repo;
  FinancialHealthService? _coach;
  bool _loading = true;
  bool _regenerating = false;
  CoachReport? _current;
  List<CoachReport> _history = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _repo = await AppRepository.getInstance();
    _coach = FinancialHealthService(_repo!);
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      var report = await _repo!.getCoachReport(now.year, now.month);
      report ??= await _coach!.ensureCurrentMonthReport();
      final history = await _repo!.getCoachReports(limit: 12);
      if (!mounted) return;
      setState(() {
        _current = report;
        _history = history;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _regenerate() async {
    setState(() => _regenerating = true);
    try {
      final now = DateTime.now();
      final report = await _coach!.generateReport(
        year: now.year,
        month: now.month,
        force: true,
      );
      if (!mounted) return;
      setState(() => _current = report);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  Map<String, dynamic> _parse(String raw) {
    try {
      final d = json.decode(raw);
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {}
    return {};
  }

  List<String> _strings(dynamic v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    return [];
  }

  Future<void> _askAboutThis() async {
    if (_current == null || _repo == null) return;
    final snap = _parse(_current!.snapshotJson);
    final report = _parse(_current!.reportJson);
    final contextBlock = '''
Latest Financial Health Coach report:
${json.encode(report)}

Snapshot metrics (base currency):
${json.encode(snap)}
''';
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AiChatScreen(
          repository: _repo!,
          geminiService: GeminiService(),
          initialContextOverride: contextBlock,
          initialPrompt: report['question']?.toString(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      appBar: AppBar(
        backgroundColor: WoColors.bg,
        elevation: 0,
        title: Text('Financial Health Coach', style: WoText.title()),
        actions: [
          if (!_loading)
            IconButton(
              onPressed: _regenerating ? null : _regenerate,
              icon: _regenerating
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: WoColors.gold),
                    )
                  : Icon(CupertinoIcons.refresh, color: WoColors.gold),
            ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: WoColors.gold))
          : _error != null && _current == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, style: WoText.body(), textAlign: TextAlign.center),
                  ),
                )
              : _current == null
                  ? const WoEmptyState(
                      icon: CupertinoIcons.heart,
                      title: 'No coach report yet',
                      hint: 'Sync statements or tap refresh to generate this month\'s wrap.',
                    )
                  : _buildBody(_current!),
    );
  }

  Widget _buildBody(CoachReport report) {
    final snap = _parse(report.snapshotJson);
    final narrative = _parse(report.reportJson);
    final headline = narrative['headline']?.toString() ??
        'Your ${snap['month_label'] ?? 'month'} wrap';
    final wentWell = _strings(narrative['went_well']);
    final watch = _strings(narrative['watch']);
    final actions = _strings(narrative['actions']);
    final question = narrative['question']?.toString();
    final base = snap['base_currency']?.toString() ?? '';

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: woCard(goldGlow: true),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: (report.score / 100).clamp(0.0, 1.0),
                      strokeWidth: 7,
                      backgroundColor: WoColors.borderHi,
                      color: WoColors.gold,
                    ),
                    Text('${report.score.round()}', style: WoText.num(size: 22)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snap['month_label']?.toString() ??
                          DateFormat.yMMMM().format(DateTime(report.year, report.month)),
                      style: WoText.caption(color: WoColors.gold),
                    ),
                    const SizedBox(height: 4),
                    Text(headline, style: WoText.subtitle()),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _metricRow(snap, base),
        if (snap['unmatched_transfer_risk'] == true) ...[
          const SizedBox(height: 12),
          WoNotice(
            'Some transfers may still be unmatched — spending could be overstated until you accept suggestions in Reconciliation.',
            color: WoColors.orange,
            icon: Icons.info_outline,
          ),
        ],
        const SizedBox(height: 20),
        if (wentWell.isNotEmpty) _bulletSection('Went well', wentWell, WoColors.mint),
        if (watch.isNotEmpty) _bulletSection('Watch', watch, WoColors.orange),
        if (actions.isNotEmpty) _bulletSection('Actions', actions, WoColors.gold),
        if (question != null && question.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Coach question', style: WoText.label()),
          const SizedBox(height: 8),
          Text(question, style: WoText.body()),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _askAboutThis,
            style: WoButtons.primary,
            icon: const Icon(CupertinoIcons.chat_bubble_2),
            label: const Text('Ask about this'),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Informational only — not regulated financial advice.',
          style: WoText.caption(color: WoColors.textLo),
          textAlign: TextAlign.center,
        ),
        if (_history.length > 1) ...[
          const SizedBox(height: 28),
          Text('Past months', style: WoText.label()),
          const SizedBox(height: 8),
          ..._history.where((h) => h.id != report.id).map((h) {
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                DateFormat.yMMMM().format(DateTime(h.year, h.month)),
                style: WoText.bodyHi(),
              ),
              trailing: Text('${h.score.round()}', style: WoText.num(size: 16)),
              onTap: () => setState(() => _current = h),
            );
          }),
        ],
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _metricRow(Map<String, dynamic> snap, String base) {
    String money(dynamic v) {
      final n = (v as num?)?.toDouble() ?? 0;
      return '$base ${NumberFormat.compact().format(n)}';
    }

    return Row(
      children: [
        Expanded(child: _mini('Income', money(snap['income']))),
        const SizedBox(width: 8),
        Expanded(child: _mini('Spend', money(snap['expenses']))),
        const SizedBox(width: 8),
        Expanded(
          child: _mini(
            'Save',
            '${((snap['savings_rate_pct'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}%',
          ),
        ),
      ],
    );
  }

  Widget _mini(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: woCard(radius: 14),
      child: Column(
        children: [
          Text(label, style: WoText.caption()),
          const SizedBox(height: 4),
          Text(value, style: WoText.num(size: 14)),
        ],
      ),
    );
  }

  Widget _bulletSection(String title, List<String> items, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: WoText.label().copyWith(color: color)),
          const SizedBox(height: 8),
          ...items.map(
            (t) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: GoogleFonts.inter(color: color)),
                  Expanded(child: Text(t, style: WoText.body())),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
