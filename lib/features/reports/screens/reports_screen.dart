import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'annual_planning_screen.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/secure_vault.dart';
import '../../../data/services/pdf_report_service.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _base = 'AED';
  AppRepository? _repo;
  bool _isLoading = true;

  double _netWorth = 0;
  double _totalAssets = 0;
  double _totalAccounts = 0;
  double _totalLiabilities = 0;
  double _monthlyIncome = 0;
  double _monthlyExpenses = 0;
  double _totalMonthlySip = 0;
  double _totalMonthlyEmi = 0;
  double _totalDividendsThisYear = 0;
  int _emergencyFundMonths = 0;

  List<Map<String, dynamic>> _assetAllocation = [];
  List<Map<String, dynamic>> _incomeVsExpense = [];
  List<Map<String, dynamic>> _topExpenses = [];

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

    // Net worth breakdown with liabilities
    final totalAssets = await _repo!.getTotalAssetValue();
    final totalAccounts = await _repo!.getTotalAccountBalance();
    final totalLiabilities = await _repo!.getTotalLiabilities();
    final netWorth = totalAssets + totalAccounts - totalLiabilities;

    // Monthly income/expense/SIP/EMI
    final now = DateTime.now();
    final income = await _repo!.getTotalIncomeByMonth(now.year, now.month);
    final expenses = await _repo!.getTotalExpensesByMonth(now.year, now.month);
    final totalSip = await _repo!.getTotalMonthlySip();
    final totalEmi = await _repo!.getTotalMonthlyEMI();

    // Dividends this year
    final dividendsThisYear = await _repo!.getTotalDividendsByYear(now.year);

    // Emergency fund
    final emergencyMonths = await _repo!.getEmergencyFundMonths();

    // Asset allocation
    final assets = await _repo!.getAllAssets();
    final assetsByType = <String, double>{};
    for (final asset in assets) {
      // Convert each holding into the base currency before aggregating —
      // allocation mixes INR/AED/USD assets.
      final base = await _repo!.toBase(asset.currentValue, asset.currencyCode);
      assetsByType[asset.type] = (assetsByType[asset.type] ?? 0) + base;
    }

    // Income vs Expense for last 6 months
    final incomeVsExpense = <Map<String, dynamic>>[];
    for (int i = 5; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final monthIncome = await _repo!.getTotalIncomeByMonth(month.year, month.month);
      final monthExpense = await _repo!.getTotalExpensesByMonth(month.year, month.month);
      incomeVsExpense.add({
        'month': DateFormat('MMM').format(month),
        'income': monthIncome,
        'expense': monthExpense,
      });
    }

    // Top expenses by category
    final expensesByCategory = await _repo!.getExpensesByCategory(
      DateTime(now.year, now.month, 1),
      DateTime(now.year, now.month + 1, 0),
    );
    final sortedExpenses = expensesByCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    setState(() {
      _netWorth = netWorth;
      _totalAssets = totalAssets;
      _totalAccounts = totalAccounts;
      _totalLiabilities = totalLiabilities;
      _totalMonthlySip = totalSip;
      _totalMonthlyEmi = totalEmi;
      _totalDividendsThisYear = dividendsThisYear;
      _monthlyIncome = income;
      _monthlyExpenses = expenses;
      _emergencyFundMonths = emergencyMonths;

      _assetAllocation = assetsByType.entries
          .map((e) => {'type': e.key, 'value': e.value})
          .toList();

      _incomeVsExpense = incomeVsExpense;

      _topExpenses = sortedExpenses.take(5)
          .map((e) => {'category': e.key, 'amount': e.value})
          .toList();

      _isLoading = false;
    });
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
            _buildKeyMetrics(),
            _buildCashFlowAnalysis(),
            _buildFinancialHealthCard(),
            _buildAssetAllocationChart(),
            _buildIncomeVsExpenseChart(),
            _buildTopExpensesCard(),
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
      title: Text('Financial Reports', style: WoText.display()),
      actions: [
        // PDF Export Menu
        PopupMenuButton<String>(
          icon: Icon(CupertinoIcons.square_arrow_up, color: WoColors.gold),
          tooltip: 'Export Report',
          color: WoColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WoRadius.control),
            side: BorderSide(color: WoColors.border),
          ),
          onSelected: (value) => _handleExport(value),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'summary',
              child: Row(
                children: [
                  Icon(CupertinoIcons.doc_chart, color: WoColors.textMid, size: 18),
                  const SizedBox(width: 12),
                  Text('Financial Summary', style: WoText.bodyHi()),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'annual',
              child: Row(
                children: [
                  Icon(CupertinoIcons.calendar, color: WoColors.textMid, size: 18),
                  const SizedBox(width: 12),
                  Text('Annual Report ${DateTime.now().year}', style: WoText.bodyHi()),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'csv',
              child: Row(
                children: [
                  Icon(CupertinoIcons.table, color: WoColors.textMid, size: 18),
                  const SizedBox(width: 12),
                  Text('Transactions (CSV)', style: WoText.bodyHi()),
                ],
              ),
            ),
          ],
        ),
        IconButton(
          icon: Icon(CupertinoIcons.doc_text_search, color: WoColors.textMid),
          tooltip: 'Annual Plan',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AnnualPlanningScreen())),
        ),
        IconButton(
          icon: Icon(CupertinoIcons.arrow_clockwise, color: WoColors.textMid),
          onPressed: _loadData,
        ),
      ],
    );
  }

  Future<void> _exportTransactionsCsv() async {
    if (_repo == null) return;
    try {
      final txns = await _repo!.getAllTransactions();
      final categories = await _repo!.getAllCategories();
      final accounts = await _repo!.getAllAccounts();
      final catName = {for (final c in categories) c.id: c.name};
      final accName = {for (final a in accounts) a.id: a.name};

      String esc(String s) => '"${s.replaceAll('"', '""')}"';
      final buffer = StringBuffer('Date,Description,Merchant,Type,Amount,Currency,Category,Account,Status\n');
      for (final t in txns) {
        buffer.writeln([
          t.transactionDate.toIso8601String().split('T').first,
          esc(t.description),
          esc(t.merchant ?? ''),
          t.type,
          t.amountBase.toStringAsFixed(2),
          t.currencyCode,
          esc(catName[t.categoryId] ?? ''),
          esc(accName[t.accountId] ?? ''),
          t.status,
        ].join(','));
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/wealthorbit_transactions_${DateTime.now().millisecondsSinceEpoch}.csv');
      await file.writeAsString(buffer.toString());
      await Share.shareXFiles([XFile(file.path)], subject: 'WealthOrbit Transactions');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _handleExport(String type) async {
    if (_repo == null) return;

    if (type == 'csv') {
      await _exportTransactionsCsv();
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: WoColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.card)),
        content: Row(
          children: [
            CircularProgressIndicator(color: WoColors.gold),
            const SizedBox(width: 20),
            Text('Generating PDF...', style: WoText.bodyHi()),
          ],
        ),
      ),
    );

    try {
      final pdfService = PdfReportService(_repo!);
      final file = type == 'summary'
          ? await pdfService.generateFinancialSummaryReport()
          : await pdfService.generateAnnualReport(DateTime.now().year);

      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      // Show success and share option
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (context) => WoSheet(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Center(child: Icon(CupertinoIcons.checkmark_circle_fill, color: WoColors.mint, size: 48)),
              const SizedBox(height: 16),
              Center(child: Text('Report Generated!', style: WoText.title())),
              const SizedBox(height: 8),
              Center(child: Text(file.path.split('/').last, style: WoText.caption())),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    pdfService.shareReport(file);
                  },
                  icon: const Icon(CupertinoIcons.share, color: Colors.black),
                  label: const Text('Share Report'),
                  style: WoButtons.primary,
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to generate report: $e'), backgroundColor: WoColors.red),
      );
    }
  }

  Widget _buildNetWorthCard() {
    final savingsRate = _monthlyIncome > 0
        ? ((_monthlyIncome - _monthlyExpenses) / _monthlyIncome * 100)
        : 0.0;

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(24),
        decoration: woCard(goldGlow: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('NET WORTH', style: WoText.label()),
                    const SizedBox(height: 6),
                    Text(_formatCurrency(_netWorth), style: WoText.display(color: WoColors.gold)),
                  ],
                ),
                WoChip('${savingsRate.toStringAsFixed(0)}% savings rate', color: WoColors.gold),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: _buildNetWorthItem('Assets', _totalAssets, WoColors.mint)),
                Expanded(child: _buildNetWorthItem('Accounts', _totalAccounts, WoColors.blue)),
                Expanded(child: _buildNetWorthItem('Liabilities', _totalLiabilities, WoColors.red)),
              ],
            ),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _buildNetWorthItem(String label, double value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
            const SizedBox(width: 6),
            Text(label, style: WoText.caption()),
          ],
        ),
        const SizedBox(height: 4),
        Text(_formatCompact(value), style: WoText.num(size: 14)),
      ],
    );
  }

  Widget _buildKeyMetrics() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Expanded(child: _buildMetricCard('Income', _monthlyIncome, CupertinoIcons.arrow_down_circle_fill, WoColors.mint)),
            const SizedBox(width: 10),
            Expanded(child: _buildMetricCard('Expenses', _monthlyExpenses, CupertinoIcons.arrow_up_circle_fill, WoColors.red)),
            const SizedBox(width: 10),
            Expanded(child: _buildMetricCard('Emergency', _emergencyFundMonths.toDouble(), CupertinoIcons.shield_fill, WoColors.blue, suffix: ' mo')),
          ],
        ),
      ).animate().fadeIn(delay: 100.ms),
    );
  }

  Widget _buildMetricCard(String title, double value, IconData icon, Color color, {String suffix = ''}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: woCard(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(suffix.isEmpty ? _formatCompact(value) : '${value.toInt()}$suffix', style: WoText.num(size: 16)),
          Text(title, style: WoText.caption(color: WoColors.textLo)),
        ],
      ),
    );
  }

  Widget _buildAssetAllocationChart() {
    if (_assetAllocation.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final total = _assetAllocation.fold(0.0, (sum, e) => sum + (e['value'] as double));
    if (total == 0) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final colors = [
      WoColors.gold,
      WoColors.blue,
      WoColors.mint,
      WoColors.orange,
      WoColors.indigo,
      WoColors.teal,
      WoColors.red,
    ];

    final sections = _assetAllocation.asMap().entries.map((entry) {
      final value = entry.value['value'] as double;
      return PieChartSectionData(
        value: value,
        color: colors[entry.key % colors.length],
        title: '${(value / total * 100).toStringAsFixed(0)}%',
        radius: 30,
        titleStyle: GoogleFonts.poppins(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold),
      );
    }).toList();

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: woCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const WoSectionHeader('Asset Allocation', padding: EdgeInsets.zero),
            const SizedBox(height: 16),
            Row(
              children: [
                SizedBox(
                  width: 100,
                  height: 100,
                  child: PieChart(PieChartData(sections: sections, centerSpaceRadius: 25, sectionsSpace: 2)),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    children: _assetAllocation.asMap().entries.map((entry) {
                      final type = _formatAssetType(entry.value['type'] as String);
                      final value = entry.value['value'] as double;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[entry.key % colors.length], borderRadius: BorderRadius.circular(2))),
                            const SizedBox(width: 8),
                            Expanded(child: Text(type, style: WoText.caption())),
                            Text(_formatCompact(value), style: WoText.num(size: 11)),
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
      ).animate().fadeIn(delay: 200.ms),
    );
  }

  Widget _buildIncomeVsExpenseChart() {
    if (_incomeVsExpense.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final maxValue = _incomeVsExpense.fold(0.0, (max, e) {
      final income = e['income'] as double;
      final expense = e['expense'] as double;
      return [max, income, expense].reduce((a, b) => a > b ? a : b);
    });

    if (maxValue == 0) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: woCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('INCOME VS EXPENSES', style: WoText.label()),
                Row(
                  children: [
                    _buildLegendDot('Income', WoColors.mint),
                    const SizedBox(width: 12),
                    _buildLegendDot('Expense', WoColors.red),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 180,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxValue * 1.2,
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          if (value.toInt() < _incomeVsExpense.length) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(_incomeVsExpense[value.toInt()]['month'], style: WoText.caption(color: WoColors.textLo)),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(show: false),
                  barGroups: _incomeVsExpense.asMap().entries.map((entry) {
                    return BarChartGroupData(
                      x: entry.key,
                      barRods: [
                        BarChartRodData(toY: entry.value['income'] as double, color: WoColors.mint, width: 12, borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
                        BarChartRodData(toY: entry.value['expense'] as double, color: WoColors.red, width: 12, borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ).animate().fadeIn(delay: 300.ms),
    );
  }

  Widget _buildLegendDot(String label, Color color) {
    return Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
        const SizedBox(width: 4),
        Text(label, style: WoText.caption()),
      ],
    );
  }

  Widget _buildTopExpensesCard() {
    if (_topExpenses.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final colors = [
      WoColors.red,
      WoColors.orange,
      WoColors.gold,
      WoColors.mint,
      WoColors.blue,
    ];

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: woCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('TOP EXPENSES THIS MONTH', style: WoText.label()),
            const SizedBox(height: 16),
            ..._topExpenses.asMap().entries.map((entry) {
              final category = entry.value['category'] as String;
              final amount = entry.value['amount'] as double;
              final maxAmount = _topExpenses.first['amount'] as double;

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(category, style: WoText.bodyHi()),
                        Text(_formatCurrency(amount), style: WoText.num(size: 12)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: maxAmount > 0 ? amount / maxAmount : 0,
                        backgroundColor: WoColors.inputFill,
                        valueColor: AlwaysStoppedAnimation(colors[entry.key % colors.length]),
                        minHeight: 6,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ).animate().fadeIn(delay: 400.ms),
    );
  }

  String _formatAssetType(String type) {
    switch (type) {
      case 'real_estate': return 'Real Estate';
      case 'stocks': return 'Stocks';
      case 'mutual_funds': return 'Mutual Funds';
      case 'fixed_deposit': return 'Fixed Deposits';
      case 'gold': return 'Gold';
      case 'crypto': return 'Crypto';
      case 'ppf': return 'PPF';
      case 'nps': return 'NPS';
      default: return type.replaceAll('_', ' ').split(' ').map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
    }
  }

  String _formatCurrency(double amount) => CurrencyUtils.format(amount, _base);
  String _formatCompact(double amount) => CurrencyUtils.formatCompact(amount, _base);

  // ═══════════════════════════════════════════════════════════════════════════
  // CASH FLOW ANALYSIS WIDGET
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildCashFlowAnalysis() {
    final netCashFlow = _monthlyIncome - _monthlyExpenses - _totalMonthlyEmi;
    final freeCashFlow = netCashFlow - _totalMonthlySip;
    final isPositive = netCashFlow >= 0;

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: woCard(tint: isPositive ? WoColors.mint : WoColors.red),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('CASH FLOW ANALYSIS', style: WoText.label()),
                Icon(
                  isPositive ? CupertinoIcons.arrow_up_circle_fill : CupertinoIcons.arrow_down_circle_fill,
                  color: isPositive ? WoColors.mint : WoColors.red,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildCashFlowRow('Income', _monthlyIncome, WoColors.mint),
            _buildCashFlowRow('Expenses', -_monthlyExpenses, WoColors.red),
            _buildCashFlowRow('EMI Payments', -_totalMonthlyEmi, WoColors.orange),
            Divider(color: WoColors.borderHi, height: 24),
            _buildCashFlowRow('Net Cash Flow', netCashFlow, isPositive ? WoColors.mint : WoColors.red, isBold: true),
            const SizedBox(height: 8),
            _buildCashFlowRow('SIP Investments', -_totalMonthlySip, WoColors.blue),
            Divider(color: WoColors.borderHi, height: 24),
            _buildCashFlowRow('Free Cash Flow', freeCashFlow, freeCashFlow >= 0 ? WoColors.mint : WoColors.red, isBold: true),
            const SizedBox(height: 12),
            if (_totalDividendsThisYear > 0)
              WoNotice(
                'Dividends YTD: ${_formatCurrency(_totalDividendsThisYear)}',
                color: WoColors.mint,
                icon: CupertinoIcons.money_dollar_circle_fill,
              ),
          ],
        ),
      ).animate().fadeIn(delay: 200.ms),
    );
  }

  Widget _buildCashFlowRow(String label, double amount, Color color, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: isBold ? WoText.bodyHi() : WoText.body()),
          Text(
            '${amount >= 0 ? '+' : ''}${_formatCurrency(amount.abs())}',
            style: WoText.num(color: color, size: 13),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // FINANCIAL HEALTH CARD
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildFinancialHealthCard() {
    // Calculate key financial ratios
    final savingsRate = _monthlyIncome > 0 ? ((_monthlyIncome - _monthlyExpenses) / _monthlyIncome * 100) : 0.0;
    final debtToIncome = _monthlyIncome > 0 ? (_totalMonthlyEmi / _monthlyIncome * 100) : 0.0;
    final investmentRate = _monthlyIncome > 0 ? (_totalMonthlySip / _monthlyIncome * 100) : 0.0;
    final debtToAssets = (_totalAssets + _totalAccounts) > 0 ? (_totalLiabilities / (_totalAssets + _totalAccounts) * 100) : 0.0;

    // Calculate health score (0-100)
    double healthScore = 50.0; // Base score

    // Savings rate contribution (max +20 points)
    healthScore += (savingsRate.clamp(0, 30) / 30 * 20);

    // Emergency fund contribution (max +15 points)
    healthScore += (_emergencyFundMonths.clamp(0, 6) / 6 * 15);

    // Investment rate contribution (max +10 points)
    healthScore += (investmentRate.clamp(0, 20) / 20 * 10);

    // Debt penalties
    healthScore -= (debtToIncome.clamp(0, 50) / 50 * 15); // Penalty for high debt-to-income
    healthScore -= (debtToAssets.clamp(0, 80) / 80 * 10); // Penalty for high debt-to-assets

    healthScore = healthScore.clamp(0, 100);

    final healthGrade = healthScore >= 80 ? 'Excellent' : healthScore >= 60 ? 'Good' : healthScore >= 40 ? 'Fair' : 'Needs Attention';
    final healthColor = healthScore >= 80 ? WoColors.mint : healthScore >= 60 ? WoColors.gold : healthScore >= 40 ? WoColors.orange : WoColors.red;

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: woCard(tint: healthColor),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('FINANCIAL HEALTH', style: WoText.label()),
                    const SizedBox(height: 4),
                    Text(healthGrade, style: WoText.subtitle(color: healthColor)),
                  ],
                ),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 60,
                      height: 60,
                      child: CircularProgressIndicator(
                        value: healthScore / 100,
                        strokeWidth: 6,
                        backgroundColor: WoColors.borderHi,
                        valueColor: AlwaysStoppedAnimation(healthColor),
                      ),
                    ),
                    Text('${healthScore.toInt()}', style: WoText.num(size: 16)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: _buildHealthMetric('Savings Rate', '${savingsRate.toStringAsFixed(0)}%', savingsRate >= 20 ? WoColors.mint : WoColors.orange)),
                Expanded(child: _buildHealthMetric('Debt-to-Income', '${debtToIncome.toStringAsFixed(0)}%', debtToIncome <= 36 ? WoColors.mint : WoColors.red)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _buildHealthMetric('Investment Rate', '${investmentRate.toStringAsFixed(0)}%', investmentRate >= 10 ? WoColors.mint : WoColors.orange)),
                Expanded(child: _buildHealthMetric('Debt-to-Assets', '${debtToAssets.toStringAsFixed(0)}%', debtToAssets <= 50 ? WoColors.mint : WoColors.red)),
              ],
            ),
          ],
        ),
      ).animate().fadeIn(delay: 250.ms),
    );
  }

  Widget _buildHealthMetric(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: WoText.caption()),
        const SizedBox(height: 4),
        Text(value, style: WoText.num(color: color, size: 18)),
      ],
    );
  }
}
