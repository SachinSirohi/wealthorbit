import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../database/database.dart';
import '../repositories/app_repository.dart';
import 'secure_vault.dart';

/// Writes a machine-readable health report of the local ledger to the app's
/// external files directory.
///
/// The app is a release build, so `run-as` cannot reach its private database
/// and the only other way to inspect state is to drive the UI. This lets the
/// data be reviewed over ADB while the phone is being used for something
/// else: any background task writes the report, and
/// `/sdcard/Android/data/<pkg>/files/wo_diagnostics.json` can then be read
/// directly.
///
/// Aggregates only, plus a handful of samples — enough to tell what the
/// import pipeline is and is not doing, without copying the whole ledger out.
class DiagnosticsService {
  static const fileName = 'wo_diagnostics.json';

  static Future<String?> dump(AppDatabase db, AppRepository repo) async {
    try {
      final report = await _build(db, repo);
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      debugPrint('🩺 Diagnostics written to ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('🩺 Diagnostics failed: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>> _build(
      AppDatabase db, AppRepository repo) async {
    final now = DateTime.now();

    // ── Accounts ────────────────────────────────────────────────────────
    final accounts = await repo.getAllAccounts();
    final accountRows = <Map<String, dynamic>>[];
    for (final a in accounts) {
      final anchor = await repo.getAnchorInfo(a.id);
      final txCount = (await (db.select(db.transactions)
                ..where((t) => t.accountId.equals(a.id)))
              .get())
          .length;
      accountRows.add({
        'name': a.name,
        'type': a.type,
        'currency': a.currencyCode,
        'balance': _r(a.balance),
        'opening': _r(a.openingBalance),
        'transactions': txCount,
        'anchored': anchor != null,
        'anchor_closing': anchor == null ? null : _r(anchor.closing),
        'anchor_date': anchor?.date?.toIso8601String().split('T').first,
        'anchor_unexplained': anchor == null ? null : _r(anchor.drift),
        'untrustworthy': await repo.isBalanceUntrustworthy(a),
      });
    }

    // ── Transactions ────────────────────────────────────────────────────
    final all = await db.select(db.transactions).get();
    final byStatus = <String, int>{};
    final byType = <String, int>{};
    final byClass = <String, int>{};
    final byMonth = <String, int>{};
    var uncategorised = 0;
    var noMerchant = 0;
    DateTime? oldest, newest;
    for (final t in all) {
      byStatus[t.status] = (byStatus[t.status] ?? 0) + 1;
      byType[t.type] = (byType[t.type] ?? 0) + 1;
      byClass[t.txnClass ?? '(none)'] = (byClass[t.txnClass ?? '(none)'] ?? 0) + 1;
      final m = '${t.transactionDate.year}-'
          '${t.transactionDate.month.toString().padLeft(2, '0')}';
      byMonth[m] = (byMonth[m] ?? 0) + 1;
      if (t.categoryId == null) uncategorised++;
      if (t.merchant == null || t.merchant!.isEmpty) noMerchant++;
      if (oldest == null || t.transactionDate.isBefore(oldest)) {
        oldest = t.transactionDate;
      }
      if (newest == null || t.transactionDate.isAfter(newest)) {
        newest = t.transactionDate;
      }
    }
    final sortedMonths = byMonth.keys.toList()..sort();

    // ── Statement queue ─────────────────────────────────────────────────
    final queue = await db.select(db.statementQueue).get();
    final queueByStatus = <String, int>{};
    final failureReasons = <String, int>{};
    for (final q in queue) {
      queueByStatus[q.status] = (queueByStatus[q.status] ?? 0) + 1;
      if (q.status == 'failed' || q.status == 'empty') {
        failureReasons[_bucketError(q.errorMessage)] =
            (failureReasons[_bucketError(q.errorMessage)] ?? 0) + 1;
      }
    }

    // ── Sources ─────────────────────────────────────────────────────────
    final sources = await repo.getAllStatementSources();
    final sourceRows = <Map<String, dynamic>>[];
    for (final s in sources) {
      final pwd = await SecureVault.resolvePdfPassword(
        sourceId: s.id,
        senderEmail: s.senderEmail,
        bankName: s.bankName,
      );
      final mapped = s.accountId == null
          ? null
          : accounts.where((a) => a.id == s.accountId).firstOrNull?.name;
      final queued = queue.where((q) => q.sourceId == s.id).toList();
      sourceRows.add({
        'bank': s.bankName,
        'sender': s.senderEmail,
        'mapped_account': mapped,
        'has_password': pwd != null && pwd.isNotEmpty,
        'queued': queued.length,
        'completed': queued.where((q) => q.status == 'completed').length,
        'failed': queued.where((q) => q.status == 'failed').length,
        'empty': queued.where((q) => q.status == 'empty').length,
      });
    }

    // ── Investments & liabilities ───────────────────────────────────────
    final assets = await repo.getAllAssets();
    final assetsByType = <String, int>{};
    var withHoldingDetail = 0;
    for (final a in assets) {
      assetsByType[a.type] = (assetsByType[a.type] ?? 0) + 1;
      if (a.metadata != null && a.metadata!.contains('quantity')) {
        withHoldingDetail++;
      }
    }
    final liabilities = await repo.getActiveLiabilities();

    // ── Aggregates the dashboard actually shows ─────────────────────────
    final thisMonthIncome = await repo.getTotalIncomeByMonth(now.year, now.month);
    final thisMonthExpense = await repo.getTotalExpensesByMonth(now.year, now.month);
    final prev = DateTime(now.year, now.month - 1, 1);

    return {
      'generated_at': now.toIso8601String(),
      'accounts': accountRows,
      'transactions': {
        'total': all.length,
        'by_status': byStatus,
        'by_type': byType,
        'by_txn_class': byClass,
        'uncategorised': uncategorised,
        'without_merchant': noMerchant,
        'oldest': oldest?.toIso8601String().split('T').first,
        'newest': newest?.toIso8601String().split('T').first,
        'months_covered': sortedMonths.length,
        'per_month': {
          for (final m in sortedMonths.reversed.take(15)) m: byMonth[m],
        },
      },
      'statement_queue': {
        'total': queue.length,
        'by_status': queueByStatus,
        'failure_reasons': failureReasons,
      },
      'sources': sourceRows,
      'investments': {
        'assets': assets.length,
        'by_type': assetsByType,
        'with_holding_detail': withHoldingDetail,
      },
      'liabilities': liabilities
          .map((l) => {
                'name': l.name,
                'type': l.type,
                'currency': l.currencyCode,
                'outstanding': _r(l.outstandingAmount),
                'emi': _r(l.emi),
              })
          .toList(),
      'dashboard': {
        'this_month_income': _r(thisMonthIncome),
        'this_month_expense': _r(thisMonthExpense),
        'prev_month_income':
            _r(await repo.getTotalIncomeByMonth(prev.year, prev.month)),
        'prev_month_expense':
            _r(await repo.getTotalExpensesByMonth(prev.year, prev.month)),
        'cash_total_base': _r(await repo.getTotalAccountBalance()),
        'card_outstanding_base': _r(await repo.getCreditCardOutstanding()),
        'assets_base': _r(await repo.getTotalAssetValue()),
        'net_worth_base': _r(await repo.getNetWorthWithLiabilities()),
        'emergency_fund_months': await repo.getEmergencyFundMonths(),
        'avg_monthly_expense': _r(await repo.getAverageMonthlyExpenses(months: 3)),
        'pending_suggested_matches': await repo.countPendingSuggestedMatches(),
      },
    };
  }

  /// Collapse a raw error into a countable bucket.
  static String _bucketError(String? message) {
    final m = (message ?? '').toLowerCase();
    if (m.isEmpty) return '(none)';
    if (m.contains('password')) return 'needs PDF password';
    if (m.contains('timeout') || m.contains('timed out')) return 'AI timed out';
    if (m.contains('no account mapped')) return 'sender not mapped to an account';
    if (m.contains('already imported')) return 'already imported';
    if (m.contains('no pdf')) return 'no PDF attached';
    if (m.contains('not a bank statement')) return 'not a bank statement';
    if (m.contains('no extractable text')) return 'scanned image, no text';
    if (m.contains('no transactions')) return 'AI found no transactions';
    if (m.contains('not in') && m.contains('mailbox')) return 'email gone from mailbox';
    return 'other';
  }

  static double _r(double v) => double.parse(v.toStringAsFixed(2));
}
