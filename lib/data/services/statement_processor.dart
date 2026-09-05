import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../../core/amount_sanity.dart';
import '../../core/statement_date.dart';
import '../../core/statement_kind.dart';
import '../../core/savings_space.dart';
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
  return RegExp(r'zerodha|groww|upstox|angelone|angel one|5paisa|icicidirect|hdfcsec|kotaksecurities|cdsl|nsdl|kfintech|cams(online|nps)?|npscra|protean|\bnps\b|\bdemat\b|reportsmailer')
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

  /// Ensure the statement LLM is configured and initialized.
  /// Returns null on success, or a user-facing error message.
  static Future<String?> ensureGeminiReady() async {
    await GeminiService.seedDefaultKey();
    if (!await SecureVault.hasAnyLlmKey()) {
      return 'Add an AI API key in Settings to extract statements.';
    }
    final ok = await GeminiService.initialize();
    return ok ? null : 'Could not initialize AI. Check your API key and connection.';
  }

  /// Open a statement PDF, trying passwords the user has already saved for
  /// other sources when the one on file does not work.
  ///
  /// A household usually protects every statement with the same one or two
  /// secrets. Without this, unlocking Zerodha did nothing for CDSL, NSDL or
  /// CAMS — each had to be typed separately, and until it was, every one of
  /// their statements failed. A password that works is written back to this
  /// source so the next sync uses it directly.
  Future<String?> _extractText({
    required Uint8List bytes,
    String? password,
    String? sourceId,
    String? senderEmail,
  }) async {
    try {
      return await PdfExtractionService.extractText(bytes, password: password);
    } catch (firstError) {
      final candidates = (await SecureVault.getKnownPdfPasswords())
          .where((p) => p != password)
          .toList();
      for (final candidate in candidates) {
        try {
          final text = await PdfExtractionService.extractText(bytes, password: candidate);
          debugPrint('🔑 Opened with a password saved for another source');
          if (sourceId != null || senderEmail != null) {
            await SecureVault.setPdfPasswordForSource(
              sourceId: sourceId,
              senderEmail: senderEmail,
              password: candidate,
            );
          }
          return text;
        } catch (_) {
          // wrong password for this PDF — keep trying
        }
      }
      rethrow; // surface the original "needs a password" error
    }
  }

  /// Extract transactions from [bytes] and persist them against [accountId].
  /// Imported transactions are marked `pending` for reconciliation.
  ///
  /// Returns a [StatementImportResult]. A result with `imported == 0` always
  /// carries an `emptyReason` — callers must surface it instead of recording
  /// the statement as a silent success.
  Future<StatementImportResult> processPdf({
    required Uint8List bytes,
    required String accountId,
    String? pdfPassword,
    String? statementId,
    String? sourceId,
    String? senderEmail,
    DateTime? statementDate,
  }) async {
    // ignore: parameter_assignments — re-pointed below once the document
    // tells us which account it actually belongs to.
    final text = await _extractText(
      bytes: bytes,
      password: pdfPassword,
      sourceId: sourceId,
      senderEmail: senderEmail,
    );
    if (text == null || text.trim().isEmpty) {
      return const StatementImportResult(
        emptyReason: 'The PDF opened but contained no extractable text '
            '(it is probably a scanned image).',
      );
    }

    // The account's own currency is the authoritative reporting currency
    // (an HDFC statement is ₹ even if the AI guesses otherwise). amountBase
    // is the value converted into the user's base currency for aggregates.
    // What the document IS decides where it goes. A card statement aimed at
    // a bank account turns every repayment into income; a bank statement
    // aimed at a card account gets its balance stored as debt.
    final kind = StatementKindDetector.detect(text);
    var targetAccountId = accountId;
    if (kind != null) {
      targetAccountId = await repository.resolveAccountForStatementKind(
        accountId: accountId,
        isCardStatement: kind == StatementKind.creditCard,
      );
      if (targetAccountId != accountId) {
        debugPrint('🔀 ${kind == StatementKind.creditCard ? "Card" : "Bank"} '
            'statement re-routed to its matching account');
      }
    }
    accountId = targetAccountId;

    final account = await repository.getAccount(accountId);
    final currency = account?.currencyCode ?? 'AED';
    final isCardAccount = account?.type == 'credit_card';
    final rateToBase = (await repository.getCurrency(currency))?.rateToBase ?? 1.0;

    // Keep a sample of the extracted text, as the brokerage path does. Bank
    // statements carry balances the app does not model yet — fixed deposits,
    // savings pots — and those need designing against a real document.
    await _sampleStatementText(account?.name ?? accountId, text);

    final parsed =
        await GeminiService.parseStatementText(text, isCreditCard: isCardAccount);
    final closingBalance = GeminiService.lastClosingBalance;
    if (parsed.isEmpty) {
      return const StatementImportResult(
        emptyReason: 'The AI read the statement but found no transactions in it.',
      );
    }

    // CURRENCY GUARD: the destination account decides how every amount is
    // labelled and converted, so importing an INR statement into an AED
    // account silently multiplies every figure by the AED rate. When the
    // statement plainly reports another currency, refuse rather than write
    // mislabelled rows — the fix is to map the sender to the right account.
    final reported = _dominantCurrency(parsed);
    if (reported != null && reported != currency) {
      return StatementImportResult(
        emptyReason: 'This statement is in $reported but '
            '"${account?.name ?? accountId}" is a $currency account. '
            'Map this sender to the correct account, then retry.',
      );
    }

    // Re-reading a statement must REPLACE what it produced last time. Ids
    // are content-derived including the date, so a corrected date yields a
    // new id that matches nothing and would be inserted beside the wrong
    // row. Done only now that parsing has succeeded, so a failed extraction
    // never costs the data already on file.
    if (statementId != null) {
      final superseded =
          await repository.supersedeStatementTransactions(statementId);
      if (superseded > 0) {
        debugPrint('♻️ Superseded $superseded row(s) from a previous read');
      }
    }

    int count = 0;
    int skippedDupes = 0;
    int skippedAbsurd = 0;
    int skippedUndated = 0;
    // A statement covers the period BEFORE the email that carried it, so its
    // own date is a far better guess for an unreadable line than today.
    final fallbackDate = statementDate == null
        ? null
        : DateTime(statementDate.year, statementDate.month - 1, 15);
    // Peer set for the outlier guard: EXPENSES only. A salary credit or a
    // full card-bill payment legitimately dwarfs every purchase around it,
    // and comparing it against those peers threw away the real row.
    final peerAmounts = parsed
        .where((tx) => (tx['type'] ?? 'expense').toString() == 'expense')
        .map((tx) => (tx['amount'] as num?)?.toDouble() ?? 0)
        .where((a) => a > 0)
        .toList();

    for (final tx in parsed) {
      final amount = (tx['amount'] as num?)?.toDouble() ?? 0;
      if (amount <= 0) continue;
      // Normalise to the two types the ledger understands. The model
      // occasionally answers "refund" or "credit", and such rows matched
      // neither the income nor the expense filter — so they sat in the
      // database contributing to nothing at all.
      final type = _normalizeType(tx['type']);

      // A date that cannot be read must NOT become today. Doing so collapsed
      // years of history onto the current month. Fall back to the period the
      // statement covers, and if even that is unknown, skip the row and say
      // so rather than filing it under a date we invented.
      final date = StatementDate.parse((tx['date'] ?? '').toString()) ?? fallbackDate;
      if (date == null) {
        skippedUndated++;
        continue;
      }
      final description = (tx['description'] ?? '').toString();
      final merchant = tx['merchant'] as String?;
      // On a CREDIT CARD, a credit is a repayment, not income — money you
      // sent the card, not money you earned. The extractor cannot know
      // this: on the statement it is simply a positive number, so it comes
      // back typed "income" and inflates earnings by the whole card bill
      // every month. The account type is the missing piece, and inverting
      // the test is what makes it reliable: on a card, a credit is a
      // PAYMENT unless it is plainly a refund.
      var txnClass = (tx['txn_class'] ?? '').toString();
      if (isCardAccount && type == 'income') {
        txnClass = _looksLikeRefund(description) ? 'refund' : 'cc_payment';
      }

      // Large-but-real rows (income, card payments, investment funding) are
      // exempt from the peer-outlier test; the absolute ceiling still applies.
      final exemptFromPeers = type == 'income' ||
          txnClass == 'cc_payment' ||
          txnClass == 'own_transfer' ||
          txnClass == 'investment';

      if (!AmountSanity.isPlausible(amount, currency) ||
          (!exemptFromPeers &&
              AmountSanity.isOutlierVsPeers(amount, peerAmounts,
                  currencyCode: currency))) {
        skippedAbsurd++;
        debugPrint(
            '🛑 Skipped absurd amount $amount $currency · ${description.length > 40 ? description.substring(0, 40) : description}');
        continue;
      }

      // DEDUPE: never import the same transaction twice (re-synced or
      // overlapping statements are skipped silently).
      if (await repository.transactionExists(
          accountId: accountId,
          amountSource: amount,
          date: date,
          type: type,
          description: description)) {
        skippedDupes++;
        continue;
      }

      // Money moved into or out of a savings pot at the same bank is not
      // spending or income — the user still has it. Route it to an account
      // standing for the pot, so a fixed deposit shows up as the balance it
      // is instead of vanishing the moment it is funded.
      final potMove = SavingsSpace.detect(description);
      if (potMove != null && account != null) {
        final pot = await repository.ensureSavingsPotAccount(
          bankName: account.name,
          pot: potMove.pot,
          currencyCode: currency,
        );
        if (pot.id != accountId) {
          await repository.insertTransaction(
            TransactionsCompanion.insert(
              id: statementLineId(
                accountId: accountId,
                date: date,
                amount: amount,
                type: 'transfer',
                description: description,
              ),
              // A move INTO the pot leaves this account; a move out arrives.
              accountId: potMove.intoPot ? accountId : pot.id,
              transferAccountId: Value(potMove.intoPot ? pot.id : accountId),
              amountSource: amount,
              amountBase: amount * rateToBase,
              currencyCode: currency,
              description: description,
              type: 'transfer',
              txnClass: const Value('savings_transfer'),
              transactionDate: date,
              sourceStatementId: Value(statementId),
              status: const Value('cleared'),
            ),
            replaceExisting: true,
          );
          count++;
          continue;
        }
      }

      // Category: user-learned merchant mapping → AI hint → income keywords.
      final learned = await repository.getLearnedCategory(merchant);
      final categoryId = learned ??
          mapCategoryHint(tx['category_hint'] as String?) ??
          (type == 'income' ? incomeCategoryFromText('$description ${merchant ?? ''}') : null);

      await repository.insertTransaction(TransactionsCompanion.insert(
        // Content-derived id: re-importing the same statement line produces
        // the same id, so imports are idempotent and two PDFs finishing in
        // the same millisecond can no longer collide on the primary key.
        id: statementLineId(
          accountId: accountId,
          date: date,
          amount: amount,
          type: type,
          description: description,
        ),
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
        txnClass: Value(txnClass.isEmpty ? null : txnClass),
        status: const Value('pending'),
      ), replaceExisting: true);
      count++;
    }
    if (skippedDupes > 0) {
      debugPrint('🔁 Skipped $skippedDupes duplicate transactions for $accountId');
    }
    if (skippedAbsurd > 0) {
      debugPrint('🛑 Skipped $skippedAbsurd absurd-amount lines for $accountId');
    }
    if (skippedUndated > 0) {
      debugPrint('📅 Skipped $skippedUndated lines with an unreadable date');
    }

    // Only trust a closing balance that itself looks plausible.
    if (closingBalance != null && AmountSanity.isPlausible(closingBalance.abs(), currency)) {
      DateTime? stmtDate;
      for (final tx in parsed) {
        final d = StatementDate.parse((tx['date'] ?? '').toString());
        if (d != null && (stmtDate == null || d.isAfter(stmtDate))) stmtDate = d;
      }
      await repository.applyClosingBalance(accountId, closingBalance, statementDate: stmtDate);
      debugPrint('🏦 Anchored $accountId to closing balance $closingBalance (stmt ${stmtDate?.toIso8601String().split('T').first ?? 'n/a'})');
    }

    return StatementImportResult(
      imported: count,
      duplicates: skippedDupes,
      rejected: skippedAbsurd + skippedUndated,
      emptyReason: count > 0
          ? null
          : skippedDupes > 0
              ? 'Every transaction in this statement was already imported.'
              : 'No usable transactions were found in this statement.',
    );
  }

  /// A credit on a card statement that really is money coming back to you,
  /// rather than a repayment you made.
  static bool _looksLikeRefund(String description) => RegExp(
        r'refund|reversal|reversed|cashback|cash back|chargeback|charge back|'
        r'goods return|returned|credit adjustment|adjustment credit|'
        r'annual fee waiver|waiver|dispute',
        caseSensitive: false,
      ).hasMatch(description);

  /// Why a brokerage statement yielded no holdings.
  ///
  /// Most broker mail is not a holdings report at all: Zerodha sends a
  /// weekly "Statement of Account of Securities" listing the week's
  /// transactions, which is empty in a week with no trades. Reporting that
  /// as a failure sends the user hunting for a problem that does not exist.
  /// Positions live in the monthly CDSL/NSDL consolidated account statement.
  static String _noHoldingsReason(String text) {
    final t = text.toLowerCase();
    final looksTransactional = RegExp(
      r'statement of account|transaction date|execution date|pending obligation|'
      r'settlement|contract note|ledger',
    ).hasMatch(t);
    if (looksTransactional) {
      return 'This is a transaction statement, not a holdings report — it '
          'lists trades for the period, not what you own. Portfolio positions '
          'come from the monthly CDSL/NSDL consolidated account statement '
          '(CAS); add edcas@cdslindia.com as a source to import them.';
    }
    return 'No holdings were found in this portfolio statement.';
  }

  /// Sample of a bank statement's extracted text, for inspection over ADB.
  static Future<void> _sampleStatementText(String label, String text) async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      final safe = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
      final file = File('${dir.path}/statement_sample_$safe.txt');
      await file.writeAsString(
          text.length > 8000 ? text.substring(0, 8000) : text);
    } catch (_) {
      // diagnostics only — never let this affect an import
    }
  }

  /// Write the first few thousand characters of a brokerage statement to
  /// the app's external files directory for inspection over ADB.
  static Future<void> _sampleBrokerageText(String label, String text) async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      final safe = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
      final file = File('${dir.path}/brokerage_sample_$safe.txt');
      await file.writeAsString(
          text.length > 6000 ? text.substring(0, 6000) : text);
      debugPrint('📄 Brokerage sample written: ${file.path}');
    } catch (e) {
      debugPrint('Brokerage sample skipped: $e');
    }
  }

  /// Map whatever the model answered onto `income` or `expense`.
  static String _normalizeType(Object? raw) {
    final t = (raw ?? 'expense').toString().trim().toLowerCase();
    const incomeWords = {
      'income', 'i', 'credit', 'cr', 'refund', 'deposit', 'salary', 'inflow',
    };
    return incomeWords.contains(t) ? 'income' : 'expense';
  }

  /// The currency the statement itself reports, when it reports one
  /// consistently. Null when the lines disagree or none is stated.
  static String? _dominantCurrency(List<Map<String, dynamic>> parsed) {
    final counts = <String, int>{};
    for (final tx in parsed) {
      final c = (tx['currency'] ?? '').toString().trim().toUpperCase();
      if (c.length != 3) continue;
      counts[c] = (counts[c] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final total = counts.values.reduce((a, b) => a + b);
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    // Only act when the statement is overwhelmingly one currency; a handful
    // of foreign-currency lines on a card statement is normal.
    return top.value / total >= 0.8 ? top.key : null;
  }

  /// Brokerage path: extract HOLDINGS and upsert them as investment Assets
  /// (Investments tab), instead of treating portfolio lines as transactions.
  /// Returns how many holdings were upserted, with a reason when none were.
  Future<StatementImportResult> processBrokeragePdf({
    required Uint8List bytes,
    required String accountId,
    String? pdfPassword,
    String? bankName,
    String? sourceId,
    String? senderEmail,
  }) async {
    final text = await _extractText(
      bytes: bytes,
      password: pdfPassword,
      sourceId: sourceId,
      senderEmail: senderEmail,
    );
    if (text == null || text.trim().isEmpty) {
      return const StatementImportResult(
        emptyReason: 'The PDF opened but contained no extractable text '
            '(it is probably a scanned image).',
      );
    }

    final account = await repository.getAccount(accountId);
    final currency = account?.currencyCode ?? 'INR';

    // Evidence before guesswork. Twenty-two Zerodha statements have been
    // processed successfully and produced zero holdings, which means the
    // holdings prompt is being shown something it does not recognise — a
    // P&L or a ledger rather than a positions list. Keep a sample of the
    // extracted text so the prompt can be fixed against the real document
    // instead of a guess. Overwritten each run; app-private storage.
    await _sampleBrokerageText(bankName ?? accountId, text);

    final holdings = await GeminiService.parseBrokerageStatement(text);
    final asOf = GeminiService.lastStatementDate;
    int count = 0;
    for (final h in holdings) {
      final symbol = (h['symbol'] ?? h['name'] ?? '').toString().trim();
      final value = (h['value'] as num?)?.toDouble() ?? 0;
      if (symbol.isEmpty || value <= 0) continue;
      if (!AmountSanity.isPlausible(value, currency)) continue;
      final kind = (h['kind'] ?? 'stocks').toString();
      final isin = (h['isin'] ?? '').toString().trim();
      final quantity = (h['quantity'] as num?)?.toDouble();
      final price = (h['price'] as num?)?.toDouble();

      // Existing rows are keyed on the symbol; keep that so re-syncs update
      // rather than duplicate. New rows prefer the ISIN, which is stable
      // across brokers and across a symbol rename.
      final symbolId = 'hold_${accountId}_${symbol.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}';
      final isinId = isin.isNotEmpty ? 'hold_${accountId}_$isin' : null;
      final existing = await repository.getAsset(symbolId) ??
          (isinId != null ? await repository.getAsset(isinId) : null);

      // Stock detail lives in `metadata` (the Assets table has no columns for
      // it): units, price/NAV, ISIN, statement date and where it came from.
      final metadata = json.encode({
        'isin': isin.isNotEmpty ? isin : null,
        'quantity': quantity,
        'price': price,
        'symbol': symbol,
        'asOf': asOf,
        'source': bankName,
        'accountId': accountId,
        'updatedAt': DateTime.now().toIso8601String(),
      });

      if (existing == null) {
        await repository.insertAsset(AssetsCompanion.insert(
          id: isinId ?? symbolId,
          name: (h['name'] ?? symbol).toString(),
          type: kind,
          currencyCode: currency,
          // Cost basis is not on a holdings statement; the first sighting
          // becomes the baseline until a contract note / P&L supplies it.
          purchaseValue: value,
          currentValue: value,
          purchaseDate: DateTime.now(),
          geography: currency == 'INR' ? 'India' : 'UAE',
          isLiquid: Value(kind != 'nps'),
          lockInMonths: Value(kind == 'nps' ? 999 : 0),
          metadata: Value(metadata),
        ));
      } else {
        await repository.updateAsset(
          existing.id,
          AssetsCompanion(
            currentValue: Value(value),
            type: Value(kind),
            metadata: Value(metadata),
          ),
        );
      }
      count++;
    }
    debugPrint('📈 ${bankName ?? accountId}: upserted $count holdings');
    return StatementImportResult(
      imported: count,
      emptyReason: count > 0
          ? null
          : _noHoldingsReason(text),
    );
  }
}

/// Outcome of importing one statement PDF.
///
/// `imported == 0` always carries an [emptyReason]. The queue records that
/// reason instead of marking the statement `completed`, so "processed but
/// nothing changed" can never look like success again.
class StatementImportResult {
  final int imported;
  final int duplicates;
  final int rejected;
  final String? emptyReason;

  const StatementImportResult({
    this.imported = 0,
    this.duplicates = 0,
    this.rejected = 0,
    this.emptyReason,
  });

  bool get isEmpty => imported == 0;
}

/// Stable, content-derived id for one imported statement line.
///
/// Ids used to be `<millisecondsSinceEpoch>_<index>`, which made re-imports
/// produce fresh rows and let two PDFs finishing in the same millisecond
/// collide on the primary key. Hashing the line's own content fixes both.
String statementLineId({
  required String accountId,
  required DateTime date,
  required double amount,
  required String type,
  required String description,
}) {
  final normalized = description.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  final seed = '$accountId|${date.toIso8601String().split('T').first}'
      '|${amount.toStringAsFixed(2)}|$type|$normalized';
  // FNV-1a 64-bit — stable across runs and isolates, unlike String.hashCode.
  var hash = 0xcbf29ce484222325;
  for (final unit in seed.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return 'tx_${hash.toRadixString(16).padLeft(16, '0')}';
}
