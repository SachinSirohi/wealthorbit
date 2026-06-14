import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drift/drift.dart' show Value;
import '../../../core/theme/wo_design.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../data/database/database.dart';
import '../../../data/repositories/app_repository.dart';
import '../../../data/services/secure_vault.dart';
import '../widgets/transfer_sheet.dart';
import '../../reconciliation/screens/reconciliation_screen.dart';

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  AppRepository? _repo;
  List<Account> _accounts = [];
  bool _isLoading = true;
  double _totalBalance = 0;
  String _base = 'AED';

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
      final accounts = await _repo!.getAllAccounts();
      if (!mounted) return;
      // Convert each account to the base currency for the headline total.
      final total = await _repo!.getTotalAccountBalance();
      final base = await SecureVault.getBaseCurrency();

      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _totalBalance = total;
        _base = base;
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
          _buildTotalCard(),
          if (_isLoading)
            SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: WoColors.gold)),
            )
          else if (_accounts.isEmpty)
            _buildEmptyState()
          else
            _buildAccountList(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddAccountSheet(),
        backgroundColor: WoColors.gold,
        icon: const Icon(CupertinoIcons.add, color: Colors.black),
        label: Text('Add Account', style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600)),
      ).animate().scale(delay: 300.ms),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 100,
      floating: true,
      pinned: true,
      backgroundColor: WoColors.bg,
      actions: [
        IconButton(
          tooltip: 'Transfer / Pay Bill',
          icon: Icon(CupertinoIcons.arrow_right_arrow_left, color: WoColors.textMid),
          onPressed: _accounts.length < 2 ? null : _showTransfer,
        ),
        IconButton(
          tooltip: 'Reconcile',
          icon: Icon(CupertinoIcons.checkmark_seal, color: WoColors.textMid),
          onPressed: _accounts.isEmpty
              ? null
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ReconciliationScreen()),
                  ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        title: Text('Accounts', style: WoText.display()),
        titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
      ),
    );
  }

  Future<void> _showTransfer({Account? creditCard}) async {
    final ok = await TransferSheet.show(
      context,
      repository: _repo!,
      accounts: _accounts,
      creditCard: creditCard,
    );
    if (ok == true) _loadData();
  }

  Widget _buildTotalCard() {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(24),
        decoration: woCard(goldGlow: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('TOTAL BALANCE', style: WoText.label(color: WoColors.gold)),
            const SizedBox(height: 10),
            Text(CurrencyUtils.format(_totalBalance, _base, decimals: 2), style: WoText.hero()),
            const SizedBox(height: 6),
            Text('${_accounts.length} accounts connected', style: WoText.caption(color: WoColors.textLo)),
          ],
        ),
      ).animate().fadeIn().slideY(begin: 0.1),
    );
  }

  Widget _buildEmptyState() {
    return SliverFillRemaining(
      child: WoEmptyState(
        icon: CupertinoIcons.creditcard,
        title: 'No accounts yet',
        hint: 'Add your bank accounts, cards & wallets',
        ctaLabel: 'Add Account',
        onCta: _showAddAccountSheet,
      ).animate().fadeIn(),
    );
  }

  Widget _buildAccountList() {
    // Group by type
    final byType = <String, List<Account>>{};
    for (var a in _accounts) {
      byType.putIfAbsent(a.type, () => []).add(a);
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final types = byType.keys.toList();
          final type = types[index];
          final accounts = byType[type]!;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WoSectionHeader(
                _getTypeLabel(type),
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
              ),
              ...accounts.asMap().entries.map((entry) {
                return _buildAccountTile(entry.value)
                  .animate(delay: (entry.key * 50).ms)
                  .fadeIn()
                  .slideX(begin: 0.05);
              }),
            ],
          );
        },
        childCount: byType.keys.length,
      ),
    );
  }

  String _getTypeLabel(String type) {
    final labels = {
      'bank': 'Bank Accounts',
      'credit_card': 'Credit Cards',
      'wallet': 'Digital Wallets',
      'cash': 'Cash',
      'investment': 'Investment Accounts',
    };
    return labels[type] ?? type.toUpperCase();
  }

  Widget _buildAccountTile(Account account) {
    final typeIcons = {
      'bank': CupertinoIcons.building_2_fill,
      'credit_card': CupertinoIcons.creditcard_fill,
      'wallet': CupertinoIcons.money_dollar_circle_fill,
      'cash': CupertinoIcons.money_dollar,
      'investment': CupertinoIcons.chart_bar_fill,
    };

    final typeColors = {
      'bank': WoColors.blue,
      'credit_card': WoColors.red,
      'wallet': WoColors.indigo,
      'cash': WoColors.mint,
      'investment': WoColors.gold,
    };

    final icon = typeIcons[account.type] ?? CupertinoIcons.circle;
    final color = typeColors[account.type] ?? WoColors.textMid;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      decoration: woCard(radius: 18),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: WoIconBubble(icon, color: color, size: 46),
        title: Text(account.name, style: WoText.subtitle()),
        subtitle: account.institution != null
            ? Text(account.institution!, style: WoText.caption())
            : null,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              CurrencyUtils.format(account.balance, account.currencyCode, decimals: 2),
              style: WoText.num(color: account.balance >= 0 ? WoColors.textHi : WoColors.red),
            ),
            Text(account.currencyCode, style: WoText.caption(color: WoColors.textLo)),
          ],
        ),
        onTap: () => _showEditAccountSheet(account),
      ),
    );
  }

  void _showAddAccountSheet() {
    _showAccountSheet(null);
  }

  void _showEditAccountSheet(Account account) {
    _showAccountSheet(account);
  }

  void _showAccountSheet(Account? existing) {
    final isEditing = existing != null;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final balanceController = TextEditingController(text: existing?.balance.toString() ?? '0');
    final institutionController = TextEditingController(text: existing?.institution ?? '');
    String type = existing?.type ?? 'bank';
    String currency = existing?.currencyCode ?? 'AED';

    final types = [
      {'value': 'bank', 'label': 'Bank Account'},
      {'value': 'credit_card', 'label': 'Credit Card'},
      {'value': 'wallet', 'label': 'Digital Wallet'},
      {'value': 'cash', 'label': 'Cash'},
      {'value': 'investment', 'label': 'Investment Account'},
    ];

    final currencies = ['AED', 'USD', 'INR', 'EUR', 'GBP'];

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
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: WoSheetHandle(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(isEditing ? 'Edit Account' : 'Add Account', style: WoText.title()),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isEditing && existing.type == 'credit_card' && _accounts.length > 1)
                          TextButton.icon(
                            icon: Icon(CupertinoIcons.creditcard, color: WoColors.gold, size: 18),
                            label: Text('Pay Bill', style: GoogleFonts.poppins(color: WoColors.gold)),
                            onPressed: () {
                              Navigator.pop(context);
                              _showTransfer(creditCard: existing);
                            },
                          ),
                        if (isEditing)
                          IconButton(
                            icon: Icon(CupertinoIcons.trash, color: WoColors.red),
                            onPressed: () async {
                              await _repo!.deleteAccount(existing.id);
                              if (!context.mounted) return;
                              Navigator.pop(context);
                              _loadData();
                              HapticFeedback.heavyImpact();
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      // Account Name
                      TextField(
                        controller: nameController,
                        style: WoText.bodyHi(),
                        decoration: woInput('Account Name'),
                      ),
                      const SizedBox(height: 16),
                      // Institution
                      TextField(
                        controller: institutionController,
                        style: WoText.bodyHi(),
                        decoration: woInput('Bank/Institution (Optional)'),
                      ),
                      const SizedBox(height: 16),
                      // Type Dropdown
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: woWell(),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: type,
                            dropdownColor: WoColors.surface,
                            isExpanded: true,
                            items: types.map((t) => DropdownMenuItem(
                              value: t['value'],
                              child: Text(t['label']!, style: WoText.bodyHi()),
                            )).toList(),
                            onChanged: (val) => setSheetState(() => type = val!),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Currency & Balance Row
                      Row(
                        children: [
                          SizedBox(
                            width: 100,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              decoration: woWell(),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: currency,
                                  dropdownColor: WoColors.surface,
                                  items: currencies.map((c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(c, style: WoText.bodyHi()),
                                  )).toList(),
                                  onChanged: (val) => setSheetState(() => currency = val!),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: balanceController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                              style: WoText.bodyHi(),
                              decoration: woInput('Current Balance'),
                            ),
                          ),
                        ],
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Please enter account name')),
                        );
                        return;
                      }

                      final enteredBalance = double.tryParse(balanceController.text) ?? 0;
                      final account = AccountsCompanion(
                        id: Value(existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString()),
                        name: Value(nameController.text),
                        type: Value(type),
                        currencyCode: Value(currency),
                        balance: Value(enteredBalance),
                        // Treat the user-entered balance as the opening balance so
                        // transaction-driven recomputation stays correct.
                        openingBalance: Value(enteredBalance),
                        institution: Value(institutionController.text.isNotEmpty ? institutionController.text : null),
                      );

                      if (isEditing) {
                        await _repo!.updateAccount(existing.id, account);
                      } else {
                        await _repo!.insertAccount(account);
                      }

                      if (!context.mounted) return;
                      Navigator.pop(context);
                      _loadData();
                      HapticFeedback.mediumImpact();
                    },
                    style: WoButtons.primary,
                    child: Text(isEditing ? 'Update' : 'Add Account'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

}
