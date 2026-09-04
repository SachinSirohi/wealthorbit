import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'secure_vault.dart';

/// OpenAI-compatible client pointed at the WealthOrbit LLM
/// (`https://llm.edgenroots.org`, model `qwen-14b`).
///
/// qwen-14b is a thinking model. By default it spends the whole budget on
/// `reasoning_content` and leaves `content` empty, which looks like a timeout
/// or "0 transactions imported". Every request disables thinking
/// (`/no_think` + `chat_template_kwargs.enable_thinking=false`).
///
/// The class name is historical (this used to wrap Google Gemini). Call sites
/// keep using [GeminiService] so the rest of the app does not have to change.
class GeminiService {
  static const endpoint = 'https://llm.edgenroots.org/chat/completions';
  static const model = 'qwen-14b';

  /// Budget for one extraction request.
  ///
  /// Measured against this deployment (qwen-14b, thinking disabled): output
  /// generation runs at roughly 8-17 tokens/sec and dominates the request —
  /// time-to-first-token is only ~10-30s. The old 90s ceiling was therefore
  /// not survivable by any real statement, which is what produced the wall
  /// of "TimeoutException after 0:01:30" failures. Requests of 400s+ have
  /// been observed completing, so the "Cloudflare kills at 120s" assumption
  /// this was built on does not hold.
  static const statementTimeout = Duration(seconds: 240);

  /// Output ceiling per window. With the compact row format below a
  /// transaction costs ~45 tokens, so this covers ~60 transactions —
  /// comfortably more than one window can contain.
  static const statementMaxTokens = 3000;

  /// Characters of statement text sent per request.
  ///
  /// Sized so a window's OUTPUT finishes inside [statementTimeout]: a
  /// statement line is ~110 characters, so 4,000 chars is ~35 transactions
  /// ~= 1,600 output tokens ~= 100-190s. Statements longer than this are
  /// split into overlapping windows, never clipped.
  static const statementChunkChars = 4000;

  /// Overlap between consecutive windows so a transaction that straddles a
  /// boundary is still seen whole by at least one call.
  static const statementChunkOverlap = 400;

  /// Upper bound on windows per statement, so one pathological PDF cannot
  /// consume the whole background execution budget.
  static const statementMaxChunks = 12;

  /// Build-time API key, supplied by the release build and NEVER committed:
  ///
  ///   flutter build apk --release --dart-define-from-file=dart_defines.json
  ///
  /// The default is deliberately empty — this repository is public, and a key
  /// literal in source is scraped within minutes of being pushed. When it is
  /// empty the app simply asks the user for their own key in Settings.
  static const defaultApiKey = String.fromEnvironment('LLM_API_KEY');

  static bool _ready = false;
  static String? _lastError;

  /// Closing balance reported by the most recent parseStatementText call
  /// (null when the statement didn't state one).
  static double? lastClosingBalance;

  /// Write the built-in key if none is stored, or if the stored key is a
  /// leftover Google Gemini key (`AIza…`) that this build no longer uses.
  static Future<void> seedDefaultKey() async {
    // Nothing to seed in a build without a baked-in key: leave whatever the
    // user configured alone rather than overwriting it with an empty string.
    if (defaultApiKey.isEmpty) return;
    final existing = await SecureVault.getGeminiApiKey();
    if (existing == null ||
        existing.isEmpty ||
        existing.startsWith('AIza') ||
        existing == 'demo-key-not-real') {
      await SecureVault.setGeminiApiKey(defaultApiKey);
    }
  }

  /// Ready if a key is present. Does not hit the network (background jobs
  /// must not stall on a health-check).
  static Future<bool> initialize() async {
    await seedDefaultKey();
    final apiKey = await SecureVault.getGeminiApiKey();
    _ready = apiKey != null && apiKey.isNotEmpty;
    return _ready;
  }

