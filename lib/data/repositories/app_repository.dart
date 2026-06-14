import 'package:drift/drift.dart';
import '../database/database.dart';
import '../services/secure_vault.dart';
import '../../core/utils/currency_utils.dart';

/// Repository for all database operations
class AppRepository {
  final AppDatabase _db;
  
  // Singleton pattern
  static AppRepository? _instance;
  static AppDatabase? _database;
  
  AppRepository._(this._db);
  
  static Future<AppRepository> getInstance() async {
    if (_instance == null) {
      _database = AppDatabase();
      _instance = AppRepository._(_database!);
    }
    return _instance!;
  }
  
  /// Factory constructor for use with specific database instance
  factory AppRepository.withDatabase(AppDatabase db) => AppRepository._(db);
  
  static AppDatabase? get database => _database;
  
  // ═══════════════════════════════════════════════════════════════════════════
  // CURRENCIES
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Currency>> getAllCurrencies() => _db.select(_db.currencies).get();
  
  Future<Currency?> getCurrency(String code) => 
    (_db.select(_db.currencies)..where((c) => c.code.equals(code)))
      .getSingleOrNull();
  
  Future<void> updateExchangeRate(String code, double rate) async {
    await (_db.update(_db.currencies)..where((c) => c.code.equals(code)))
      .write(CurrenciesCompanion(rateToBase: Value(rate), lastUpdated: Value(DateTime.now())));
    _rateCache = null; // invalidate
  }

  // ── Currency conversion ─────────────────────────────────────────────────
  // rateToBase = value of 1 unit of a currency expressed in the base currency.
  Map<String, double>? _rateCache;

  Future<Map<String, double>> _rates() async {
    if (_rateCache != null) return _rateCache!;
    final list = await getAllCurrencies();
    _rateCache = {for (final c in list) c.code: c.rateToBase};
    return _rateCache!;
  }

  /// Convert [amount] from [code] into the base currency.
  Future<double> toBase(double amount, String code) async {
    final r = (await _rates())[code] ?? 1.0;
    return amount * (r == 0 ? 1.0 : r);
  }

  /// One-time repair for data imported before multi-currency support:
  /// re-tag each account to its bank's real currency, re-tag every
  /// transaction to its account's currency, recompute amountBase via FX,
  /// and recompute balances. Idempotent.
  Future<void> repairCurrencies() async {
    final accounts = await getAllAccounts();
    final rates = await _rates();
    for (final acc in accounts) {
      final correct = CurrencyUtils.currencyForBank('${acc.name} ${acc.institution ?? ''}');
      if (correct != acc.currencyCode) {
        await (_db.update(_db.accounts)..where((a) => a.id.equals(acc.id)))
          .write(AccountsCompanion(currencyCode: Value(correct)));
      }
      final cur = correct;
      final rate = rates[cur] ?? 1.0;
      // Re-tag + reconvert this account's transactions.
      final txns = await (_db.select(_db.transactions)..where((t) => t.accountId.equals(acc.id))).get();
      for (final t in txns) {
        if (t.currencyCode != cur || t.amountBase != t.amountSource * rate) {
          await (_db.update(_db.transactions)..where((x) => x.id.equals(t.id))).write(
            TransactionsCompanion(currencyCode: Value(cur), amountBase: Value(t.amountSource * rate)),
          );
        }
      }
      await recomputeAccountBalance(acc.id);
    }
  }

  Future<void> updateAccountCurrency(String id, String code) =>
    (_db.update(_db.accounts)..where((a) => a.id.equals(id)))
      .write(AccountsCompanion(currencyCode: Value(code)));
  
  // ═══════════════════════════════════════════════════════════════════════════
  // ACCOUNTS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Account>> getAllAccounts() => _db.select(_db.accounts).get();
  
  Stream<List<Account>> watchAllAccounts() => _db.select(_db.accounts).watch();
  
  Future<Account?> getAccount(String id) =>
    (_db.select(_db.accounts)..where((a) => a.id.equals(id))).getSingleOrNull();
  
  Future<int> insertAccount(AccountsCompanion account) =>
    _db.into(_db.accounts).insert(account);
  
  Future<void> updateAccount(String id, AccountsCompanion account) =>
    (_db.update(_db.accounts)..where((a) => a.id.equals(id))).write(account);
  
  Future<void> deleteAccount(String id) =>
    (_db.delete(_db.accounts)..where((a) => a.id.equals(id))).go();
  
  Future<double> getTotalAccountsBalance(String currencyCode) async {
    final accounts = await (_db.select(_db.accounts)
      ..where((a) => a.currencyCode.equals(currencyCode))).get();
    double total = 0.0;
    for (final a in accounts) {
      total += a.balance;
    }
    return total;
  }
  
  /// Total of CASH account balances (bank/wallet/cash/investment), each
  /// converted to the base currency. Credit cards are debt instruments and
  /// are reported under liabilities instead — a card never inflates or
  /// deflates the "Accounts" cash figure.
  Future<double> getTotalAccountBalance() async {
    final accounts = await getAllAccounts();
    final rates = await _rates();
    double total = 0.0;
    for (final a in accounts) {
      if (a.type == 'credit_card') continue;
      total += a.balance * (rates[a.currencyCode] ?? 1.0);
    }
    return total;
  }

  /// Outstanding credit-card debt (negative card balances, as a positive
  /// number) converted to base. Counted with liabilities in net worth.
  Future<double> getCreditCardOutstanding() async {
    final accounts = await getAllAccounts();
    final rates = await _rates();
    double total = 0.0;
    for (final a in accounts) {
      if (a.type != 'credit_card') continue;
      if (a.balance < 0) total += -a.balance * (rates[a.currencyCode] ?? 1.0);
    }
    return total;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // CATEGORIES
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Category>> getAllCategories() => _db.select(_db.categories).get();
  
  Future<List<Category>> getCategoriesByType(String type) =>
    (_db.select(_db.categories)..where((c) => c.budgetType.equals(type))).get();
  
  // ═══════════════════════════════════════════════════════════════════════════
  // TRANSACTIONS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Transaction>> getAllTransactions() =>
    (_db.select(_db.transactions)..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).get();
  
  Stream<List<Transaction>> watchAllTransactions() =>
    (_db.select(_db.transactions)..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).watch();
  
  Future<List<Transaction>> getTransactionsByDateRange(DateTime start, DateTime end) =>
    (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBetweenValues(start, end))
      ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).get();
  
