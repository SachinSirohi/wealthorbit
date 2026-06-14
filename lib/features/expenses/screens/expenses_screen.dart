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
import '../../../data/services/secure_vault.dart';

class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  String _base = 'AED';
  AppRepository? _repo;
  List<Budget> _budgets = [];
  List<Category> _categories = [];
  List<Account> _accounts = [];
  Map<String, double> _categorySpending = {};
  List<Map<String, dynamic>> _budgetAlerts = [];
  bool _isLoading = true;
  double _totalBudget = 0;
  double _totalSpent = 0;
  DateTime _selectedMonth = DateTime.now();

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
      final budgets = await _repo!.getAllBudgets();
      if (!mounted) return;

      final categories = await _repo!.getAllCategories();
      if (!mounted) return;

      final accounts = await _repo!.getAllAccounts();
      if (!mounted) return;

      // Calculate spending per category for selected month
      final startOfMonth = DateTime(_selectedMonth.year, _selectedMonth.month, 1);
      final endOfMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1, 0, 23, 59, 59);
      final expensesByCategory = await _repo!.getExpensesByCategory(startOfMonth, endOfMonth);
      if (!mounted) return;

      final totalBudget = budgets.fold(0.0, (sum, b) => sum + b.limitAmount);
      final totalSpent = expensesByCategory.values.fold(0.0, (sum, v) => sum + v);

      // Check budget thresholds
      final alerts = await _repo!.checkBudgetThresholds();
      if (!mounted) return;

      setState(() {
        _budgets = budgets;
        _categories = categories;
        _accounts = accounts;
        _categorySpending = expensesByCategory;
        _totalBudget = totalBudget;
        _totalSpent = totalSpent;
        _budgetAlerts = alerts;
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
          _buildMonthSelector(),
          _buildBudgetAlerts(),
          _buildOverviewCard(),
          _buildSpendingChart(),
          if (_isLoading)
            SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: WoColors.gold)),
            )
          else if (_budgets.isEmpty)
            _buildEmptyState()
          else
            _buildBudgetList(),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
             FloatingActionButton.extended(
              heroTag: 'add_expense',
              onPressed: () => _showAddTransactionSheet(), // We need to expose this method or duplicate logic
              backgroundColor: WoColors.red,
              icon: const Icon(CupertinoIcons.minus_circle, color: Colors.white),
              label: Text('Add Expense', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 12),
            FloatingActionButton.extended(
              heroTag: 'set_budget',
              onPressed: () => _showAddBudgetSheet(),
              backgroundColor: WoColors.gold,
              icon: const Icon(CupertinoIcons.slider_horizontal_3, color: Colors.black),
              label: Text('Set Budget', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ).animate().scale(delay: 300.ms),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 60,
      floating: true,
      pinned: true,
      backgroundColor: WoColors.bg,
      title: Text('Budget & Expenses', style: WoText.display()),
    );
  }

  Widget _buildBudgetAlerts() {
    if (_budgetAlerts.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    // Filter to only show critical alerts (>90% or exceeded)
    final criticalAlerts = _budgetAlerts.where((a) => (a['percentUsed'] as double) >= 90).toList();
    if (criticalAlerts.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [WoColors.red.withValues(alpha: 0.16), WoColors.orange.withValues(alpha: 0.08)],
          ),
          borderRadius: BorderRadius.circular(WoRadius.card),
          border: Border.all(color: WoColors.red.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(CupertinoIcons.exclamationmark_triangle_fill, color: WoColors.red, size: 20),
                const SizedBox(width: 8),
                Text('Budget Alerts', style: WoText.subtitle()),
                const Spacer(),
                Text('${criticalAlerts.length} alert${criticalAlerts.length > 1 ? 's' : ''}', style: WoText.caption()),
              ],
            ),
            const SizedBox(height: 12),
            ...criticalAlerts.take(3).map((alert) {
              final categoryName = alert['categoryName'] as String;
              final percentUsed = alert['percentUsed'] as double;
              final isExceeded = percentUsed >= 100;

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: isExceeded ? WoColors.red : WoColors.orange,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(categoryName, style: WoText.body())),
                    WoChip(
                      isExceeded ? 'EXCEEDED' : '${percentUsed.toInt()}% used',
                      color: isExceeded ? WoColors.red : WoColors.orange,
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ).animate().fadeIn().shake(hz: 2, duration: 500.ms),
    );
  }

  Widget _buildMonthSelector() {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        height: 50,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(CupertinoIcons.chevron_left, color: WoColors.textMid),
              onPressed: () {
                setState(() => _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1));
                _loadData();
              },
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: woWell(),
              child: Text(DateFormat('MMMM yyyy').format(_selectedMonth), style: WoText.subtitle()),
            ),
            IconButton(
              icon: Icon(CupertinoIcons.chevron_right, color: WoColors.textMid),
              onPressed: _selectedMonth.month == DateTime.now().month && _selectedMonth.year == DateTime.now().year
                  ? null
                  : () {
                      setState(() => _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1));
                      _loadData();
                    },
            ),
          ],
        ),
      ).animate().fadeIn(),
    );
  }

  Widget _buildOverviewCard() {
    final remaining = _totalBudget - _totalSpent;
    final progress = _totalBudget > 0 ? (_totalSpent / _totalBudget).clamp(0.0, 1.5) : 0.0;
    final isOverBudget = _totalSpent > _totalBudget;

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(24),
        decoration: woCard(tint: isOverBudget ? WoColors.red : WoColors.indigo),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TOTAL BUDGET', style: WoText.label()),
                    const SizedBox(height: 6),
                    Text(_formatCurrency(_totalBudget), style: WoText.display()),
                  ],
                ),
                WoChip(
                  '${(progress * 100).toStringAsFixed(0)}% used',
                  color: isOverBudget ? WoColors.red : WoColors.indigo,
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                backgroundColor: WoColors.inputFill,
                valueColor: AlwaysStoppedAnimation(isOverBudget ? WoColors.red : WoColors.gold),
                minHeight: 10,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Spent', style: WoText.caption()),
                      Text(_formatCurrency(_totalSpent), style: WoText.num(size: 16)),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isOverBudget ? 'Over budget' : 'Remaining', style: WoText.caption()),
                      Text(_formatCurrency(remaining.abs()),
                          style: WoText.num(color: isOverBudget ? WoColors.red : WoColors.mint, size: 16)),
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

  Widget _buildSpendingChart() {
    if (_categorySpending.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final sortedEntries = _categorySpending.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topCategories = sortedEntries.take(5).toList();

    final colors = [
      WoColors.red,
      WoColors.orange,
      WoColors.gold,
      WoColors.mint,
      WoColors.blue,
    ];

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(18),
        decoration: woCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const WoSectionHeader('Top Spending Categories', padding: EdgeInsets.only(bottom: 12)),
            ...topCategories.asMap().entries.map((entry) {
              final categoryName = entry.value.key;
              final spent = entry.value.value;
              final maxSpent = topCategories.first.value;
              final progress = maxSpent > 0 ? (spent / maxSpent) : 0.0;

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[entry.key % colors.length], borderRadius: BorderRadius.circular(2))),
                            const SizedBox(width: 8),
                            Text(categoryName, style: WoText.bodyHi()),
                          ],
                        ),
                        Text(_formatCurrency(spent), style: WoText.num(color: WoColors.textMid, size: 12.5)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
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
      ).animate().fadeIn(delay: 100.ms),
    );
  }

  Widget _buildEmptyState() {
    return SliverFillRemaining(
      child: WoEmptyState(
        icon: CupertinoIcons.chart_bar_alt_fill,
        title: 'No budgets set',
        hint: 'Set budgets to track your spending',
        ctaLabel: 'Set Budget',
        onCta: _showAddBudgetSheet,
      ).animate().fadeIn(),
    );
  }

  Widget _buildBudgetList() {
    // Group budgets by budgetType (needs, wants, future)
    final categoryMap = {for (var c in _categories) c.id: c};

    final needsBudgets = _budgets.where((b) {
      final cat = categoryMap[b.categoryId];
      return cat?.budgetType == 'needs';
    }).toList();

    final wantsBudgets = _budgets.where((b) {
      final cat = categoryMap[b.categoryId];
      return cat?.budgetType == 'wants';
    }).toList();

    final futureBudgets = _budgets.where((b) {
      final cat = categoryMap[b.categoryId];
      return cat?.budgetType == 'future';
    }).toList();

    return SliverPadding(
      padding: const EdgeInsets.only(top: 16, bottom: 100),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          if (needsBudgets.isNotEmpty) _buildBudgetGroup('Needs (50%)', needsBudgets, WoColors.mint),
          if (wantsBudgets.isNotEmpty) _buildBudgetGroup('Wants (30%)', wantsBudgets, WoColors.blue),
          if (futureBudgets.isNotEmpty) _buildBudgetGroup('Future/Savings (20%)', futureBudgets, WoColors.gold),
        ]),
      ),
    );
  }

  Widget _buildBudgetGroup(String title, List<Budget> budgets, Color color) {
    final categoryMap = {for (var c in _categories) c.id: c};

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: woCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(width: 4, height: 20, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 10),
                Text(title, style: WoText.subtitle()),
              ],
            ),
          ),
          ...budgets.map((budget) {
            final category = categoryMap[budget.categoryId];
            final categoryName = category?.name ?? 'Unknown';
            final spent = _categorySpending[categoryName] ?? 0;
            final progress = budget.limitAmount > 0 ? (spent / budget.limitAmount) : 0.0;
            final isOverBudget = spent > budget.limitAmount;

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: WoColors.border, width: 1)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: Text(categoryName, style: WoText.bodyHi())),
                      Text('${_formatCurrency(spent)} / ${_formatCurrency(budget.limitAmount)}',
                          style: WoText.num(color: isOverBudget ? WoColors.red : WoColors.textMid, size: 12.5)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      backgroundColor: WoColors.inputFill,
                      valueColor: AlwaysStoppedAnimation(isOverBudget ? WoColors.red : color),
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    ).animate().fadeIn().slideX(begin: 0.03);
  }

  void _showAddBudgetSheet() {
    String? selectedCategoryId;
    final amountController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          height: MediaQuery.of(context).size.height * 0.65,
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
                child: Text('Set Budget', style: WoText.title()),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const WoSectionHeader('Select Category', padding: EdgeInsets.only(bottom: 8)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: woWell(),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: selectedCategoryId,
                            hint: Text('Choose a category', style: WoText.body(color: WoColors.textLo)),
                            dropdownColor: WoColors.surface,
                            isExpanded: true,
                            items: _categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name, style: WoText.bodyHi()))).toList(),
                            onChanged: (val) => setSheetState(() => selectedCategoryId = val),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: WoText.bodyHi(),
                        decoration: woInput('Budget Amount').copyWith(
                          prefixText: 'AED ',
                          prefixStyle: GoogleFonts.inter(color: WoColors.textMid, fontSize: 13),
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
                      if (selectedCategoryId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a category')));
                        return;
                      }

                      final amount = double.tryParse(amountController.text) ?? 0;
                      if (amount <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid amount')));
                        return;
                      }

                      final budget = BudgetsCompanion(
                        id: Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        categoryId: Value(selectedCategoryId!),
                        limitAmount: Value(amount),
                        year: Value(_selectedMonth.year),
                        month: Value(_selectedMonth.month),
                      );

                      await _repo!.insertBudget(budget);
                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: const Text('Set Budget'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddTransactionSheet() {
    _showTransactionSheet(null);
  }

  void _showTransactionSheet(Transaction? existing) {
    final isEditing = existing != null;
    final descController = TextEditingController(text: existing?.description ?? '');
    final amountController = TextEditingController(text: existing?.amountSource.toString() ?? '');
    String type = existing?.type ?? 'expense';
    String? selectedCategoryId = existing?.categoryId;
    String? selectedAccountId = existing?.accountId;
    DateTime selectedDate = existing?.transactionDate ?? DateTime.now();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
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
                    Text(isEditing ? 'Edit Transaction' : 'Add Transaction', style: WoText.title()),
                  ],
                ),
              ),
              // Type Toggle
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setSheetState(() => type = 'expense'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: type == 'expense' ? WoColors.red : WoColors.inputFill,
                            borderRadius: BorderRadius.circular(WoRadius.control),
                            border: Border.all(color: type == 'expense' ? WoColors.red : WoColors.border),
                          ),
                          child: Center(
                            child: Text('Expense',
                                style: GoogleFonts.poppins(
                                    color: type == 'expense' ? Colors.white : WoColors.textMid,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setSheetState(() => type = 'income'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: type == 'income' ? WoColors.mint : WoColors.inputFill,
                            borderRadius: BorderRadius.circular(WoRadius.control),
                            border: Border.all(color: type == 'income' ? WoColors.mint : WoColors.border),
                          ),
                          child: Center(
                            child: Text('Income',
                                style: GoogleFonts.poppins(
                                    color: type == 'income' ? Colors.black : WoColors.textMid,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Amount
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: GoogleFonts.poppins(color: WoColors.textHi, fontSize: 32, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: '0.00',
                    hintStyle: GoogleFonts.poppins(color: WoColors.textLo, fontSize: 32),
                    border: InputBorder.none,
                    prefixText: 'AED ',
                    prefixStyle: GoogleFonts.poppins(color: WoColors.textMid, fontSize: 20),
                  ),
                ),
              ),
              Divider(color: WoColors.borderHi),
              // Description
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: descController,
                  style: WoText.bodyHi(),
                  decoration: woInput('Description'),
                ),
              ),
              const SizedBox(height: 16),
              // Category Dropdown
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: woWell(),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selectedCategoryId,
                      hint: Text('Select Category', style: WoText.body(color: WoColors.textLo)),
                      dropdownColor: WoColors.surface,
                      isExpanded: true,
                      items: _categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name, style: WoText.bodyHi()))).toList(),
                      onChanged: (val) => setSheetState(() => selectedCategoryId = val),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Account Dropdown
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: woWell(),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selectedAccountId,
                      hint: Text('Select Account', style: WoText.body(color: WoColors.textLo)),
                      dropdownColor: WoColors.surface,
                      isExpanded: true,
                      items: _accounts.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name, style: WoText.bodyHi()))).toList(),
                      onChanged: (val) => setSheetState(() => selectedAccountId = val),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Date Picker
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GestureDetector(
                  onTap: () async {
                    final date = await showDatePicker(context: context, initialDate: selectedDate, firstDate: DateTime(2020), lastDate: DateTime.now());
                    if (date != null) setSheetState(() => selectedDate = date);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: woWell(),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.calendar, color: WoColors.textMid),
                        const SizedBox(width: 12),
                        Text(DateFormat('MMM dd, yyyy').format(selectedDate), style: WoText.bodyHi()),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // Save Button
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final amount = double.tryParse(amountController.text) ?? 0;
                      if (amount <= 0 || descController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
                        return;
                      }

                      if (selectedAccountId == null && _accounts.isNotEmpty) {
                        selectedAccountId = _accounts.first.id;
                      }

                      final transaction = TransactionsCompanion(
                        id: isEditing ? Value(existing.id) : Value(DateTime.now().millisecondsSinceEpoch.toString()),
                        description: Value(descController.text),
                        amountSource: Value(amount),
                        amountBase: Value(amount),
                        currencyCode: const Value('AED'),
                        type: Value(type),
                        categoryId: Value(selectedCategoryId),
                        accountId: Value(selectedAccountId ?? _accounts.firstOrNull?.id ?? 'default'),
                        transactionDate: Value(selectedDate),
                      );

                      if (isEditing) {
                        await _repo!.updateTransaction(existing.id, transaction);
                      } else {
                        await _repo!.insertTransaction(transaction);
                      }

                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: Text(isEditing ? 'Update' : 'Add Transaction'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCurrency(double amount) => CurrencyUtils.format(amount, _base);
}