  /// Check if the API key is valid. Returns null if valid, or an error message.
  static Future<String?> validateApiKey(String apiKey) async {
    if (apiKey.isEmpty || apiKey.length < 8) {
      return 'Key is too short';
    }
    try {
      final text = await _complete(
        apiKey: apiKey,
        user: 'Reply with the single word PONG',
        jsonMode: false,
        temperature: 0,
        maxTokens: 16,
        timeout: const Duration(seconds: 30),
      );
      if (text.trim().isEmpty) {
        return 'The AI returned an empty response. Check the key and network.';
      }
      _lastError = null;
      return null;
    } catch (e) {
      _lastError = e.toString();
      return 'Failed: ${_shortError(e)}\n\nCheck: API key, internet, firewall';
    }
  }

  /// Extract every transaction in [statementText].
  ///
  /// Long statements are split into overlapping windows and extracted in
  /// several calls, then merged. The previous implementation clipped the
  /// text to 10,000 characters — keeping the head and tail and DISCARDING
  /// THE MIDDLE — so a multi-page statement silently lost most of its
  /// transactions while still reporting success.
  static Future<List<Map<String, dynamic>>> parseStatementText(
      String statementText) async {
    if (!_ready && !await initialize()) {
      throw Exception('AI is not configured. Add your API key in Settings.');
    }

    final windows = _splitStatement(statementText);
    if (windows.length == 1) {
      return _parseStatementWindow(windows.first);
    }

    debugPrint('📄 Statement split into ${windows.length} windows '
        '(${statementText.length} chars)');

    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};
    double? closing;
    Object? lastError;
    var succeeded = 0;

    for (var i = 0; i < windows.length; i++) {
      try {
        final rows = await _parseStatementWindow(windows[i]);
        succeeded++;
        // The closing balance is usually printed in the summary block at the
        // top; fall back to any later window that reports one.
        closing ??= lastClosingBalance;
        for (final row in rows) {
          // Overlapping windows re-emit boundary lines — key them so a
          // transaction is not imported twice.
          final key = '${row['date']}|${row['amount']}|'
              '${(row['description'] ?? '').toString().toLowerCase().trim()}';
          if (seen.add(key)) merged.add(row);
        }
      } catch (e) {
        lastError = e;
        debugPrint('⚠️ Statement window ${i + 1}/${windows.length} failed: $e');
      }
    }

    // Only fail the statement outright if EVERY window failed; a partial
    // read is still worth importing, and the queue records the shortfall.
    if (succeeded == 0) {
      throw Exception('Failed to parse statement: ${lastError ?? 'no windows succeeded'}');
    }
    if (succeeded < windows.length) {
      debugPrint('⚠️ Statement partially extracted: $succeeded/${windows.length} windows');
    }

