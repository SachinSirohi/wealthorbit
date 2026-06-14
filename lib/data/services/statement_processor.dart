import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../database/database.dart';
import '../repositories/app_repository.dart';
import 'gemini_service.dart';
import 'pdf_extraction_service.dart';
import 'secure_vault.dart';

/// Map a Gemini "category_hint" (e.g. "groceries") to a seeded category id
/// (e.g. "cat_groceries"). Returns null when the hint is unknown/"other".
String? mapCategoryHint(String? hint) {
  if (hint == null) return null;
  const known = {
    'housing', 'utilities', 'groceries', 'transport', 'insurance',
    'dining', 'leisure', 'travel', 'shopping', 'subscriptions',
    'investments', 'savings', 'debt',
    // income categories
    'salary', 'business', 'interest', 'refund', 'rent_income',
  };
  final key = hint.trim().toLowerCase();
  return known.contains(key) ? 'cat_$key' : null;
}

/// Brokers/demat senders whose statements carry HOLDINGS, not transactions.
bool isBrokerageSender(String text) {
  final s = text.toLowerCase();
  return RegExp(r'zerodha|groww|upstox|angelone|angel one|5paisa|icicidirect|hdfcsec|kotaksecurities|cdsl|nsdl|kfintech|camsonline|\bdemat\b|reportsmailer')
      .hasMatch(s);
}

/// Keyword fallback for income classification when the AI gives no hint.
String? incomeCategoryFromText(String text) {
  final s = text.toLowerCase();
  if (RegExp(r'salar|payroll|sal cr|wages|stipend').hasMatch(s)) return 'cat_salary';
  if (RegExp(r'interest|int\.cr|int cr|dividend').hasMatch(s)) return 'cat_interest';
  if (RegExp(r'refund|reversal|cashback|chargeback').hasMatch(s)) return 'cat_refund';
  if (RegExp(r'\brent\b').hasMatch(s)) return 'cat_rent_income';
  return null;
}

/// Shared pipeline for turning a statement PDF into transactions. Used by the
/// manual upload flow, the foreground "Sync Now" flow, and the scheduled
/// background task so they all behave identically.
class StatementProcessor {
  final AppRepository repository;
  StatementProcessor(this.repository);

  /// Ensure Gemini is configured and initialized.
  /// Returns null on success, or a user-facing error message.
  static Future<String?> ensureGeminiReady() async {
    if (!await SecureVault.hasGeminiApiKey()) {
      return 'Add your Gemini API key in Settings to extract statements.';
    }
    final ok = await GeminiService.initialize();
    return ok ? null : 'Could not initialize Gemini AI. Check your API key and connection.';
  }