  Future<List<Transaction>> getTransactionsByCategory(String categoryId) =>
    (_db.select(_db.transactions)
      ..where((t) => t.categoryId.equals(categoryId))
      ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).get();
  
  Future<int> insertTransaction(TransactionsCompanion transaction) async {
    final rowId = await _db.into(_db.transactions).insert(transaction);
    await _recomputeForCompanion(transaction);
    return rowId;
  }

  Future<void> updateTransaction(String id, TransactionsCompanion transaction) async {
    final before = await (_db.select(_db.transactions)..where((t) => t.id.equals(id))).getSingleOrNull();
    await (_db.update(_db.transactions)..where((t) => t.id.equals(id))).write(transaction);
    // Categorization learning: a user-applied category on a merchant
    // transaction becomes the default for that merchant on future imports.
    if (transaction.categoryId.present &&
        transaction.categoryId.value != null &&
        before?.merchant != null &&
        transaction.categoryId.value != before!.categoryId) {
      await learnMerchantCategory(before.merchant!, transaction.categoryId.value!);
    }
    final affected = <String>{};
    if (before != null) {
      affected.add(before.accountId);
      if (before.transferAccountId != null) affected.add(before.transferAccountId!);
    }
    if (transaction.accountId.present) affected.add(transaction.accountId.value);
    if (transaction.transferAccountId.present && transaction.transferAccountId.value != null) {
      affected.add(transaction.transferAccountId.value!);
    }
    for (final a in affected) {
      await recomputeAccountBalance(a);
    }
  }

  Future<void> deleteTransaction(String id) async {
    final before = await (_db.select(_db.transactions)..where((t) => t.id.equals(id))).getSingleOrNull();
    await (_db.delete(_db.transactions)..where((t) => t.id.equals(id))).go();
    if (before != null) {
      await recomputeAccountBalance(before.accountId);
      if (before.transferAccountId != null) await recomputeAccountBalance(before.transferAccountId!);
    }
  }

  Future<void> _recomputeForCompanion(TransactionsCompanion t) async {
    if (t.accountId.present) await recomputeAccountBalance(t.accountId.value);
    if (t.transferAccountId.present && t.transferAccountId.value != null) {
      await recomputeAccountBalance(t.transferAccountId.value!);
    }
  }

  /// Recompute an account's balance from its opening balance + all transactions
  /// that touch it (as source or as a transfer target). Keeps balances correct
  /// after any insert/update/delete/transfer/bill-payment.
  Future<void> recomputeAccountBalance(String accountId) async {
    final acc = await getAccount(accountId);
    if (acc == null) return;
    final asSource = await (_db.select(_db.transactions)
      ..where((t) => t.accountId.equals(accountId))).get();
    final asTarget = await (_db.select(_db.transactions)
      ..where((t) => t.transferAccountId.equals(accountId))).get();
    // Balance is kept in the ACCOUNT'S OWN currency, so it sums amountSource
    // (the original amounts), not amountBase (the base-currency conversion).
    // Aggregates convert per-account via rateToBase.
    double bal = acc.openingBalance;
    for (final t in asSource) {
      switch (t.type) {
        case 'income':
          bal += t.amountSource;
          break;
        case 'expense':
          bal -= t.amountSource;
          break;
        case 'transfer':
          bal -= t.amountSource; // money leaves the source account
          break;
      }
    }
    for (final t in asTarget) {
      if (t.type == 'transfer') bal += t.amountSource; // money enters the target
    }
    await (_db.update(_db.accounts)..where((a) => a.id.equals(accountId)))
      .write(AccountsCompanion(balance: Value(bal)));
  }

  /// Create a double-entry transfer: a single row whose `accountId` is the
  /// source and `transferAccountId` is the destination. Both balances update.
  Future<void> createTransfer({
    required String fromAccountId,
    required String toAccountId,
    required double amount,
    required DateTime date,
    String? note,
    String currencyCode = 'AED',
  }) async {
    if (fromAccountId == toAccountId || amount <= 0) return;
    await insertTransaction(TransactionsCompanion.insert(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      accountId: fromAccountId,
      transferAccountId: Value(toAccountId),
      amountSource: amount,
      amountBase: amount,
      currencyCode: currencyCode,
      description: (note != null && note.isNotEmpty) ? note : 'Transfer',
      type: 'transfer',
      transactionDate: date,
    ));
  }

  /// Pay a credit-card bill from a funding account. Models the payment as a
  /// transfer (bank ↓, card balance moves toward 0) and, when the card account
  /// is linked to a Liability, reduces that outstanding amount too.
  Future<void> payCreditCardBill({
    required String fromAccountId,
    required String creditCardAccountId,
    required double amount,
    required DateTime date,
  }) async {
    await createTransfer(
      fromAccountId: fromAccountId,
      toAccountId: creditCardAccountId,
      amount: amount,
      date: date,
      note: 'Credit Card Payment',
    );
    final cc = await getAccount(creditCardAccountId);
    if (cc?.linkedLiabilityId != null) {
      final liab = await (_db.select(_db.liabilities)
        ..where((l) => l.id.equals(cc!.linkedLiabilityId!))).getSingleOrNull();
      if (liab != null) {
        final newOutstanding = (liab.outstandingAmount - amount).clamp(0.0, double.infinity);
        await updateLiability(liab.id, LiabilitiesCompanion(outstandingAmount: Value(newOutstanding)));
      }
    }
  }

  // ── Reconciliation ────────────────────────────────────────────────────────

  Future<List<Transaction>> getPendingTransactions(String accountId) =>
    (_db.select(_db.transactions)
      ..where((t) => t.accountId.equals(accountId) & t.status.equals('pending'))
      ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).get();

  Future<void> markTransactionCleared(String id) =>
    (_db.update(_db.transactions)..where((t) => t.id.equals(id)))
      .write(const TransactionsCompanion(status: Value('cleared')));

