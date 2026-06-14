import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drift/drift.dart' show Value;
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../widgets/deal_analyzer_sheet.dart';
import '../widgets/exit_strategy_sheet.dart';

class RealEstateScreen extends StatefulWidget {
  const RealEstateScreen({super.key});

  @override
  State<RealEstateScreen> createState() => _RealEstateScreenState();
}

class _RealEstateScreenState extends State<RealEstateScreen> {
  AppRepository? _repo;
  List<Asset> _properties = [];
  bool _isLoading = true;
  double _totalValue = 0;
  double _totalRentalIncome = 0;
  Map<String, double> _propertyRentalIncome = {};
  Map<String, double> _propertyExpenses = {};

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    try {
      _repo = await AppRepository.getInstance();
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
      final properties = allAssets.where((a) => a.type == 'real_estate').toList();
      // Portfolio value is an aggregate → convert each property into the base
      // currency (properties may be held in INR/AED/etc.).
      double total = 0;
      for (final p in properties) {
        total += await _repo!.toBase(p.currentValue, p.currencyCode);
      }

      final now = DateTime.now();
      final transactions = await _repo!.getTransactionsByDateRange(
        DateTime(now.year, now.month - 12, 1), now);
      if (!mounted) return;

      // Rental income is sourced from the RentalIncome table (source of truth),
      // not free-text transaction descriptions. Entries may be in any currency
      // → convert each to the base currency.
      final propertyRentalIncomeMap = <String, double>{}; // trailing-12-mo, base
      final propertyExpensesMap = <String, double>{};
      double monthlyRental = 0; // most-recent month's rent across all properties
      final cutoff = DateTime(now.year - 1, now.month);

      for (final property in properties) {
        final entries = await _repo!.getRentalIncome(property.id);
        double annual = 0;
        int latestKey = -1;
        double latestRent = 0;
        for (final e in entries) {
          final base = await _repo!.toBase(e.amount, e.currencyCode);
          if (!DateTime(e.year, e.month).isBefore(cutoff)) annual += base;
          final key = e.year * 12 + e.month;
          if (key > latestKey) {
            latestKey = key;
            latestRent = base;
          } else if (key == latestKey) {
            latestRent += base;
          }
        }
        monthlyRental += latestRent;
        propertyRentalIncomeMap[property.id] = annual;

        // Property-specific expenses still come from tagged transactions.
        final propertyTransactions = transactions.where((t) => t.description.contains(property.name));
        final expenses = propertyTransactions.where((t) => t.type == 'expense').fold(0.0, (sum, t) => sum + t.amountBase);
        propertyExpensesMap[property.id] = expenses;
      }
      final rentalIncome = monthlyRental;

      if (!mounted) return;
      setState(() {
        _properties = properties;
        _totalValue = total;
        _totalRentalIncome = rentalIncome;
        _propertyRentalIncome = propertyRentalIncomeMap;
        _propertyExpenses = propertyExpensesMap;
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
          _buildPortfolioSummary(),
          _buildMetricsRow(),
          if (_isLoading)
            SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: WoColors.gold)),
            )
          else if (_properties.isEmpty)
            _buildEmptyState()
          else
            _buildPropertyList(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddPropertySheet(),
        backgroundColor: WoColors.gold,
        icon: const Icon(CupertinoIcons.add, color: Colors.black),
        label: Text('Add Property', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
      ).animate().scale(delay: 300.ms),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 100,
      floating: true,
      pinned: true,
      backgroundColor: WoColors.bg,
      flexibleSpace: FlexibleSpaceBar(
        title: Text('Real Estate', style: WoText.display()),
        titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
      ),
    );
  }

  Widget _buildPortfolioSummary() {
    final avgROI = _totalValue > 0 && _totalRentalIncome > 0
        ? (_totalRentalIncome * 12 / _totalValue * 100)
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
                    Text('PORTFOLIO VALUE', style: WoText.label()),
                    const SizedBox(height: 6),
                    Text(
                      _formatCurrency(_totalValue),
                      style: WoText.display(),
                    ),
                  ],
                ),
                WoChip('${_properties.length} Properties', color: WoColors.gold, icon: CupertinoIcons.house_fill),
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
                      Text('Monthly Rental', style: WoText.caption()),
                      Text(_formatCurrency(_totalRentalIncome), style: WoText.num(size: 16)),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Gross Yield', style: WoText.caption()),
                      Text('${avgROI.toStringAsFixed(1)}%', style: WoText.num(color: WoColors.mint, size: 16)),
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

  Widget _buildMetricsRow() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Expanded(child: _buildMetricCard('UAE Properties', _properties.where((p) => p.geography == 'UAE').length.toString(), CupertinoIcons.building_2_fill, WoColors.gold)),
            const SizedBox(width: 12),
            Expanded(child: _buildMetricCard('India Properties', _properties.where((p) => p.geography == 'India').length.toString(), CupertinoIcons.house_fill, WoColors.indigo)),
          ],
        ),
      ).animate().fadeIn(delay: 100.ms),
    );
  }

  Widget _buildMetricCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: woCard(radius: 16),
      child: Row(
        children: [
          WoIconBubble(icon, color: color, size: 40),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: WoText.num(size: 20)),
              Text(title, style: WoText.caption()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return SliverFillRemaining(
      child: const WoEmptyState(
        icon: CupertinoIcons.house,
        title: 'No properties yet',
        hint: 'Add your real estate investments',
      ).animate().fadeIn(),
    );
  }

  Widget _buildPropertyList() {
    return SliverPadding(
      padding: const EdgeInsets.only(top: 16, bottom: 100),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildPropertyCard(_properties[index]).animate(delay: (index * 80).ms).fadeIn().slideX(begin: 0.05),
          childCount: _properties.length,
        ),
      ),
    );
  }

  Widget _buildPropertyCard(Asset property) {
    final gain = property.currentValue - property.purchaseValue;
    final gainPercent = property.purchaseValue > 0 ? (gain / property.purchaseValue * 100) : 0;
    final isPositive = gain >= 0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: woCard(),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: WoIconBubble(CupertinoIcons.house_fill, color: WoColors.blue, size: 56),
            title: Text(property.name, style: WoText.subtitle()),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(CupertinoIcons.location_solid, size: 12, color: WoColors.textLo),
                    const SizedBox(width: 4),
                    Text(property.geography, style: WoText.caption()),
                  ],
                ),
              ],
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(CurrencyUtils.format(property.currentValue, property.currencyCode), style: WoText.num()),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(isPositive ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down, color: isPositive ? WoColors.mint : WoColors.red, size: 12),
                    Text('${gainPercent.abs().toStringAsFixed(1)}%', style: WoText.num(color: isPositive ? WoColors.mint : WoColors.red, size: 12)),
                  ],
                ),
              ],
            ),
            onTap: () => _showPropertyDetail(property),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: WoColors.inputFill,
              borderRadius: BorderRadius.only(bottomLeft: Radius.circular(WoRadius.card), bottomRight: Radius.circular(WoRadius.card)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildPropertyStat('Purchase', CurrencyUtils.formatCompact(property.purchaseValue, property.currencyCode)),
                _buildPropertyStat('Current', CurrencyUtils.formatCompact(property.currentValue, property.currencyCode)),
                _buildPropertyStat('Gain', '${isPositive ? "+" : ""}${CurrencyUtils.formatCompact(gain, property.currencyCode)}'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPropertyStat(String label, String value) {
    return Column(
      children: [
        Text(value, style: WoText.num(size: 14)),
        Text(label, style: WoText.caption(color: WoColors.textLo)),
      ],
    );
  }

  void _showPropertyDetail(Asset property) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: BoxDecoration(
          color: WoColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
        ),
        child: Column(
          children: [
            const Padding(padding: EdgeInsets.only(top: 8), child: WoSheetHandle()),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(property.name, style: WoText.display()),
                  IconButton(icon: Icon(CupertinoIcons.xmark, color: WoColors.textMid), onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDetailSection('Property Details', [
                      _buildDetailRow('Location', property.geography),
                      _buildDetailRow('Type', 'Residential'),
                      _buildDetailRow('Currency', property.currencyCode),
                      _buildDetailRow('Liquid', property.isLiquid ? 'Yes' : 'No'),
                    ]),
                    const SizedBox(height: 20),
                    _buildDetailSection('Valuation', [
                      _buildDetailRow('Purchase Price', CurrencyUtils.format(property.purchaseValue, property.currencyCode)),
                      _buildDetailRow('Current Value', CurrencyUtils.format(property.currentValue, property.currencyCode)),
                      _buildDetailRow('Unrealized Gain', CurrencyUtils.format(property.currentValue - property.purchaseValue, property.currencyCode)),
                      _buildDetailRow('ROI', '${((property.currentValue - property.purchaseValue) / property.purchaseValue * 100).toStringAsFixed(1)}%'),
                    ]),
                    const SizedBox(height: 20),
                    Builder(builder: (context) {
                      final annualRent = _propertyRentalIncome[property.id] ?? 0;
                      final annualExpenses = _propertyExpenses[property.id] ?? 0;
                      final noi = annualRent - annualExpenses;
                      final capRate = property.purchaseValue > 0 ? (noi / property.purchaseValue * 100) : 0.0;
                      final grossYield = property.currentValue > 0 ? (annualRent / property.currentValue * 100) : 0.0;

                      return _buildDetailSection('P&L Summary', [
                        _buildDetailRow('Annual Rental Income', _formatCurrency(annualRent)),
                        _buildDetailRow('Annual Expenses', _formatCurrency(annualExpenses)),
                        _buildDetailRow('Net Operating Income', _formatCurrency(noi)),
                        _buildDetailRow('Cap Rate', '${capRate.toStringAsFixed(1)}%'),
                        _buildDetailRow('Gross Yield', '${grossYield.toStringAsFixed(1)}%'),
                      ]);
                    }),
                    const SizedBox(height: 20),
                    // Analyze Deal Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showDealAnalyzer(property);
                        },
                        icon: const Icon(Icons.analytics_outlined, color: Colors.black),
                        label: const Text('Analyze Deal'),
                        style: WoButtons.primary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Exit Strategy Button
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showExitStrategySheet(property);
                        },
                        icon: Icon(CupertinoIcons.flag_fill, color: WoColors.red),
                        label: const Text('Exit Strategy & Alerts'),
                        style: WoButtons.ghost.copyWith(
                          foregroundColor: WidgetStatePropertyAll(WoColors.red),
                          side: WidgetStatePropertyAll(BorderSide(color: WoColors.red.withValues(alpha: 0.5))),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _showEditPropertySheet(property);
                      },
                      style: WoButtons.ghost,
                      child: const Text('Edit'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _showAddRentalIncomeSheet(property),
                      style: WoButtons.primary,
                      child: const Text('Add Income'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailSection(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: woWell(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: WoText.label()),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: WoText.body()),
          Text(value, style: WoText.num(size: 13)),
        ],
      ),
    );
  }

  void _showAddPropertySheet() => _showPropertySheet(null);
  void _showEditPropertySheet(Asset property) => _showPropertySheet(property);

  void _showPropertySheet(Asset? existing) {
    final isEditing = existing != null;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final purchaseController = TextEditingController(text: existing?.purchaseValue.toString() ?? '');
    final currentController = TextEditingController(text: existing?.currentValue.toString() ?? '');
    String geography = existing?.geography ?? 'UAE';
    String currency = existing?.currencyCode ?? 'AED';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          height: MediaQuery.of(context).size.height * 0.8,
          decoration: BoxDecoration(
            color: WoColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
          ),
          child: Column(
            children: [
              const Padding(padding: EdgeInsets.only(top: 8), child: WoSheetHandle()),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(isEditing ? 'Edit Property' : 'Add Property', style: WoText.display()),
                    if (isEditing)
                      IconButton(icon: Icon(CupertinoIcons.trash, color: WoColors.red), onPressed: () async {
                        await _repo!.deleteAsset(existing.id);
                        if (!context.mounted) return;
                        Navigator.pop(context);
                        _loadData();
                      }),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      TextField(
                        controller: nameController,
                        style: WoText.bodyHi(),
                        decoration: woInput('Property Name', hint: 'e.g., Marina Heights Apartment'),
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
                                  dropdownColor: WoColors.surfaceHi,
                                  items: ['UAE', 'India', 'UK', 'USA', 'Other'].map((g) => DropdownMenuItem(value: g, child: Text(g, style: WoText.bodyHi()))).toList(),
                                  onChanged: (val) => setSheetState(() => geography = val!),
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
                                  dropdownColor: WoColors.surfaceHi,
                                  items: ['AED', 'INR', 'USD', 'GBP', 'EUR'].map((c) => DropdownMenuItem(value: c, child: Text(c, style: WoText.bodyHi()))).toList(),
                                  onChanged: (val) => setSheetState(() => currency = val!),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: purchaseController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: WoText.bodyHi(),
                        decoration: woInput('Purchase Price').copyWith(
                          prefixText: '$currency ',
                          prefixStyle: WoText.body(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: currentController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: WoText.bodyHi(),
                        decoration: woInput('Current Market Value').copyWith(
                          prefixText: '$currency ',
                          prefixStyle: WoText.body(),
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
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Please enter property name')));
                        return;
                      }

                      final purchase = double.tryParse(purchaseController.text) ?? 0;
                      final current = double.tryParse(currentController.text) ?? purchase;

                      final asset = AssetsCompanion(
                        id: isEditing ? Value(existing.id) : Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        name: Value(nameController.text),
                        type: const Value('real_estate'),
                        currencyCode: Value(currency),
                        purchaseValue: Value(purchase),
                        currentValue: Value(current),
                        geography: Value(geography),
                        isLiquid: const Value(false),
                        purchaseDate: Value(DateTime.now()),
                      );

                      if (isEditing) {
                        await _repo!.updateAsset(existing.id, asset);
                      } else {
                        await _repo!.insertAsset(asset);
                      }

                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: Text(isEditing ? 'Update' : 'Add Property'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Aggregates (portfolio value, rental income) are in the base currency.
  String _formatCurrency(double amount) => NumberFormat.currency(symbol: 'AED ', decimalDigits: 0).format(amount);

  void _showDealAnalyzer(Asset property) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DealAnalyzerSheet(
        propertyName: property.name,
        purchasePrice: property.purchaseValue,
        currentValue: property.currentValue,
        currency: property.currencyCode,
        geography: property.geography,
      ),
    );
  }

  void _showExitStrategySheet(Asset property) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.5,
        builder: (context, scrollController) => ExitStrategySheet(
          asset: property,
          scrollController: scrollController,
        ),
      ),
    );
  }

  void _showAddRentalIncomeSheet(Asset property) {
    final amountController = TextEditingController();
    final tenantController = TextEditingController();
    DateTime selectedMonth = DateTime.now();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          height: MediaQuery.of(context).size.height * 0.5,
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          decoration: BoxDecoration(
            color: WoColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const WoSheetHandle(),
                Text('Add Rental Income', style: WoText.display()),
                Text(property.name, style: WoText.body()),
                const SizedBox(height: 20),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  style: WoText.bodyHi(),
                  decoration: woInput('Amount (${property.currencyCode})'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tenantController,
                  style: WoText.bodyHi(),
                  decoration: woInput('Tenant Name (optional)'),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final amount = double.tryParse(amountController.text) ?? 0;
                      if (amount <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter valid amount')));
                        return;
                      }

                      await _repo!.insertRentalIncome(RentalIncomeCompanion(
                        id: Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        assetId: Value(property.id),
                        currencyCode: Value(property.currencyCode),
                        amount: Value(amount),
                        year: Value(selectedMonth.year),
                        month: Value(selectedMonth.month),
                        tenantName: Value(tenantController.text.isNotEmpty ? tenantController.text : null),
                      ));

                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: const Text('Save Income'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
