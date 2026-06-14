import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/secure_vault.dart';

class NetWorthScreen extends StatefulWidget {
  const NetWorthScreen({super.key});

  @override
  State<NetWorthScreen> createState() => _NetWorthScreenState();
}

class _NetWorthScreenState extends State<NetWorthScreen> {
  String _base = 'AED';
  AppRepository? _repo;
  bool _isLoading = true;

  double _netWorth = 0;
  double _totalAssets = 0;
  double _totalAccounts = 0;
  double _totalLiabilities = 0;
  double _liquidAssets = 0;

  List<Asset> _assets = [];
  List<Account> _accounts = [];
  Map<String, double> _assetBreakdown = {};
  // Per-asset value already converted into the base currency (for sorting).
  Map<String, double> _assetBaseValue = {};

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    try {
      _repo = await AppRepository.getInstance();
      _base = await SecureVault.getBaseCurrency();
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
      final netWorth = await _repo!.getNetWorthWithLiabilities();
      if (!mounted) return;
      final totalAssets = await _repo!.getTotalAssetValue();
      if (!mounted) return;
      final totalAccounts = await _repo!.getTotalAccountBalance();
      if (!mounted) return;
      final totalLiabilities = await _repo!.getTotalLiabilities();
      if (!mounted) return;
      final liquidAssets = await _repo!.getLiquidAssetValue();
      if (!mounted) return;

      final assets = await _repo!.getAllAssets();
      if (!mounted) return;
      final accounts = await _repo!.getAllAccounts();
      if (!mounted) return;

      // Calculate breakdown by asset type — convert each holding into the base
      // currency first (assets may be in INR/AED/USD/etc.).
      final breakdown = <String, double>{};
      final assetBase = <String, double>{};
      for (final asset in assets) {
        final base = await _repo!.toBase(asset.currentValue, asset.currencyCode);
        assetBase[asset.id] = base;
        breakdown[asset.type] = (breakdown[asset.type] ?? 0) + base;
      }
      // Add accounts to breakdown (already in base currency)
      breakdown['cash_accounts'] = totalAccounts;

      if (!mounted) return;
      setState(() {
        _netWorth = netWorth;
        _totalAssets = totalAssets;
        _totalAccounts = totalAccounts;
        _totalLiabilities = totalLiabilities;
        _liquidAssets = liquidAssets;
        _assets = assets;
        _accounts = accounts;
        _assetBreakdown = breakdown;
        _assetBaseValue = assetBase;
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
      body: CustomScrollView(
        slivers: [
          _buildAppBar(),
          if (_isLoading)
            SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: WoColors.gold)),
            )
          else ...[
            _buildNetWorthCard(),
            _buildBreakdownChart(),
            _buildQuickStats(),
            _buildAssetsList(),
            _buildAccountsList(),
            if (_assets.isEmpty && _accounts.isEmpty) _buildEmptyState(),
            const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
          ],
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 60,
      floating: true,
      pinned: true,
      backgroundColor: WoColors.bg,
      title: Text('Net Worth', style: WoText.display()),
      actions: [
        IconButton(
          icon: Icon(CupertinoIcons.arrow_clockwise, color: WoColors.textMid),
          onPressed: _loadData,
        ),
      ],
    );
  }

