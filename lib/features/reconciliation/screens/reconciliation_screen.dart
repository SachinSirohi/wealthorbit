import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/reconciliation_service.dart';

/// Bank reconciliation: review pending imports, suggested transfers, and
/// same-account duplicates.
class ReconciliationScreen extends StatefulWidget {
  const ReconciliationScreen({super.key});

  @override
  State<ReconciliationScreen> createState() => _ReconciliationScreenState();
}

class _ReconciliationScreenState extends State<ReconciliationScreen> {
  AppRepository? _repo;
  ReconciliationService? _recon;
  bool _isLoading = true;
  List<Account> _accounts = [];
  final Map<String, List<Transaction>> _pendingByAccount = {};
  List<_SuggestedTransferVm> _suggestions = [];
  Map<String, Account> _accountById = {};
  // Per-account: what the bank's last statement said vs what the ledger
  // could explain. The pipeline used to anchor silently; now the gap shows.
  final List<_AnchorVm> _anchors = [];
  int _pendingCount = 0;
  int _uncategorisedCount = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _repo = await AppRepository.getInstance();
    _recon = ReconciliationService(_repo!);
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final accounts = await _repo!.getAllAccounts();
    _accountById = {for (final a in accounts) a.id: a};
    _pendingByAccount.clear();
    for (final a in accounts) {
      final pending = await _repo!.getPendingTransactions(a.id);
      if (pending.isNotEmpty) _pendingByAccount[a.id] = pending;
    }

    _anchors.clear();
    for (final a in accounts) {
      final info = await _repo!.getAnchorInfo(a.id);
      if (info != null) _anchors.add(_AnchorVm(account: a, closing: info.closing, date: info.date, drift: info.drift));
    }
    _anchors.sort((x, y) => y.drift.abs().compareTo(x.drift.abs()));

    _pendingCount = await _repo!.countPendingTransactions();
    _uncategorisedCount = (await _repo!.getAllTransactions())
        .where((t) => t.categoryId == null && t.type != 'transfer')
        .length;

    final pendingSuggestions = await _repo!.getPendingSuggestedMatches();
    final vms = <_SuggestedTransferVm>[];
    for (final s in pendingSuggestions) {
      final from = await _repo!.getTransactionById(s.fromTxnId);
      final to = await _repo!.getTransactionById(s.toTxnId);
      if (from == null || to == null) continue;
      vms.add(_SuggestedTransferVm(suggestion: s, from: from, to: to));
    }

