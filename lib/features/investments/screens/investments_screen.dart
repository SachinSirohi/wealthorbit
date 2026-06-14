import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fl_chart/fl_chart.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/secure_vault.dart';
import '../widgets/xirr_calculator_sheet.dart';
import 'sip_manager_screen.dart';
import 'dividend_tracker_screen.dart';

class InvestmentsScreen extends StatefulWidget {
  const InvestmentsScreen({super.key});

  @override
  State<InvestmentsScreen> createState() => _InvestmentsScreenState();
}

class _InvestmentsScreenState extends State<InvestmentsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  AppRepository? _repo;
  List<Asset> _stocks = [];
  List<Asset> _mutualFunds = [];
  List<Asset> _fixedDeposits = [];
  List<Asset> _retirement = []; // PPF, NPS, EPF
  bool _isLoading = true;
  double _totalValue = 0;
  double _totalGain = 0;
  // Category totals, already converted into the base currency.
  double _stocksBase = 0;
  double _mfBase = 0;
  double _fdBase = 0;
  double _retirementBase = 0;
  String _base = 'AED';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _initializeData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
      final allAssets = await _repo!.getAllAssets();
      if (!mounted) return;

      final stocks = allAssets.where((a) => a.type == 'stocks').toList();
      final mfs = allAssets.where((a) => a.type == 'mutual_funds').toList();
      final fds = allAssets.where((a) => a.type == 'fixed_deposit').toList();
      final retirement = allAssets.where((a) => ['ppf', 'nps', 'epf'].contains(a.type)).toList();

      // Holdings may be in INR/AED/USD/etc. → convert each into the base
      // currency before aggregating (totals & allocation are cross-currency).
      Future<double> sumBase(List<Asset> list, double Function(Asset) pick) async {
        double s = 0;
        for (final a in list) {
          s += await _repo!.toBase(pick(a), a.currencyCode);
        }
        return s;
      }

      final sBase = await sumBase(stocks, (a) => a.currentValue);
      final mBase = await sumBase(mfs, (a) => a.currentValue);
      final fBase = await sumBase(fds, (a) => a.currentValue);
      final rBase = await sumBase(retirement, (a) => a.currentValue);
      final total = sBase + mBase + fBase + rBase;

      final allInvestments = [...stocks, ...mfs, ...fds, ...retirement];
      final purchase = await sumBase(allInvestments, (a) => a.purchaseValue);

      if (!mounted) return;
      setState(() {
        _stocks = stocks;
        _mutualFunds = mfs;
        _fixedDeposits = fds;
        _retirement = retirement;
        _stocksBase = sBase;
        _mfBase = mBase;
        _fdBase = fBase;
        _retirementBase = rBase;
        _totalValue = total;
        _totalGain = total - purchase;
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
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          _buildAppBar(),
          _buildPortfolioSummary(),
          _buildQuickActions(),
          _buildAllocationChart(),
          SliverPersistentHeader(
            delegate: _SliverTabBarDelegate(
              TabBar(
                controller: _tabController,
                indicatorColor: WoColors.gold,
                labelColor: WoColors.gold,
                unselectedLabelColor: WoColors.textLo,
                labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12),
                tabs: [
                  Tab(text: 'STOCKS'),
                  Tab(text: 'MF/SIP'),
                  Tab(text: 'FD'),
                  Tab(text: 'RETIREMENT'),
                ],
              ),
            ),
            pinned: true,
          ),
        ],
        body: _isLoading
          ? Center(child: CircularProgressIndicator(color: WoColors.gold))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildInvestmentList(_stocks, 'stocks'),
                _buildInvestmentList(_mutualFunds, 'mutual_funds'),
                _buildInvestmentList(_fixedDeposits, 'fixed_deposit'),
                _buildInvestmentList(_retirement, 'ppf'),
              ],
            ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddInvestmentSheet(),
        backgroundColor: WoColors.gold,
        icon: const Icon(CupertinoIcons.add, color: Colors.black),
        label: Text('Add Investment', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
      ).animate().scale(delay: 300.ms),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 60,
      floating: true,
      pinned: true,
      backgroundColor: WoColors.bg,
      title: Text('Investments', style: WoText.display()),
    );
  }

  Widget _buildQuickActions() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Row(
          children: [
            Expanded(child: _buildQuickActionButton('XIRR', Icons.calculate_outlined, WoColors.mint, () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => const XIRRCalculatorSheet(),
              );
            })),
            const SizedBox(width: 8),
            Expanded(child: _buildQuickActionButton('SIPs', Icons.event_repeat, WoColors.gold, () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SIPManagerScreen()));
            })),
            const SizedBox(width: 8),
            Expanded(child: _buildQuickActionButton('Dividends', Icons.monetization_on_outlined, WoColors.indigo, () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const DividendTrackerScreen()));
            })),
          ],
        ),
      ).animate().fadeIn(delay: 150.ms),
    );
  }

  Widget _buildQuickActionButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.07)],
          ),
          borderRadius: BorderRadius.circular(WoRadius.control),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(label, style: GoogleFonts.inter(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildPortfolioSummary() {
    final gainPercent = (_totalValue - _totalGain) > 0 ? (_totalGain / (_totalValue - _totalGain) * 100) : 0;
    final isPositive = _totalGain >= 0;
    final gainColor = isPositive ? WoColors.mint : WoColors.red;

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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('PORTFOLIO VALUE', style: WoText.label()),
                    const SizedBox(height: 6),
                    Text(_formatCurrency(_totalValue), style: WoText.display()),
                  ],
                ),
                WoChip(
                  '${gainPercent.abs().toStringAsFixed(1)}%',
                  color: gainColor,
                  icon: isPositive ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(height: 1, color: WoColors.border),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total Gain/Loss', style: WoText.caption(color: WoColors.textLo)),
                      Text('${isPositive ? "+" : ""}${_formatCurrency(_totalGain)}', style: WoText.num(color: gainColor, size: 16)),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Holdings', style: WoText.caption(color: WoColors.textLo)),
                      Text('${_stocks.length + _mutualFunds.length + _fixedDeposits.length + _retirement.length}', style: WoText.num(size: 16)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _buildAllocationChart() {
    final stocksValue = _stocksBase;
    final mfValue = _mfBase;
    final fdValue = _fdBase;
    final retirementValue = _retirementBase;

    if (_totalValue == 0) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final sections = <PieChartSectionData>[];
    if (stocksValue > 0) sections.add(PieChartSectionData(value: stocksValue, color: WoColors.mint, title: '${(stocksValue / _totalValue * 100).toStringAsFixed(0)}%', radius: 25, titleStyle: GoogleFonts.poppins(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)));
    if (mfValue > 0) sections.add(PieChartSectionData(value: mfValue, color: WoColors.blue, title: '${(mfValue / _totalValue * 100).toStringAsFixed(0)}%', radius: 25, titleStyle: GoogleFonts.poppins(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)));
    if (fdValue > 0) sections.add(PieChartSectionData(value: fdValue, color: WoColors.orange, title: '${(fdValue / _totalValue * 100).toStringAsFixed(0)}%', radius: 25, titleStyle: GoogleFonts.poppins(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)));
    if (retirementValue > 0) sections.add(PieChartSectionData(value: retirementValue, color: WoColors.indigo, title: '${(retirementValue / _totalValue * 100).toStringAsFixed(0)}%', radius: 25, titleStyle: GoogleFonts.poppins(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)));

    if (sections.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(16),
        decoration: woCard(),
        child: Row(
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: PieChart(PieChartData(sections: sections, centerSpaceRadius: 20, sectionsSpace: 2)),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (stocksValue > 0) _buildLegendItem('Stocks', stocksValue, WoColors.mint),
                  if (mfValue > 0) _buildLegendItem('Mutual Funds', mfValue, WoColors.blue),
                  if (fdValue > 0) _buildLegendItem('Fixed Deposits', fdValue, WoColors.orange),
                  if (retirementValue > 0) _buildLegendItem('Retirement', retirementValue, WoColors.indigo),
                ],
              ),
            ),
          ],
        ),
      ).animate().fadeIn(delay: 100.ms),
    );
  }

  Widget _buildLegendItem(String label, double value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: WoText.caption())),
          Text(_formatCompact(value), style: WoText.num(size: 11.5)),
        ],
      ),
    );
  }

  Widget _buildInvestmentList(List<Asset> investments, String type) {
    if (investments.isEmpty) {
      return WoEmptyState(
        icon: _getTypeIcon(type),
        title: 'No ${_getTypeName(type)} yet',
        hint: 'Tap + to add',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 100),
      itemCount: investments.length,
      itemBuilder: (context, index) => _buildInvestmentCard(investments[index]).animate(delay: (index * 60).ms).fadeIn().slideX(begin: 0.03),
    );
  }

  Widget _buildInvestmentCard(Asset investment) {
    final gain = investment.currentValue - investment.purchaseValue;
    final gainPercent = investment.purchaseValue > 0 ? (gain / investment.purchaseValue * 100) : 0;
    final isPositive = gain >= 0;
    final gainColor = isPositive ? WoColors.mint : WoColors.red;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 18),
      child: Row(
        children: [
          WoIconBubble(_getTypeIcon(investment.type), color: _getTypeColor(investment.type), size: 46),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(investment.name, style: WoText.subtitle(), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(investment.geography, style: WoText.caption(color: WoColors.textLo)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(CurrencyUtils.format(investment.currentValue, investment.currencyCode), style: WoText.num()),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(isPositive ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down, color: gainColor, size: 11),
                  Text('${gainPercent.abs().toStringAsFixed(1)}%', style: WoText.caption(color: gainColor)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAddInvestmentSheet() {
    final nameController = TextEditingController();
    final purchaseController = TextEditingController();
    final currentController = TextEditingController();
    final quantityController = TextEditingController(text: '1');
    String type = 'stocks';
    String currency = 'INR';
    String geography = 'India';

    final types = [
      {'value': 'stocks', 'label': 'Stocks', 'icon': CupertinoIcons.graph_square},
      {'value': 'mutual_funds', 'label': 'Mutual Fund', 'icon': CupertinoIcons.chart_pie},
      {'value': 'fixed_deposit', 'label': 'Fixed Deposit', 'icon': CupertinoIcons.lock_shield},
      {'value': 'ppf', 'label': 'PPF', 'icon': CupertinoIcons.shield},
      {'value': 'nps', 'label': 'NPS', 'icon': CupertinoIcons.person_2},
      {'value': 'gold', 'label': 'Gold', 'icon': CupertinoIcons.circle_fill},
      {'value': 'crypto', 'label': 'Crypto', 'icon': CupertinoIcons.bitcoin_circle},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          height: MediaQuery.of(context).size.height * 0.85,
          decoration: BoxDecoration(color: WoColors.surface, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
          child: Column(
            children: [
              const SizedBox(height: 8),
              const WoSheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Text('Add Investment', style: WoText.title()),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('INVESTMENT TYPE', style: WoText.label()),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: types.map((t) => ChoiceChip(
                          label: Text(t['label'] as String),
                          selected: type == t['value'],
                          onSelected: (sel) => setSheetState(() => type = t['value'] as String),
                          selectedColor: WoColors.gold,
                          labelStyle: GoogleFonts.poppins(color: type == t['value'] ? Colors.black : WoColors.textMid, fontSize: 12),
                          backgroundColor: WoColors.inputFill,
                          side: BorderSide(color: WoColors.border),
                        )).toList(),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: nameController,
                        style: WoText.bodyHi(),
                        decoration: woInput(
                          type == 'stocks' ? 'Stock Name / Symbol' : type == 'mutual_funds' ? 'Fund Name' : 'Investment Name',
                          hint: type == 'stocks' ? 'e.g., RELIANCE, TCS' : type == 'mutual_funds' ? 'e.g., HDFC Equity Fund' : 'Enter name',
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              decoration: woWell(),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: geography,
                                  dropdownColor: WoColors.surface,
                                  items: ['India', 'UAE', 'USA', 'UK'].map((g) => DropdownMenuItem(value: g, child: Text(g, style: WoText.bodyHi()))).toList(),
                                  onChanged: (val) {
                                    setSheetState(() {
                                      geography = val!;
                                      currency = val == 'India' ? 'INR' : val == 'UAE' ? 'AED' : val == 'USA' ? 'USD' : 'GBP';
                                    });
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              decoration: woWell(),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: currency,
                                  dropdownColor: WoColors.surface,
                                  items: ['INR', 'AED', 'USD', 'GBP', 'EUR'].map((c) => DropdownMenuItem(value: c, child: Text(c, style: WoText.bodyHi()))).toList(),
                                  onChanged: (val) => setSheetState(() => currency = val!),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (type == 'stocks') ...[
                        const SizedBox(height: 16),
                        TextField(
                          controller: quantityController,
                          keyboardType: TextInputType.number,
                          style: WoText.bodyHi(),
                          decoration: woInput('Quantity'),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        controller: purchaseController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: WoText.bodyHi(),
                        decoration: woInput(type == 'stocks' ? 'Buy Price (per share)' : 'Invested Amount').copyWith(
                          prefixText: '$currency ',
                          prefixStyle: WoText.body(color: WoColors.textLo),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: currentController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: WoText.bodyHi(),
                        decoration: woInput(type == 'stocks' ? 'Current Price (per share)' : 'Current Value').copyWith(
                          prefixText: '$currency ',
                          prefixStyle: WoText.body(color: WoColors.textLo),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (nameController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Please enter investment name')));
                        return;
                      }

                      final qty = int.tryParse(quantityController.text) ?? 1;
                      var purchase = double.tryParse(purchaseController.text) ?? 0;
                      var current = double.tryParse(currentController.text) ?? purchase;

                      if (type == 'stocks') {
                        purchase = purchase * qty;
                        current = current * qty;
                      }

                      final asset = AssetsCompanion(
                        id: Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        name: Value(nameController.text),
                        type: Value(type),
                        currencyCode: Value(currency),
                        purchaseValue: Value(purchase),
                        currentValue: Value(current),
                        geography: Value(geography),
                        isLiquid: Value(type == 'stocks' || type == 'mutual_funds'),
                        purchaseDate: Value(DateTime.now()),
                      );

                      await _repo!.insertAsset(asset);
                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: const Text('Add Investment'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getTypeIcon(String type) {
    switch (type) {
      case 'stocks': return CupertinoIcons.graph_square;
      case 'mutual_funds': return CupertinoIcons.chart_pie;
      case 'fixed_deposit': return CupertinoIcons.lock_shield;
      case 'ppf': case 'nps': case 'epf': return CupertinoIcons.shield;
      case 'gold': return CupertinoIcons.circle_fill;
      case 'crypto': return CupertinoIcons.bitcoin_circle;
      default: return CupertinoIcons.money_dollar_circle;
    }
  }

  Color _getTypeColor(String type) {
    switch (type) {
      case 'stocks': return WoColors.mint;
      case 'mutual_funds': return WoColors.blue;
      case 'fixed_deposit': return WoColors.orange;
      case 'ppf': case 'nps': case 'epf': return WoColors.indigo;
      case 'gold': return WoColors.gold;
      case 'crypto': return WoColors.teal;
      default: return WoColors.textMid;
    }
  }

  String _getTypeName(String type) {
    switch (type) {
      case 'stocks': return 'stocks';
      case 'mutual_funds': return 'mutual funds';
      case 'fixed_deposit': return 'fixed deposits';
      case 'ppf': return 'retirement accounts';
      default: return 'investments';
    }
  }

  String _formatCurrency(double amount) => CurrencyUtils.format(amount, _base);
  String _formatCompact(double amount) => CurrencyUtils.formatCompact(amount, _base);
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  _SliverTabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(color: WoColors.bg, child: tabBar);
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) => false;
}