  /// Extract transactions from [bytes] and persist them against [accountId].
  /// Imported transactions are marked `pending` for reconciliation. Returns the
  /// number of transactions inserted.
  Future<int> processPdf({
    required Uint8List bytes,
    required String accountId,
    String? pdfPassword,
    String? statementId,
  }) async {
    final text = await PdfExtractionService.extractText(bytes, password: pdfPassword);
    if (text == null || text.trim().isEmpty) return 0;

    // The account's own currency is the authoritative reporting currency
    // (an HDFC statement is ₹ even if the AI guesses otherwise). amountBase
    // is the value converted into the user's base currency for aggregates.
    final account = await repository.getAccount(accountId);
    final currency = account?.currencyCode ?? 'AED';
    final rateToBase = (await repository.getCurrency(currency))?.rateToBase ?? 1.0;

    final parsed = await GeminiService.parseStatementText(text);
    final closingBalance = GeminiService.lastClosingBalance;
    int count = 0;
    int skippedDupes = 0;
    for (final tx in parsed) {
      final amount = (tx['amount'] as num?)?.toDouble() ?? 0;
      if (amount <= 0) continue;
      final type = (tx['type'] ?? 'expense').toString();
      final date = DateTime.tryParse((tx['date'] ?? '').toString()) ?? DateTime.now();
      final description = (tx['description'] ?? '').toString();
      final merchant = tx['merchant'] as String?;

      // DEDUPE: never import the same transaction twice (re-synced or
      // overlapping statements are skipped silently).
      if (await repository.transactionExists(
          accountId: accountId, amountSource: amount, date: date, type: type)) {
        skippedDupes++;
        continue;
      }

      // Category: user-learned merchant mapping → AI hint → income keywords.
      final learned = await repository.getLearnedCategory(merchant);
      final categoryId = learned ??
          mapCategoryHint(tx['category_hint'] as String?) ??
          (type == 'income' ? incomeCategoryFromText('$description ${merchant ?? ''}') : null);

      await repository.insertTransaction(TransactionsCompanion.insert(
        id: '${DateTime.now().millisecondsSinceEpoch}_$count',
        accountId: accountId,
        amountSource: amount,
        amountBase: amount * rateToBase,
        currencyCode: currency,
        description: description,
        type: type,
        transactionDate: date,
        merchant: Value(merchant),
        categoryId: Value(categoryId),
        sourceStatementId: Value(statementId),
        status: const Value('pending'),
      ));
      count++;
    }
    if (skippedDupes > 0) {
      debugPrint('🔁 Skipped $skippedDupes duplicate transactions for $accountId');
    }

    // Anchor the account to the statement's stated closing balance so the
    // displayed balance is the bank's real number, not a from-zero sum.
    // Tag it with the statement's newest transaction date so only the most
    // recent statement's balance sticks (older statements processed later
    // must not clobber a newer balance).
    if (closingBalance != null) {
      DateTime? stmtDate;
      for (final tx in parsed) {
        final d = DateTime.tryParse((tx['date'] ?? '').toString());
        if (d != null && (stmtDate == null || d.isAfter(stmtDate))) stmtDate = d;
      }
      await repository.applyClosingBalance(accountId, closingBalance, statementDate: stmtDate);
      debugPrint('🏦 Anchored $accountId to closing balance $closingBalance (stmt ${stmtDate?.toIso8601String().split('T').first ?? 'n/a'})');
    }
    return count;
  }

  /// Brokerage path: extract HOLDINGS and upsert them as investment Assets
  /// (Investments tab), instead of treating portfolio lines as transactions.
  /// Returns the number of holdings upserted.
  Future<int> processBrokeragePdf({
    required Uint8List bytes,
    required String accountId,
    String? pdfPassword,
    String? bankName,
  }) async {
    final text = await PdfExtractionService.extractText(bytes, password: pdfPassword);
    if (text == null || text.trim().isEmpty) return 0;

    final account = await repository.getAccount(accountId);
    final currency = account?.currencyCode ?? 'INR';

    final holdings = await GeminiService.parseBrokerageStatement(text);
    int count = 0;
    for (final h in holdings) {
      final symbol = (h['symbol'] ?? h['name'] ?? '').toString().trim();
      final value = (h['value'] as num?)?.toDouble() ?? 0;
      if (symbol.isEmpty || value <= 0) continue;
      final kind = (h['kind'] ?? 'stock').toString() == 'mutual_fund' ? 'mutual_funds' : 'stocks';
      final id = 'hold_${accountId}_${symbol.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}';
      final existing = await repository.getAsset(id);
      if (existing == null) {
        await repository.insertAsset(AssetsCompanion.insert(
          id: id,
          name: (h['name'] ?? symbol).toString(),
          type: kind,
          currencyCode: currency,
          purchaseValue: value,
          currentValue: value,
          purchaseDate: DateTime.now(),
          geography: currency == 'INR' ? 'India' : 'UAE',
          isLiquid: const Value(true),
        ));
      } else {
        await repository.updateAsset(id, AssetsCompanion(currentValue: Value(value)));
      }
      count++;
    }
    debugPrint('📈 ${bankName ?? accountId}: upserted $count holdings');
    return count;
  }
}
