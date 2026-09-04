import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drift/drift.dart' show Value;
import 'package:intl/intl.dart';
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/services/secure_vault.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  String _base = 'AED';
  AppRepository? _repo;
  List<Transaction> _transactions = [];
  List<Category> _categories = [];
  List<Account> _accounts = [];
  bool _isLoading = true;
  String _filterType = 'all';

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
      final transactions = await _repo!.getAllTransactions();
      if (!mounted) return;
      final categories = await _repo!.getAllCategories();
      if (!mounted) return;
      final accounts = await _repo!.getAllAccounts();
      if (!mounted) return;

      setState(() {
        _transactions = transactions;
        _categories = categories;
        _accounts = accounts;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<Transaction> get _filteredTransactions {
    if (_filterType == 'all') return _transactions;
    return _transactions.where((t) => t.type == _filterType).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(),
          _buildFilterChips(),
          _buildSummaryCard(),
          if (_isLoading)
            SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: WoColors.gold)),
            )
          else if (_filteredTransactions.isEmpty)
            _buildEmptyState()
          else
            _buildTransactionList(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddTransactionSheet(),
        backgroundColor: WoColors.gold,
        icon: const Icon(CupertinoIcons.add, color: Colors.black),
        label: Text('Add', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
      ).animate().scale(delay: 300.ms),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 80,
      floating: true,
      pinned: true,
      backgroundColor: WoColors.bg,
      title: Text('Transactions', style: WoText.display()),
    );
  }

  Widget _buildFilterChips() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            _buildChip('All', 'all'),
            const SizedBox(width: 8),
            _buildChip('Expenses', 'expense'),
            const SizedBox(width: 8),
            _buildChip('Income', 'income'),
            const SizedBox(width: 8),
            _buildChip('Transfers', 'transfer'),
          ],
        ),
      ),
    );
  }

  Widget _buildChip(String label, String type) {
    final isSelected = _filterType == type;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _filterType = type);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? WoColors.gold : WoColors.surface,
          borderRadius: BorderRadius.circular(WoRadius.chip),
          border: Border.all(color: isSelected ? WoColors.gold : WoColors.borderHi),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.black : WoColors.textMid,
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    double totalIncome = _transactions.where((t) => t.type == 'income').fold(0.0, (sum, t) => sum + t.amountBase);
    double totalExpense = _transactions.where((t) => t.type == 'expense').fold(0.0, (sum, t) => sum + t.amountBase);

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: woCard(),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: WoColors.mint, shape: BoxShape.circle)),
                      const SizedBox(width: 8),
                      Text('Income', style: WoText.caption()),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(_formatCurrency(totalIncome), style: WoText.num(color: WoColors.mint, size: 18)),
                ],
              ),
            ),
            Container(width: 1, height: 50, color: WoColors.borderHi),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: WoColors.red, shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text('Expenses', style: WoText.caption()),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(_formatCurrency(totalExpense), style: WoText.num(color: WoColors.red, size: 18)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _buildEmptyState() {
    return SliverFillRemaining(
      child: WoEmptyState(
        icon: CupertinoIcons.doc_text,
        title: 'No transactions yet',
        hint: 'Add your first transaction to get started',
        ctaLabel: 'Add Transaction',
        onCta: _showAddTransactionSheet,
      ).animate().fadeIn(),
    );
  }

  Widget _buildTransactionList() {
    // Group transactions by date
    final grouped = <String, List<Transaction>>{};
    for (var t in _filteredTransactions) {
      final dateKey = DateFormat('MMM dd, yyyy').format(t.transactionDate);
      grouped.putIfAbsent(dateKey, () => []).add(t);
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final dateKeys = grouped.keys.toList();
          final date = dateKeys[index];
          final transactions = grouped[date]!;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WoSectionHeader(date, padding: const EdgeInsets.fromLTRB(22, 14, 22, 8)),
              ...transactions.asMap().entries.map((entry) {
                return _buildTransactionTile(entry.value).animate(delay: (entry.key * 50).ms).fadeIn().slideX(begin: 0.05);
              }),
            ],
          );
        },
        childCount: grouped.keys.length,
      ),
    );
  }

  Widget _buildTransactionTile(Transaction transaction) {
    if (transaction.type == 'transfer') return _buildTransferTile(transaction);
    final category = _categories.firstWhere(
      (c) => c.id == transaction.categoryId,
      orElse: () => _defaultCategory(),
    );
    final isExpense = transaction.type == 'expense';
    final color = Color(category.colorValue);
    // A duplicate is a real statement line kept on file but left out of every
    // total — shown greyed so it can be spotted and put back if wrong.
    final isDuplicate = transaction.status == kDuplicateStatus;

    return Opacity(
      opacity: isDuplicate ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
        decoration: woCard(radius: 18),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: WoIconBubble(
            isDuplicate ? CupertinoIcons.doc_on_doc : _getCategoryIcon(category.icon),
            color: isDuplicate ? WoColors.textLo : color,
            size: 46,
          ),
          title: Text(transaction.description, style: WoText.subtitle(), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            isDuplicate ? 'Duplicate · not counted in totals' : category.name,
            style: WoText.caption(),
          ),
          trailing: Text(
            '${isExpense ? "-" : "+"}${CurrencyUtils.format(transaction.amountSource, transaction.currencyCode, decimals: 2)}',
            style: WoText.num(
              color: isDuplicate
                  ? WoColors.textLo
                  : (isExpense ? WoColors.expense : WoColors.income),
            ),
          ),
          onTap: () => isDuplicate
              ? _showDuplicateSheet(transaction)
              : _showEditTransactionSheet(transaction),
        ),
      ),
    );
  }

  Future<void> _showDuplicateSheet(Transaction t) async {
    final twin = t.linkedTransactionId != null
        ? await _repo!.getTransactionById(t.linkedTransactionId!)
        : null;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => WoSheet(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Duplicate spend', style: WoText.title()),
            const SizedBox(height: 8),
            Text(t.description, style: WoText.bodyHi()),
            const SizedBox(height: 6),
            Text(
              twin != null
                  ? 'Treated as the same purchase as "${twin.description}" on '
                      '${_accountName(twin.accountId)}, so it is left out of your totals.'
                  : 'Left out of your totals as a duplicate.',
              style: WoText.caption(),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: WoButtons.primary,
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final ok = await _repo!.restoreDuplicate(t.id);
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  messenger.showSnackBar(SnackBar(
                    content: Text(ok
                        ? 'Restored — counted in your totals again'
                        : 'Could not restore'),
                  ));
                  _loadData();
                },
                child: const Text('Not a duplicate — count it'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _accountName(String? id) =>
      _accounts.where((a) => a.id == id).firstOrNull?.name ?? 'Account';

  /// A transfer is money moving between two of the user's own accounts. It
  /// used to render as a green "+income" on the SOURCE account; now it reads
  /// as what it is, with both legs when the currencies differ.
  Widget _buildTransferTile(Transaction t) {
    final label = switch (t.txnClass) {
      'cc_payment' => 'Card payment',
      'investment' => 'Investment contribution',
      'debt' => 'Loan instalment',
      _ => 'Transfer',
    };
    final sent = CurrencyUtils.format(t.amountSource, t.currencyCode, decimals: 2);
    final received = (t.toAmount != null && t.toCurrency != null)
        ? CurrencyUtils.format(t.toAmount!, t.toCurrency!, decimals: 2)
        : null;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      decoration: woCard(radius: 18),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: WoIconBubble(CupertinoIcons.arrow_right_arrow_left, color: WoColors.indigo, size: 46),
        title: Text(t.description, style: WoText.subtitle(), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '$label · ${_accountName(t.accountId)} → ${_accountName(t.transferAccountId)}',
          style: WoText.caption(), maxLines: 1, overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(sent, style: WoText.num(color: WoColors.textHi)),
            if (received != null)
              Text('→ $received', style: WoText.caption(color: WoColors.textMid)),
          ],
        ),
        onTap: () => _showTransferSheet(t),
      ),
    );
  }

  Future<void> _showTransferSheet(Transaction t) async {
    final leg = t.linkedTransactionId != null
        ? await _repo!.getTransactionById(t.linkedTransactionId!)
        : null;
    final canUnmerge = leg != null && leg.status == kMergedStatus;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => WoSheet(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Transfer', style: WoText.title()),
            const SizedBox(height: 8),
            Text(t.description, style: WoText.bodyHi()),
            const SizedBox(height: 4),
            Text(
              '${_accountName(t.accountId)} → ${_accountName(t.transferAccountId)} · '
              '${DateFormat('MMM d, yyyy').format(t.transactionDate)}',
              style: WoText.caption(),
            ),
            if (canUnmerge) ...[
              const SizedBox(height: 14),
              Text(
                'Matched from two statement lines. Unmerging restores both as '
                'separate income and expense entries.',
                style: WoText.caption(color: WoColors.textMid),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                if (canUnmerge)
                  Expanded(
                    child: OutlinedButton(
                      style: WoButtons.ghost,
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final ok = await _repo!.unmergeTransferPair(t.id);
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        messenger.showSnackBar(SnackBar(
                          content: Text(ok ? 'Unmerged — both entries restored' : 'Could not unmerge'),
                        ));
                        _loadData();
                      },
                      child: const Text('Unmerge'),
                    ),
                  ),
                if (canUnmerge) const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: WoButtons.primary,
                    onPressed: () async {
                      await _repo!.deleteTransaction(t.id);
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      _loadData();
                    },
                    child: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Category _defaultCategory() {
    return Category(
      id: 'uncategorized',
      name: 'Uncategorized',
      budgetType: 'needs',
      icon: 'help_outline',
      colorValue: 0xFF666666,
      parentId: null,
    );
  }

  IconData _getCategoryIcon(String? iconName) {
    final icons = {
      'home': CupertinoIcons.home,
      'flash': CupertinoIcons.bolt,
      'cart': CupertinoIcons.cart,
      'car': CupertinoIcons.car,
      'heart': CupertinoIcons.heart,
      'briefcase': CupertinoIcons.briefcase,
      'gamecontroller': CupertinoIcons.gamecontroller,
      'airplane': CupertinoIcons.airplane,
      'bag': CupertinoIcons.bag,
      'arrow_2_circlepath': CupertinoIcons.arrow_2_circlepath,
      'chart_bar': CupertinoIcons.chart_bar,
      'person': CupertinoIcons.person,
      'shield': CupertinoIcons.shield,
    };
    return icons[iconName] ?? CupertinoIcons.circle;
  }

  void _showAddTransactionSheet() {
    _showTransactionSheet(null);
  }

  void _showEditTransactionSheet(Transaction transaction) {
    _showTransactionSheet(transaction);
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
                    if (isEditing)
                      IconButton(
                        icon: Icon(CupertinoIcons.trash, color: WoColors.red),
                        onPressed: () async {
                          await _repo!.deleteTransaction(existing.id);
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          _loadData();
                          HapticFeedback.heavyImpact();
                        },
                      ),
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

  String _formatCurrency(double amount) => CurrencyUtils.format(amount, _base, decimals: 2);
}
