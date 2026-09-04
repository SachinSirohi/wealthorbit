import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../database/database.dart';
import '../services/secure_vault.dart';
import '../../core/utils/currency_utils.dart';
import '../../core/amount_sanity.dart';

/// Status marking the counter-leg of a matched transfer.
///
/// When two rows are recognised as one movement of money (an outflow on one
/// account and the matching inflow on another) the outflow becomes a
/// `transfer` and the inflow is marked with this status instead of being
/// DELETED, as it used to be. The row stays on file — recoverable if the
/// match was wrong — but is excluded from balances and every aggregate so
/// the money is not counted twice.
const String kMergedStatus = 'merged';

/// Status for rows whose amounts are impossible (AI mis-parses such as a
/// ₹7.5-billion card purchase). They are held rather than deleted so the
/// month is recoverable once the statement is re-extracted correctly.
const String kQuarantinedStatus = 'quarantined';

/// A purchase that also landed on another card/account. Both rows are real
/// statement lines, so neither is deleted — the second is marked and left out
/// of totals, which is what "duplicate spend" actually means. Folding the
/// pair into a transfer (the old behaviour) claimed money moved between the
/// cards, which it never did.
const String kDuplicateStatus = 'duplicate';

/// Row states that must never reach a balance or any aggregate.
const List<String> kHiddenStatuses = [
  kMergedStatus,
  kQuarantinedStatus,
  kDuplicateStatus,
];

