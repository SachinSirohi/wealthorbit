import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../database/database.dart';
import '../repositories/app_repository.dart';
import 'secure_vault.dart';

/// Seeds a complete, realistic, 100% FICTIONAL dataset for marketing
/// screenshots. Only compiled in when built with --dart-define=DEMO=true.
/// No real names, emails, balances or account numbers anywhere.
class DemoDataService {
  static Future<void> seed(AppRepository repo) async {
    if (await repo.getBoolSetting('demo_seeded')) return;
    debugPrint('🎬 Seeding DEMO dataset…');

    await SecureVault.setOnboardingComplete(true);
    await SecureVault.setBaseCurrency('AED');
    await SecureVault.setGeminiApiKey('demo-key-not-real');
    await SecureVault.addEmailAccount('demo@wealthorbit.app', 'demo', 'gmail');

    const inr = 0.0441; // → AED
    final now = DateTime.now();

    // ── Accounts ────────────────────────────────────────────────────────
    Future<void> acc(String id, String name, String type, String cur, double opening) =>
        repo.insertAccount(AccountsCompanion.insert(
          id: id, name: name, type: type, currencyCode: cur,
          balance: Value(opening), openingBalance: Value(opening),
        ));
    await acc('demo_enbd', 'Emirates NBD', 'bank', 'AED', 31250.75);
    await acc('demo_wio', 'Wio Bank', 'bank', 'AED', 12840.50);
    await acc('demo_hdfc', 'HDFC Bank', 'bank', 'INR', 245600.00);
    await acc('demo_kotak', 'Kotak Mahindra Bank', 'bank', 'INR', 86420.00);
    await acc('demo_hdfc_cc', 'HDFC Credit Card', 'credit_card', 'INR', -42350.00);

    // ── Transactions (6 months of life) ─────────────────────────────────
    int n = 0;
    Future<void> tx(String accId, String cur, double rate, String type, double amt,
        String desc, String? merchant, String? cat, int monthsAgo, int day,
        {String status = 'cleared'}) async {
      final d = DateTime(now.year, now.month - monthsAgo, day);
      await repo.insertTransaction(TransactionsCompanion.insert(
        id: 'demo_tx_${n++}',
        accountId: accId,
        amountSource: amt,
        amountBase: amt * rate,
        currencyCode: cur,
        description: desc,
        type: type,
        transactionDate: d,
        merchant: Value(merchant),
        categoryId: Value(cat),
        status: Value(status),
      ));
    }

    for (int m = 5; m >= 0; m--) {
      // Salary + rent on ENBD (AED)
      await tx('demo_enbd', 'AED', 1, 'income', 18500, 'SALARY CREDIT — TECHCORP FZ LLC', 'TechCorp', 'cat_salary', m, 25);
      await tx('demo_enbd', 'AED', 1, 'expense', 5500, 'RENT — MARINA HEIGHTS', 'Landlord', 'cat_housing', m, 1);
      await tx('demo_enbd', 'AED', 1, 'expense', 612.40, 'DEWA ELECTRICITY & WATER', 'DEWA', 'cat_utilities', m, 5);
      await tx('demo_enbd', 'AED', 1, 'expense', 389.00, 'ETISALAT POSTPAID', 'Etisalat', 'cat_utilities', m, 6);
      await tx('demo_enbd', 'AED', 1, 'expense', 845.30 + m * 23, 'CARREFOUR MALL OF EMIRATES', 'Carrefour', 'cat_groceries', m, 8);
      await tx('demo_wio', 'AED', 1, 'expense', 421.75 + m * 11, 'LULU HYPERMARKET', 'Lulu', 'cat_groceries', m, 19);
      await tx('demo_enbd', 'AED', 1, 'expense', 56.00, 'NETFLIX.COM', 'Netflix', 'cat_subscriptions', m, 3);
      await tx('demo_wio', 'AED', 1, 'expense', 23.99, 'SPOTIFY AE', 'Spotify', 'cat_subscriptions', m, 4);
      await tx('demo_enbd', 'AED', 1, 'expense', 187.50 + m * 9, 'CAREEM RIDES', 'Careem', 'cat_transport', m, 12);
      await tx('demo_enbd', 'AED', 1, 'expense', 240.00, 'ADNOC FUEL', 'ADNOC', 'cat_transport', m, 15);
      await tx('demo_wio', 'AED', 1, 'expense', 312.80 + m * 14, 'TALABAT ORDERS', 'Talabat', 'cat_dining', m, 17);
      await tx('demo_enbd', 'AED', 1, 'expense', 478.25, 'ZUMA DUBAI', 'Zuma', 'cat_dining', m, 21);
      // India side (INR)
      await tx('demo_hdfc', 'INR', inr, 'income', 4200, 'SAVINGS A/C INTEREST CREDIT', 'HDFC Bank', 'cat_interest', m, 28);
      await tx('demo_hdfc', 'INR', inr, 'expense', 2890 + m * 120.0, 'SWIGGY ORDER', 'Swiggy', 'cat_dining', m, 9);
      await tx('demo_kotak', 'INR', inr, 'expense', 3450.0, 'BIGBASKET GROCERIES', 'BigBasket', 'cat_groceries', m, 11);
      await tx('demo_hdfc_cc', 'INR', inr, 'expense', 5670 + m * 240.0, 'AMAZON.IN PURCHASE', 'Amazon', 'cat_shopping', m, 14);
      await tx('demo_hdfc_cc', 'INR', inr, 'expense', 1899.0, 'UBER INDIA', 'Uber', 'cat_transport', m, 18);
    }
    // One-offs
    await tx('demo_enbd', 'AED', 1, 'expense', 3650, 'EMIRATES AIRLINES — DXB-BOM', 'Emirates', 'cat_travel', 1, 10);
    await tx('demo_wio', 'AED', 1, 'expense', 1289, 'NOON.COM ELECTRONICS', 'Noon', 'cat_shopping', 2, 22);
    await tx('demo_hdfc', 'INR', inr, 'income', 1450, 'REFUND — FLIPKART RETURN', 'Flipkart', 'cat_refund', 0, 6, status: 'pending');
    await tx('demo_enbd', 'AED', 1, 'expense', 950, 'GOLD\'S GYM ANNUAL', "Gold's Gym", 'cat_leisure', 3, 7);
    // Own-account transfer + CC bill payment
    await repo.createTransfer(
        fromAccountId: 'demo_enbd', toAccountId: 'demo_hdfc',
        amount: 5000, date: DateTime(now.year, now.month, 2), note: 'Family remittance');
    await repo.payCreditCardBill(
        fromAccountId: 'demo_hdfc', creditCardAccountId: 'demo_hdfc_cc',
        amount: 38000, date: DateTime(now.year, now.month - 1, 27));

    // ── Investments / Assets ────────────────────────────────────────────
    Future<void> asset(String id, String name, String type, String cur,
            double buy, double cv, String geo, {bool liquid = true}) =>
        repo.insertAsset(AssetsCompanion.insert(
          id: id, name: name, type: type, currencyCode: cur,
          purchaseValue: buy, currentValue: cv,
          purchaseDate: DateTime(now.year - 2, 3, 15), geography: geo,
          isLiquid: Value(liquid),
        ));
    await asset('demo_st1', 'Reliance Industries', 'stocks', 'INR', 182000, 241500, 'India');
    await asset('demo_st2', 'TCS', 'stocks', 'INR', 145000, 168900, 'India');
    await asset('demo_st3', 'Infosys', 'stocks', 'INR', 98000, 112400, 'India');
    await asset('demo_mf1', 'Parag Parikh Flexi Cap', 'mutual_funds', 'INR', 420000, 561200, 'India');
    await asset('demo_mf2', 'HDFC Index Nifty 50', 'mutual_funds', 'INR', 310000, 384700, 'India');
    await asset('demo_fd1', 'Emirates NBD Fixed Deposit', 'fixed_deposit', 'AED', 50000, 53400, 'UAE');
    await asset('demo_gold', 'Digital Gold (24K)', 'gold', 'INR', 150000, 196500, 'India');
    await asset('demo_ppf', 'PPF Account', 'ppf', 'INR', 480000, 542000, 'India', liquid: false);
    await asset('demo_re1', 'Marina Heights 2BHK', 'real_estate', 'AED', 1150000, 1450000, 'UAE', liquid: false);
    await asset('demo_re2', 'Baner Apartment, Pune', 'real_estate', 'INR', 7800000, 9500000, 'India', liquid: false);

    // Rental income + property expenses for the Dubai flat
    for (int m = 5; m >= 0; m--) {
      final d = DateTime(now.year, now.month - m, 1);
      await repo.insertRentalIncome(RentalIncomeCompanion.insert(
        id: 'demo_rent_$m', assetId: 'demo_re1', amount: 7500,
        currencyCode: 'AED', year: d.year, month: d.month,
        tenantName: const Value('Tenant — Marina Heights'),
      ));
    }
    await repo.insertPropertyExpense(PropertyExpensesCompanion.insert(
      id: 'demo_pe1', assetId: 'demo_re1', category: 'maintenance',
      amount: 2400, currencyCode: 'AED',
      expenseDate: DateTime(now.year, now.month - 2, 12),
      description: const Value('Annual AC maintenance'),
    ));
    await repo.insertExitRule(PropertyExitRulesCompanion.insert(
      id: 'demo_exit1', assetId: 'demo_re1', ruleType: 'profit_threshold',
      thresholdValue: 400000,
    ));

    // ── Liabilities ─────────────────────────────────────────────────────
    await repo.insertLiability(LiabilitiesCompanion.insert(
      id: 'demo_loan1', name: 'Home Loan — Marina Heights', type: 'home_loan',
      currencyCode: 'AED', principalAmount: 900000, outstandingAmount: 612000,
      interestRate: 3.99, tenureMonths: 240, emi: 4850,
      startDate: DateTime(now.year - 3, 6, 1),
      linkedAssetId: const Value('demo_re1'),
      institution: const Value('Emirates NBD'),
    ));
    await repo.insertLiability(LiabilitiesCompanion.insert(
      id: 'demo_loan2', name: 'Car Loan', type: 'vehicle_loan',
      currencyCode: 'INR', principalAmount: 850000, outstandingAmount: 310000,
      interestRate: 8.5, tenureMonths: 60, emi: 17400,
      startDate: DateTime(now.year - 2, 1, 10),
      institution: const Value('HDFC Bank'),
    ));

    // ── Goals ───────────────────────────────────────────────────────────
    Future<void> goal(String id, String name, double target, double cur,
            int yearsOut, String priority) =>
        repo.insertGoal(GoalsCompanion.insert(
          id: id, name: name, currencyCode: 'AED', targetAmount: target,
          currentAmount: Value(cur),
          targetDate: DateTime(now.year + yearsOut, 6, 1),
          priority: Value(priority),
        ));
    await goal('demo_g1', 'Retirement Fund', 2500000, 580000, 18, 'high');
    await goal('demo_g2', 'Dream Home Down Payment', 800000, 295000, 4, 'high');
    await goal('demo_g3', 'Kids\' Education', 600000, 140000, 9, 'medium');

    // ── SIPs ────────────────────────────────────────────────────────────
    await repo.insertSipRecord(SipRecordsCompanion.insert(
      id: 'demo_sip1', assetId: 'demo_mf1', name: 'Parag Parikh Flexi Cap SIP',
      amount: 25000, currencyCode: 'INR', dayOfMonth: 5,
      startDate: DateTime(now.year - 2, 1, 5), goalId: const Value('demo_g1'),
    ));
    await repo.insertSipRecord(SipRecordsCompanion.insert(
      id: 'demo_sip2', assetId: 'demo_mf2', name: 'Nifty 50 Index SIP',
      amount: 15000, currencyCode: 'INR', dayOfMonth: 10,
      startDate: DateTime(now.year - 1, 4, 10), goalId: const Value('demo_g2'),
    ));

    // ── Dividends ───────────────────────────────────────────────────────
    await repo.insertDividend(DividendsCompanion.insert(
      id: 'demo_div1', assetId: 'demo_st1', amount: 4500, currencyCode: 'INR',
      exDate: DateTime(now.year, now.month - 2, 4),
      paymentDate: DateTime(now.year, now.month - 2, 18),
    ));
    await repo.insertDividend(DividendsCompanion.insert(
      id: 'demo_div2', assetId: 'demo_st2', amount: 3200, currencyCode: 'INR',
      exDate: DateTime(now.year, now.month - 4, 9),
      paymentDate: DateTime(now.year, now.month - 4, 22),
    ));

    // ── Statement sources (so Settings looks alive) ─────────────────────
    Future<void> src(String id, String email, String bank, String accId) =>
        repo.insertStatementSource(StatementSourcesCompanion.insert(
          id: id, senderEmail: email, bankName: bank, accountType: 'bank',
          accountId: Value(accId),
        ));
    await src('demo_src1', 'statements@emiratesnbd.com', 'Emirates NBD', 'demo_enbd');
    await src('demo_src2', 'estatements@hdfcbank.net', 'HDFC Bank', 'demo_hdfc');
    await src('demo_src3', 'cards@hdfcbank.net', 'HDFC Credit Card', 'demo_hdfc_cc');
    await src('demo_src4', 'statements@kotak.bank.in', 'Kotak Mahindra Bank', 'demo_kotak');

    // ── Net-worth trend (8 months, rising) ──────────────────────────────
    const series = <double>[2310000, 2335000, 2348000, 2371000, 2390000, 2412000, 2446000, 2480000];
    for (int i = 0; i < series.length; i++) {
      final d = DateTime(now.year, now.month - (series.length - 1 - i), 3);
      await repo.insertNetWorthSnapshot(NetWorthSnapshotsCompanion.insert(
        id: 'demo_nw_$i', date: d,
        totalAssets: Value(series[i] * 0.97),
        totalAccounts: Value(series[i] * 0.05),
        totalLiabilities: Value(series[i] * 0.02),
        netWorth: Value(series[i]),
      ));
    }

    // Realistic monthly budgets (base AED) keyed to actual spend so every
    // category sits at a healthy utilisation — no overrun alerts in the demo.
    const budgets = <String, double>{
      'cat_housing': 7500,
      'cat_utilities': 1500,
      'cat_groceries': 2200,
      'cat_dining': 1600,
      'cat_transport': 1000,
      'cat_subscriptions': 150,
      'cat_shopping': 1400,
      'cat_travel': 1200,
      'cat_leisure': 600,
    };
    for (final entry in budgets.entries) {
      await repo.insertBudget(BudgetsCompanion.insert(
        id: 'bud_${now.year}${now.month}_${entry.key}',
        categoryId: entry.key,
        year: now.year,
        month: now.month,
        limitAmount: entry.value,
        currencyCode: 'AED',
      ));
    }
    for (final id in ['demo_enbd', 'demo_wio', 'demo_hdfc', 'demo_kotak', 'demo_hdfc_cc']) {
      await repo.recomputeAccountBalance(id);
    }

    await repo.setAppSetting('demo_seeded', 'true');
    debugPrint('🎬 DEMO dataset seeded');
  }
}