  Widget _buildNetWorthCard() {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(28),
        decoration: woCard(goldGlow: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('TOTAL NET WORTH', style: WoText.label(color: WoColors.gold)),
                WoChip(DateFormat('MMM dd, yyyy').format(DateTime.now()), color: WoColors.textMid),
              ],
            ),
            const SizedBox(height: 10),
            Text(_formatCurrency(_netWorth), style: WoText.hero()),
            const SizedBox(height: 24),
            Container(height: 1, color: WoColors.border),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: _buildNetWorthStat('Assets', _totalAssets, CupertinoIcons.chart_bar_fill, WoColors.mint)),
                Container(width: 1, height: 40, color: WoColors.border),
                Expanded(child: _buildNetWorthStat('Accounts', _totalAccounts, CupertinoIcons.creditcard_fill, WoColors.blue)),
                Container(width: 1, height: 40, color: WoColors.border),
                Expanded(child: _buildNetWorthStat('Liabilities', _totalLiabilities, CupertinoIcons.minus_circle_fill, WoColors.red)),
              ],
            ),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _buildNetWorthStat(String label, double value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 6),
        Text(_formatCompact(value), style: WoText.num(size: 14)),
        Text(label, style: WoText.caption(color: WoColors.textLo)),
      ],
    );
  }

  Widget _buildBreakdownChart() {
    if (_assetBreakdown.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final total = _assetBreakdown.values.fold(0.0, (sum, v) => sum + v);
    if (total == 0) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final colors = [
      WoColors.mint,
      WoColors.blue,
      WoColors.orange,
      WoColors.red,
      WoColors.indigo,
      WoColors.teal,
      WoColors.gold,
      WoColors.goldDeep,
    ];

    final sortedEntries = _assetBreakdown.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final sections = sortedEntries.asMap().entries.map((entry) {
      final value = entry.value.value;
      return PieChartSectionData(
        value: value,
        color: colors[entry.key % colors.length],
        title: '',
        radius: 35,
      );
    }).toList();

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: woCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const WoSectionHeader('Wealth Breakdown', padding: EdgeInsets.only(bottom: 16)),
            Row(
              children: [
                SizedBox(
                  width: 110,
                  height: 110,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(PieChartData(sections: sections, centerSpaceRadius: 30, sectionsSpace: 2)),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${sortedEntries.length}', style: WoText.num(size: 18)),
                          Text('Types', style: WoText.caption(color: WoColors.textLo)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    children: sortedEntries.asMap().entries.map((entry) {
                      final type = _formatAssetType(entry.value.key);
                      final value = entry.value.value;
                      final percent = total > 0 ? (value / total * 100) : 0;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[entry.key % colors.length], borderRadius: BorderRadius.circular(2))),
                            const SizedBox(width: 8),
                            Expanded(child: Text(type, style: WoText.caption(), overflow: TextOverflow.ellipsis)),
                            Text('${percent.toStringAsFixed(0)}%', style: WoText.num(color: WoColors.textMid, size: 11)),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ).animate().fadeIn(delay: 100.ms),
    );
  }

  Widget _buildQuickStats() {
    // Bank/cash account balances ARE liquid — only assets like property are
    // non-liquid. (Previously "Liquid" counted liquid-flagged assets only, so
    // it showed 0 even with cash in the bank.)
    final liquid = _liquidAssets + _totalAccounts;
    final nonLiquid = (_totalAssets - _liquidAssets).clamp(0.0, double.infinity);
    final denom = liquid + nonLiquid;
    final liquidPercent = denom > 0 ? (liquid / denom * 100) : 0.0;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Expanded(
              child: _buildStatCard('Liquid', liquid, '${liquidPercent.toStringAsFixed(0)}%', WoColors.mint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard('Non-Liquid', nonLiquid, '${(100 - liquidPercent).toStringAsFixed(0)}%', WoColors.orange),
            ),
          ],
        ),
      ).animate().fadeIn(delay: 150.ms),
    );
  }

  Widget _buildStatCard(String label, double value, String percent, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 18, tint: color),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.08)],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.25), width: 0.8),
            ),
            child: Center(child: Text(percent, style: WoText.num(color: color, size: 11))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: WoText.caption()),
                Text(_formatCompact(value), style: WoText.num(size: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssetsList() {
    if (_assets.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final topAssets = _assets.toList()
      ..sort((a, b) => (_assetBaseValue[b.id] ?? 0).compareTo(_assetBaseValue[a.id] ?? 0));

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(16),
        decoration: woCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const WoSectionHeader('Top Assets', padding: EdgeInsets.only(bottom: 12)),
            ...topAssets.take(5).map((asset) => _buildAssetRow(asset)),
          ],
        ),
      ).animate().fadeIn(delay: 200.ms),
    );
  }

  Widget _buildAssetRow(Asset asset) {
    final gain = asset.currentValue - asset.purchaseValue;
    final isPositive = gain >= 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          WoIconBubble(_getAssetIcon(asset.type), color: _getAssetColor(asset.type), size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(asset.name, style: WoText.bodyHi(), overflow: TextOverflow.ellipsis),
                Text(_formatAssetType(asset.type), style: WoText.caption(color: WoColors.textLo)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(CurrencyUtils.formatCompact(asset.currentValue, asset.currencyCode), style: WoText.num(size: 13)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(isPositive ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down, size: 10, color: isPositive ? WoColors.mint : WoColors.red),
                  Text(CurrencyUtils.formatCompact(gain.abs(), asset.currencyCode), style: WoText.num(color: isPositive ? WoColors.mint : WoColors.red, size: 10)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAccountsList() {
    if (_accounts.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(16),
        decoration: woCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const WoSectionHeader('Bank Accounts', padding: EdgeInsets.only(bottom: 12)),
            ..._accounts.take(5).map((account) => _buildAccountRow(account)),
          ],
        ),
      ).animate().fadeIn(delay: 250.ms),
    );
  }

  Widget _buildAccountRow(Account account) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          WoIconBubble(CupertinoIcons.creditcard_fill, color: WoColors.blue, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(account.name, style: WoText.bodyHi()),
                if (account.institution != null)
                  Text(account.institution!, style: WoText.caption(color: WoColors.textLo)),
              ],
            ),
          ),
          Text(CurrencyUtils.formatCompact(account.balance, account.currencyCode), style: WoText.num(size: 13)),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: const WoEmptyState(
          icon: CupertinoIcons.chart_pie_fill,
          title: 'No assets or accounts yet',
          hint: 'Add assets and accounts to see your net worth grow',
        ).animate().fadeIn(),
      ),
    );
  }

  IconData _getAssetIcon(String type) {
    switch (type) {
      case 'real_estate': return CupertinoIcons.house_fill;
      case 'stocks': return CupertinoIcons.graph_square;
      case 'mutual_funds': return CupertinoIcons.chart_pie;
      case 'fixed_deposit': return CupertinoIcons.lock_shield;
      case 'gold': return CupertinoIcons.circle_fill;
      case 'crypto': return CupertinoIcons.bitcoin_circle;
      default: return CupertinoIcons.money_dollar_circle;
    }
  }

  Color _getAssetColor(String type) {
    switch (type) {
      case 'real_estate': return WoColors.indigo;
      case 'stocks': return WoColors.mint;
      case 'mutual_funds': return WoColors.blue;
      case 'fixed_deposit': return WoColors.orange;
      case 'gold': return WoColors.gold;
      case 'crypto': return WoColors.teal;
      default: return WoColors.textMid;
    }
  }

  String _formatAssetType(String type) {
    switch (type) {
      case 'real_estate': return 'Real Estate';
      case 'stocks': return 'Stocks';
      case 'mutual_funds': return 'Mutual Funds';
      case 'fixed_deposit': return 'Fixed Deposits';
      case 'cash_accounts': return 'Cash & Accounts';
      case 'gold': return 'Gold';
      case 'crypto': return 'Crypto';
      case 'ppf': return 'PPF';
      case 'nps': return 'NPS';
      default: return type.replaceAll('_', ' ').split(' ').map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : w).join(' ');
    }
  }

  String _formatCurrency(double amount) => CurrencyUtils.format(amount, _base);
  String _formatCompact(double amount) => CurrencyUtils.formatCompact(amount, _base);
}
