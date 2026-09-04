import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/secure_vault.dart';

/// Can the numbers be trusted, and if not, what is missing?
///
/// Every other screen shows what the ledger says. This one shows how much of
/// the ledger there is: which months each account actually covers, which
/// accounts no statement has ever confirmed, and which senders are blocked
/// and why. A ledger with holes looks exactly like a complete one — the
/// totals are just wrong — so the gaps need somewhere to be visible.
class DataHealthScreen extends StatefulWidget {
  const DataHealthScreen({super.key});

  @override
  State<DataHealthScreen> createState() => _DataHealthScreenState();
}

class _DataHealthScreenState extends State<DataHealthScreen> {
  AppRepository? _repo;
  bool _loading = true;

  List<AccountCoverage> _coverage = [];
  List<Account> _untrusted = [];
  List<StatementSource> _sources = [];
  List<StatementQueueData> _blocked = [];
  Map<String, Account> _accountById = {};
  final Map<String, ({double closing, DateTime? date, double drift})?> _anchors = {};
  final Map<String, bool> _sourceHasPassword = {};
  int _totalTransactions = 0;
  int _uncategorised = 0;

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
    setState(() => _loading = true);

    final coverage = await _repo!.getCoverageMatrix();
    final accounts = await _repo!.getAllAccounts();
    final untrusted = await _repo!.getUntrustworthyAccounts();
    final sources = await _repo!.getAllStatementSources();
    final blocked = await _repo!.getFailedStatementQueue();
    final transactions = await _repo!.getAllTransactions();

    _anchors.clear();
    for (final a in accounts) {
      _anchors[a.id] = await _repo!.getAnchorInfo(a.id);
    }
    _sourceHasPassword.clear();
    for (final s in sources) {
      final pwd = await SecureVault.resolvePdfPassword(
        sourceId: s.id,
        senderEmail: s.senderEmail,
        bankName: s.bankName,
      );
      _sourceHasPassword[s.id] = pwd != null && pwd.isNotEmpty;
    }

