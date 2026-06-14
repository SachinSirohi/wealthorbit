import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';

/// Bank reconciliation: review auto-imported ("pending") transactions and
/// confirm them, or match them to a manually-entered duplicate.
class ReconciliationScreen extends StatefulWidget {
  const ReconciliationScreen({super.key});

  @override
  State<ReconciliationScreen> createState() => _ReconciliationScreenState();
}

class _ReconciliationScreenState extends State<ReconciliationScreen> {
  AppRepository? _repo;
  bool _isLoading = true;
  List<Account> _accounts = [];
  final Map<String, List<Transaction>> _pendingByAccount = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _repo = await AppRepository.getInstance();
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final accounts = await _repo!.getAllAccounts();
    _pendingByAccount.clear();
    for (final a in accounts) {
      final pending = await _repo!.getPendingTransactions(a.id);
      if (pending.isNotEmpty) _pendingByAccount[a.id] = pending;
    }
    if (!mounted) return;
    setState(() {
      _accounts = accounts.where((a) => _pendingByAccount.containsKey(a.id)).toList();
      _isLoading = false;
    });
  }

  Future<void> _clear(Transaction tx) async {
    await _repo!.markTransactionCleared(tx.id);
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
    return Scaffold(
      backgroundColor: WoColors.bg,
      appBar: AppBar(
        backgroundColor: WoColors.bg,
        elevation: 0,
        title: Text('Reconciliation', style: WoText.title()),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: WoColors.gold))
          : _accounts.isEmpty
              ? _emptyState()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: _accounts.map(_buildAccountSection).toList(),
                ),
    );
  }

  Widget _emptyState() => const WoEmptyState(
        icon: CupertinoIcons.checkmark_seal_fill,
        title: 'Everything reconciled',
        hint: 'No pending imported transactions to review',
      );

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
