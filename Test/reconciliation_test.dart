import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_orbit/data/database/database.dart';
import 'package:wealth_orbit/data/repositories/app_repository.dart';

/// Runtime verification of the Phase 1 money-movement engine:
/// balance bookkeeping, transfers, credit-card bill pay, and reconciliation.
void main() {
  late AppDatabase db;
  late AppRepository repo;

  setUp(() async {
    // onCreate seeds default currencies (incl. AED) and categories.
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AppRepository.withDatabase(db);
  });

  tearDown(() async => db.close());

  Future<String> addAccount(String name, double opening, {String type = 'bank', String? linkedLiabilityId}) async {
    final id = 'acc_$name';
    await repo.insertAccount(AccountsCompanion.insert(
      id: id,
      name: name,
      type: type,
      currencyCode: 'AED',
      balance: Value(opening),
      openingBalance: Value(opening),
      linkedLiabilityId: Value(linkedLiabilityId),
    ));
    return id;
  }

  Future<double> balanceOf(String id) async => (await repo.getAccount(id))!.balance;

  test('expense reduces balance; income increases it', () async {
    final acc = await addAccount('Checking', 1000);
    await repo.insertTransaction(TransactionsCompanion.insert(
      id: 't1', accountId: acc, amountSource: 200, amountBase: 200,
      currencyCode: 'AED', description: 'Groceries', type: 'expense',
      transactionDate: DateTime(2026, 1, 1),
    ));
    expect(await balanceOf(acc), 800);

    await repo.insertTransaction(TransactionsCompanion.insert(
      id: 't2', accountId: acc, amountSource: 500, amountBase: 500,
      currencyCode: 'AED', description: 'Salary', type: 'income',
      transactionDate: DateTime(2026, 1, 2),
    ));
    expect(await balanceOf(acc), 1300);

    await repo.deleteTransaction('t1');
    expect(await balanceOf(acc), 1500); // expense reversed
  });

  test('transfer moves money between accounts', () async {
    final a = await addAccount('A', 1000);
    final b = await addAccount('B', 100);
    await repo.createTransfer(fromAccountId: a, toAccountId: b, amount: 300, date: DateTime(2026, 1, 3));
    expect(await balanceOf(a), 700);
    expect(await balanceOf(b), 400);
  });

  test('pay credit-card bill: bank down, card up, liability reduced', () async {
    await repo.insertLiability(LiabilitiesCompanion.insert(
      id: 'liab1', name: 'Visa', type: 'credit_card', currencyCode: 'AED',
      principalAmount: 5000, outstandingAmount: 5000, interestRate: 0.0,
      tenureMonths: 0, emi: 0, startDate: DateTime(2025, 1, 1),
    ));
    final bank = await addAccount('Bank', 2000);
    // Card account starts at -800 (owes 800), linked to the liability.
    final card = await addAccount('Card', -800, type: 'credit_card', linkedLiabilityId: 'liab1');

    await repo.payCreditCardBill(fromAccountId: bank, creditCardAccountId: card, amount: 500, date: DateTime(2026, 1, 4));

    expect(await balanceOf(bank), 1500);          // bank reduced
    expect(await balanceOf(card), -300);          // card moves toward 0
    final liab = await repo.getLiability('liab1');
    expect(liab!.outstandingAmount, 4500);        // liability reduced
  });

  test('category corrections are learned per merchant', () async {
    final acc = await addAccount('Learn', 0);
    await repo.insertTransaction(TransactionsCompanion.insert(
      id: 'l1', accountId: acc, amountSource: 20, amountBase: 20,
      currencyCode: 'AED', description: 'Starbucks DIFC', type: 'expense',
      transactionDate: DateTime(2026, 1, 6), merchant: const Value('Starbucks'),
    ));
    // User corrects the category → app should remember it for the merchant.
    await repo.updateTransaction('l1', const TransactionsCompanion(categoryId: Value('cat_dining')));
    expect(await repo.getLearnedCategory('starbucks'), 'cat_dining');
    expect(await repo.getLearnedCategory('STARBUCKS '), 'cat_dining'); // normalized
    expect(await repo.getLearnedCategory('Unknown Shop'), null);
  });

  test('imported transactions are pending and can be reconciled', () async {
    final acc = await addAccount('Imp', 0);
    await repo.insertTransaction(TransactionsCompanion.insert(
      id: 'imp1', accountId: acc, amountSource: 50, amountBase: 50,
      currencyCode: 'AED', description: 'Coffee', type: 'expense',
      transactionDate: DateTime(2026, 1, 5), status: const Value('pending'),
    ));
    expect((await repo.getPendingTransactions(acc)).length, 1);

    await repo.markTransactionCleared('imp1');
    expect((await repo.getPendingTransactions(acc)).isEmpty, true);
  });
}