    if (!mounted) return;
    setState(() {
      _coverage = coverage;
      _untrusted = untrusted;
      _sources = sources;
      _blocked = blocked;
      _accountById = {for (final a in accounts) a.id: a};
      _totalTransactions = transactions.length;
      _uncategorised = transactions.where((t) => t.categoryId == null).length;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      appBar: AppBar(
        backgroundColor: WoColors.bg,
        elevation: 0,
        title: Text('Data Health', style: WoText.title()),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(CupertinoIcons.refresh, color: WoColors.textMid, size: 20),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: WoColors.gold))
          : RefreshIndicator(
              onRefresh: _load,
              color: WoColors.gold,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  _buildSummary(),
                  const SizedBox(height: 22),
                  _buildCoverage(),
                  const SizedBox(height: 22),
                  _buildAccounts(),
                  const SizedBox(height: 22),
                  _buildSources(),
                ],
              ),
            ),
    );
  }

  // ── Summary ─────────────────────────────────────────────────────────────

  Widget _buildSummary() {
    final anchored = _anchors.values.where((a) => a != null).length;
    final totalAccounts = _accountById.length;
    final coveredCells =
        _coverage.fold<int>(0, (s, c) => s + c.coveredMonths);
    final blockedCells =
        _coverage.fold<int>(0, (s, c) => s + c.blockedMonths);
    final uncatPct = _totalTransactions == 0
        ? 0
        : (_uncategorised / _totalTransactions * 100).round();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: woCard(radius: 20, goldGlow: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LEDGER COVERAGE', style: WoText.label(color: WoColors.gold)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 22,
            runSpacing: 14,
            children: [
              _stat('$coveredCells', 'months with data', WoColors.mint),
              _stat('$blockedCells', 'months blocked', WoColors.red),
              _stat('$anchored/$totalAccounts', 'accounts confirmed', WoColors.blue),
              _stat('$_totalTransactions', 'transactions', WoColors.textHi),
              _stat('$uncatPct%', 'uncategorised', WoColors.gold),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label, Color color) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: WoText.num(size: 19, color: color)),
          const SizedBox(height: 2),
          Text(label, style: WoText.caption(color: WoColors.textLo)),
        ],
      );

  // ── Coverage matrix ─────────────────────────────────────────────────────

  Widget _buildCoverage() {
    if (_coverage.isEmpty) {
      return const WoEmptyState(
        icon: CupertinoIcons.square_grid_2x2,
        title: 'No accounts yet',
        hint: 'Connect a statement source to start building history',
      );
    }
    final months = _coverage.first.months;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WoSectionHeader('Statement coverage', padding: EdgeInsets.zero),
        const SizedBox(height: 4),
        Text(
          'One square per month. Worst-covered accounts first.',
          style: WoText.caption(),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: woCard(radius: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Wide content scrolls in its own container so the page never
              // scrolls sideways.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _monthAxis(months),
                    const SizedBox(height: 6),
                    ..._coverage.map(_coverageRow),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Divider(color: WoColors.border, height: 1),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _legend(WoColors.mint, 'imported'),
                  _legend(WoColors.red, 'statement blocked'),
                  _legend(WoColors.border, 'no statement found'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const double _cell = 15;
  static const double _gap = 3;
  static const double _labelWidth = 104;

  Widget _monthAxis(List<MonthCoverage> months) {
    return Row(
      children: [
        SizedBox(width: _labelWidth),
        ...months.asMap().entries.map((e) {
          // Label every third column; more than that is unreadable at this size.
          final show = e.key % 3 == 0;
          return SizedBox(
            width: _cell + _gap,
            child: show
                ? Text(DateFormat('MMM').format(e.value.month),
                    style: WoText.caption(color: WoColors.textLo).copyWith(fontSize: 9))
                : const SizedBox.shrink(),
          );
        }),
      ],
    );
  }

  Widget _coverageRow(AccountCoverage c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _gap),
      child: Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: Text(
              c.account.name,
              style: WoText.caption(color: WoColors.textMid),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ...c.months.map((m) {
            final color = m.isCovered
                ? WoColors.mint
                : m.isBlocked
                    ? WoColors.red
                    : WoColors.border;
            return Padding(
              padding: const EdgeInsets.only(right: _gap),
              child: Tooltip(
                message: '${DateFormat('MMM yyyy').format(m.month)} · '
                    '${m.isCovered ? '${m.transactions} transactions' : m.isBlocked ? '${m.blockedStatements} statement(s) not read' : 'nothing found'}',
                child: Container(
                  width: _cell,
                  height: _cell,
                  decoration: BoxDecoration(
                    color: m.isCovered
                        ? color.withValues(alpha: 0.85)
                        : color.withValues(alpha: m.isBlocked ? 0.75 : 0.5),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _legend(Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: WoText.caption(color: WoColors.textLo)),
        ],
      );

  // ── Accounts ────────────────────────────────────────────────────────────

  Widget _buildAccounts() {
    final rows = _coverage.map((c) => c.account).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WoSectionHeader('Balances', padding: EdgeInsets.zero),
        const SizedBox(height: 4),
        Text(
          'A balance is only as good as the statement behind it.',
          style: WoText.caption(),
        ),
        const SizedBox(height: 12),
        ...rows.map(_accountTile),
      ],
    );
  }

  Widget _accountTile(Account a) {
    final anchor = _anchors[a.id];
    final untrusted = _untrusted.any((x) => x.id == a.id);
    final coverage = _coverage.firstWhere((c) => c.account.id == a.id);

    final String state;
    final Color color;
    if (untrusted) {
      state = 'Not counted — no statement has confirmed this balance';
      color = WoColors.red;
    } else if (anchor == null) {
      state = 'Never confirmed by a statement';
      color = WoColors.gold;
    } else if (anchor.drift.abs() < 1) {
      state = 'Matches the bank as of '
          '${anchor.date == null ? 'last statement' : DateFormat('MMM d').format(anchor.date!)}';
      color = WoColors.mint;
    } else {
      state = '${CurrencyUtils.format(anchor.drift.abs(), a.currencyCode, decimals: 0)} '
          'the ledger could not explain';
      color = WoColors.gold;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: woCard(radius: 16),
      child: Row(
        children: [
          Container(width: 3, height: 34, decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.name, style: WoText.subtitle(), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(state, style: WoText.caption(color: color),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(CurrencyUtils.format(a.balance, a.currencyCode, decimals: 0),
                  style: WoText.num(size: 14)),
              Text('${coverage.totalTransactions} txns',
                  style: WoText.caption(color: WoColors.textLo)),
            ],
          ),
        ],
      ),
    );
  }

  // ── Sources ─────────────────────────────────────────────────────────────

  Widget _buildSources() {
    if (_sources.isEmpty) return const SizedBox.shrink();

    // Only surface sources that actually need something doing.
    final problems = <(StatementSource, String)>[];
    for (final s in _sources) {
      final failures =
          _blocked.where((q) => q.sourceId == s.id).toList();
      if (s.accountId == null || !_accountById.containsKey(s.accountId)) {
        problems.add((s, 'Not mapped to an account — its statements cannot import'));
      } else if (_sourceHasPassword[s.id] == false && failures.isNotEmpty) {
        problems.add((s, '${failures.length} statement(s) need a PDF password'));
      } else if (failures.isNotEmpty) {
        problems.add((s, '${failures.length} statement(s) could not be read'));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WoSectionHeader('Blocked sources', padding: EdgeInsets.zero),
        const SizedBox(height: 4),
        Text(
          problems.isEmpty
              ? 'Every connected sender is importing cleanly.'
              : 'Fix these in Statements & Automation to close the gaps above.',
          style: WoText.caption(),
        ),
        const SizedBox(height: 12),
        if (problems.isEmpty)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: woCard(radius: 16),
            child: Row(
              children: [
                Icon(CupertinoIcons.checkmark_seal_fill, color: WoColors.mint, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text('Nothing blocked', style: WoText.bodyHi())),
              ],
            ),
          )
        else
          ...problems.map((p) => Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: woCard(radius: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(CupertinoIcons.exclamationmark_triangle_fill,
                        color: WoColors.red, size: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.$1.bankName, style: WoText.subtitle()),
                          const SizedBox(height: 2),
                          Text(p.$2, style: WoText.caption(color: WoColors.textMid)),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
      ],
    );
  }
}
