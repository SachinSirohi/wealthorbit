import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

// ═══════════════════════════════════════════════════════════════════════════
// CURRENCIES TABLE
// ═══════════════════════════════════════════════════════════════════════════
class Currencies extends Table {
  TextColumn get code => text().withLength(min: 3, max: 3)();
  TextColumn get name => text()();
  TextColumn get symbol => text()();
  RealColumn get rateToBase => real().withDefault(const Constant(1.0))();
  DateTimeColumn get lastUpdated => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {code};
}

// ═══════════════════════════════════════════════════════════════════════════
// ACCOUNTS TABLE (Bank Accounts, Credit Cards, Wallets)
// ═══════════════════════════════════════════════════════════════════════════
class Accounts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get type => text()(); // bank, credit_card, wallet, brokerage
  TextColumn get currencyCode => text().references(Currencies, #code)();
  TextColumn get institution => text().nullable()();
  RealColumn get balance => real().withDefault(const Constant(0.0))();
  // Opening balance captured at account creation. Displayed `balance` is
  // recomputed as openingBalance + Σ(transaction effects).
  RealColumn get openingBalance => real().withDefault(const Constant(0.0))();
  // For credit-card accounts, optionally links to a Liabilities row so that
  // paying the bill also reduces the tracked outstanding amount.
  TextColumn get linkedLiabilityId => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// CATEGORIES TABLE (Budget Categories with 50/30/20 hierarchy)
// ═══════════════════════════════════════════════════════════════════════════
class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get parentId => text().nullable()(); // For sub-categories
  TextColumn get budgetType => text()(); // needs, wants, future
  TextColumn get icon => text().nullable()();
  IntColumn get colorValue => integer().withDefault(const Constant(0xFF007AFF))();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// TRANSACTIONS TABLE
// ═══════════════════════════════════════════════════════════════════════════
class Transactions extends Table {
  TextColumn get id => text()();
  TextColumn get accountId => text().references(Accounts, #id)();
  TextColumn get categoryId => text().nullable().references(Categories, #id)();
  RealColumn get amountSource => real()(); // Original amount
  TextColumn get currencyCode => text().references(Currencies, #code)();
  RealColumn get amountBase => real()(); // Converted to base currency
  TextColumn get description => text()();
  TextColumn get merchant => text().nullable()();
  TextColumn get type => text()(); // income, expense, transfer
  // For transfers: the receiving account (this row's accountId is the source).
  TextColumn get transferAccountId => text().nullable()();
  // Reconciliation state: pending (imported, unconfirmed), cleared, reconciled.
  TextColumn get status => text().withDefault(const Constant('cleared'))();
  // Links an auto-imported transaction to a manually-entered duplicate.
  TextColumn get linkedTransactionId => text().nullable()();
  DateTimeColumn get transactionDate => dateTime()();
  TextColumn get sourceStatementId => text().nullable()(); // Link to parsed statement
  BoolColumn get isRecurring => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// ASSETS TABLE (Real Estate, Investments, etc.)
// ═══════════════════════════════════════════════════════════════════════════
class Assets extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get type => text()(); // real_estate, mutual_fund, stock, ppf, nps, fd, gold
  TextColumn get currencyCode => text().references(Currencies, #code)();
  RealColumn get purchaseValue => real()();
  RealColumn get currentValue => real()();
  DateTimeColumn get purchaseDate => dateTime()();
  TextColumn get geography => text()(); // India, UAE, US
  BoolColumn get isLiquid => boolean().withDefault(const Constant(false))();
  IntColumn get lockInMonths => integer().withDefault(const Constant(0))();
  TextColumn get metadata => text().nullable()(); // JSON for extra details
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// GOALS TABLE (Objective Funds / Financial Goals)
// ═══════════════════════════════════════════════════════════════════════════
class Goals extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()(); // "Child Education", "Tesla Model Y"
  TextColumn get currencyCode => text().references(Currencies, #code)();
  RealColumn get targetAmount => real()();
  // Manually-tracked accumulated savings toward this goal (in addition to any
  // value derived from linked assets via GoalAssetMappings).
  RealColumn get currentAmount => real().withDefault(const Constant(0.0))();
  DateTimeColumn get targetDate => dateTime()();
  TextColumn get priority => text().withDefault(const Constant('medium'))(); // low, medium, high
  TextColumn get status => text().withDefault(const Constant('active'))(); // active, achieved, paused
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// GOAL_ASSET_MAPPINGS TABLE (Many-to-Many: Asset <-> Goal)
// ═══════════════════════════════════════════════════════════════════════════
class GoalAssetMappings extends Table {
  TextColumn get goalId => text().references(Goals, #id)();
  TextColumn get assetId => text().references(Assets, #id)();
  RealColumn get allocationPercent => real()(); // 0-100, how much of this asset is for this goal
  
  @override
  Set<Column> get primaryKey => {goalId, assetId};
}

// ═══════════════════════════════════════════════════════════════════════════
// BUDGETS TABLE (Monthly Budget Limits per Category)
// ═══════════════════════════════════════════════════════════════════════════
class Budgets extends Table {
  TextColumn get id => text()();
  TextColumn get categoryId => text().references(Categories, #id)();
  IntColumn get year => integer()();
  IntColumn get month => integer()(); // 1-12
  RealColumn get limitAmount => real()();
  TextColumn get currencyCode => text().references(Currencies, #code)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// STATEMENT_SOURCES TABLE (Connected Email Sources)
// ═══════════════════════════════════════════════════════════════════════════
class StatementSources extends Table {
  TextColumn get id => text()();
  TextColumn get senderEmail => text()(); // no-reply@enbd.com
  TextColumn get bankName => text()(); // Emirates NBD
  TextColumn get accountType => text()(); // bank, credit_card, brokerage
  TextColumn get pdfPassword => text().nullable()(); // Encrypted password
  // The account that imported transactions from this source attach to.
  TextColumn get accountId => text().nullable()();
  // Highest mailbox UID already extracted — prevents re-processing the same
  // statement on every sync (monthly auto-extract stays idempotent).
  IntColumn get lastProcessedUid => integer().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get lastSyncAt => dateTime().nullable()();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// STATEMENT_QUEUE TABLE (Smart Processing Queue)
// ═══════════════════════════════════════════════════════════════════════════
class StatementQueue extends Table {
  TextColumn get id => text()();
  TextColumn get emailId => text()(); // Gmail message ID
  TextColumn get sourceId => text().nullable().references(StatementSources, #id)();
  TextColumn get subject => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))(); // pending, processing, completed, failed
  IntColumn get priority => integer().withDefault(const Constant(50))(); // Higher = process first
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get errorMessage => text().nullable()();
  DateTimeColumn get emailDate => dateTime()();
  DateTimeColumn get queuedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get processedAt => dateTime().nullable()();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// APP_SETTINGS TABLE (User Preferences)
// ═══════════════════════════════════════════════════════════════════════════
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  
  @override
  Set<Column> get primaryKey => {key};
}

// ═══════════════════════════════════════════════════════════════════════════
// LIABILITIES TABLE (Loans, Credit Cards, Debts)
// ═══════════════════════════════════════════════════════════════════════════
class Liabilities extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get type => text()(); // home_loan, personal_loan, vehicle_loan, credit_card, other
  TextColumn get currencyCode => text().references(Currencies, #code)();
  RealColumn get principalAmount => real()();
  RealColumn get outstandingAmount => real()();
  RealColumn get interestRate => real()(); // Annual interest rate as decimal
  IntColumn get tenureMonths => integer()();
  RealColumn get emi => real()();
  DateTimeColumn get startDate => dateTime()();
  DateTimeColumn get endDate => dateTime().nullable()();
  TextColumn get linkedAssetId => text().nullable().references(Assets, #id)(); // For home/vehicle loans
  TextColumn get institution => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// SIP_RECORDS TABLE (Systematic Investment Plans)
// ═══════════════════════════════════════════════════════════════════════════
class SipRecords extends Table {
  TextColumn get id => text()();
  TextColumn get assetId => text().references(Assets, #id)();
  TextColumn get name => text()();
  RealColumn get amount => real()();
  TextColumn get currencyCode => text().references(Currencies, #code)();
  IntColumn get dayOfMonth => integer()(); // 1-28
  TextColumn get frequency => text().withDefault(const Constant('monthly'))(); // monthly, quarterly
  DateTimeColumn get startDate => dateTime()();
  DateTimeColumn get endDate => dateTime().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get goalId => text().nullable().references(Goals, #id)(); // Goal mapping
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// DIVIDENDS TABLE (Dividend Income Tracking)
// ═══════════════════════════════════════════════════════════════════════════
class Dividends extends Table {
  TextColumn get id => text()();
  TextColumn get assetId => text().references(Assets, #id)();
  RealColumn get amount => real()();
  TextColumn get currencyCode => text().references(Currencies, #code)();
  DateTimeColumn get exDate => dateTime()();
  DateTimeColumn get paymentDate => dateTime()();
  TextColumn get dividendType => text().withDefault(const Constant('cash'))(); // cash, stock, special
  BoolColumn get isReinvested => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// PROPERTY_EXPENSES TABLE (Real Estate P&L Tracking)
// ═══════════════════════════════════════════════════════════════════════════
class PropertyExpenses extends Table {
  TextColumn get id => text()();
  TextColumn get assetId => text().references(Assets, #id)();
  TextColumn get category => text()(); // mortgage, property_tax, maintenance, insurance, management, utilities, vacancy
  RealColumn get amount => real()();
  TextColumn get currencyCode => text().references(Currencies, #code)();
  DateTimeColumn get expenseDate => dateTime()();
  TextColumn get description => text().nullable()();
  BoolColumn get isRecurring => boolean().withDefault(const Constant(false))();
  IntColumn get recurringDay => integer().nullable()(); // Day of month for recurring
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// RENTAL_INCOME TABLE (Property Rental Income)
// ═══════════════════════════════════════════════════════════════════════════
class RentalIncome extends Table {
  TextColumn get id => text()();
  TextColumn get assetId => text().references(Assets, #id)();
  RealColumn get amount => real()();
  TextColumn get currencyCode => text().references(Currencies, #code)();
  IntColumn get year => integer()();
  IntColumn get month => integer()(); // 1-12
  BoolColumn get isPaid => boolean().withDefault(const Constant(true))();
  TextColumn get tenantName => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// PROPERTY_EXIT_RULES TABLE (Exit Strategy Automation)
// ═══════════════════════════════════════════════════════════════════════════
class PropertyExitRules extends Table {
  TextColumn get id => text()();
  TextColumn get assetId => text().references(Assets, #id)();
  TextColumn get ruleType => text()(); // irr_threshold, equity_threshold, profit_threshold, holding_period
  RealColumn get thresholdValue => real()();
  DateTimeColumn get lastCheckedAt => dateTime().nullable()();
  BoolColumn get isTriggered => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// FINANCIAL_INSIGHTS TABLE (Proactive Alerts)
// ═══════════════════════════════════════════════════════════════════════════
class FinancialInsights extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // spending_spike, goal_lag, allocation_drift, emergency_fund
  TextColumn get message => text()();
  TextColumn get severity => text()(); // info, warning, critical
  DateTimeColumn get generatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDismissed => boolean().withDefault(const Constant(false))();
  
  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// NET_WORTH_SNAPSHOTS TABLE (Historical net worth for trend charts)
// ═══════════════════════════════════════════════════════════════════════════
class NetWorthSnapshots extends Table {
  TextColumn get id => text()();
  DateTimeColumn get date => dateTime()();
  RealColumn get totalAssets => real().withDefault(const Constant(0.0))();
  RealColumn get totalAccounts => real().withDefault(const Constant(0.0))();
  RealColumn get totalLiabilities => real().withDefault(const Constant(0.0))();
  RealColumn get netWorth => real().withDefault(const Constant(0.0))();

  @override
  Set<Column> get primaryKey => {id};
}

// ═══════════════════════════════════════════════════════════════════════════
// MERCHANT_CATEGORIES TABLE (Categorization learning from user corrections)
// ═══════════════════════════════════════════════════════════════════════════
class MerchantCategories extends Table {
  // Normalized (lowercased, trimmed) merchant name.
  TextColumn get merchant => text()();
  TextColumn get categoryId => text().references(Categories, #id)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {merchant};
}

// ═══════════════════════════════════════════════════════════════════════════
// DATABASE CLASS
// ═══════════════════════════════════════════════════════════════════════════
@DriftDatabase(tables: [
  Currencies,
  Accounts,
  Categories,
  Transactions,
  Assets,
  Goals,
  GoalAssetMappings,
  Budgets,
  StatementSources,
  StatementQueue,
  AppSettings,
  Liabilities,
  SipRecords,
  Dividends,
  PropertyExpenses,
  RentalIncome,
  PropertyExitRules,
  FinancialInsights,
  NetWorthSnapshots,
  MerchantCategories,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// Test-only: inject a custom (e.g. in-memory) executor.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      // Seed default currencies
      await _seedCurrencies();
      // Seed default categories
      await _seedCategories();
      await _seedIncomeCategories();
    },
    onUpgrade: (m, from, to) async {
      // v5: reconciliation/transfers, balance bookkeeping, source→account
      // mapping, goal progress, and net-worth history.
      if (from < 5) {
        await m.addColumn(accounts, accounts.openingBalance);
        await m.addColumn(accounts, accounts.linkedLiabilityId);
        await m.addColumn(transactions, transactions.transferAccountId);
        await m.addColumn(transactions, transactions.status);
        await m.addColumn(transactions, transactions.linkedTransactionId);
        await m.addColumn(statementSources, statementSources.accountId);
        await m.addColumn(goals, goals.currentAmount);
        await m.createTable(netWorthSnapshots);
        // Seed openingBalance from the current stored balance for existing rows.
        await customStatement(
          'UPDATE accounts SET opening_balance = balance WHERE opening_balance = 0',
        );
      }
      // v6: categorization learning (remember user category corrections).
      if (from < 6) {
        await m.createTable(merchantCategories);
      }
      // v7: statement dedupe cursor + income categories.
      if (from < 7) {
        await m.addColumn(statementSources, statementSources.lastProcessedUid);
        await _seedIncomeCategories();
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
  
  Future<void> _seedCurrencies() async {
    await batch((batch) {
      batch.insertAll(currencies, [
        CurrenciesCompanion.insert(code: 'AED', name: 'UAE Dirham', symbol: 'د.إ'),
        CurrenciesCompanion.insert(code: 'USD', name: 'US Dollar', symbol: '\$'),
        CurrenciesCompanion.insert(code: 'INR', name: 'Indian Rupee', symbol: '₹'),
        CurrenciesCompanion.insert(code: 'EUR', name: 'Euro', symbol: '€'),
        CurrenciesCompanion.insert(code: 'GBP', name: 'British Pound', symbol: '£'),
      ]);
    });
  }
  
  /// Income categories so credits get classified too (salary vs interest vs
  /// refunds), instead of landing uncategorized.
  Future<void> _seedIncomeCategories() async {
    await batch((batch) {
      batch.insertAllOnConflictUpdate(categories, [
        CategoriesCompanion.insert(id: 'cat_salary', name: 'Salary', budgetType: 'income', icon: const Value('briefcase'), colorValue: const Value(0xFF34C759)),
        CategoriesCompanion.insert(id: 'cat_business', name: 'Business Income', budgetType: 'income', icon: const Value('chart.line'), colorValue: const Value(0xFF30D158)),
        CategoriesCompanion.insert(id: 'cat_interest', name: 'Interest & Dividends', budgetType: 'income', icon: const Value('percent'), colorValue: const Value(0xFF32ADE6)),
        CategoriesCompanion.insert(id: 'cat_refund', name: 'Refunds', budgetType: 'income', icon: const Value('arrow.uturn.left'), colorValue: const Value(0xFF8E8E93)),
        CategoriesCompanion.insert(id: 'cat_rent_income', name: 'Rental Income', budgetType: 'income', icon: const Value('house'), colorValue: const Value(0xFFFF9500)),
      ]);
    });
  }

  Future<void> _seedCategories() async {
    await batch((batch) {
      batch.insertAll(categories, [
        // NEEDS (50%)
        CategoriesCompanion.insert(id: 'cat_housing', name: 'Housing', budgetType: 'needs', icon: const Value('home'), colorValue: const Value(0xFF5856D6)),
        CategoriesCompanion.insert(id: 'cat_utilities', name: 'Home Services', budgetType: 'needs', icon: const Value('bolt'), colorValue: const Value(0xFFFF9500)),
        CategoriesCompanion.insert(id: 'cat_groceries', name: 'Groceries', budgetType: 'needs', icon: const Value('cart'), colorValue: const Value(0xFF34C759)),
        CategoriesCompanion.insert(id: 'cat_transport', name: 'Transport', budgetType: 'needs', icon: const Value('car'), colorValue: const Value(0xFF007AFF)),
        CategoriesCompanion.insert(id: 'cat_insurance', name: 'Insurance', budgetType: 'needs', icon: const Value('shield'), colorValue: const Value(0xFFFF3B30)),
        // WANTS (30%)
        CategoriesCompanion.insert(id: 'cat_dining', name: 'Dining Out', budgetType: 'wants', icon: const Value('restaurant'), colorValue: const Value(0xFFFF2D55)),
        CategoriesCompanion.insert(id: 'cat_leisure', name: 'Leisure', budgetType: 'wants', icon: const Value('gamecontroller'), colorValue: const Value(0xFFAF52DE)),
        CategoriesCompanion.insert(id: 'cat_travel', name: 'Travel', budgetType: 'wants', icon: const Value('airplane'), colorValue: const Value(0xFF5AC8FA)),
        CategoriesCompanion.insert(id: 'cat_shopping', name: 'Shopping', budgetType: 'wants', icon: const Value('bag'), colorValue: const Value(0xFFFFCC00)),
        CategoriesCompanion.insert(id: 'cat_subscriptions', name: 'Subscriptions', budgetType: 'wants', icon: const Value('repeat'), colorValue: const Value(0xFF8E8E93)),
        // FUTURE (20%)
        CategoriesCompanion.insert(id: 'cat_investments', name: 'Investments', budgetType: 'future', icon: const Value('chart.bar'), colorValue: const Value(0xFF30D158)),
        CategoriesCompanion.insert(id: 'cat_savings', name: 'Savings', budgetType: 'future', icon: const Value('banknote'), colorValue: const Value(0xFF32ADE6)),
        CategoriesCompanion.insert(id: 'cat_debt', name: 'Debt Repayment', budgetType: 'future', icon: const Value('creditcard'), colorValue: const Value(0xFFFF6482)),
      ]);
    });
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'wealth_orbit.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
