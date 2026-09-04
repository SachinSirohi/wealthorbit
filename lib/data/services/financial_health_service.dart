import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../database/database.dart';
import '../repositories/app_repository.dart';
import 'gemini_service.dart';
import 'secure_vault.dart';

/// Deterministic financial-health metrics + monthly AI coach narrative.
/// Dart owns every number; the LLM only writes the story.
class FinancialHealthService {
  final AppRepository repository;
  FinancialHealthService(this.repository);

  Future<Map<String, dynamic>> buildSnapshot({int? year, int? month}) async {
    final now = DateTime.now();
    final y = year ?? now.year;
    final m = month ?? now.month;
    final base = await SecureVault.getBaseCurrency();

    final income = await repository.getTotalIncomeByMonth(y, m);
    final expenses = await repository.getTotalExpensesByMonth(y, m);
    final prev = DateTime(y, m - 1, 1);
    final prevIncome = await repository.getTotalIncomeByMonth(prev.year, prev.month);
    final prevExpenses = await repository.getTotalExpensesByMonth(prev.year, prev.month);

    double avg3Spend = 0;
    int avg3n = 0;
    for (var i = 1; i <= 3; i++) {
      final d = DateTime(y, m - i, 1);
      final e = await repository.getTotalExpensesByMonth(d.year, d.month);
      if (e > 0) {
        avg3Spend += e;
        avg3n++;
      }
    }
    if (avg3n > 0) avg3Spend /= avg3n;

    final savingsRate = income > 0 ? ((income - expenses) / income * 100) : 0.0;
    final prevSavingsRate =
        prevIncome > 0 ? ((prevIncome - prevExpenses) / prevIncome * 100) : 0.0;
    final spendDeltaPct = prevExpenses > 0
        ? ((expenses - prevExpenses) / prevExpenses * 100)
        : 0.0;

    final start = DateTime(y, m, 1);
    final end = DateTime(y, m + 1, 1).subtract(const Duration(milliseconds: 1));
    final byCat = await repository.getExpensesByCategory(start, end);
    final prevByCat = await repository.getExpensesByCategory(
      DateTime(prev.year, prev.month, 1),
      DateTime(prev.year, prev.month + 1, 1).subtract(const Duration(milliseconds: 1)),
    );
    final movers = <Map<String, dynamic>>[];
    for (final e in byCat.entries) {
      final before = prevByCat[e.key] ?? 0;
      movers.add({
        'category': e.key,
        'amount': _r(e.value),
        'delta': _r(e.value - before),
      });
    }
    movers.sort((a, b) =>
        ((b['delta'] as num).abs()).compareTo((a['delta'] as num).abs()));

    // 50/30/20 vs budgets this month
    final budgets = await repository.getAllBudgets();
    final monthBudgets =
        budgets.where((b) => b.year == y && b.month == m).toList();
    final categories = await repository.getAllCategories();
    final catType = {for (final c in categories) c.id: c.budgetType};
    double needsLimit = 0, wantsLimit = 0, futureLimit = 0;
    for (final b in monthBudgets) {
      switch (catType[b.categoryId]) {
        case 'needs':
          needsLimit += b.limitAmount;
          break;
        case 'wants':
          wantsLimit += b.limitAmount;
          break;
        case 'future':
          futureLimit += b.limitAmount;
          break;
      }
    }

    final accounts = await repository.getAllAccounts();
    double ccBalance = 0;
    double bankCash = 0;
    final cashMix = <String, double>{};
    for (final a in accounts) {
      if (!a.isActive) continue;
      final baseBal = await repository.toBase(a.balance, a.currencyCode);
      cashMix[a.currencyCode] = (cashMix[a.currencyCode] ?? 0) + baseBal;
      if (a.type == 'credit_card') {
        ccBalance += baseBal.abs();
      } else if (a.type == 'bank' || a.type == 'wallet') {
        if (a.balance > 0) bankCash += baseBal;
      }
    }

    final emergencyMonths = await repository.getEmergencyFundMonths();
    final netWorth = await repository.getNetWorthWithLiabilities();
    final snaps = await repository.getNetWorthSnapshots(limit: 2);
    double nwDelta = 0;
    if (snaps.length >= 2) {
      nwDelta = snaps.last.netWorth - snaps.first.netWorth;
    } else if (snaps.length == 1) {
      nwDelta = 0;
    }

    final pendingMatches = await repository.countPendingSuggestedMatches();
    final unmatchedRisk = pendingMatches >= 3;

    // A month with almost no rows is not a healthy month — it is a month we
    // failed to import. Scoring it produced a confident 90/100 on an empty
    // ledger, which is worse than showing nothing.
    final txCount = await repository.countTransactionsInMonth(y, m);
    final needAttention = await repository.countStatementsNeedingAttention();
    final dataSufficient = txCount >= minTransactionsToScore;

    final score = dataSufficient
        ? _score(
            savingsRate: savingsRate,
            emergencyMonths: emergencyMonths,
            spendDeltaPct: spendDeltaPct,
            nwDelta: nwDelta,
            ccBalance: ccBalance,
            income: income,
            unmatchedRisk: unmatchedRisk,
          )
        : null;

    return {
      'base_currency': base,
      'year': y,
      'month': m,
      'month_label': DateFormat.yMMMM().format(DateTime(y, m)),
      'income': _r(income),
      'expenses': _r(expenses),
      'savings_rate_pct': _r(savingsRate),
      'prev_savings_rate_pct': _r(prevSavingsRate),
      'spend_delta_pct': _r(spendDeltaPct),
      'avg_3m_spend': _r(avg3Spend),
      'top_category_movers': movers.take(3).toList(),
      'budget_503020': {
        'needs_limit': _r(needsLimit),
        'wants_limit': _r(wantsLimit),
        'future_limit': _r(futureLimit),
      },
      'credit_card_balance_base': _r(ccBalance),
      'bank_cash_base': _r(bankCash),
      'emergency_fund_months': emergencyMonths,
      'net_worth': _r(netWorth),
      'net_worth_delta': _r(nwDelta),
      'cash_mix': {
        for (final e in cashMix.entries) e.key: _r(e.value),
      },
      'pending_suggested_matches': pendingMatches,
      'unmatched_transfer_risk': unmatchedRisk,
      'transaction_count': txCount,
      'statements_needing_attention': needAttention,
      'data_sufficient': dataSufficient,
      'score': score,
    };
  }