  Future<void> markTransactionReconciled(String id) =>
    (_db.update(_db.transactions)..where((t) => t.id.equals(id)))
      .write(const TransactionsCompanion(status: Value('reconciled')));

  Future<void> linkTransactions(String importedId, String manualId) =>
    (_db.update(_db.transactions)..where((t) => t.id.equals(importedId)))
      .write(TransactionsCompanion(
        linkedTransactionId: Value(manualId),
        status: const Value('reconciled'),
      ));

  /// Find a likely manual duplicate of an imported transaction: same account,
  /// amount within 0.01, and date within ±3 days.
  Future<Transaction?> findDuplicateTransaction({
    required String accountId,
    required double amountBase,
    required DateTime date,
    required String excludeId,
  }) async {
    final start = date.subtract(const Duration(days: 3));
    final end = date.add(const Duration(days: 3));
    final candidates = await (_db.select(_db.transactions)
      ..where((t) => t.accountId.equals(accountId)
        & t.transactionDate.isBetweenValues(start, end)
        & t.id.equals(excludeId).not())).get();
    for (final c in candidates) {
      if ((c.amountBase - amountBase).abs() < 0.01) return c;
    }
    return null;
  }
  
  Future<double> getTotalExpensesByMonth(int year, int month) async {
    final start = DateTime(year, month, 1);
    final end = DateTime(year, month + 1, 0);
    final transactions = await (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBetweenValues(start, end))
      ..where((t) => t.type.equals('expense'))).get();
    double total = 0.0;
    for (final t in transactions) {
      total += t.amountBase;
    }
    return total;
  }
  
  Future<double> getTotalIncomeByMonth(int year, int month) async {
    final start = DateTime(year, month, 1);
    final end = DateTime(year, month + 1, 0);
    final transactions = await (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBetweenValues(start, end))
      ..where((t) => t.type.equals('income'))).get();
    double total = 0.0;
    for (final t in transactions) {
      total += t.amountBase;
    }
    return total;
  }
  
  Future<Map<String, double>> getExpensesByCategory(DateTime start, DateTime end) async {
    final transactions = await (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBetweenValues(start, end))
      ..where((t) => t.type.equals('expense'))).get();
    
    final categories = await getAllCategories();
    final categoryMap = {for (var c in categories) c.id: c.name};
    
    final result = <String, double>{};
    for (var t in transactions) {
      final catName = categoryMap[t.categoryId] ?? 'Uncategorized';
      result[catName] = (result[catName] ?? 0) + t.amountBase;
    }
    return result;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // ASSETS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Asset>> getAllAssets() => _db.select(_db.assets).get();

  Future<Asset?> getAsset(String id) =>
    (_db.select(_db.assets)..where((a) => a.id.equals(id))).getSingleOrNull();

  Stream<List<Asset>> watchAllAssets() => _db.select(_db.assets).watch();
  
  Future<List<Asset>> getAssetsByType(String type) =>
    (_db.select(_db.assets)..where((a) => a.type.equals(type))).get();
  
  Future<int> insertAsset(AssetsCompanion asset) =>
    _db.into(_db.assets).insert(asset);
  
  Future<void> updateAsset(String id, AssetsCompanion asset) =>
    (_db.update(_db.assets)..where((a) => a.id.equals(id))).write(asset);
  
  Future<void> deleteAsset(String id) =>
    (_db.delete(_db.assets)..where((a) => a.id.equals(id))).go();
  
  Future<double> getTotalAssetValue() async {
    final assets = await getAllAssets();
    final rates = await _rates();
    double total = 0.0;
    for (final a in assets) {
      total += a.currentValue * (rates[a.currencyCode] ?? 1.0);
    }
    return total;
  }

  Future<double> getLiquidAssetValue() async {
    final assets = await (_db.select(_db.assets)
      ..where((a) => a.isLiquid.equals(true))).get();
    final rates = await _rates();
    double total = 0.0;
    for (final a in assets) {
      total += a.currentValue * (rates[a.currencyCode] ?? 1.0);
    }
    return total;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // GOALS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Goal>> getAllGoals() => _db.select(_db.goals).get();
  
  Stream<List<Goal>> watchAllGoals() => _db.select(_db.goals).watch();
  
  Future<int> insertGoal(GoalsCompanion goal) =>
    _db.into(_db.goals).insert(goal);
  
  Future<void> updateGoal(String id, GoalsCompanion goal) =>
    (_db.update(_db.goals)..where((g) => g.id.equals(id))).write(goal);

  Future<void> deleteGoal(String id) =>
    (_db.delete(_db.goals)..where((g) => g.id.equals(id))).go();

  Future<void> updateGoalProgress(String goalId, double currentAmount) =>
    (_db.update(_db.goals)..where((g) => g.id.equals(goalId)))
      .write(GoalsCompanion(currentAmount: Value(currentAmount)));
  
  // ═══════════════════════════════════════════════════════════════════════════
  // BUDGETS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Budget>> getAllBudgets() => _db.select(_db.budgets).get();
  
  Future<int> insertBudget(BudgetsCompanion budget) =>
    _db.into(_db.budgets).insert(budget);
  
  Future<void> updateBudget(String id, BudgetsCompanion budget) =>
    (_db.update(_db.budgets)..where((b) => b.id.equals(id))).write(budget);
  
  // ═══════════════════════════════════════════════════════════════════════════
  // AGGREGATED DATA
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Calculate total net worth (assets - liabilities)
  Future<double> getNetWorth() async {
    final totalAssets = await getTotalAssetValue();
    final totalAccounts = await getTotalAccountBalance();
    return totalAssets + totalAccounts;
  }
  
  /// Get monthly expenses for the last N months
  Future<List<double>> getMonthlyExpenses(int months) async {
    final result = <double>[];
    final now = DateTime.now();
    
    for (int i = months - 1; i >= 0; i--) {
      final date = DateTime(now.year, now.month - i, 1);
      final expense = await getTotalExpensesByMonth(date.year, date.month);
      result.add(expense);
    }
    return result;
  }
  
  /// Get average monthly expenses
  Future<double> getAverageMonthlyExpenses({int months = 6}) async {
    final expenses = await getMonthlyExpenses(months);
    if (expenses.isEmpty) return 0;
    return expenses.reduce((a, b) => a + b) / expenses.length;
  }
  
  /// Emergency fund runway = positive liquid cash ÷ average monthly spend.
  ///
  /// - Liquid = liquid assets + POSITIVE balances of bank/wallet/cash
  ///   accounts, converted to base. Credit cards and overdrawn balances are
  ///   debt, not runway — they never reduce this below zero.
  /// - Spend = average of the last 3 months' expenses (more responsive than
  ///   6 and matches "based on salary and expense numbers").
  Future<int> getEmergencyFundMonths() async {
    final liquid = await getLiquidAssetValue();
    final accounts = await getAllAccounts();
    final rates = await _rates();
    double cash = 0.0;
    for (final a in accounts) {
      if (a.type == 'credit_card') continue;
      if (a.balance <= 0) continue;
      cash += a.balance * (rates[a.currencyCode] ?? 1.0);
    }
    final totalLiquid = (liquid + cash).clamp(0.0, double.infinity);
    final avgExpense = await getAverageMonthlyExpenses(months: 3);
    if (avgExpense <= 0) return 0;
    return (totalLiquid / avgExpense).floor().clamp(0, 999);
  }

  /// Average monthly income over the last [months] (salary detection input).
  Future<double> getAverageMonthlyIncome({int months = 3}) async {
    final now = DateTime.now();
    double total = 0;
    int counted = 0;
    for (int i = 0; i < months; i++) {
      final d = DateTime(now.year, now.month - i, 1);
      final inc = await getTotalIncomeByMonth(d.year, d.month);
      if (inc > 0) {
        total += inc;
        counted++;
      }
    }
    return counted == 0 ? 0 : total / counted;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // LIABILITIES
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Liability>> getAllLiabilities() => _db.select(_db.liabilities).get();
  
  Stream<List<Liability>> watchAllLiabilities() => _db.select(_db.liabilities).watch();
  
  Future<List<Liability>> getActiveLiabilities() =>
    (_db.select(_db.liabilities)..where((l) => l.isActive.equals(true))).get();

  Future<Liability?> getLiability(String id) =>
    (_db.select(_db.liabilities)..where((l) => l.id.equals(id))).getSingleOrNull();

  Future<Liability?> getLiabilityForAsset(String assetId) =>
    (_db.select(_db.liabilities)..where((l) => l.linkedAssetId.equals(assetId))).getSingleOrNull();
  
  Future<int> insertLiability(LiabilitiesCompanion liability) =>
    _db.into(_db.liabilities).insert(liability);
  
  Future<void> updateLiability(String id, LiabilitiesCompanion liability) =>
    (_db.update(_db.liabilities)..where((l) => l.id.equals(id))).write(liability);
  
  Future<void> deleteLiability(String id) =>
    (_db.delete(_db.liabilities)..where((l) => l.id.equals(id))).go();
  
  Future<double> getTotalLiabilities() async {
    final liabilities = await getActiveLiabilities();
    final rates = await _rates();
    double total = 0.0;
    for (final l in liabilities) {
      total += l.outstandingAmount * (rates[l.currencyCode] ?? 1.0);
    }
    // Credit-card debt lives on Accounts rows but is a liability.
    total += await getCreditCardOutstanding();
    return total;
  }
  
  Future<double> getTotalMonthlyEMI() async {
    final liabilities = await getActiveLiabilities();
    double total = 0.0;
    for (final l in liabilities) {
      total += await toBase(l.emi, l.currencyCode);
    }
    return total;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // SIP RECORDS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<SipRecord>> getAllSipRecords() => _db.select(_db.sipRecords).get();
  
  Stream<List<SipRecord>> watchAllSips() => _db.select(_db.sipRecords).watch();
  
  Future<List<SipRecord>> getActiveSips() =>
    (_db.select(_db.sipRecords)..where((s) => s.isActive.equals(true))).get();
  
  Future<List<SipRecord>> getSipsByGoal(String goalId) =>
    (_db.select(_db.sipRecords)..where((s) => s.goalId.equals(goalId))).get();
  
  Future<void> insertSipRecord(SipRecordsCompanion sip) =>
    _db.into(_db.sipRecords).insert(sip);
  
  Future<void> updateSipRecord(String id, SipRecordsCompanion sip) =>
    (_db.update(_db.sipRecords)..where((s) => s.id.equals(id))).write(sip);
  
  Future<void> deleteSipRecord(String id) =>
    (_db.delete(_db.sipRecords)..where((s) => s.id.equals(id))).go();
  
  Future<double> getTotalMonthlySip() async {
    final sips = await getActiveSips();
    double total = 0.0;
    for (final s in sips) {
      total += await toBase(s.amount, s.currencyCode);
    }
    return total;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // DIVIDENDS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Dividend>> getAllDividends() => _db.select(_db.dividends).get();
  
  Future<List<Dividend>> getDividendsByAsset(String assetId) =>
    (_db.select(_db.dividends)..where((d) => d.assetId.equals(assetId))).get();
  
  Future<List<Dividend>> getDividendsByYear(int year) =>
    (_db.select(_db.dividends)
      ..where((d) => d.paymentDate.isBetweenValues(
        DateTime(year, 1, 1),
        DateTime(year, 12, 31),
      ))).get();
  
  Future<void> insertDividend(DividendsCompanion dividend) =>
    _db.into(_db.dividends).insert(dividend);

  Future<void> updateDividend(String id, DividendsCompanion dividend) =>
    (_db.update(_db.dividends)..where((d) => d.id.equals(id))).write(dividend);
  
  Future<void> deleteDividend(String id) =>
    (_db.delete(_db.dividends)..where((d) => d.id.equals(id))).go();
  
  Future<double> getTotalDividendsByYear(int year) async {
    final dividends = await getDividendsByYear(year);
    double total = 0.0;
    for (final d in dividends) {
      total += await toBase(d.amount, d.currencyCode);
    }
    return total;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // PROPERTY EXPENSES
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<PropertyExpense>> getPropertyExpenses(String assetId) =>
    (_db.select(_db.propertyExpenses)..where((p) => p.assetId.equals(assetId))).get();
  
  Future<List<PropertyExpense>> getPropertyExpensesByDateRange(String assetId, DateTime start, DateTime end) =>
    (_db.select(_db.propertyExpenses)
      ..where((p) => p.assetId.equals(assetId))
      ..where((p) => p.expenseDate.isBetweenValues(start, end))).get();
  
  Future<void> insertPropertyExpense(PropertyExpensesCompanion expense) =>
    _db.into(_db.propertyExpenses).insert(expense);
  
  Future<void> deletePropertyExpense(String id) =>
    (_db.delete(_db.propertyExpenses)..where((p) => p.id.equals(id))).go();
  
  Future<double> getTotalPropertyExpenses(String assetId, {int? year}) async {
    final now = DateTime.now();
    final targetYear = year ?? now.year;
    final expenses = await getPropertyExpensesByDateRange(
      assetId,
      DateTime(targetYear, 1, 1),
      DateTime(targetYear, 12, 31),
    );
    double total = 0.0;
    for (final e in expenses) {
      total += e.amount;
    }
    return total;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // RENTAL INCOME
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<RentalIncomeData>> getRentalIncome(String assetId) =>
    (_db.select(_db.rentalIncome)..where((r) => r.assetId.equals(assetId))).get();
  
  Future<List<RentalIncomeData>> getRentalIncomeByYear(String assetId, int year) =>
    (_db.select(_db.rentalIncome)
      ..where((r) => r.assetId.equals(assetId))
      ..where((r) => r.year.equals(year))).get();
  
  Future<void> insertRentalIncome(RentalIncomeCompanion income) =>
    _db.into(_db.rentalIncome).insert(income);
  
  Future<void> updateRentalIncome(String id, RentalIncomeCompanion income) =>
    (_db.update(_db.rentalIncome)..where((r) => r.id.equals(id))).write(income);
  
  Future<void> deleteRentalIncome(String id) =>
    (_db.delete(_db.rentalIncome)..where((r) => r.id.equals(id))).go();
  
  Future<double> getTotalRentalIncome(String assetId, {int? year}) async {
    final targetYear = year ?? DateTime.now().year;
    final income = await getRentalIncomeByYear(assetId, targetYear);
    double total = 0.0;
    for (final r in income) {
      total += r.amount;
    }
    return total;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // GOAL-ASSET MAPPINGS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<GoalAssetMapping>> getGoalAssetMappings(String goalId) =>
    (_db.select(_db.goalAssetMappings)..where((m) => m.goalId.equals(goalId))).get();
  
  Future<void> insertGoalAssetMapping(GoalAssetMappingsCompanion mapping) =>
    _db.into(_db.goalAssetMappings).insert(mapping);
  
  Future<void> deleteGoalAssetMapping(String goalId, String assetId) =>
    (_db.delete(_db.goalAssetMappings)
      ..where((m) => m.goalId.equals(goalId) & m.assetId.equals(assetId))).go();
  
  Future<double> getGoalCurrentValue(String goalId) async {
    final mappings = await getGoalAssetMappings(goalId);
    double total = 0.0;
    for (final m in mappings) {
      final asset = await (_db.select(_db.assets)
        ..where((a) => a.id.equals(m.assetId))).getSingleOrNull();
      if (asset != null) {
        total += asset.currentValue * (m.allocationPercent / 100);
      }
    }
    return total;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // BUDGET THRESHOLD CHECKING
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<Map<String, dynamic>>> checkBudgetThresholds() async {
    final now = DateTime.now();
    final budgets = await getAllBudgets();
    final alerts = <Map<String, dynamic>>[];
    
    for (final budget in budgets) {
      if (budget.year != now.year || budget.month != now.month) continue;
      
      // Get actual expenses for this category
      final transactions = await getTransactionsByCategory(budget.categoryId);
      double spent = 0.0;
      for (final tx in transactions) {
        if (tx.transactionDate.year == now.year && 
            tx.transactionDate.month == now.month &&
            tx.type == 'expense') {
          spent += tx.amountBase;
        }
      }
      
      final percentUsed = budget.limitAmount > 0 ? (spent / budget.limitAmount * 100) : 0;
      
      if (percentUsed >= 70) {
        final category = await (_db.select(_db.categories)
          ..where((c) => c.id.equals(budget.categoryId))).getSingleOrNull();
        
        alerts.add({
          'categoryId': budget.categoryId,
          'categoryName': category?.name ?? 'Unknown',
          'budgetLimit': budget.limitAmount,
          'spent': spent,
          'percentUsed': percentUsed,
          'threshold': percentUsed >= 100 ? 'exceeded' : (percentUsed >= 90 ? 'critical' : 'warning'),
        });
      }
    }
    
    return alerts;
  }
  
  /// Calculate net worth including liabilities
  Future<double> getNetWorthWithLiabilities() async {
    final assets = await getTotalAssetValue();
    final accounts = await getTotalAccountBalance();
    final liabilities = await getTotalLiabilities();
    return assets + accounts - liabilities;
  }
  
  /// Calculate property P&L for a specific year
  Future<Map<String, double>> getPropertyProfitLoss(String assetId, int year) async {
    final income = await getTotalRentalIncome(assetId, year: year);
    final expenses = await getTotalPropertyExpenses(assetId, year: year);
    
    return {
      'income': income,
      'expenses': expenses,
      'netIncome': income - expenses,
    };
  }

  /// Get total income for a specific year
  Future<double> getTotalIncomeByYear(int year) async {
    final start = DateTime(year, 1, 1);
    final end = DateTime(year, 12, 31);
    
    final result = await (_db.selectOnly(_db.transactions)
      ..addColumns([_db.transactions.amountBase.sum()])
      ..where(_db.transactions.transactionDate.isBetweenValues(start, end))
      ..where(_db.transactions.type.equals('income')))
      .map((row) => row.read(_db.transactions.amountBase.sum()))
      .getSingle();
      
    return result ?? 0.0;
  }

  /// Get total expenses for a specific year
  Future<double> getTotalExpensesByYear(int year) async {
    final start = DateTime(year, 1, 1);
    final end = DateTime(year, 12, 31);
    
    final result = await (_db.selectOnly(_db.transactions)
      ..addColumns([_db.transactions.amountBase.sum()])
      ..where(_db.transactions.transactionDate.isBetweenValues(start, end))
      ..where(_db.transactions.type.equals('expense')))
      .map((row) => row.read(_db.transactions.amountBase.sum()))
      .getSingle();
      
    return result?.abs() ?? 0.0;
  }
  // ═══════════════════════════════════════════════════════════════════════════
  // STATEMENT AUTOMATION
  // ═══════════════════════════════════════════════════════════════════════════
  
  // Statement Sources
  Future<List<StatementSource>> getAllStatementSources() =>
    _db.select(_db.statementSources).get();

  Future<StatementSource?> getStatementSource(String id) =>
    (_db.select(_db.statementSources)..where((s) => s.id.equals(id))).getSingleOrNull();

  Future<void> insertStatementSource(StatementSourcesCompanion source) =>
    _db.into(_db.statementSources).insert(source);

  Future<void> updateStatementSource(String id, StatementSourcesCompanion source) =>
    (_db.update(_db.statementSources)..where((s) => s.id.equals(id))).write(source);

  Future<void> deleteStatementSource(String id) =>
    (_db.delete(_db.statementSources)..where((s) => s.id.equals(id))).go();
    
  // Statement Queue
  Future<List<StatementQueueData>> getAllStatementQueue() =>
    (_db.select(_db.statementQueue)
      ..orderBy([(t) => OrderingTerm(expression: t.queuedAt, mode: OrderingMode.desc)]))
      .get();
      
  Future<List<StatementQueueData>> getPendingStatementQueue() =>
    (_db.select(_db.statementQueue)
      ..where((t) => t.status.isIn(['pending', 'processing']))
      ..orderBy([(t) => OrderingTerm(expression: t.priority, mode: OrderingMode.desc)]))
      .get();
      
  Future<void> insertStatementQueueItem(StatementQueueCompanion item) =>
    _db.into(_db.statementQueue).insert(item);
    
  Future<void> updateStatementQueueStatus(String id, String status, {String? errorMessage}) {
    return (_db.update(_db.statementQueue)..where((t) => t.id.equals(id))).write(
      StatementQueueCompanion(
        status: Value(status),
        errorMessage: Value(errorMessage),
        processedAt: status == 'completed' || status == 'failed' ? Value(DateTime.now()) : const Value.absent(),
      ),
    );
  }
  
  Future<void> deleteStatementQueueItem(String id) =>
    (_db.delete(_db.statementQueue)..where((t) => t.id.equals(id))).go();
    
  Future<void> clearCompletedStatementQueue() =>
    (_db.delete(_db.statementQueue)..where((t) => t.status.equals('completed'))).go();

  // ═══════════════════════════════════════════════════════════════════════════
  // PROPERTY EXIT RULES
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<List<PropertyExitRule>> getAllExitRules() => _db.select(_db.propertyExitRules).get();
  
  Future<List<PropertyExitRule>> getExitRulesForAsset(String assetId) =>
    (_db.select(_db.propertyExitRules)..where((r) => r.assetId.equals(assetId))).get();
    
  Future<int> insertExitRule(PropertyExitRulesCompanion rule) =>
    _db.into(_db.propertyExitRules).insert(rule);
    
  Future<void> updateExitRule(String id, PropertyExitRulesCompanion rule) =>
    (_db.update(_db.propertyExitRules)..where((r) => r.id.equals(id))).write(rule);
    
  Future<void> deleteExitRule(String id) =>
    (_db.delete(_db.propertyExitRules)..where((r) => r.id.equals(id))).go();
    
  Stream<List<PropertyExitRule>> watchExitRulesForAsset(String assetId) =>
    (_db.select(_db.propertyExitRules)..where((r) => r.assetId.equals(assetId))).watch();

  // ═══════════════════════════════════════════════════════════════════════════
  // FINANCIAL INSIGHTS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<FinancialInsight>> getAllInsights() =>
    (_db.select(_db.financialInsights)..orderBy([(t) => OrderingTerm(expression: t.generatedAt, mode: OrderingMode.desc)])).get();
    
  Future<List<FinancialInsight>> getActiveInsights() =>
    (_db.select(_db.financialInsights)
      ..where((t) => t.isDismissed.equals(false))
      ..orderBy([(t) => OrderingTerm(expression: t.generatedAt, mode: OrderingMode.desc)]))
      .get();
      
  /// Delete all non-dismissed insights so a fresh generation reflects CURRENT
  /// data — stale ones (e.g. "emergency fund 0 months" computed before balances
  /// loaded) must not linger once the real numbers are in.
  Future<void> deleteActiveInsights() =>
    (_db.delete(_db.financialInsights)..where((t) => t.isDismissed.equals(false))).go();

  Future<void> insertInsight(FinancialInsightsCompanion insight) =>
    _db.into(_db.financialInsights).insert(insight);

  Future<void> dismissInsight(String id) =>
    (_db.update(_db.financialInsights)..where((t) => t.id.equals(id))).write(const FinancialInsightsCompanion(isDismissed: Value(true)));
    
  Future<void> deleteInsight(String id) =>
    (_db.delete(_db.financialInsights)..where((t) => t.id.equals(id))).go();

  // ═══════════════════════════════════════════════════════════════════════════
  // SMART RECONCILIATION & AUTOMATION
  // ═══════════════════════════════════════════════════════════════════════════

  /// Detect own-account transfers among imported transactions: an expense in
  /// one account and an income in another, same original amount, within
  /// ±3 days. Converts the pair into a single transfer row so money moved
  /// between your own accounts never counts as income or spending.
  /// Returns the number of pairs converted.
  Future<int> detectInterAccountTransfers() async {
    final all = await (_db.select(_db.transactions)
      ..where((t) => t.type.isIn(['income', 'expense']))
      ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).get();
    final incomes = all.where((t) => t.type == 'income').toList();
    final expenses = all.where((t) => t.type == 'expense').toList();
    final consumed = <String>{};
    int converted = 0;

    for (final out in expenses) {
      if (consumed.contains(out.id)) continue;
      for (final inc in incomes) {
        if (consumed.contains(inc.id)) continue;
        if (inc.accountId == out.accountId) continue;
        if ((inc.amountSource - out.amountSource).abs() > 0.01) continue;
        if (inc.transactionDate.difference(out.transactionDate).inDays.abs() > 3) continue;

        // Convert: expense row becomes the transfer (source -> target),
        // income row is removed (its effect is the transfer credit).
        await (_db.update(_db.transactions)..where((t) => t.id.equals(out.id))).write(
          TransactionsCompanion(
            type: const Value('transfer'),
            transferAccountId: Value(inc.accountId),
            status: const Value('cleared'),
            linkedTransactionId: Value(inc.id),
            categoryId: const Value(null),
          ),
        );
        await (_db.delete(_db.transactions)..where((t) => t.id.equals(inc.id))).go();
        consumed..add(out.id)..add(inc.id);
        await recomputeAccountBalance(out.accountId);
        await recomputeAccountBalance(inc.accountId);
        converted++;
        break;
      }
    }
    return converted;
  }

  /// Auto-create this month's budgets from detected income using the
  /// 50/30/20 rule (needs/wants/future), splitting each bucket across its
  /// categories. No-op when budgets already exist or income is unknown.
  /// Returns the number of budget rows created.
  Future<int> autoPopulateBudgets() async {
    final now = DateTime.now();
    final existing = await getAllBudgets();
    final hasThisMonth = existing.any((b) => b.year == now.year && b.month == now.month);
    if (hasThisMonth) return 0;

    final income = await getAverageMonthlyIncome();
    if (income <= 0) return 0;

    final base = await SecureVault.getBaseCurrency();
    final categories = await getAllCategories();
    int created = 0;
    const buckets = {'needs': 0.50, 'wants': 0.30, 'future': 0.20};
    for (final entry in buckets.entries) {
      final cats = categories.where((c) => c.budgetType == entry.key).toList();
      if (cats.isEmpty) continue;
      final perCategory = income * entry.value / cats.length;
      for (final c in cats) {
        await insertBudget(BudgetsCompanion.insert(
          id: 'bud_${now.year}${now.month}_${c.id}',
          categoryId: c.id,
          year: now.year,
          month: now.month,
          limitAmount: perCategory,
          currencyCode: base,
        ));
        created++;
      }
    }
    return created;
  }

  /// Merge duplicate statement sources (same sender email): keeps the one
  /// with a processed-UID cursor / account mapping, deletes the rest — a
  /// passwordless twin otherwise fails the sync before the good one runs.
  Future<void> mergeDuplicateSources() async {
    final sources = await getAllStatementSources();
    final bySender = <String, List<StatementSource>>{};
    for (final s in sources) {
      bySender.putIfAbsent(s.senderEmail.toLowerCase(), () => []).add(s);
    }
    for (final group in bySender.values) {
      if (group.length < 2) continue;
      group.sort((a, b) {
        final cursor = (b.lastProcessedUid ?? 0).compareTo(a.lastProcessedUid ?? 0);
        if (cursor != 0) return cursor;
        return (b.accountId != null ? 1 : 0).compareTo(a.accountId != null ? 1 : 0);
      });
      final keep = group.first;
      for (final dupe in group.skip(1)) {
        // Preserve a mapped account / password if only the dupe had one.
        if (keep.accountId == null && dupe.accountId != null) {
          await updateStatementSource(keep.id,
              StatementSourcesCompanion(accountId: Value(dupe.accountId)));
        }
        final dupePwd = await SecureVault.getPdfPassword(dupe.id);
        final keepPwd = await SecureVault.getPdfPassword(keep.id);
        if ((keepPwd == null || keepPwd.isEmpty) && dupePwd != null && dupePwd.isNotEmpty) {
          await SecureVault.setPdfPassword(keep.id, dupePwd);
        }
        await deleteStatementSource(dupe.id);
      }
    }
  }

  /// Retype accounts that are clearly credit cards (sender/name says "card")
  /// and flip their anchored balance to debt (negative).
  Future<void> retypeCardAccounts() async {
    final accounts = await getAllAccounts();
    final sources = await getAllStatementSources();
    for (final a in accounts) {
      if (a.type == 'credit_card') continue;
      final senderHints = sources
          .where((s) => s.accountId == a.id)
          .map((s) => s.senderEmail)
          .join(' ');
      if (CurrencyUtils.isCreditCardHint('${a.name} ${a.institution ?? ''} $senderHints')) {
        await (_db.update(_db.accounts)..where((x) => x.id.equals(a.id)))
          .write(const AccountsCompanion(type: Value('credit_card')));
        if (a.balance > 0) {
          await applyClosingBalance(a.id, a.balance); // re-anchors as negative
        }
      }
    }
  }

  /// Merge duplicate accounts created per email-sender (same bank name):
  /// keeps the earliest, moves transactions and statement sources onto it,
  /// then recomputes. Idempotent.
  Future<void> mergeDuplicateAccounts() async {
    final accounts = await getAllAccounts();
    final byName = <String, List<Account>>{};
    for (final a in accounts) {
      byName.putIfAbsent('${a.name.toLowerCase()}|${a.type}', () => []).add(a);
    }
    for (final group in byName.values) {
      if (group.length < 2) continue;
      group.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final keep = group.first;
      for (final dupe in group.skip(1)) {
        await (_db.update(_db.transactions)..where((t) => t.accountId.equals(dupe.id)))
          .write(TransactionsCompanion(accountId: Value(keep.id)));
        await (_db.update(_db.transactions)..where((t) => t.transferAccountId.equals(dupe.id)))
          .write(TransactionsCompanion(transferAccountId: Value(keep.id)));
        await (_db.update(_db.statementSources)..where((s) => s.accountId.equals(dupe.id)))
          .write(StatementSourcesCompanion(accountId: Value(keep.id)));
        await (_db.update(_db.accounts)..where((a) => a.id.equals(keep.id))).write(
          AccountsCompanion(openingBalance: Value(keep.openingBalance + dupe.openingBalance)),
        );
        await deleteAccount(dupe.id);
      }
      await recomputeAccountBalance(keep.id);
    }
  }

  /// Anchor an account to a bank-stated closing balance: sets the opening
  /// balance such that opening + Σ(transaction effects) == closing, so the
  /// app shows the bank's real number instead of a from-zero sum.
  /// For CREDIT CARDS the statement "closing balance" is the amount DUE —
  /// stored as a negative balance (debt).
  Future<void> applyClosingBalance(String accountId, double closing,
      {DateTime? statementDate}) async {
    // Only the NEWEST statement should set an account's balance. When several
    // statements for one account are processed out of order, an older one used
    // to overwrite a newer one (leaving a stale/0 balance). Gate by the
    // statement's date so an older statement never clobbers a newer anchor.
    if (statementDate != null) {
      final key = 'closing_date_$accountId';
      final prev = await getAppSetting(key);
      final prevDate = prev != null ? DateTime.tryParse(prev) : null;
      if (prevDate != null && statementDate.isBefore(prevDate)) {
        return; // a newer statement already set the balance — ignore this one
      }
      await setAppSetting(key, statementDate.toIso8601String());
    }
    final account = await getAccount(accountId);
    if (account?.type == 'credit_card') {
      closing = -closing.abs();
    }
    final asSource = await (_db.select(_db.transactions)
      ..where((t) => t.accountId.equals(accountId))).get();
    final asTarget = await (_db.select(_db.transactions)
      ..where((t) => t.transferAccountId.equals(accountId))).get();
    double effects = 0;
    for (final t in asSource) {
      switch (t.type) {
        case 'income':
          effects += t.amountSource;
          break;
        case 'expense':
        case 'transfer':
          effects -= t.amountSource;
          break;
      }
    }
    for (final t in asTarget) {
      if (t.type == 'transfer') effects += t.amountSource;
    }
    await (_db.update(_db.accounts)..where((a) => a.id.equals(accountId)))
      .write(AccountsCompanion(openingBalance: Value(closing - effects)));
    await recomputeAccountBalance(accountId);
  }

  /// Record the newest processed mailbox UID for a source (dedupe cursor).
  /// Keeps the maximum — processing an older statement never lowers it.
  Future<void> setSourceLastProcessedUid(String sourceId, int uid) async {
    final source = await getStatementSource(sourceId);
    if (source != null && (source.lastProcessedUid ?? 0) >= uid) return;
    await (_db.update(_db.statementSources)..where((s) => s.id.equals(sourceId)))
      .write(StatementSourcesCompanion(lastProcessedUid: Value(uid)));
  }

  /// True when an equivalent transaction already exists (same account, same
  /// original amount, same date ±1 day, same type) — the import dedupe gate.
  Future<bool> transactionExists({
    required String accountId,
    required double amountSource,
    required DateTime date,
    required String type,
  }) async {
    final start = date.subtract(const Duration(days: 1));
    final end = date.add(const Duration(days: 1));
    final rows = await (_db.select(_db.transactions)
      ..where((t) => t.accountId.equals(accountId)
        & t.type.equals(type)
        & t.transactionDate.isBetweenValues(start, end))).get();
    return rows.any((t) => (t.amountSource - amountSource).abs() < 0.01);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // APP SETTINGS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String?> getAppSetting(String key) async {
    final row = await (_db.select(_db.appSettings)..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<bool> getBoolSetting(String key, {bool defaultValue = false}) async {
    final v = await getAppSetting(key);
    if (v == null) return defaultValue;
    return v == 'true';
  }

  Future<void> setAppSetting(String key, String value) =>
    _db.into(_db.appSettings).insertOnConflictUpdate(
      AppSettingsCompanion(key: Value(key), value: Value(value)),
    );

  // ═══════════════════════════════════════════════════════════════════════════
  // CATEGORIZATION LEARNING
  // ═══════════════════════════════════════════════════════════════════════════

  static String _normalizeMerchant(String merchant) => merchant.trim().toLowerCase();

  /// Remember that transactions from [merchant] belong to [categoryId].
  Future<void> learnMerchantCategory(String merchant, String categoryId) {
    final key = _normalizeMerchant(merchant);
    if (key.isEmpty) return Future.value();
    return _db.into(_db.merchantCategories).insertOnConflictUpdate(
      MerchantCategoriesCompanion(
        merchant: Value(key),
        categoryId: Value(categoryId),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// The category the user previously assigned to this merchant, if any.
  Future<String?> getLearnedCategory(String? merchant) async {
    if (merchant == null) return null;
    final row = await (_db.select(_db.merchantCategories)
      ..where((m) => m.merchant.equals(_normalizeMerchant(merchant)))).getSingleOrNull();
    return row?.categoryId;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // NET WORTH SNAPSHOTS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> insertNetWorthSnapshot(NetWorthSnapshotsCompanion snapshot) =>
    _db.into(_db.netWorthSnapshots).insert(snapshot);

  Future<List<NetWorthSnapshot>> getNetWorthSnapshots({int limit = 12}) =>
    (_db.select(_db.netWorthSnapshots)
      ..orderBy([(s) => OrderingTerm.asc(s.date)])
      ..limit(limit)).get();

  Future<NetWorthSnapshot?> getLatestNetWorthSnapshot() =>
    (_db.select(_db.netWorthSnapshots)
      ..orderBy([(s) => OrderingTerm.desc(s.date)])
      ..limit(1)).getSingleOrNull();

  /// Capture a net-worth snapshot if none exists for the current month.
  Future<void> captureMonthlyNetWorthSnapshot() async {
    final now = DateTime.now();
    final latest = await getLatestNetWorthSnapshot();
    if (latest != null && latest.date.year == now.year && latest.date.month == now.month) {
      return; // already captured this month
    }
    final assets = await getTotalAssetValue();
    final accounts = await getTotalAccountBalance();
    final liabilities = await getTotalLiabilities();
    await insertNetWorthSnapshot(NetWorthSnapshotsCompanion.insert(
      id: now.millisecondsSinceEpoch.toString(),
      date: now,
      totalAssets: Value(assets),
      totalAccounts: Value(accounts),
      totalLiabilities: Value(liabilities),
      netWorth: Value(assets + accounts - liabilities),
    ));
  }
}
