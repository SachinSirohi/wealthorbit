import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/secure_vault.dart';
import '../../../data/services/gemini_service.dart';
import '../../../data/services/insights_service.dart';
import '../widgets/insight_carousel.dart';
import '../../ai/screens/ai_chat_screen.dart';

/// Home Dashboard screen with real data integration
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _base = 'AED';
  AppRepository? _repo;
  bool _isLoading = true;
  
  // Dashboard data
  double _netWorth = 0;
  double _totalAssets = 0;
  double _totalAccounts = 0;
  double _monthlyIncome = 0;
  double _monthlyExpenses = 0;
  int _emergencyFundMonths = 0;
  double _budgetUsed = 0;
  double _budgetTotal = 0;

  List<Transaction> _recentTransactions = [];
  List<Goal> _activeGoals = [];
  Map<String, double> _assetAllocation = {};
  List<double> _expenseSeries = [];
  List<double> _incomeSeries = [];
  List<NetWorthSnapshot> _netWorthTrend = [];
  List<_Obligation> _obligations = [];
  List<FinancialInsight> _insights = [];
  
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
    setState(() => _isLoading = true);
    
    try {
      // Capture a monthly net-worth snapshot for the trend chart.
      await _repo!.captureMonthlyNetWorthSnapshot();

      // Net worth (assets + accounts − liabilities)
      final netWorth = await _repo!.getNetWorthWithLiabilities();
      final totalAssets = await _repo!.getTotalAssetValue();
      final totalAccounts = await _repo!.getTotalAccountBalance();

      // Monthly data
      final now = DateTime.now();
      final income = await _repo!.getTotalIncomeByMonth(now.year, now.month);
      final expenses = await _repo!.getTotalExpensesByMonth(now.year, now.month);

      // 6-month income / expense series for the cashflow chart
      final expenseSeries = await _repo!.getMonthlyExpenses(6);
      final incomeSeries = <double>[];
      for (int i = 5; i >= 0; i--) {
        final d = DateTime(now.year, now.month - i, 1);
        incomeSeries.add(await _repo!.getTotalIncomeByMonth(d.year, d.month));
      }

      // Emergency fund
      final emergencyMonths = await _repo!.getEmergencyFundMonths();

      // Budget
      final budgets = await _repo!.getAllBudgets();
      final budgetTotal = budgets.fold(0.0, (sum, b) => sum + b.limitAmount);

      // Recent transactions
      final transactions = await _repo!.getAllTransactions();
      final recentTx = transactions.take(5).toList();

      // Goals
      final goals = await _repo!.getAllGoals();
      final activeGoals = goals.take(3).toList();

      // Asset allocation — convert each holding into the base currency first
      // (assets may be held in INR/AED/USD/etc.).
      final assets = await _repo!.getAllAssets();
      final allocation = <String, double>{};
      for (final asset in assets) {
        final base = await _repo!.toBase(asset.currentValue, asset.currencyCode);
        allocation[asset.type] = (allocation[asset.type] ?? 0) + base;
      }

      // Net-worth trend
      final trend = await _repo!.getNetWorthSnapshots(limit: 12);

      // Upcoming obligations (EMIs + SIPs)
      final obligations = await _buildObligations();

      // Proactive insights
      List<FinancialInsight> insights = [];
      try {
        await InsightsService(_repo!).generateInsights();
        insights = await _repo!.getActiveInsights();
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _insights = insights;
        _netWorth = netWorth;
        _totalAssets = totalAssets;
        _totalAccounts = totalAccounts;
        _monthlyIncome = income;
        _monthlyExpenses = expenses;
        _expenseSeries = expenseSeries;
        _incomeSeries = incomeSeries;
        _emergencyFundMonths = emergencyMonths;
        _budgetTotal = budgetTotal;
        _budgetUsed = expenses;
        _recentTransactions = recentTx;
        _activeGoals = activeGoals;
        _assetAllocation = allocation;
        _netWorthTrend = trend;
        _obligations = obligations;
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
      body: RefreshIndicator(
        onRefresh: _loadData,
        color: WoColors.gold,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildAppBar(),
            if (_isLoading)
              SliverFillRemaining(
                child: Center(child: CircularProgressIndicator(color: WoColors.gold)),
              )
            else ...[
              _buildInsights(),
              _buildNetWorthCard(),
              _buildQuickActions(),
              _buildFinancialHealth(),
              _buildNetWorthTrend(),
              _buildCashflowChart(),
              _buildUpcomingObligations(),
              _buildAssetAllocation(),
              _buildGoalsSection(),
              _buildRecentTransactions(),
              const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 100,
      floating: false,
      pinned: true,
      backgroundColor: WoColors.bg,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _getGreeting(),
              style: GoogleFonts.poppins(fontSize: 12, color: WoColors.textMid, fontWeight: FontWeight.w400),
            ),
            Text(
              'WealthOrbit',
              style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold, color: WoColors.textHi),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: Icon(CupertinoIcons.sparkles, color: WoColors.gold),
          tooltip: 'Ask WealthOrbit AI',
          onPressed: _openAiChat,
        ),
        IconButton(
          icon: Icon(CupertinoIcons.gear, color: WoColors.textMid),
          tooltip: 'Statements & Automation',
          onPressed: () => context.push('/settings'),
        ),
      ],
    );
  }

  Widget _buildNetWorthCard() {
    final savingsRate = _monthlyIncome > 0
        ? ((_monthlyIncome - _monthlyExpenses) / _monthlyIncome * 100)
        : 0.0;

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(24),
        decoration: woCard(radius: 26, goldGlow: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('NET WORTH', style: WoText.label(color: WoColors.gold)),
                WoChip('${savingsRate.toStringAsFixed(0)}% saved',
                    color: savingsRate >= 0 ? WoColors.gold : WoColors.red,
                    icon: CupertinoIcons.sparkles),
              ],
            ),
            const SizedBox(height: 12),
            Text(_formatCurrency(_netWorth), style: WoText.hero()),
            const SizedBox(height: 22),
            Container(height: 1, color: WoColors.border),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _heroStat('Assets', _formatCompact(_totalAssets), WoColors.blue,
                      onTap: () => context.push('/assets')),
                ),
                Expanded(
                  child: _heroStat('Accounts', _formatCompact(_totalAccounts), WoColors.teal,
                      onTap: () => context.push('/accounts')),
                ),
                Expanded(
                  child: _heroStat(
                    'This Month',
                    _monthlyIncome >= _monthlyExpenses
                        ? '+${_formatCompact(_monthlyIncome - _monthlyExpenses)}'
                        : '-${_formatCompact(_monthlyExpenses - _monthlyIncome)}',
                    _monthlyIncome >= _monthlyExpenses ? WoColors.mint : WoColors.red,
                  ),
                ),
              ],
            ),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _heroStat(String label, String value, Color dot, {VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(label, style: WoText.caption(color: WoColors.textLo)),
            ],
          ),
          const SizedBox(height: 6),
          Text(value, style: WoText.num(size: 15.5)),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    final actions = [
      {'icon': CupertinoIcons.arrow_down_circle_fill, 'label': 'Income', 'color': const Color(0xFF4CAF50), 'route': '/transactions'},
      {'icon': CupertinoIcons.arrow_up_circle_fill, 'label': 'Expense', 'color': const Color(0xFFE53935), 'route': '/transactions'},
      {'icon': CupertinoIcons.chart_bar_fill, 'label': 'Budget', 'color': const Color(0xFF7C4DFF), 'route': '/expenses'},
      {'icon': CupertinoIcons.graph_square, 'label': 'Invest', 'color': const Color(0xFF2196F3), 'route': '/investments'},
    ];
    
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: actions.map((action) => _buildQuickAction(
            action['icon'] as IconData,
            action['label'] as String,
            action['color'] as Color,
            action['route'] as String,
          )).toList(),
        ),
      ).animate().fadeIn(delay: 100.ms),
    );
  }

  Widget _buildQuickAction(IconData icon, String label, Color color, String route) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        context.push(route);
      },
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [WoColors.surfaceHi, WoColors.surfaceLo],
              ),
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
              boxShadow: WoShadows.card,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 8),
          Text(label, style: WoText.caption(color: WoColors.textMid)),
        ],
      ),
    );
  }

  Widget _buildFinancialHealth() {
    final budgetProgress = _budgetTotal > 0 ? (_budgetUsed / _budgetTotal).clamp(0.0, 1.0) : 0.0;
    
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const WoSectionHeader('Financial Health'),
            Row(
              children: [
                Expanded(child: _buildHealthCard('Emergency Fund', '$_emergencyFundMonths months', CupertinoIcons.shield_fill, WoColors.mint, _emergencyFundMonths >= 6 ? 1.0 : _emergencyFundMonths / 6)),
                const SizedBox(width: 14),
                Expanded(child: _buildHealthCard('Budget Used', '${(budgetProgress * 100).toStringAsFixed(0)}%', CupertinoIcons.chart_pie_fill, budgetProgress > 0.9 ? WoColors.red : WoColors.blue, budgetProgress)),
              ],
            ),
          ],
        ),
      ).animate().fadeIn(delay: 150.ms),
    );
  }

  Widget _buildHealthCard(String title, String value, IconData icon, Color color, double progress) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              WoIconBubble(icon, color: color, size: 36),
              Text(value, style: WoText.num(size: 16)),
            ],
          ),
          const SizedBox(height: 12),
          Text(title, style: WoText.caption()),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: WoColors.inputFill,
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsights() {
    if (_insights.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: InsightCarousel(insights: _insights, onDismiss: _dismissInsight),
      ),
    );
  }

  Future<void> _dismissInsight(String id) async {
    await _repo!.dismissInsight(id);
    final insights = await _repo!.getActiveInsights();
    if (mounted) setState(() => _insights = insights);
  }

  BoxDecoration _cardDecoration() => woCard();

  TextStyle _sectionStyle() => WoText.title();

  Widget _legendDot(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label, style: GoogleFonts.poppins(color: WoColors.textMid, fontSize: 11)),
        ],
      );

  String _assetTypeLabel(String type) {
    const labels = {
      'real_estate': 'Real Estate', 'mutual_fund': 'Mutual Funds', 'stock': 'Stocks',
      'ppf': 'PPF', 'nps': 'NPS', 'fd': 'Fixed Deposit', 'gold': 'Gold',
    };
    return labels[type] ?? type;
  }

  Widget _buildNetWorthTrend() {
    if (_netWorthTrend.length < 2) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final spots = <FlSpot>[
      for (int i = 0; i < _netWorthTrend.length; i++) FlSpot(i.toDouble(), _netWorthTrend[i].netWorth),
    ];
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Net Worth Trend', style: _sectionStyle()),
              const SizedBox(height: 16),
              SizedBox(
                height: 120,
                child: LineChart(LineChartData(
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: WoColors.gold,
                      barWidth: 3,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: true, color: WoColors.gold.withValues(alpha: 0.14)),
                    ),
                  ],
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCashflowChart() {
    final hasData = _expenseSeries.any((e) => e > 0) || _incomeSeries.any((e) => e > 0);
    if (!hasData) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final now = DateTime.now();
    final months = [for (int i = 5; i >= 0; i--) DateFormat('MMM').format(DateTime(now.year, now.month - i, 1))];
    double maxY = 0;
    for (final v in [..._expenseSeries, ..._incomeSeries]) {
      if (v > maxY) maxY = v;
    }
    maxY = maxY == 0 ? 1 : maxY * 1.2;
    final groups = <BarChartGroupData>[
      for (int i = 0; i < 6; i++)
        BarChartGroupData(x: i, barRods: [
          BarChartRodData(
            toY: i < _incomeSeries.length ? _incomeSeries[i] : 0,
            color: const Color(0xFF4CAF50),
            width: 7,
            borderRadius: BorderRadius.circular(2),
          ),
          BarChartRodData(
            toY: i < _expenseSeries.length ? _expenseSeries[i] : 0,
            color: const Color(0xFFE53935),
            width: 7,
            borderRadius: BorderRadius.circular(2),
          ),
        ]),
    ];
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('Cashflow', style: _sectionStyle()),
                const Spacer(),
                _legendDot(const Color(0xFF4CAF50), 'In'),
                const SizedBox(width: 10),
                _legendDot(const Color(0xFFE53935), 'Out'),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                height: 140,
                child: BarChart(BarChartData(
                  maxY: maxY,
                  barGroups: groups,
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          if (i < 0 || i >= months.length) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(months[i], style: GoogleFonts.poppins(color: WoColors.textLo, fontSize: 10)),
                          );
                        },
                      ),
                    ),
                  ),
                )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUpcomingObligations() {
    if (_obligations.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Upcoming Bills', style: _sectionStyle()),
              const SizedBox(height: 8),
              ..._obligations.map((o) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(color: o.color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                        child: Icon(o.icon, color: o.color, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(o.label, style: GoogleFonts.poppins(color: WoColors.textHi, fontSize: 13, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(o.daysUntil <= 0 ? 'Due today' : 'In ${o.daysUntil} days', style: GoogleFonts.poppins(color: WoColors.textLo, fontSize: 11)),
                        ]),
                      ),
                      Text(NumberFormat.compactCurrency(symbol: '${o.currency} ', decimalDigits: 0).format(o.amount),
                          style: GoogleFonts.poppins(color: WoColors.textHi, fontSize: 13, fontWeight: FontWeight.w600)),
                    ]),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAssetAllocation() {
    final total = _assetAllocation.values.fold(0.0, (s, v) => s + v);
    if (total <= 0) return SliverToBoxAdapter(child: SizedBox.shrink());
    final palette = [
      WoColors.gold, WoColors.blue, WoColors.mint, WoColors.orange,
      Color(0xFFAF52DE), Color(0xFFFF2D55), Color(0xFF5856D6),
    ];
    final entries = _assetAllocation.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final sections = <PieChartSectionData>[
      for (int i = 0; i < entries.length; i++)
        PieChartSectionData(
          value: entries[i].value,
          color: palette[i % palette.length],
          title: '${(entries[i].value / total * 100).toStringAsFixed(0)}%',
          radius: 50,
          titleStyle: GoogleFonts.poppins(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
        ),
    ];
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Asset Allocation', style: _sectionStyle()),
              SizedBox(height: 12),
              SizedBox(height: 150, child: PieChart(PieChartData(sections: sections, centerSpaceRadius: 30, sectionsSpace: 2))),
              SizedBox(height: 12),
              Wrap(spacing: 12, runSpacing: 6, children: [
                for (int i = 0; i < entries.length; i++) _legendDot(palette[i % palette.length], _assetTypeLabel(entries[i].key)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGoalsSection() {
    if (_activeGoals.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Active Goals', style: WoText.title()),
                TextButton(
                  onPressed: () => context.push('/goals'),
                  child: Text('See All', style: GoogleFonts.inter(color: WoColors.gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._activeGoals.map((goal) => _buildGoalCard(goal)),
          ],
        ),
      ).animate().fadeIn(delay: 200.ms),
    );
  }

  Widget _buildGoalCard(Goal goal) {
    final progress = goal.targetAmount > 0
        ? (goal.currentAmount / goal.targetAmount).clamp(0.0, 1.0)
        : 0.0;
    final daysLeft = goal.targetDate.difference(DateTime.now()).inDays;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 18),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(goal.name, style: GoogleFonts.poppins(color: WoColors.textHi, fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(daysLeft > 0 ? '$daysLeft days left' : 'Due date passed', style: GoogleFonts.poppins(color: daysLeft > 0 ? Colors.white38 : const Color(0xFFE53935), fontSize: 11)),
                ],
              ),
              Text('${(progress * 100).toStringAsFixed(0)}%', style: WoText.num(color: WoColors.gold, size: 18)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: WoColors.inputFill,
              valueColor: AlwaysStoppedAnimation(WoColors.gold),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentTransactions() {
    if (_recentTransactions.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Recent Transactions', style: WoText.title()),
                TextButton(
                  onPressed: () => context.push('/transactions'),
                  child: Text('See All', style: GoogleFonts.inter(color: WoColors.gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            Container(
              decoration: woCard(radius: 18),
              child: Column(
                children: _recentTransactions.asMap().entries.map((entry) {
                  final tx = entry.value;
                  final isLast = entry.key == _recentTransactions.length - 1;
                  return _buildTransactionRow(tx, isLast);
                }).toList(),
              ),
            ),
          ],
        ),
      ).animate().fadeIn(delay: 250.ms),
    );
  }

  Widget _buildTransactionRow(Transaction tx, bool isLast) {
    final isExpense = tx.type == 'expense';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: WoColors.border, width: 1)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: (isExpense ? const Color(0xFFE53935) : const Color(0xFF4CAF50)).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isExpense ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down,
              color: isExpense ? const Color(0xFFE53935) : const Color(0xFF4CAF50),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tx.description, style: GoogleFonts.poppins(color: WoColors.textHi, fontSize: 13, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(DateFormat('MMM d, yyyy').format(tx.transactionDate), style: GoogleFonts.poppins(color: WoColors.textLo, fontSize: 11)),
              ],
            ),
          ),
          Text(
            '${isExpense ? "-" : "+"}${_formatCurrency(tx.amountBase)}',
            style: GoogleFonts.poppins(color: isExpense ? const Color(0xFFE53935) : const Color(0xFF4CAF50), fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Future<List<_Obligation>> _buildObligations() async {
    final now = DateTime.now();
    final items = <_Obligation>[];

    int nextDue(int dayOfMonth) {
      var d = DateTime(now.year, now.month, dayOfMonth.clamp(1, 28));
      if (d.isBefore(DateTime(now.year, now.month, now.day))) {
        d = DateTime(now.year, now.month + 1, dayOfMonth.clamp(1, 28));
      }
      return d.difference(DateTime(now.year, now.month, now.day)).inDays;
    }

    for (final l in await _repo!.getActiveLiabilities()) {
      if (l.emi <= 0) continue;
      items.add(_Obligation(
        label: '${l.name} EMI',
        amount: l.emi,
        currency: l.currencyCode,
        daysUntil: nextDue(l.startDate.day),
        icon: CupertinoIcons.creditcard,
        color: const Color(0xFFE53935),
      ));
    }
    for (final s in await _repo!.getActiveSips()) {
      items.add(_Obligation(
        label: '${s.name} SIP',
        amount: s.amount,
        currency: s.currencyCode,
        daysUntil: nextDue(s.dayOfMonth),
        icon: CupertinoIcons.chart_bar_alt_fill,
        color: const Color(0xFF30D158),
      ));
    }
    items.sort((a, b) => a.daysUntil.compareTo(b.daysUntil));
    return items.take(4).toList();
  }

  void _openAiChat() {
    if (_repo == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AiChatScreen(
          repository: _repo!,
          geminiService: GeminiService(),
        ),
      ),
    );
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  String _formatCurrency(double amount) => CurrencyUtils.format(amount, _base);
  String _formatCompact(double amount) => CurrencyUtils.formatCompact(amount, _base);
}

class _Obligation {
  final String label;
  final double amount;
  final String currency;
  final int daysUntil;
  final IconData icon;
  final Color color;

  _Obligation({
    required this.label,
    required this.amount,
    required this.currency,
    required this.daysUntil,
    required this.icon,
    required this.color,
  });
}