  /// Below this many transactions in a month, the ledger is treated as
  /// incomplete and no score is produced.
  static const int minTransactionsToScore = 5;

  int _score({
    required double savingsRate,
    required int emergencyMonths,
    required double spendDeltaPct,
    required double nwDelta,
    required double ccBalance,
    required double income,
    required bool unmatchedRisk,
  }) {
    double s = 50;
    // Savings rate: 0→0, 20%→+20, 40%+→+25
    s += (savingsRate.clamp(0, 40) / 40) * 25;
    // Emergency fund: 0→0, 6 months→+20
    s += (emergencyMonths.clamp(0, 6) / 6) * 20;
    // Spend trend: down is good
    if (spendDeltaPct < -5) {
      s += 10;
    } else if (spendDeltaPct > 15) {
      s -= 10;
    }
    // Net worth direction
    if (nwDelta > 0) {
      s += 10;
    } else if (nwDelta < 0) {
      s -= 5;
    }
    // CC load vs income
    if (income > 0 && ccBalance > income * 0.5) s -= 10;
    if (unmatchedRisk) s -= 5;
    return s.round().clamp(0, 100);
  }

  double _r(double v) => double.parse(v.toStringAsFixed(2));

  /// Generate (or regenerate) the coach report for [year]/[month].
  Future<CoachReport> generateReport({
    int? year,
    int? month,
    bool force = false,
  }) async {
    final now = DateTime.now();
    final y = year ?? now.year;
    final m = month ?? now.month;

    if (!force) {
      final existing = await repository.getCoachReport(y, m);
      if (existing != null) return existing;
    }

    await GeminiService.seedDefaultKey();
    if (!await GeminiService.initialize()) {
      throw Exception('AI is not configured. Add your API key in Settings.');
    }

    final snapshot = await buildSnapshot(year: y, month: m);
    if (snapshot['data_sufficient'] != true) {
      final n = snapshot['transaction_count'];
      final pending = snapshot['statements_needing_attention'];
      throw InsufficientDataException(
        'Only $n transaction(s) imported for this month'
        '${pending is int && pending > 0 ? ' — $pending statement(s) still need attention' : ''}.',
      );
    }
    final report = await GeminiService.generateCoachReport(snapshot);
    final score = (snapshot['score'] as num?)?.toDouble() ?? 0;

    final row = CoachReportsCompanion.insert(
      id: const Uuid().v4(),
      year: y,
      month: m,
      generatedAt: Value(DateTime.now()),
      snapshotJson: json.encode(snapshot),
      reportJson: json.encode(report),
      score: Value(score),
    );
    await repository.upsertCoachReport(row);
    debugPrint('🩺 Coach report $y-$m score=$score');

    final saved = await repository.getCoachReport(y, m);
    return saved!;
  }

  /// Generate this month's report if missing (background / Sync Now).
  Future<CoachReport?> ensureCurrentMonthReport() async {
    final now = DateTime.now();
    final existing = await repository.getCoachReport(now.year, now.month);
    if (existing != null) return existing;
    try {
      return await generateReport(year: now.year, month: now.month);
    } on InsufficientDataException catch (e) {
      // Not an error: there genuinely is not enough imported data to score
      // this month. No report, no notification, no invented 90/100.
      debugPrint('🩺 Coach skipped — ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Coach ensure failed: $e');
      return null;
    }
  }
}

/// Raised when a month has too little imported data to be scored honestly.
class InsufficientDataException implements Exception {
  final String message;
  const InsufficientDataException(this.message);
  @override
  String toString() => 'InsufficientDataException: $message';
}