    lastClosingBalance = closing;
    return merged;
  }

  /// Split [text] into overlapping windows small enough for one request.
  static List<String> _splitStatement(String text) {
    if (text.length <= statementChunkChars) return [text];
    final windows = <String>[];
    var start = 0;
    while (start < text.length && windows.length < statementMaxChunks) {
      final end = (start + statementChunkChars).clamp(0, text.length);
      windows.add(text.substring(start, end));
      if (end >= text.length) break;
      start = end - statementChunkOverlap;
    }
    if (windows.length == statementMaxChunks) {
      final covered = statementMaxChunks * statementChunkChars;
      if (text.length > covered) {
        debugPrint('⚠️ Statement is ${text.length} chars — only the first '
            '~$covered were read (window cap reached)');
      }
    }
    return windows;
  }

  static Future<List<Map<String, dynamic>>> _parseStatementWindow(
      String clipped) async {
    // COMPACT ROW FORMAT. The original prompt asked for a 9-field object per
    // transaction, which cost ~117 output tokens each; at this deployment's
    // measured 8-17 tok/s a 28-line statement took ~400s and a 90-line one
    // blew past the token ceiling and came back as unparseable JSON. The same
    // statement in 5-element arrays costs ~43 tokens per row and completes in
    // ~70s. Fields the app can derive itself (merchant, transaction class) are
    // derived in [_expandCompactRow] rather than generated.
    final prompt = '''
Extract every transaction from the bank statement below.

Return ONE JSON object, no markdown:
{"cb":<closing balance or null>,"cur":"<ISO currency code>","t":[[date,desc,amount,kind,cat],...]}

Each transaction is a 5-element ARRAY, not an object:
  date   "YYYY-MM-DD"
  desc   short description (max 40 chars)
  amount positive number, never negative
  kind   "e" for debit/withdrawal/purchase, "i" for credit/deposit/refund/salary
  cat    one of: housing utilities groceries transport insurance dining leisure
         travel shopping subscriptions investments savings debt salary business
         interest refund rent_income other

Rules:
1. Every debit is kind "e"; every credit is kind "i". Amounts stay positive.
2. "cb" is the statement's closing/final balance, or null if not stated.
3. "cur" is the statement currency (INR, AED, USD...), from the header.
4. Include EVERY transaction line. Do not summarise or omit any.
5. Output JSON only. No markdown, no commentary.

STATEMENT:
$clipped
''';

    try {
      final jsonText = await _complete(
        user: prompt,
        jsonMode: true,
        temperature: 0.1,
        maxTokens: statementMaxTokens,
        timeout: statementTimeout,
      );
      final decoded = _decodeJson(jsonText);
      lastClosingBalance = null;
      if (decoded is! Map) return [];

      lastClosingBalance = (decoded['cb'] as num?)?.toDouble() ??
          (decoded['closing_balance'] as num?)?.toDouble();
      final currency = (decoded['cur'] ?? decoded['currency'])?.toString();

      final rows = (decoded['t'] as List?) ?? (decoded['transactions'] as List?);
      if (rows == null) return [];

      final out = <Map<String, dynamic>>[];
      for (final row in rows) {
        // Tolerate the model falling back to the older object shape.
        if (row is Map) {
          final m = row.cast<String, dynamic>();
          m['currency'] ??= currency;
          out.add(m);
        } else if (row is List) {
          final expanded = _expandCompactRow(row, currency);
          if (expanded != null) out.add(expanded);
        }
      }
      return out;
    } catch (e) {
      throw Exception('Failed to parse statement: $e');
    }
  }

  /// Turn `[date, desc, amount, kind, cat]` into the map shape the rest of
  /// the app consumes, deriving merchant and transaction class locally.
  static Map<String, dynamic>? _expandCompactRow(List row, String? currency) {
    if (row.length < 4) return null;
    final amount = (row[2] as num?)?.toDouble();
    if (amount == null) return null;
    final date = row[0]?.toString() ?? '';
    final description = row[1]?.toString() ?? '';
    final kind = row[3]?.toString().toLowerCase() ?? 'e';
    final category = row.length > 4 ? row[4]?.toString() : null;
    final type = kind.startsWith('i') ? 'income' : 'expense';

    return {
      'date': date,
      'description': description,
      'merchant': _merchantFromDescription(description),
      'amount': amount.abs(),
      'currency': currency,
      'type': type,
      'txn_class': _classifyDescription(description, type),
      'category_hint': category,
    };
  }

  /// Best-effort merchant name from a statement narration. Bank narrations
  /// are mostly `UPI/<MERCHANT>/<ref>` or `POS <MERCHANT> <city>`, so the
  /// leading alphabetic run is a better merchant key than an AI guess — and
  /// it is stable, which is what the learned-category map needs.
  static String? _merchantFromDescription(String description) {
    final cleaned = description
        .toUpperCase()
        .replaceAll(RegExp(r'\b(UPI|POS|NEFT|IMPS|ACH|RTGS|ATM|REF|TXN)\b'), ' ')
        .replaceAll(RegExp(r'[0-9]{4,}'), ' ')
        .replaceAll(RegExp(r'[^A-Z ]+'), ' ');
    final words =
        cleaned.split(RegExp(r'\s+')).where((w) => w.length >= 3).toList();
    if (words.isEmpty) return null;
    return words.take(3).join(' ').trim();
  }

  /// Coarse transaction class, used by the import guards: a card payment or a
  /// salary credit is legitimately far larger than the lines around it and
  /// must not be discarded as a peer outlier.
  static String _classifyDescription(String description, String type) {
    final s = description.toLowerCase();
    if (RegExp(r'credit card|card payment|cc payment|bill pay|payment received')
        .hasMatch(s)) {
      return 'cc_payment';
    }
    if (RegExp(r'\bsip\b|mutual fund|zerodha|groww|invest').hasMatch(s)) {
      return 'investment';
    }
    if (RegExp(r'\bneft\b|\bimps\b|\brtgs\b|self|own account').hasMatch(s)) {
      return 'own_transfer';
    }
    if (RegExp(r'charge|fee|gst|interest levied').hasMatch(s)) return 'fee';
    return type == 'income' ? 'income' : 'purchase';
  }

  /// Extract HOLDINGS from a brokerage / demat / mutual-fund statement.
  ///
  /// Windowed like [parseStatementText] — a CDSL CAS or Zerodha quarterly
  /// statement with many folios runs well past one request, and clipping it
  /// dropped most holdings. Rows use a compact array format for the same
  /// throughput reason as bank statements. Each returned map carries
  /// `symbol`, `name`, `isin`, `quantity`, `price`, `value`, `kind`.
  static Future<List<Map<String, dynamic>>> parseBrokerageStatement(
      String statementText) async {
    if (!_ready && !await initialize()) {
      throw Exception('AI is not configured. Add your API key in Settings.');
    }

    final windows = _splitStatement(statementText);
    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};
    double? portfolio;
    String? asOf;
    Object? lastError;
    var succeeded = 0;

    for (var i = 0; i < windows.length; i++) {
      try {
        final result = await _parseBrokerageWindow(windows[i]);
        succeeded++;
        portfolio ??= result.portfolioValue;
        asOf ??= result.asOf;
        for (final h in result.holdings) {
          // Overlapping windows re-emit boundary rows; key on ISIN when the
          // statement prints one (CAS always does), else on the symbol.
          final key = ((h['isin'] ?? '') as String).isNotEmpty
              ? 'isin:${h['isin']}'
              : 'sym:${(h['symbol'] ?? h['name'] ?? '').toString().toLowerCase()}';
          if (seen.add(key)) merged.add(h);
        }
      } catch (e) {
        lastError = e;
        debugPrint('⚠️ Brokerage window ${i + 1}/${windows.length} failed: $e');
      }
    }

    if (succeeded == 0) {
      throw Exception(
          'Failed to parse brokerage statement: ${lastError ?? 'no windows succeeded'}');
    }
    lastClosingBalance = portfolio;
    lastStatementDate = asOf;
    return merged;
  }

  /// "As of" date reported by the most recent brokerage parse (ISO date), if
  /// the statement stated one.
  static String? lastStatementDate;

  static Future<({List<Map<String, dynamic>> holdings, double? portfolioValue, String? asOf})>
      _parseBrokerageWindow(String clipped) async {
    final prompt = '''
Extract every HOLDING from the brokerage / demat / mutual fund statement below
(Zerodha, Groww, Upstox, CDSL/NSDL CAS, CAMS, KFintech, NPS).

Return ONE JSON object, no markdown:
{"pv":<total portfolio value or null>,"cur":"<ISO currency>","asof":"YYYY-MM-DD or null","h":[[symbol,name,isin,qty,price,value,kind],...]}

Each holding is a 7-element ARRAY, not an object:
  symbol  trading symbol or scheme short name (e.g. "INFY", "TCS", "HDFC Flexi Cap")
  name    full security / scheme name
  isin    ISIN if printed (e.g. "INE009A01021"), else null
  qty     units or shares held (number)
  price   closing price / NAV per unit if printed, else null
  value   current market value of the holding (qty × price) in the statement currency
  kind    "s" for stock or ETF, "m" for mutual fund, "n" for NPS / pension, "b" for bond

Rules:
1. Include EVERY equity, ETF, mutual fund, NPS and bond holding. Do not summarise.
2. This is a HOLDINGS list, not a ledger — ignore buy/sell transactions and charges.
3. "pv" is the statement's stated total portfolio / holdings value, or null.
4. Output JSON only. No markdown, no commentary.

STATEMENT:
$clipped
''';

    final jsonText = await _complete(
      user: prompt,
      jsonMode: true,
      temperature: 0.1,
      maxTokens: statementMaxTokens,
      timeout: statementTimeout,
    );
    final decoded = _decodeJson(jsonText);
    if (decoded is! Map) return (holdings: <Map<String, dynamic>>[], portfolioValue: null, asOf: null);

    final portfolio = (decoded['pv'] as num?)?.toDouble() ??
        (decoded['portfolio_value'] as num?)?.toDouble();
    final asOf = decoded['asof']?.toString();
    final rows = (decoded['h'] as List?) ?? (decoded['holdings'] as List?) ?? const [];

    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (row is Map) {
        // Tolerate the older object shape.
        final m = row.cast<String, dynamic>();
        m['kind'] = _normalizeHoldingKind(m['kind']?.toString());
        out.add(m);
      } else if (row is List && row.length >= 6) {
        final value = (row[5] as num?)?.toDouble();
        if (value == null) continue;
        out.add({
          'symbol': row[0]?.toString(),
          'name': row[1]?.toString(),
          'isin': row[2]?.toString(),
          'quantity': (row[3] as num?)?.toDouble(),
          'price': (row[4] as num?)?.toDouble(),
          'value': value,
          'kind': _normalizeHoldingKind(row.length > 6 ? row[6]?.toString() : null),
        });
      }
    }
    return (holdings: out, portfolioValue: portfolio, asOf: asOf);
  }

  /// Map the model's kind code onto the Asset `type` values the app uses.
  static String _normalizeHoldingKind(String? k) {
    switch ((k ?? 's').toLowerCase()) {
      case 'm':
      case 'mutual_fund':
      case 'mutual_funds':
        return 'mutual_funds';
      case 'n':
      case 'nps':
        return 'nps';
      case 'b':
      case 'bond':
        return 'bonds';
      default:
        return 'stocks';
    }
  }

  static Future<String> askQuestion(String question, String contextData) async {
    if (!_ready && !await initialize()) {
      throw Exception('AI is not configured. Add your API key in Settings.');
    }

    final prompt = '''
You are WealthOrbit AI, a helpful personal finance assistant for NRI individuals managing finances in UAE and India.

USER'S FINANCIAL CONTEXT:
$contextData

USER'S QUESTION:
$question

Provide a helpful, actionable answer. Use the user's financial context when relevant.
Format your response with markdown (bold text with **, bullet points with •) for better readability.
Keep responses concise but comprehensive. Be friendly and professional.
''';

    try {
      return await _complete(
        user: prompt,
        jsonMode: false,
        temperature: 0.7,
        maxTokens: 1200,
        timeout: const Duration(minutes: 3),
      );
    } catch (e) {
      debugPrint('AI Chat error: $e');
      throw Exception('Failed to get response: $e');
    }
  }

  static Future<List<String>> detectAnomalies(
      List<Map<String, dynamic>> recentTransactions) async {
    if (!_ready && !await initialize()) return [];

    final prompt = '''
Analyze these recent transactions for anomalies or notable patterns:

${json.encode(recentTransactions)}

Return a JSON array of warning strings. Examples:
- "Subscription increase: Netflix went up by \$2"
- "Unusual spending: \$500 at Unknown Merchant"
- "Duplicate charge: Two transactions for same amount at same merchant"

Only return genuine concerns. Return empty array [] if nothing notable.
Output JSON only.
''';

    try {
      final jsonText = await _complete(
        user: prompt,
        jsonMode: true,
        temperature: 0.2,
        maxTokens: 800,
        timeout: const Duration(minutes: 3),
      );
      final decoded = _decodeJson(jsonText);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Propose self-transfer / CC-payment pairs among unmatched ledger rows.
  /// Does not invent FX rates — compare amountBase for cross-currency.
  static Future<List<Map<String, dynamic>>> matchTransferPairs({
    required List<Map<String, dynamic>> accounts,
    required List<Map<String, dynamic>> candidates,
  }) async {
    if (!_ready && !await initialize()) return [];
    if (candidates.length < 2) return [];

    final prompt = '''
You match OWN-ACCOUNT transfers and credit-card bill payments in a personal finance ledger.

ACCOUNTS (user's own banks/cards):
${json.encode(accounts)}

CANDIDATE TRANSACTIONS (unmatched income/expense only):
${json.encode(candidates)}

Return ONE JSON object:
{
  "pairs": [
    {
      "fromTxnId": "expense-side id",
      "toTxnId": "income-side id",
      "kind": "own_transfer" | "cc_payment" | "duplicate_spend",
      "confidence": 0.0-1.0,
      "reason": "one short sentence"
    }
  ]
}

Rules:
1. fromTxnId should be the outflow (expense); toTxnId the inflow (income) when possible.
2. Different accountId required. Never pair two rows on the same account.
3. Dates within 5 days.
4. Same currency: amounts within 0.01 or 1%. Cross-currency: amountBase within 3% (do NOT invent FX rates).
5. own_transfer = money between user's own bank/wallet accounts.
6. cc_payment = bank/wallet debit funding a credit_card account credit (PAYMENT RECEIVED / bill pay).
7. duplicate_spend = same purchase on two credit cards (do not convert to transfer).
8. Prefer fewer high-confidence pairs over many weak ones. Max 25 pairs.
9. Output JSON only.

''';

    try {
      final jsonText = await _complete(
        user: prompt,
        jsonMode: true,
        temperature: 0.1,
        maxTokens: 2500,
        timeout: statementTimeout,
      );
      final decoded = _decodeJson(jsonText);
      List? list;
      if (decoded is Map) {
        list = decoded['pairs'] as List?;
      } else if (decoded is List) {
        list = decoded;
      }
      if (list == null) return [];
      return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (e) {
      debugPrint('matchTransferPairs error: $e');
      return [];
    }
  }

  /// Narrate a monthly financial-health wrap from a Dart-computed snapshot.
  /// Must not invent numbers — only use values present in [snapshot].
  static Future<Map<String, dynamic>> generateCoachReport(
      Map<String, dynamic> snapshot) async {
    if (!_ready && !await initialize()) {
      throw Exception('AI is not configured.');
    }

    final prompt = '''
You are WealthOrbit Financial Health Coach for an NRI managing AED/INR/USD accounts.
Write a monthly wrap like a health coach: warm, specific, actionable. Not an auditor.

SNAPSHOT (all amounts already in the user's base currency — trust these numbers):
${json.encode(snapshot)}

Return ONE JSON object:
{
  "headline": "one sentence",
  "went_well": ["2-4 bullets citing snapshot fields"],
  "watch": ["2-4 bullets"],
  "actions": ["exactly 3 specific actions with amounts/accounts when possible"],
  "question": "one follow-up question for chat"
}

Rules:
1. Do NOT invent amounts, rates, or a different score. Use snapshot.score as-is.
2. If unmatched_transfer_risk is true, warn that spending may be overstated until transfers are confirmed.
3. Be NRI-aware when cash_mix shows multiple currencies.
4. Tone: coach, not lecture. Output JSON only.
''';

    final jsonText = await _complete(
      user: prompt,
      jsonMode: true,
      temperature: 0.4,
      maxTokens: 1500,
      timeout: statementTimeout,
    );
    final decoded = _decodeJson(jsonText);
    if (decoded is! Map) {
      throw Exception('Coach report was not a JSON object');
    }
    final report = decoded.cast<String, dynamic>();
    if (!_coachReportUsesSnapshotNumbers(report, snapshot)) {
      debugPrint('⚠️ Coach report failed number-grounding check; keeping narrative');
    }
    return report;
  }

  /// Cheap grounding check: every number of 3+ digits the coach quotes should
  /// also appear in the snapshot it was given, so a hallucinated figure is at
  /// least logged. Soft fail — the narrative is still returned.
  ///
  /// This previously `continue`d in every branch and returned `true`
  /// unconditionally, so it could never flag anything.
  static bool _coachReportUsesSnapshotNumbers(
    Map<String, dynamic> report,
    Map<String, dynamic> snapshot,
  ) {
    final snapText = json.encode(snapshot);
    final reportText = json.encode(report);
    final ungrounded = <String>[];
    for (final m in RegExp(r'\d{3,}').allMatches(reportText)) {
      final n = m.group(0)!;
      if (!snapText.contains(n)) ungrounded.add(n);
    }
    if (ungrounded.isNotEmpty) {
      debugPrint('⚠️ Coach quoted numbers absent from the snapshot: '
          '${ungrounded.take(5).join(', ')}');
      return false;
    }
    return true;
  }

  static Future<String> _complete({
    String? apiKey,
    required String user,
    required bool jsonMode,
    double temperature = 0.2,
    int maxTokens = 2048,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final key = apiKey ?? await SecureVault.getGeminiApiKey();
    if (key == null || key.isEmpty) {
      throw Exception('No AI API key configured');
    }

    final system = jsonMode
        ? 'You are a JSON generator. Thinking is disabled. Reply with a single valid JSON value and nothing else. No markdown fences. No reasoning.'
        : 'Thinking is disabled. Answer directly and concisely. No hidden reasoning.';

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': system},
      // Qwen thinking models honor this token; without it they fill
      // reasoning_content and leave content empty.
      {'role': 'user', 'content': '/no_think\n$user'},
    ];

    var lastError = '';
    http.Response? response;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        debugPrint('🔁 LLM retry after $lastError');
        await Future<void>.delayed(const Duration(seconds: 8));
      }
      try {
        final res = await http
            .post(
              Uri.parse(endpoint),
              headers: {
                'Authorization': 'Bearer $key',
                'Content-Type': 'application/json',
              },
              body: json.encode({
                'model': model,
                'messages': messages,
                'temperature': temperature,
                'max_tokens': maxTokens,
                'chat_template_kwargs': {'enable_thinking': false},
              }),
            )
            .timeout(timeout);
        final timedOut = res.statusCode == 408 ||
            res.statusCode == 524 ||
            res.body.contains('error_524') ||
            res.body.contains('Timeout');
        if (timedOut && attempt == 0) {
          lastError = 'HTTP ${res.statusCode}';
          continue;
        }
        response = res;
        break;
      } on TimeoutException catch (e) {
        lastError = e.toString();
        if (attempt == 0) continue;
        rethrow;
      }
    }
    if (response == null) {
      throw Exception('AI timed out: $lastError');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      _lastError = 'HTTP ${response.statusCode}: ${response.body}';
      debugPrint('❌ LLM error: $_lastError');
      throw Exception('AI HTTP ${response.statusCode}: ${_shortError(response.body)}');
    }

    final decoded = json.decode(response.body);
    if (decoded is! Map) {
      throw Exception('AI returned a malformed payload');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw Exception('AI returned no choices');
    }
    final message = (choices.first as Map)['message'];
    var content = (message is Map ? message['content'] : null)?.toString();
    if (content == null || content.trim().isEmpty) {
      // Thinking models sometimes still park the answer here.
      content = (message is Map ? message['reasoning_content'] : null)?.toString();
    }
    if (content == null || content.trim().isEmpty) {
      throw Exception('AI returned an empty response');
    }
    debugPrint(
        '🤖 LLM ${jsonMode ? "json" : "chat"} ${content.length} chars (thinking off)');
    return content;
  }

  static dynamic _decodeJson(String raw) {
    var jsonText = raw.trim();
    jsonText = jsonText.replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), '').trim();
    if (!jsonText.startsWith('{') && !jsonText.startsWith('[')) {
      final match = RegExp(r'[\{\[][\s\S]*[\}\]]').firstMatch(jsonText);
      if (match != null) jsonText = match.group(0)!;
    }
    return json.decode(jsonText);
  }

  static String _shortError(Object e) {
    final s = e.toString();
    return s.length > 180 ? '${s.substring(0, 180)}…' : s;
  }
}