    if (!mounted) return;
    setState(() {
      _accounts = accounts.where((a) => _pendingByAccount.containsKey(a.id)).toList();
      _suggestions = vms;
      _isLoading = false;
    });
  }

  Future<void> _clear(Transaction tx) async {
    await _repo!.markTransactionCleared(tx.id);
    await _load();
  }

  Future<void> _acceptSuggestion(_SuggestedTransferVm vm) async {
    final ok = await _recon!.acceptSuggestion(vm.suggestion.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? (vm.suggestion.kind == 'duplicate_spend'
              ? 'Marked as a duplicate — excluded from totals'
              : 'Transfer applied')
          : 'Could not apply this match'),
    ));
    await _load();
  }

  Future<void> _rejectSuggestion(_SuggestedTransferVm vm) async {
    await _recon!.rejectSuggestion(vm.suggestion.id);
    await _load();
  }

  Future<void> _findMatch(Transaction tx) async {
    final dup = await _repo!.findDuplicateTransaction(
      accountId: tx.accountId,
      amountBase: tx.amountBase,
      date: tx.transactionDate,
      excludeId: tx.id,
    );
    if (!mounted) return;
    if (dup == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No likely duplicate found nearby')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WoColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
        title: Text('Match found', style: WoText.title()),
        content: Text(
          'Link this import to your existing entry "${dup.description}" '
          '(${DateFormat('MMM d').format(dup.transactionDate)})? '
          'The imported copy will be marked reconciled.',
          style: WoText.body(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.inter(color: WoColors.textMid)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Link', style: GoogleFonts.inter(color: WoColors.gold, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _repo!.linkTransactions(tx.id, dup.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final empty = _accounts.isEmpty &&
        _suggestions.isEmpty &&
        _anchors.isEmpty &&
        _pendingCount == 0 &&
        _uncategorisedCount == 0;
    return Scaffold(
      backgroundColor: WoColors.bg,
      appBar: AppBar(
        backgroundColor: WoColors.bg,
        elevation: 0,
        title: Text('Reconciliation', style: WoText.title()),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: WoColors.gold))
          : empty
              ? _emptyState()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildBulkActions(),
                    if (_anchors.isNotEmpty) ...[
                      WoSectionHeader(
                        'Statement check',
                        padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
                      ),
                      Text(
                        'What each bank last reported, and how much of it the ledger could not explain.',
                        style: WoText.caption(),
                      ),
                      const SizedBox(height: 12),
                      ..._anchors.map(_buildAnchorTile),
                      const SizedBox(height: 16),
                    ],
                    if (_suggestions.isNotEmpty) ...[
                      WoSectionHeader(
                        'Suggested transfers',
                        padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
                      ),
                      Text(
                        'High-confidence matches auto-apply. Review these and Accept or Reject.',
                        style: WoText.caption(),
                      ),
                      const SizedBox(height: 12),
                      ..._suggestions.map(_buildSuggestionTile),
                      const SizedBox(height: 16),
                    ],
                    ..._accounts.map(_buildAccountSection),
                  ],
                ),
    );
  }

  Widget _emptyState() => const WoEmptyState(
        icon: CupertinoIcons.checkmark_seal_fill,
        title: 'Everything reconciled',
        hint: 'No pending imports or suggested transfers to review',
      );

  /// Reviewing a thousand imported rows one at a time is not a workflow.
  /// A first sync produces well over that, so the bulk paths have to exist
  /// or the pending queue simply never gets dealt with.
  Widget _buildBulkActions() {
    if (_pendingCount == 0 && _uncategorisedCount == 0) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Bulk actions', style: WoText.subtitle()),
          const SizedBox(height: 4),
          Text(
            '$_pendingCount imported transaction(s) awaiting review · '
            '$_uncategorisedCount uncategorised',
            style: WoText.caption(),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (_uncategorisedCount > 0)
                Expanded(
                  child: OutlinedButton(
                    style: WoButtons.ghost,
                    onPressed: _busy ? null : _autoCategorise,
                    child: const Text('Auto-categorise'),
                  ),
                ),
              if (_uncategorisedCount > 0 && _pendingCount > 0)
                const SizedBox(width: 12),
              if (_pendingCount > 0)
                Expanded(
                  child: ElevatedButton(
                    style: WoButtons.primary,
                    onPressed: _busy ? null : _clearAllPending,
                    child: const Text('Clear all'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _autoCategorise() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final n = await _repo!.autoCategoriseUncategorised();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
      content: Text(n > 0
          ? 'Categorised $n transaction(s)'
          : 'Nothing could be categorised confidently'),
    ));
    await _load();
  }

  Future<void> _clearAllPending() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WoColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
        title: Text('Clear all pending?', style: WoText.title()),
        content: Text(
          'Marks all $_pendingCount imported transaction(s) as cleared. They '
          'stay in your ledger and keep counting toward every total — this '
          'only means you are no longer asked to review them one by one.',
          style: WoText.body(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.inter(color: WoColors.textMid)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Clear all',
                style: GoogleFonts.inter(color: WoColors.gold, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final n = await _repo!.clearAllPending();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(content: Text('Cleared $n transaction(s)')));
    await _load();
  }

  Widget _buildAnchorTile(_AnchorVm vm) {
    final explained = vm.drift.abs() < 1;
    final color = explained ? WoColors.mint : WoColors.red;
    final when = vm.date != null ? DateFormat('MMM d').format(vm.date!) : 'latest';
    final fmt = NumberFormat.currency(symbol: '${vm.account.currencyCode} ', decimalDigits: 0);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(vm.account.name, style: WoText.subtitle()),
                const SizedBox(height: 2),
                Text('Bank statement ($when): ${fmt.format(vm.closing)}', style: WoText.caption()),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                explained ? 'Fully explained' : '${fmt.format(vm.drift.abs())} unexplained',
                style: WoText.caption(color: color),
              ),
              if (!explained)
                Text(
                  vm.drift > 0 ? 'ledger was short' : 'ledger was over',
                  style: WoText.caption(color: WoColors.textLo),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionTile(_SuggestedTransferVm vm) {
    final fromAcc = _accountById[vm.from.accountId];
    final toAcc = _accountById[vm.to.accountId];
    final kindLabel = switch (vm.suggestion.kind) {
      'cc_payment' => 'Credit card payment',
      'duplicate_spend' => 'Duplicate spend',
      _ => 'Own-account transfer',
    };
    final pct = (vm.suggestion.confidence * 100).round();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 18, tint: WoColors.gold),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(kindLabel, style: WoText.subtitle())),
              WoChip('$pct%', color: WoColors.gold),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${fromAcc?.name ?? 'Account'} → ${toAcc?.name ?? 'Account'}',
            style: WoText.bodyHi(),
          ),
          const SizedBox(height: 4),
          Text(
            '${vm.from.currencyCode} ${vm.from.amountSource.toStringAsFixed(2)}'
            ' · base ${vm.from.amountBase.toStringAsFixed(0)}'
            ' · ${DateFormat.MMMd().format(vm.from.transactionDate)}',
            style: WoText.caption(),
          ),
          if (vm.suggestion.reason != null && vm.suggestion.reason!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(vm.suggestion.reason!, style: WoText.caption(color: WoColors.textMid)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _rejectSuggestion(vm),
                  style: WoButtons.ghost,
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _acceptSuggestion(vm),
                  style: WoButtons.primary,
                  child: Text(vm.suggestion.kind == 'duplicate_spend'
                      ? 'Mark duplicate'
                      : 'Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAccountSection(Account account) {
    final pending = _pendingByAccount[account.id]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WoSectionHeader(
          '${account.name} · ${pending.length} pending',
          padding: const EdgeInsets.fromLTRB(2, 12, 2, 10),
        ),
        ...pending.map((tx) => _buildTile(tx, account)),
      ],
    );
  }

  Widget _buildTile(Transaction tx, Account account) {
    final isExpense = tx.type == 'expense';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(tx.description,
                    style: WoText.subtitle(),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              Text(
                '${isExpense ? "-" : "+"}${NumberFormat.currency(symbol: '${account.currencyCode} ', decimalDigits: 2).format(tx.amountBase)}',
                style: WoText.num(color: isExpense ? WoColors.expense : WoColors.income),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(DateFormat('MMM d, yyyy').format(tx.transactionDate),
              style: WoText.caption(color: WoColors.textLo)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _findMatch(tx),
                  style: WoButtons.ghost,
                  child: const Text('Find duplicate'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _clear(tx),
                  style: WoButtons.primary,
                  child: const Text('Mark cleared'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SuggestedTransferVm {
  final SuggestedMatche suggestion;
  final Transaction from;
  final Transaction to;
  _SuggestedTransferVm({
    required this.suggestion,
    required this.from,
    required this.to,
  });
}


class _AnchorVm {
  final Account account;
  final double closing;
  final DateTime? date;
  final double drift;
  _AnchorVm({required this.account, required this.closing, required this.date, required this.drift});
}