/// Row states hidden from the transaction LIST too. A duplicate stays
/// visible (badged) so it can be restored; a merged counter-leg does not,
/// because the transfer row already stands for it.
const List<String> kLedgerHiddenStatuses = [kMergedStatus, kQuarantinedStatus];

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

  /// Close the singleton so a restored sqlite file can replace it.
  static Future<void> closeForRestore() async {
    await _database?.close();
    _database = null;
    _instance = null;
  }

  Future<void> checkpointWal() => _db.checkpointWal();
  
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
      // A brokerage account's balance is net contributions, not cash; its
      // worth is the holdings on the Invest tab. Counting both double-counts.
      if (a.type == 'brokerage') continue;
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
    (_db.select(_db.transactions)
      ..where((t) => t.status.isIn(kLedgerHiddenStatuses).not())
      ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).get();
  
  Stream<List<Transaction>> watchAllTransactions() =>
    (_db.select(_db.transactions)
      ..where((t) => t.status.isIn(kLedgerHiddenStatuses).not())
      ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).watch();
  
  Future<List<Transaction>> getTransactionsByDateRange(DateTime start, DateTime end) =>
    (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBetweenValues(start, end)
        & t.status.isIn(kLedgerHiddenStatuses).not())
      ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).get();
  
  Future<List<Transaction>> getTransactionsByCategory(String categoryId) =>
    (_db.select(_db.transactions)
      ..where((t) => t.categoryId.equals(categoryId)
        & t.status.isIn(kLedgerHiddenStatuses).not())
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

  /// Delete AI-misparsed mega-amounts and reset affected account anchors.
  /// Returns how many rows were removed.
  Future<int> quarantineAbsurdTransactions() async {
    final all = await (_db.select(_db.transactions)
      ..where((t) => t.status.equals(kQuarantinedStatus).not())).get();
    final doomed = <Transaction>[];
    for (final t in all) {
      if (!AmountSanity.isPlausible(t.amountSource, t.currencyCode)) {
        doomed.add(t);
      }
    }
    if (doomed.isEmpty) return 0;

    final accounts = <String>{};
    final statements = <String>{};
    for (final t in doomed) {
      accounts.add(t.accountId);
      if (t.sourceStatementId != null) statements.add(t.sourceStatementId!);
      // Mark, do not delete. These rows are mis-parses, but deleting them
      // destroyed the only record that the month had data at all, while the
      // statement stayed `completed` and could never be re-extracted.
      await (_db.update(_db.transactions)..where((x) => x.id.equals(t.id))).write(
        const TransactionsCompanion(status: Value(kQuarantinedStatus)),
      );
      debugPrint(
          '🧹 Quarantined absurd ${t.amountSource} ${t.currencyCode} · ${t.description}');
    }

    // Re-open the statements these rows came from so a corrected parse can
    // replace them on the next sync.
    for (final id in statements) {
      await (_db.update(_db.statementQueue)..where((q) => q.id.equals(id))).write(
        const StatementQueueCompanion(
          status: Value('pending'),
          errorMessage: Value('Re-queued: previous extraction produced impossible amounts'),
        ),
      );
    }

    for (final id in accounts) {
      // Drop stale closing-date gate + opening so the next good statement can
      // re-anchor. Until then, balance = Σ remaining tx effects.
      await (_db.delete(_db.appSettings)..where((s) => s.key.equals('closing_date_$id'))).go();
      await (_db.update(_db.accounts)..where((a) => a.id.equals(id)))
          .write(const AccountsCompanion(openingBalance: Value(0)));
      await recomputeAccountBalance(id);
    }
    return doomed.length;
  }

  /// Statements that need the user's attention: hard failures plus the ones
  /// that "succeeded" without importing anything. The `empty` bucket used to
  /// be recorded as `completed`, which is why a run could report success
  /// while the ledger stayed unchanged.
  /// One-shot repair for accounts the old, over-broad credit-card heuristic
  /// converted from bank to card.
  ///
  /// `isCreditCardHint` used to match any text containing "card" or "credit",
  /// so a savings account at a card-issuing bank was retyped as a credit card
  /// and its positive balance re-signed as debt — which is how a savings
  /// account came to show millions in "debt". Accounts whose senders show no
  /// real card vocabulary are put back to `bank`, their bogus opening balance
  /// cleared, and their closing-balance gate dropped so the next statement
  /// re-anchors them correctly.
  Future<int> repairMiscardedAccounts() async {
    final accounts = await getAllAccounts();
    final sources = await getAllStatementSources();
    int repaired = 0;
    for (final a in accounts) {
      if (a.type != 'credit_card') continue;
      final senderHints = sources
          .where((s) => s.accountId == a.id)
          .map((s) => s.senderEmail)
          .join(' ');
      // Keep it a card if a mapped sender really is a card sender, or if the
      // user named it as one. Otherwise this was a mis-retype.
      if (CurrencyUtils.isCreditCardHint('$senderHints ${a.name}')) continue;

      await (_db.update(_db.accounts)..where((x) => x.id.equals(a.id)))
          .write(const AccountsCompanion(
        type: Value('bank'),
        openingBalance: Value(0),
      ));
      await (_db.delete(_db.appSettings)
            ..where((x) => x.key.equals('closing_date_${a.id}')))
          .go();
      await recomputeAccountBalance(a.id);
      repaired++;
      debugPrint('🩹 Repaired mis-typed card account ${a.name} → bank');
    }

    // Cards that legitimately stay cards can still carry a corrupt anchor
    // (years of spend with none of the payments matched). Where the balance
    // is not even a plausible amount of money, drop the anchor so the next
    // real statement re-establishes it instead of compounding.
    for (final a in await getAllAccounts()) {
      if (a.type != 'credit_card') continue;
      if (AmountSanity.isPlausible(a.balance.abs(), a.currencyCode)) continue;
      await (_db.update(_db.accounts)..where((x) => x.id.equals(a.id)))
          .write(const AccountsCompanion(openingBalance: Value(0)));
      await (_db.delete(_db.appSettings)
            ..where((x) => x.key.equals('closing_date_${a.id}')))
          .go();
      await recomputeAccountBalance(a.id);
      repaired++;
      debugPrint('🩹 Cleared implausible anchor on card ${a.name} '
          '(was ${a.balance} ${a.currencyCode})');
    }
    return repaired;
  }

  Future<List<StatementQueueData>> getFailedStatementQueue() =>
    (_db.select(_db.statementQueue)
      ..where((t) => t.status.isIn(['failed', 'empty']))
      ..orderBy([(t) => OrderingTerm.desc(t.processedAt)]))
      .get();

  /// Re-queue failed items (optionally only LLM timeouts).
  Future<int> requeueFailedStatements({bool timeoutsOnly = false}) async {
    final failed = await getFailedStatementQueue();
    int n = 0;
    for (final item in failed) {
      final err = (item.errorMessage ?? '').toLowerCase();
      if (timeoutsOnly && !err.contains('timeout')) continue;
      // Skip insurance / survey subjects forever.
      if (isNonBankStatementSubject(item.subject)) continue;
      await updateStatementQueueStatus(item.id, 'pending', errorMessage: null);
      n++;
    }
    return n;
  }

  Future<void> requeueStatementItem(String id) =>
      updateStatementQueueStatus(id, 'pending', errorMessage: null);

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
      ..where((t) => t.accountId.equals(accountId)
        & t.status.isIn(kHiddenStatuses).not())).get();
    final asTarget = await (_db.select(_db.transactions)
      ..where((t) => t.transferAccountId.equals(accountId)
        & t.status.isIn(kHiddenStatuses).not())).get();
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
      // Money enters the target in ITS currency: a cross-currency transfer
      // carries the arriving amount in toAmount. Crediting amountSource here
      // used to book an AED 5,000 remittance as ₹5,000 on the INR side.
      if (t.type == 'transfer') bal += t.toAmount ?? t.amountSource;
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
    double? toAmount,
    double? feeAmount,
  }) async {
    if (fromAccountId == toAccountId || amount <= 0) return;
    final from = await getAccount(fromAccountId);
    final to = await getAccount(toAccountId);
    final code = from?.currencyCode ?? currencyCode;
    final toCode = to?.currencyCode ?? code;
    final amountBase = await toBase(amount, code);

    // Cross-currency: what ARRIVES is a different number. Use the caller's
    // figure (from the remittance receipt) or convert at today's rate.
    double? arriving = toAmount;
    if (toCode != code && arriving == null) {
      final toRate = (await getCurrency(toCode))?.rateToBase ?? 1.0;
      arriving = amountBase / toRate;
    }

    await insertTransaction(TransactionsCompanion.insert(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      accountId: fromAccountId,
      transferAccountId: Value(toAccountId),
      amountSource: amount,
      amountBase: amountBase,
      currencyCode: code,
      toAmount: Value(toCode != code ? arriving : null),
      toCurrency: Value(toCode != code ? toCode : null),
      description: (note != null && note.isNotEmpty) ? note : 'Transfer',
      type: 'transfer',
      txnClass: const Value('own_transfer'),
      transactionDate: date,
    ));

    if (feeAmount != null && feeAmount > 0) {
      await bookTransferFee(
        accountId: fromAccountId,
        amount: feeAmount,
        date: date,
        description: 'Transfer fee · ${(note != null && note.isNotEmpty) ? note : 'Transfer'}',
      );
    }
  }

  /// Book a bank / remittance / FX charge as its own expense line so the
  /// gap between "sent" and "received" is visible as a fee, not lost.
  Future<void> bookTransferFee({
    required String accountId,
    required double amount,
    required DateTime date,
    required String description,
  }) async {
    if (amount <= 0) return;
    final acc = await getAccount(accountId);
    final code = acc?.currencyCode ?? 'AED';
    await insertTransaction(TransactionsCompanion.insert(
      id: 'fee_${DateTime.now().microsecondsSinceEpoch}',
      accountId: accountId,
      amountSource: amount,
      amountBase: await toBase(amount, code),
      currencyCode: code,
      description: description,
      type: 'expense',
      categoryId: const Value('cat_fees'),
      txnClass: const Value('fee'),
      status: const Value('cleared'),
      transactionDate: date,
    ));
  }

  /// Convert an expense+income pair into a transfer (or CC payment). Returns
  /// true when applied. The expense becomes the transfer row; the income row
  /// is deleted (its effect is the transfer credit on the destination).
  Future<bool> applyTransferPair({
    required String fromTxnId,
    required String toTxnId,
    required String kind,
  }) async {
    final out = await (_db.select(_db.transactions)..where((t) => t.id.equals(fromTxnId))).getSingleOrNull();
    final inc = await (_db.select(_db.transactions)..where((t) => t.id.equals(toTxnId))).getSingleOrNull();
    if (out == null || inc == null) return false;
    if (out.type == 'transfer' || inc.type == 'transfer') return false;
    if (out.accountId == inc.accountId) return false;

    // Prefer expense → income orientation; if swapped, flip.
    Transaction source = out;
    Transaction target = inc;
    if (out.type == 'income' && inc.type == 'expense') {
      source = inc;
      target = out;
    }

    final amountBase = await toBase(source.amountSource, source.currencyCode);
    final crossCurrency = source.currencyCode != target.currencyCode;
    // The matched inflow tells us EXACTLY what arrived — so a cross-currency
    // pair credits the destination correctly, and any shortfall (bank charge
    // or FX spread) is booked as a fee rather than vanishing.
    final targetBase = await toBase(target.amountSource, target.currencyCode);
    final shortfallBase = amountBase - targetBase;
    await (_db.update(_db.transactions)..where((t) => t.id.equals(source.id))).write(
      TransactionsCompanion(
        type: const Value('transfer'),
        transferAccountId: Value(target.accountId),
        amountBase: Value(amountBase),
        toAmount: Value(crossCurrency || (source.amountSource - target.amountSource).abs() > 0.01
            ? target.amountSource
            : null),
        toCurrency: Value(crossCurrency ? target.currencyCode : null),
        txnClass: Value(kind == 'cc_payment' ? 'cc_payment' : 'own_transfer'),
        status: const Value('cleared'),
        linkedTransactionId: Value(target.id),
        categoryId: const Value(null),
        description: Value(
          kind == 'cc_payment'
              ? (source.description.toLowerCase().contains('credit')
                  ? source.description
                  : 'Credit Card Payment · ${source.description}')
              : source.description,
        ),
      ),
    );
    // The counter-leg is retained, marked merged, so an incorrect AI match
    // can be reversed instead of permanently erasing the row.
    await (_db.update(_db.transactions)..where((t) => t.id.equals(target.id))).write(
      TransactionsCompanion(
        status: const Value(kMergedStatus),
        linkedTransactionId: Value(source.id),
      ),
    );

    // Fee = what left minus what arrived (in base). Ignore rounding noise.
    if (shortfallBase > 0.5) {
      final sourceRate = (await getCurrency(source.currencyCode))?.rateToBase ?? 1.0;
      await bookTransferFee(
        accountId: source.accountId,
        amount: shortfallBase / sourceRate,
        date: source.transactionDate,
        description: crossCurrency
            ? 'FX / remittance fee · ${source.description}'
            : 'Transfer fee · ${source.description}',
      );
    }

    // Drop any suggested_matches that referenced either side.
    await (_db.delete(_db.suggestedMatches)
          ..where((s) => s.fromTxnId.isIn([source.id, target.id]) | s.toTxnId.isIn([source.id, target.id])))
        .go();

    final toAccount = await getAccount(target.accountId);
    if (kind == 'cc_payment' || toAccount?.type == 'credit_card') {
      if (toAccount?.linkedLiabilityId != null) {
        final liab = await (_db.select(_db.liabilities)
          ..where((l) => l.id.equals(toAccount!.linkedLiabilityId!))).getSingleOrNull();
        if (liab != null) {
          final newOutstanding =
              (liab.outstandingAmount - source.amountSource).clamp(0.0, double.infinity);
          await updateLiability(
              liab.id, LiabilitiesCompanion(outstandingAmount: Value(newOutstanding)));
        }
      }
    }

    await recomputeAccountBalance(source.accountId);
    await recomputeAccountBalance(target.accountId);
    return true;
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
  
  /// Total expenses for a calendar month, in base currency.
  ///
  /// The upper bound is the FIRST INSTANT OF THE NEXT MONTH, exclusive.
  /// `DateTime(year, month + 1, 0)` is the last day at 00:00:00, which
  /// silently excluded anything timestamped later on that final day.
  Future<double> getTotalExpensesByMonth(int year, int month) async {
    final start = DateTime(year, month, 1);
    final end = DateTime(year, month + 1, 1);
    final transactions = await (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBiggerOrEqualValue(start))
      ..where((t) => t.transactionDate.isSmallerThanValue(end))
      ..where((t) => t.type.equals('expense'))
      ..where((t) => t.status.isIn(kHiddenStatuses).not())).get();
    double total = 0.0;
    for (final t in transactions) {
      total += t.amountBase;
    }
    return total;
  }
  
  Future<double> getTotalIncomeByMonth(int year, int month) async {
    final start = DateTime(year, month, 1);
    final end = DateTime(year, month + 1, 1);
    final transactions = await (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBiggerOrEqualValue(start))
      ..where((t) => t.transactionDate.isSmallerThanValue(end))
      ..where((t) => t.type.equals('income'))
      ..where((t) => t.status.isIn(kHiddenStatuses).not())).get();
    double total = 0.0;
    for (final t in transactions) {
      total += t.amountBase;
    }
    return total;
  }
  
  /// How many real (non-hidden) transactions a calendar month holds.
  /// The coach uses this to refuse to score a month it has no data for.
  Future<int> countTransactionsInMonth(int year, int month) async {
    final start = DateTime(year, month, 1);
    final end = DateTime(year, month + 1, 1);
    final rows = await (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBiggerOrEqualValue(start))
      ..where((t) => t.transactionDate.isSmallerThanValue(end))
      ..where((t) => t.type.isIn(['income', 'expense']))
      ..where((t) => t.status.isIn(kHiddenStatuses).not())).get();
    return rows.length;
  }

  /// Statements that failed or imported nothing — when this is non-zero the
  /// ledger is known to be incomplete, whatever the totals say.
  Future<int> countStatementsNeedingAttention() async =>
      (await getFailedStatementQueue()).length;

  Future<Map<String, double>> getExpensesByCategory(DateTime start, DateTime end) async {
    final transactions = await (_db.select(_db.transactions)
      ..where((t) => t.transactionDate.isBetweenValues(start, end))
      ..where((t) => t.type.equals('expense'))
      ..where((t) => t.status.isIn(kHiddenStatuses).not())).get();
    
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
  
  /// Get monthly expenses for the last N months, most recent last.
  /// Includes the month in progress — for trend charts, not for averages.
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

  /// The last [months] COMPLETE months of expenses, excluding the month in
  /// progress. Averaging a partial month drags the mean toward zero, which
  /// is what inflated the emergency-fund runway to hundreds of months.
  Future<List<double>> getCompletedMonthlyExpenses(int months) async {
    final result = <double>[];
    final now = DateTime.now();
    for (int i = months; i >= 1; i--) {
      final date = DateTime(now.year, now.month - i, 1);
      result.add(await getTotalExpensesByMonth(date.year, date.month));
    }
    return result;
  }
  
  /// Average monthly expenses over the last [months] COMPLETE months.
  /// Months with no data at all are excluded so a gap in imports cannot
  /// halve the average.
  Future<double> getAverageMonthlyExpenses({int months = 6}) async {
    final expenses = (await getCompletedMonthlyExpenses(months))
        .where((e) => e > 0)
        .toList();
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
      if (a.type == 'credit_card' || a.type == 'brokerage') continue;
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
      // Card debt is the card ACCOUNT's negative balance (added below). A
      // Liabilities row of type credit_card is the same debt entered twice.
      if (l.type == 'credit_card') continue;
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
      ..orderBy([
        (t) => OrderingTerm(expression: t.emailDate, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.queuedAt, mode: OrderingMode.desc),
      ]))
      .get();
      
  Future<void> insertStatementQueueItem(StatementQueueCompanion item) =>
    _db.into(_db.statementQueue).insert(item);

  /// Look up a queue row by mailbox + UID. IMAP UIDs repeat across mailboxes,
  /// so [accountEmail] is what makes the lookup unambiguous; rows created
  /// before the column existed are matched on UID alone.
  Future<StatementQueueData?> getQueueItemByEmailId(
    String emailId, {
    String? accountEmail,
  }) async {
    final rows = await (_db.select(_db.statementQueue)
      ..where((q) => q.emailId.equals(emailId))).get();
    if (rows.isEmpty) return null;
    if (accountEmail == null || accountEmail.isEmpty) return rows.first;
    for (final r in rows) {
      if (r.accountEmail == accountEmail) return r;
    }
    // Adopt a legacy row that predates mailbox tracking.
    for (final r in rows) {
      if (r.accountEmail == null) return r;
    }
    return null;
  }

  /// Stable primary key for a queue row: mailbox-namespaced where known.
  static String queueRowId(String emailId, String? accountEmail) =>
      (accountEmail == null || accountEmail.isEmpty)
          ? 'q_$emailId'
          : 'q_${accountEmail.toLowerCase()}_$emailId';

  /// Insert or update a queue row keyed by IMAP UID. Skips no-op inserts when
  /// the UID is already present unless [status] is a terminal state.
  Future<void> recordQueuedEmail({
    required String emailId,
    required String subject,
    required DateTime emailDate,
    String? sourceId,
    String? accountEmail,
    String status = 'pending',
    String? errorMessage,
  }) async {
    if (emailId.isEmpty || emailId == 'manual_upload') return;
    if (isNonBankStatementSubject(subject)) {
      // Persist as failed so we don't keep rediscovering it.
      status = 'failed';
    }
    final existing = await getQueueItemByEmailId(emailId, accountEmail: accountEmail);
    if (existing != null) {
      // Backfill the mailbox on rows queued before the column existed, and
      // attach a source that was mapped after the row was first queued —
      // an unmapped sourceId is why some items could never find a password.
      if ((existing.accountEmail == null && accountEmail != null) ||
          (existing.sourceId == null && sourceId != null)) {
        await (_db.update(_db.statementQueue)..where((q) => q.id.equals(existing.id)))
            .write(StatementQueueCompanion(
          accountEmail: Value(existing.accountEmail ?? accountEmail),
          sourceId: Value(existing.sourceId ?? sourceId),
        ));
      }
      if (status != existing.status &&
          (status == 'completed' || status == 'failed' || existing.status == 'processing')) {
        await updateStatementQueueStatus(
          existing.id,
          status,
          errorMessage: isNonBankStatementSubject(subject)
              ? 'Skipped: not a bank statement'
              : errorMessage,
        );
      }
      return;
    }
    await insertStatementQueueItem(StatementQueueCompanion.insert(
      id: queueRowId(emailId, accountEmail),
      emailId: emailId,
      accountEmail: Value(accountEmail),
      sourceId: Value(sourceId),
      subject: subject,
      emailDate: emailDate,
      status: Value(status),
      errorMessage: Value(isNonBankStatementSubject(subject)
          ? 'Skipped: not a bank statement'
          : errorMessage),
      processedAt: const ['completed', 'failed', 'empty'].contains(status)
          ? Value(DateTime.now())
          : const Value.absent(),
    ));
  }

  /// Rows left in `processing` after a killed worker block the queue.
  Future<int> resetStuckProcessing() async {
    return (_db.update(_db.statementQueue)..where((q) => q.status.equals('processing')))
        .write(const StatementQueueCompanion(status: Value('pending')));
  }
    
  Future<void> updateStatementQueueStatus(String id, String status, {String? errorMessage}) {
    const terminal = ['completed', 'failed', 'empty'];
    return (_db.update(_db.statementQueue)..where((t) => t.id.equals(id))).write(
      StatementQueueCompanion(
        status: Value(status),
        errorMessage: Value(errorMessage),
        processedAt: terminal.contains(status) ? Value(DateTime.now()) : const Value.absent(),
      ),
    );
  }
  
  Future<void> deleteStatementQueueItem(String id) =>
    (_db.delete(_db.statementQueue)..where((t) => t.id.equals(id))).go();
    
  /// Send already-processed statements back through extraction.
  ///
  /// Import guards have rejected real lines in the past (an over-tight
  /// outlier test dropped large but genuine purchases). Those statements are
  /// marked `completed`, so nothing would ever look at them again. Re-running
  /// is safe: transaction-level dedupe skips everything already imported, so
  /// only the previously-missing lines are added. Returns how many were
  /// re-queued.
  Future<int> requeueCompletedStatements() async {
    final rows = await (_db.select(_db.statementQueue)
      ..where((q) => q.status.equals('completed'))).get();
    int n = 0;
    for (final row in rows) {
      if (row.emailId == 'manual_upload') continue; // the PDF is long gone
      await updateStatementQueueStatus(row.id, 'pending', errorMessage: null);
      n++;
    }
    return n;
  }

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
  /// Heuristic pass: fold an outflow and the matching inflow on another
  /// account into a single transfer.
  ///
  /// Two rules here exist because their absence corrupted real data:
  ///
  /// 1. CURRENCY MUST MATCH. The old comparison was on `amountSource`
  ///    alone, so an INR 5,000 debit and an AED 5,000 credit three days
  ///    apart were "the same transfer" — and the credit was destroyed.
  ///    Only same-currency pairs are folded here; cross-currency matching
  ///    goes through the AI matcher, which compares `amountBase`.
  /// 2. NOTHING IS DELETED. The inflow is marked [kMergedStatus] rather
  ///    than removed, so a wrong match is reversible and never silently
  ///    erases income.
  Future<int> detectInterAccountTransfers({int daysBack = 90}) async {
    final cutoff = DateTime.now().subtract(Duration(days: daysBack));
    final all = await (_db.select(_db.transactions)
      ..where((t) => t.type.isIn(['income', 'expense'])
        & t.status.isIn(kHiddenStatuses).not()
        & t.transactionDate.isBiggerOrEqualValue(cutoff))
      ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)])).get();
    final incomes = all.where((t) => t.type == 'income').toList();
    final expenses = all.where((t) => t.type == 'expense').toList();
    final consumed = <String>{};
    final touched = <String>{};
    int converted = 0;

    for (final out in expenses) {
      if (consumed.contains(out.id)) continue;
      for (final inc in incomes) {
        if (consumed.contains(inc.id)) continue;
        if (inc.accountId == out.accountId) continue;
        if (inc.currencyCode != out.currencyCode) continue;
        if ((inc.amountSource - out.amountSource).abs() > 0.01) continue;
        if (inc.transactionDate.difference(out.transactionDate).inDays.abs() > 3) continue;

        // The expense row becomes the transfer (source -> target); the
        // income row is retained but marked merged so it is excluded from
        // balances and aggregates without being lost.
        await (_db.update(_db.transactions)..where((t) => t.id.equals(out.id))).write(
          TransactionsCompanion(
            type: const Value('transfer'),
            transferAccountId: Value(inc.accountId),
            status: const Value('cleared'),
            linkedTransactionId: Value(inc.id),
            categoryId: const Value(null),
          ),
        );
        await (_db.update(_db.transactions)..where((t) => t.id.equals(inc.id))).write(
          TransactionsCompanion(
            status: const Value(kMergedStatus),
            linkedTransactionId: Value(out.id),
          ),
        );
        consumed..add(out.id)..add(inc.id);
        touched..add(out.accountId)..add(inc.accountId);
        converted++;
        break;
      }
    }
    for (final id in touched) {
      await recomputeAccountBalance(id);
    }
    return converted;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MONEY-MOVEMENT RULES (broker funding, cash withdrawals, EMIs, classed
  // transfers). Each pass is idempotent: it only touches rows it has not
  // already converted, so running it on every sync is safe.
  // ═══════════════════════════════════════════════════════════════════════════

  static final RegExp _brokerRx = RegExp(
      r'zerodha|groww|upstox|angel ?one|5paisa|icici ?direct|hdfc ?sec|kotak ?sec|'
      r'paytm ?money|kuvera|coin\b|smallcase|indian clearing|cdsl|nsdl|\bnps\b|npst|'
      r'\bmf\b|mutual fund|\bsip\b|bse ?star|camsonline|kfintech');
  static final RegExp _atmRx = RegExp(
      r'\batm\b|cash ?w(ith)?d(rawa)?l|cash withdrawal|\bcwd\b|csh wdl|self ?cheque');
  static final RegExp _emiRx = RegExp(r'\bemi\b|\bloan\b|instal?l?ment|\bnach\b|\bach\b');

  /// Accounts whose statements come from a broker/demat sender become
  /// `brokerage`, so they leave cash totals and read as "net contributions".
  Future<int> retypeBrokerageAccounts() async {
    final accounts = await getAllAccounts();
    final sources = await getAllStatementSources();
    int n = 0;
    for (final a in accounts) {
      if (a.type == 'brokerage' || a.type == 'credit_card') continue;
      final senders = sources
          .where((x) => x.accountId == a.id)
          .map((x) => '${x.senderEmail} ${x.bankName} ${x.accountType}')
          .join(' ');
      final hay = '${a.name} $senders'.toLowerCase();
      final isBroker = senders.contains('brokerage') ||
          RegExp(r'zerodha|groww|upstox|angel ?one|5paisa|icici ?direct|hdfc ?sec|'
                  r'kotak ?sec|paytm ?money|kuvera|camsnps|npscra|protean|\bnps\b')
              .hasMatch(hay);
      if (!isBroker) continue;
      await (_db.update(_db.accounts)..where((x) => x.id.equals(a.id)))
          .write(const AccountsCompanion(type: Value('brokerage')));
      n++;
      debugPrint('📈 Retyped ${a.name} as brokerage');
    }
    return n;
  }

  /// Money sent to a broker is an INVESTMENT CONTRIBUTION, not spending; a
  /// payout from a broker is not income. Both become transfers against the
  /// brokerage account so budgets and the savings rate stop mis-reading them.
  Future<int> convertBrokerFunding({int daysBack = 400}) async {
    final accounts = await getAllAccounts();
    final brokers = accounts.where((a) => a.type == 'brokerage').toList();
    if (brokers.isEmpty) return 0;
    final cutoff = DateTime.now().subtract(Duration(days: daysBack));
    final rows = await (_db.select(_db.transactions)
      ..where((t) => t.type.isIn(['income', 'expense'])
        & t.status.isIn(kHiddenStatuses).not()
        & t.transactionDate.isBiggerOrEqualValue(cutoff))).get();
    final byId = {for (final a in accounts) a.id: a};
    final touched = <String>{};
    int n = 0;
    for (final t in rows) {
      final acc = byId[t.accountId];
      if (acc == null || acc.type == 'brokerage' || acc.type == 'credit_card') continue;
      final hay = '${t.description} ${t.merchant ?? ''}'.toLowerCase();
      if (!_brokerRx.hasMatch(hay)) continue;
      // Prefer the broker in the same currency; else the only/first one.
      final broker = brokers.firstWhere(
          (b) => b.currencyCode == t.currencyCode,
          orElse: () => brokers.first);
      if (t.type == 'expense') {
        await (_db.update(_db.transactions)..where((x) => x.id.equals(t.id))).write(
          TransactionsCompanion(
            type: const Value('transfer'),
            transferAccountId: Value(broker.id),
            categoryId: const Value(null),
            txnClass: const Value('investment'),
            status: const Value('cleared'),
          ),
        );
      } else {
        // Payout: the broker is the source, this account the destination.
        await (_db.update(_db.transactions)..where((x) => x.id.equals(t.id))).write(
          TransactionsCompanion(
            type: const Value('transfer'),
            accountId: Value(broker.id),
            transferAccountId: Value(t.accountId),
            categoryId: const Value(null),
            txnClass: const Value('investment'),
            status: const Value('cleared'),
          ),
        );
      }
      touched..add(t.accountId)..add(broker.id);
      n++;
    }
    for (final id in touched) {
      await recomputeAccountBalance(id);
    }
    return n;
  }

  /// An ATM withdrawal moves money to your pocket; it is not yet spent.
  /// Route it to a per-currency "Cash" wallet so cash spending can be logged
  /// from there and the bank account still reconciles.
  Future<int> convertAtmWithdrawals({int daysBack = 400}) async {
    final cutoff = DateTime.now().subtract(Duration(days: daysBack));
    final rows = await (_db.select(_db.transactions)
      ..where((t) => t.type.equals('expense')
        & t.status.isIn(kHiddenStatuses).not()
        & t.transactionDate.isBiggerOrEqualValue(cutoff))).get();
    final touched = <String>{};
    int n = 0;
    for (final t in rows) {
      final hay = '${t.description} ${t.merchant ?? ''}'.toLowerCase();
      if (!_atmRx.hasMatch(hay)) continue;
      final wallet = await _ensureCashWallet(t.currencyCode);
      if (wallet.id == t.accountId) continue;
      await (_db.update(_db.transactions)..where((x) => x.id.equals(t.id))).write(
        TransactionsCompanion(
          type: const Value('transfer'),
          transferAccountId: Value(wallet.id),
          categoryId: const Value(null),
          txnClass: const Value('own_transfer'),
          status: const Value('cleared'),
        ),
      );
      touched..add(t.accountId)..add(wallet.id);
      n++;
    }
    for (final id in touched) {
      await recomputeAccountBalance(id);
    }
    return n;
  }

  Future<Account> _ensureCashWallet(String currencyCode) async {
    final id = 'cash_${currencyCode.toLowerCase()}';
    final existing = await getAccount(id);
    if (existing != null) return existing;
    await insertAccount(AccountsCompanion.insert(
      id: id,
      name: 'Cash ($currencyCode)',
      type: 'wallet',
      currencyCode: currencyCode,
    ));
    return (await getAccount(id))!;
  }

  /// Imported EMI debits reduce the matching loan's outstanding balance by
  /// their principal portion (EMI − this month's interest). Without this the
  /// Liabilities screen never moves no matter how many instalments clear.
  Future<int> linkEmiPayments({int daysBack = 400}) async {
    final liabilities = (await getActiveLiabilities())
        .where((l) => l.type != 'credit_card' && l.emi > 0)
        .toList();
    if (liabilities.isEmpty) return 0;
    final cutoff = DateTime.now().subtract(Duration(days: daysBack));
    final rows = await (_db.select(_db.transactions)
      ..where((t) => t.type.equals('expense')
        & t.liabilityId.isNull()
        & t.status.isIn(kHiddenStatuses).not()
        & t.transactionDate.isBiggerOrEqualValue(cutoff))
      ..orderBy([(t) => OrderingTerm.asc(t.transactionDate)])).get();
    int n = 0;
    for (final t in rows) {
      final hay = '${t.description} ${t.merchant ?? ''}'.toLowerCase();
      for (final l in liabilities) {
        if (l.currencyCode != t.currencyCode) continue;
        if ((t.amountSource - l.emi).abs() > l.emi * 0.02) continue;
        final nameHit = l.name.toLowerCase().split(RegExp(r'\s+'))
                .where((w) => w.length >= 4)
                .any((w) => hay.contains(w)) ||
            (l.institution ?? '').toLowerCase().split(RegExp(r'\s+'))
                .where((w) => w.length >= 4)
                .any((w) => hay.contains(w));
        if (!nameHit && !_emiRx.hasMatch(hay)) continue;

        // Annual rate may be stored as 0.085 or as 8.5 — normalise.
        final rate = l.interestRate > 1 ? l.interestRate / 100 : l.interestRate;
        final current = (await (_db.select(_db.liabilities)
              ..where((x) => x.id.equals(l.id))).getSingle());
        final interest = current.outstandingAmount * rate / 12;
        final principal = (t.amountSource - interest).clamp(0.0, t.amountSource);
        await updateLiability(
          l.id,
          LiabilitiesCompanion(
            outstandingAmount: Value(
                (current.outstandingAmount - principal).clamp(0.0, double.infinity)),
          ),
        );
        await (_db.update(_db.transactions)..where((x) => x.id.equals(t.id))).write(
          TransactionsCompanion(
            liabilityId: Value(l.id),
            categoryId: const Value('cat_debt'),
            txnClass: const Value('debt'),
            status: const Value('cleared'),
          ),
        );
        n++;
        break;
      }
    }
    return n;
  }

  /// Transfers the statement itself labelled as such. A line classed
  /// `cc_payment` / `own_transfer` on one account, with a matching inflow on
  /// another within 5 days, is folded even across currencies (base amount
  /// within 3%) — the class is a strong enough prior for that.
  Future<int> detectClassedTransfers({int daysBack = 120}) async {
    final accounts = await getAllAccounts();
    if (accounts.length < 2) return 0;
    final byId = {for (final a in accounts) a.id: a};
    final cutoff = DateTime.now().subtract(Duration(days: daysBack));
    final rows = await (_db.select(_db.transactions)
      ..where((t) => t.type.isIn(['income', 'expense'])
        & t.status.isIn(kHiddenStatuses).not()
        & t.transactionDate.isBiggerOrEqualValue(cutoff))).get();
    final outs = rows.where((t) => t.type == 'expense' &&
        (t.txnClass == 'cc_payment' || t.txnClass == 'own_transfer')).toList();
    final ins = rows.where((t) => t.type == 'income').toList();
    final used = <String>{};
    int n = 0;
    for (final out in outs) {
      if (used.contains(out.id)) continue;
      Transaction? best;
      double bestScore = 0;
      for (final inc in ins) {
        if (used.contains(inc.id) || inc.accountId == out.accountId) continue;
        if (inc.transactionDate.difference(out.transactionDate).inDays.abs() > 5) continue;
        final target = byId[inc.accountId];
        if (out.txnClass == 'cc_payment' && target?.type != 'credit_card') continue;
        double score;
        if (inc.currencyCode == out.currencyCode) {
          final diff = (inc.amountSource - out.amountSource).abs();
          if (diff > out.amountSource * 0.01 && diff > 0.01) continue;
          score = 1 - diff / (out.amountSource == 0 ? 1 : out.amountSource);
        } else {
          final larger = out.amountBase > inc.amountBase ? out.amountBase : inc.amountBase;
          if (larger <= 0) continue;
          final diff = (out.amountBase - inc.amountBase).abs() / larger;
          if (diff > 0.03) continue;
          score = 0.9 - diff;
        }
        if (score > bestScore) {
          bestScore = score;
          best = inc;
        }
      }
      if (best == null) continue;
      final ok = await applyTransferPair(
        fromTxnId: out.id,
        toTxnId: best.id,
        kind: out.txnClass == 'cc_payment' ? 'cc_payment' : 'own_transfer',
      );
      if (ok) {
        used..add(out.id)..add(best.id);
        n++;
      }
    }
    return n;
  }

  /// Record that [dupeId] is the same real-world purchase as [keepId] on
  /// another card. The duplicate keeps its row and stays visible in the
  /// ledger, but leaves every total.
  Future<bool> markDuplicateSpend({
    required String keepId,
    required String dupeId,
  }) async {
    final keep = await getTransactionById(keepId);
    final dupe = await getTransactionById(dupeId);
    if (keep == null || dupe == null || keep.id == dupe.id) return false;
    if (dupe.status == kDuplicateStatus) return true;
    await (_db.update(_db.transactions)..where((t) => t.id.equals(dupe.id))).write(
      TransactionsCompanion(
        status: const Value(kDuplicateStatus),
        linkedTransactionId: Value(keep.id),
      ),
    );
    await recomputeAccountBalance(dupe.accountId);
    return true;
  }

  /// Put a row marked as a duplicate back into the totals.
  Future<bool> restoreDuplicate(String id) async {
    final row = await getTransactionById(id);
    if (row == null || row.status != kDuplicateStatus) return false;
    await (_db.update(_db.transactions)..where((t) => t.id.equals(id))).write(
      const TransactionsCompanion(
        status: Value('cleared'),
        linkedTransactionId: Value(null),
      ),
    );
    await recomputeAccountBalance(row.accountId);
    return true;
  }

  /// Undo a merge made by the transfer matcher: the transfer reverts to its
  /// original expense and the counter-leg returns to the ledger.
  Future<bool> unmergeTransferPair(String transferTxnId) async {
    final row = await getTransactionById(transferTxnId);
    if (row == null || row.type != 'transfer') return false;
    final legId = row.linkedTransactionId;
    if (legId == null) return false;
    final leg = await getTransactionById(legId);
    if (leg == null || leg.status != kMergedStatus) return false;

    await (_db.update(_db.transactions)..where((t) => t.id.equals(row.id))).write(
      const TransactionsCompanion(
        type: Value('expense'),
        transferAccountId: Value(null),
        linkedTransactionId: Value(null),
        status: Value('pending'),
      ),
    );
    await (_db.update(_db.transactions)..where((t) => t.id.equals(leg.id))).write(
      const TransactionsCompanion(
        status: Value('pending'),
        linkedTransactionId: Value(null),
      ),
    );
    await recomputeAccountBalance(row.accountId);
    await recomputeAccountBalance(leg.accountId);
    return true;
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
        // Queue rows FK to statement_sources — re-point before delete or
        // startup merge aborts the rest of launch (FX, card retype, …).
        await (_db.update(_db.statementQueue)..where((q) => q.sourceId.equals(dupe.id)))
          .write(StatementQueueCompanion(sourceId: Value(keep.id)));
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
      // Only the SENDER decides this, never the account name: a savings
      // account at a card-issuing bank shares the bank's name, and matching
      // on it retyped the savings account as a card. Retyping also no longer
      // re-signs the existing balance as debt — that flip is what produced
      // the multi-million "credit card" balances. The next card statement's
      // own closing balance anchors it correctly.
      if (senderHints.isNotEmpty &&
          CurrencyUtils.isCreditCardHint(senderHints)) {
        await (_db.update(_db.accounts)..where((x) => x.id.equals(a.id)))
          .write(const AccountsCompanion(type: Value('credit_card')));
        debugPrint('💳 Retyped ${a.name} as credit_card (sender hint)');
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
    bool hadPreviousAnchor = false;
    if (statementDate != null) {
      final key = 'closing_date_$accountId';
      final prev = await getAppSetting(key);
      final prevDate = prev != null ? DateTime.tryParse(prev) : null;
      hadPreviousAnchor = prevDate != null;
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
      ..where((t) => t.accountId.equals(accountId)
        & t.status.isIn(kHiddenStatuses).not())).get();
    final asTarget = await (_db.select(_db.transactions)
      ..where((t) => t.transferAccountId.equals(accountId)
        & t.status.isIn(kHiddenStatuses).not())).get();
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
      if (t.type == 'transfer') effects += t.toAmount ?? t.amountSource;
    }
    // STATEMENT CHECK. Anchoring forces opening + Σeffects == closing, so
    // the ledger always "agrees" with the bank afterwards. The honest number
    // is how far the anchor had to MOVE to make that true: money the ledger
    // does not explain (missed lines, a failed statement, a mis-parse).
    // Recorded so the Reconciliation screen can show it instead of hiding it.
    final newOpening = closing - effects;
    final drift = hadPreviousAnchor ? newOpening - (account?.openingBalance ?? 0) : 0.0;
    await setAppSetting('anchor_closing_$accountId', closing.toString());
    await setAppSetting('anchor_drift_$accountId', drift.toString());
    if (statementDate != null) {
      await setAppSetting('anchor_date_$accountId', statementDate.toIso8601String());
    }
    await (_db.update(_db.accounts)..where((a) => a.id.equals(accountId)))
      .write(AccountsCompanion(openingBalance: Value(newOpening)));
    await recomputeAccountBalance(accountId);
  }

  /// What the bank last said about an account, and how much of it the
  /// ledger could not explain. Null when no statement has anchored it yet.
  Future<({double closing, DateTime? date, double drift})?> getAnchorInfo(
      String accountId) async {
    final closing = double.tryParse(await getAppSetting('anchor_closing_$accountId') ?? '');
    if (closing == null) return null;
    final date = DateTime.tryParse(await getAppSetting('anchor_date_$accountId') ?? '');
    final drift = double.tryParse(await getAppSetting('anchor_drift_$accountId') ?? '') ?? 0;
    return (closing: closing, date: date, drift: drift);
  }

  /// Record the newest processed mailbox UID for a source (dedupe cursor).
  /// Keeps the maximum — processing an older statement never lowers it.
  Future<void> setSourceLastProcessedUid(String sourceId, int uid) async {
    final source = await getStatementSource(sourceId);
    if (source != null && (source.lastProcessedUid ?? 0) >= uid) return;
    await (_db.update(_db.statementSources)..where((s) => s.id.equals(sourceId)))
      .write(StatementSourcesCompanion(lastProcessedUid: Value(uid)));
  }

  /// True when this exact statement line was already imported.
  ///
  /// The gate used to match on account + type + amount across a ±1 day
  /// window, with no regard for the description. That is a three-day sweep:
  /// two identical fares on consecutive days, a daily coffee, or a split
  /// bill all collapsed into one row and the rest were silently discarded,
  /// which systematically under-reported spending. Now it matches the SAME
  /// CALENDAR DAY and requires the descriptions to agree, so genuine repeat
  /// spends survive while re-syncs and overlapping statements still dedupe.
  Future<bool> transactionExists({
    required String accountId,
    required double amountSource,
    required DateTime date,
    required String type,
    String? description,
  }) async {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final rows = await (_db.select(_db.transactions)
      ..where((t) => t.accountId.equals(accountId)
        & t.type.equals(type)
        & t.transactionDate.isBiggerOrEqualValue(dayStart)
        & t.transactionDate.isSmallerThanValue(dayEnd))).get();
    final needle = _normalizeDescription(description ?? '');
    return rows.any((t) {
      if ((t.amountSource - amountSource).abs() >= 0.01) return false;
      // No description on either side: fall back to amount+day equality.
      if (needle.isEmpty) return true;
      return _normalizeDescription(t.description) == needle;
    });
  }

  static String _normalizeDescription(String d) =>
      d.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

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
  // SUGGESTED MATCHES & TRANSFER PATTERNS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<SuggestedMatche>> getPendingSuggestedMatches() =>
    (_db.select(_db.suggestedMatches)
      ..where((s) => s.status.equals('pending'))
      ..orderBy([(s) => OrderingTerm.desc(s.confidence)])).get();

  Future<int> countPendingSuggestedMatches() async {
    final rows = await getPendingSuggestedMatches();
    return rows.length;
  }

  Future<void> insertSuggestedMatch(SuggestedMatchesCompanion row) =>
    _db.into(_db.suggestedMatches).insert(row);

  Future<void> updateSuggestedMatchStatus(String id, String status) =>
    (_db.update(_db.suggestedMatches)..where((s) => s.id.equals(id)))
      .write(SuggestedMatchesCompanion(status: Value(status)));

  Future<SuggestedMatche?> getSuggestedMatch(String id) =>
    (_db.select(_db.suggestedMatches)..where((s) => s.id.equals(id))).getSingleOrNull();

  /// True if this exact pair was already rejected.
  Future<bool> wasMatchRejected(String fromTxnId, String toTxnId) async {
    final row = await (_db.select(_db.suggestedMatches)
      ..where((s) =>
          s.fromTxnId.equals(fromTxnId) &
          s.toTxnId.equals(toTxnId) &
          s.status.equals('rejected'))).getSingleOrNull();
    return row != null;
  }

  Future<Transaction?> getTransactionById(String id) =>
    (_db.select(_db.transactions)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<Transaction>> getUnmatchedIncomeExpense({int daysBack = 45}) async {
    final cutoff = DateTime.now().subtract(Duration(days: daysBack));
    return (_db.select(_db.transactions)
          ..where((t) =>
              t.type.isIn(['income', 'expense']) &
              t.status.isIn(kHiddenStatuses).not() &
              t.transactionDate.isBiggerOrEqualValue(cutoff))
          ..orderBy([(t) => OrderingTerm.desc(t.transactionDate)]))
        .get();
  }

  Future<void> upsertTransferPattern({
    required String pattern,
    required String targetAccountId,
    required String kind,
  }) {
    final key = pattern.trim().toLowerCase();
    if (key.isEmpty) return Future.value();
    return _db.into(_db.transferPatterns).insertOnConflictUpdate(
      TransferPatternsCompanion(
        id: Value('pat_${key.hashCode.abs()}'),
        pattern: Value(key),
        targetAccountId: Value(targetAccountId),
        kind: Value(kind),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<List<TransferPattern>> getAllTransferPatterns() =>
    _db.select(_db.transferPatterns).get();

  // ═══════════════════════════════════════════════════════════════════════════
  // COACH REPORTS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<CoachReport?> getCoachReport(int year, int month) =>
    (_db.select(_db.coachReports)
      ..where((c) => c.year.equals(year) & c.month.equals(month))).getSingleOrNull();

  Future<List<CoachReport>> getCoachReports({int limit = 12}) =>
    (_db.select(_db.coachReports)
      ..orderBy([
        (c) => OrderingTerm.desc(c.year),
        (c) => OrderingTerm.desc(c.month),
      ])
      ..limit(limit)).get();

  Future<void> upsertCoachReport(CoachReportsCompanion row) async {
    final existing = await getCoachReport(row.year.value, row.month.value);
    if (existing != null) {
      await (_db.delete(_db.coachReports)..where((c) => c.id.equals(existing.id))).go();
    }
    await _db.into(_db.coachReports).insert(row);
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
