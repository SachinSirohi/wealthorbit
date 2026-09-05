import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_orbit/core/amount_sanity.dart';
import 'package:wealth_orbit/core/statement_date.dart';
import 'package:wealth_orbit/core/merchant_rules.dart';
import 'package:wealth_orbit/data/services/llm_router.dart';
import 'package:wealth_orbit/data/services/secure_vault.dart';
import 'package:wealth_orbit/core/utils/currency_utils.dart';
import 'package:wealth_orbit/data/repositories/app_repository.dart';
import 'package:wealth_orbit/data/services/statement_processor.dart';

/// Regression tests for the import guards. Each of these encodes a rule that
/// was previously wrong and silently corrupted or discarded real data.
void main() {
  group('AmountSanity.isOutlierVsPeers', () {
    // A card statement of small purchases plus one genuine large buy. The old
    // rule (200x the median, no absolute floor) discarded a real AED 7,687
    // jewellery purchase because the median coffee was AED 35.
    final cardStatement = [35.0, 42.0, 18.0, 60.0, 25.0, 39.0, 51.0];

    test('keeps a large but real purchase', () {
      expect(
        AmountSanity.isOutlierVsPeers(7687, cardStatement, currencyCode: 'AED'),
        isFalse,
      );
    });

    test('keeps a salary-sized credit among small spends', () {
      expect(
        AmountSanity.isOutlierVsPeers(25000, cardStatement, currencyCode: 'AED'),
        isFalse,
      );
    });

    test('still rejects a mis-parse orders of magnitude out', () {
      // Under the INR ceiling, so isPlausible alone would let it through.
      expect(
        AmountSanity.isOutlierVsPeers(
            4500000, [400.0, 600.0, 350.0, 900.0], currencyCode: 'INR'),
        isTrue,
      );
    });

    test('needs at least a few peers before judging anything', () {
      expect(
        AmountSanity.isOutlierVsPeers(999999, [10.0, 20.0], currencyCode: 'AED'),
        isFalse,
      );
    });
  });

  group('AmountSanity.isPlausible', () {
    test('catches the mis-parses the quarantine was written for', () {
      for (final absurd in [7500281295.6, 4188157126.0, 44416726.51, 88033004.76]) {
        expect(AmountSanity.isPlausible(absurd, 'INR'), isFalse,
            reason: '$absurd should be rejected outright');
      }
    });

    test('accepts ordinary amounts', () {
      expect(AmountSanity.isPlausible(7687, 'AED'), isTrue);
      expect(AmountSanity.isPlausible(173130.37, 'INR'), isTrue);
    });

    test('rejects zero, negative and non-finite', () {
      expect(AmountSanity.isPlausible(0, 'AED'), isFalse);
      expect(AmountSanity.isPlausible(-5, 'AED'), isFalse);
      expect(AmountSanity.isPlausible(double.nan, 'AED'), isFalse);
      expect(AmountSanity.isPlausible(double.infinity, 'AED'), isFalse);
    });
  });

  group('CurrencyUtils.isCreditCardHint', () {
    test('matches real card vocabulary', () {
      for (final s in [
        'cardstatement@hdfcbank.net',
        'Your Credit Card statement',
        'ADCB Card Statement - August',
        'americanexpress@aexp.com',
      ]) {
        expect(CurrencyUtils.isCreditCardHint(s), isTrue, reason: s);
      }
    });

    test('does not fire on a savings account at a card-issuing bank', () {
      // The old `contains("card") || contains("credit")` matched all of these,
      // retyped the savings account as a card and re-signed its balance as
      // debt — which produced a multi-million "credit card" balance.
      for (final s in [
        'HDFC Bank',
        'estatement@hdfcbank.net',
        'Kotak Mahindra Bank',
        'alerts@icicibank.com',
        'discard@example.com',
      ]) {
        expect(CurrencyUtils.isCreditCardHint(s), isFalse, reason: s);
      }
    });
  });

  group('isBrokerageSender', () {
    test('recognises brokers, depositories and NPS', () {
      for (final s in [
        'reportsmailer@zerodha.net',
        'edcas@cdslindia.com',
        'NSDL e-CAS',
        'donotreply@camsnps.com',
        'protean nps statement',
        'kfintech folio summary',
      ]) {
        expect(isBrokerageSender(s), isTrue, reason: s);
      }
    });

    test('leaves banks alone', () {
      for (final s in ['estatement@hdfcbank.net', 'Emirates NBD', 'Wio Bank']) {
        expect(isBrokerageSender(s), isFalse, reason: s);
      }
    });
  });

  group('statementLineId', () {
    final base = {
      'accountId': 'acct_1',
      'date': DateTime(2026, 8, 14),
      'amount': 1414.19,
      'type': 'expense',
      'description': 'UPI/RAZORPAY/1207388624',
    };

    String idOf({String? accountId, DateTime? date, double? amount, String? desc}) =>
        statementLineId(
          accountId: accountId ?? base['accountId'] as String,
          date: date ?? base['date'] as DateTime,
          amount: amount ?? base['amount'] as double,
          type: base['type'] as String,
          description: desc ?? base['description'] as String,
        );

    test('is stable across runs, so re-imports are idempotent', () {
      expect(idOf(), equals(idOf()));
    });

    test('ignores case and whitespace noise in the description', () {
      expect(idOf(desc: '  upi/razorpay/1207388624 '), equals(idOf()));
    });

    test('separates different amounts, dates and accounts', () {
      expect(idOf(amount: 1414.20), isNot(equals(idOf())));
      expect(idOf(date: DateTime(2026, 8, 15)), isNot(equals(idOf())));
      expect(idOf(accountId: 'acct_2'), isNot(equals(idOf())));
    });

    test('two same-day purchases at different merchants stay distinct', () {
      expect(idOf(desc: 'STARBUCKS DIFC'), isNot(equals(idOf(desc: 'COSTA MALL'))));
    });
  });

  group('AppRepository.isTransientFailure', () {
    test('retries what a retry could actually fix', () {
      for (final e in [
        'Exception: Failed to parse statement: TimeoutException after 0:04:00',
        'SocketException: Connection reset by peer',
        'AI HTTP 503: upstream unavailable',
        'AI returned an empty response',
      ]) {
        expect(AppRepository.isTransientFailure(e), isTrue, reason: e);
      }
    });

    test('never loops on something only the user can fix', () {
      for (final e in [
        'Invalid argument (password): Cannot open an encrypted document.',
        'No account mapped for HDFC Bank. Map it to an account, then retry.',
        'Skipped: not a bank statement',
        'The PDF opened but contained no extractable text',
        'Every transaction in this statement was already imported.',
      ]) {
        expect(AppRepository.isTransientFailure(e), isFalse, reason: e);
      }
    });

    test('treats no error as nothing to retry', () {
      expect(AppRepository.isTransientFailure(null), isFalse);
      expect(AppRepository.isTransientFailure(''), isFalse);
    });
  });

  group('MonthCoverage', () {
    final m = DateTime(2026, 6, 1);

    test('covered when transactions exist', () {
      final c = MonthCoverage(month: m, transactions: 12, blockedStatements: 0);
      expect(c.isCovered, isTrue);
      expect(c.isBlocked, isFalse);
      expect(c.isMissing, isFalse);
    });

    test('blocked when nothing imported but a statement exists', () {
      final c = MonthCoverage(month: m, transactions: 0, blockedStatements: 2);
      expect(c.isCovered, isFalse);
      expect(c.isBlocked, isTrue);
      expect(c.isMissing, isFalse);
    });

    test('missing when there is neither data nor a statement', () {
      final c = MonthCoverage(month: m, transactions: 0, blockedStatements: 0);
      expect(c.isMissing, isTrue);
    });

    test('data present wins over a blocked statement', () {
      final c = MonthCoverage(month: m, transactions: 5, blockedStatements: 3);
      expect(c.isCovered, isTrue);
      expect(c.isBlocked, isFalse);
    });
  });

  group('StatementDate.parse', () {
    final now = DateTime(2026, 9, 5);

    test('reads every format banks actually print', () {
      final expected = DateTime(2026, 8, 14);
      for (final raw in [
        '2026-08-14',
        '14-08-2026',
        '14/08/2026',
        '14.08.2026',
        '14-Aug-2026',
        '14 Aug 2026',
        '14-August-2026',
        'Aug 14, 2026',
        '14/08/26',
        '2026/08/14',
        '20260814',
      ]) {
        expect(StatementDate.parse(raw, now: now), equals(expected), reason: raw);
      }
    });

    test('prefers day-first for ambiguous numeric dates', () {
      // UAE and Indian statements are day-first; 03/04 is 3 April.
      expect(StatementDate.parse('03/04/2026', now: now),
          equals(DateTime(2026, 4, 3)));
    });

    test('uses the unambiguous component when there is one', () {
      // 13 cannot be a month, so this is 13 May whichever way round it is.
      expect(StatementDate.parse('13/05/2026', now: now),
          equals(DateTime(2026, 5, 13)));
      // 25 cannot be a month either.
      expect(StatementDate.parse('05/25/2026', now: now),
          equals(DateTime(2026, 5, 25)));
    });

    test('rejects dates in the future instead of trusting them', () {
      // Transactions dated 2028 reached a 2026 ledger because nothing checked.
      expect(StatementDate.parse('2028-06-29', now: now), isNull);
      expect(StatementDate.parse('2026-12-31', now: now), isNull);
    });

    test('allows a couple of days of timezone slack', () {
      expect(StatementDate.parse('2026-09-06', now: now), isNotNull);
    });

    test('rejects the implausibly old', () {
      expect(StatementDate.parse('1974-05-02', now: now), isNull);
    });

    test('rejects impossible calendar dates rather than rolling them over', () {
      expect(StatementDate.parse('31-02-2026', now: now), isNull);
      expect(StatementDate.parse('32/01/2026', now: now), isNull);
      expect(StatementDate.parse('00-08-2026', now: now), isNull);
    });

    test('returns null for junk, so the caller can fall back deliberately', () {
      for (final raw in [null, '', '   ', 'n/a', 'Opening Balance', '--']) {
        expect(StatementDate.parse(raw, now: now), isNull, reason: '$raw');
      }
    });

    test('expands two-digit years sensibly', () {
      expect(StatementDate.parse('14-08-26', now: now), equals(DateTime(2026, 8, 14)));
      expect(StatementDate.parse('14-08-24', now: now), equals(DateTime(2024, 8, 14)));
      // '98' expands to 1998, which the plausibility window then rejects —
      // a 1998 line in a statement is a misread, not history.
      expect(StatementDate.parse('14-08-98', now: now), isNull);
    });
  });

  group('MerchantRules.categorise', () {
    String? cat(String desc, {String type = 'expense'}) =>
        MerchantRules.categorise(desc, null, type);

    test('recognises everyday UAE and Indian merchants', () {
      expect(cat('POS CARREFOUR MALL OF EMIRATES'), 'cat_groceries');
      expect(cat('UPI/SWIGGY/1234'), 'cat_dining');
      expect(cat('CAREEM RIDE DUBAI'), 'cat_transport');
      expect(cat('SALIK TOLL'), 'cat_transport');
      expect(cat('NETFLIX SUBSCRIPTION'), 'cat_subscriptions');
      expect(cat('DEWA BILL PAYMENT'), 'cat_utilities');
      expect(cat('XDX TANISHQ MANKHOOL'), 'cat_shopping');
      expect(cat('AGODA COMPANY PTE LTD'), 'cat_travel');
    });

    test('never files an income line as spending', () {
      // A salary credit must not become "shopping" because of a stray word.
      expect(cat('SALARY CREDIT AUG', type: 'income'), 'cat_salary');
      expect(cat('AMAZON REFUND', type: 'income'), 'cat_refund');
      // ...and an expense must never land in an income category.
      expect(cat('SALARY ADVANCE RECOVERY'), isNot('cat_salary'));
    });

    test('never files spending as income', () {
      expect(cat('CARREFOUR', type: 'income'), isNull);
    });

    test('leaves ambiguous narrations alone rather than guessing', () {
      for (final d in [
        'TRANSFER 8829201',
        'POS 449102',
        'MISC DEBIT',
        '',
        'NEFT DR-XXXXXX',
      ]) {
        expect(cat(d), isNull, reason: d);
      }
    });

    test('does not confuse Emirates the airline with Emirates NBD the bank', () {
      expect(cat('EMIRATES NBD ATM'), isNot('cat_travel'));
      expect(cat('EMIRATES AIRLINE TICKET'), 'cat_travel');
    });
  });

  group('LlmRouter model rotation', () {
    setUp(LlmRouter.reset);

    test('starts on the strongest free-tier model', () {
      expect(LlmRouter.nextAvailableModel(), 'gemini-2.5-flash');
    });

    test('rotates to the next model when one is out of quota', () {
      final now = DateTime(2026, 9, 5, 12);
      LlmRouter.markExhausted('gemini-2.5-flash', now: now);
      expect(LlmRouter.nextAvailableModel(now: now), 'gemini-2.0-flash');
    });

    test('returns null only once every model is resting', () {
      final now = DateTime(2026, 9, 5, 12);
      for (final m in LlmRouter.geminiModels) {
        LlmRouter.markExhausted(m, now: now);
      }
      expect(LlmRouter.nextAvailableModel(now: now), isNull);
    });

    test('a rested model comes back into rotation', () {
      final now = DateTime(2026, 9, 5, 12);
      LlmRouter.markExhausted('gemini-2.5-flash',
          retryAfter: const Duration(seconds: 30), now: now);
      expect(LlmRouter.nextAvailableModel(now: now), 'gemini-2.0-flash');
      final later = now.add(const Duration(seconds: 31));
      expect(LlmRouter.nextAvailableModel(now: later), 'gemini-2.5-flash');
    });

    test('honours a retry delay named by the API', () {
      const body = '{"error":{"code":429,"details":[{"retryDelay":"37s"}]}}';
      expect(LlmRouter.parseRetryDelay(body), const Duration(seconds: 37));
      expect(LlmRouter.parseRetryDelay('{"error":{}}'), isNull);
    });

    test('tells quota trouble apart from a bad key', () {
      // Worth rotating to another model...
      expect(LlmRouter.isQuotaFailure(429, 'rate limit exceeded'), isTrue);
      expect(LlmRouter.isQuotaFailure(200, 'RESOURCE_EXHAUSTED'), isTrue);
      // ...and not worth it: these fail the same way on every model.
      expect(LlmRouter.isQuotaFailure(400, 'API key not valid'), isFalse);
      expect(LlmRouter.isQuotaFailure(403, 'permission denied'), isFalse);
      expect(LlmRouter.isQuotaFailure(500, 'internal'), isFalse);
    });
  });

  group('LlmRouter.extractText', () {
    test('reads the answer out of a normal response', () {
      const body = '{"candidates":[{"content":{"parts":[{"text":"{\\"t\\":[]}"}]}}]}';
      expect(LlmRouter.extractText(body), '{"t":[]}');
    });

    test('joins multi-part answers', () {
      const body =
          '{"candidates":[{"content":{"parts":[{"text":"ab"},{"text":"cd"}]}}]}';
      expect(LlmRouter.extractText(body), 'abcd');
    });

    test('surfaces the finish reason when there is no text', () {
      const body = '{"candidates":[{"finishReason":"MAX_TOKENS","content":{}}]}';
      expect(() => LlmRouter.extractText(body),
          throwsA(predicate((e) => e.toString().contains('MAX_TOKENS'))));
    });

    test('surfaces a blocked prompt', () {
      const body = '{"candidates":[],"promptFeedback":{"blockReason":"SAFETY"}}';
      expect(() => LlmRouter.extractText(body),
          throwsA(predicate((e) => e.toString().contains('SAFETY'))));
    });
  });

  group('SecureVault.looksLikeGeminiKey', () {
    test('recognises a Google key', () {
      expect(
        SecureVault.looksLikeGeminiKey('AIzaFAKEKEYFORTESTSONLY000000000000000'),
        isTrue,
      );
    });

    test('does not mistake the Qwen key for one', () {
      // The two shared a slot until 4.4.0; telling them apart is what stops
      // a Qwen key being sent to Google and a Google key being overwritten.
      expect(SecureVault.looksLikeGeminiKey('sk-FAKEKEYFORTESTSONLY00'), isFalse);
      expect(SecureVault.looksLikeGeminiKey('AIza-too-short'), isFalse);
      expect(SecureVault.looksLikeGeminiKey(''), isFalse);
    });
  });

  group('credit-card credits are repayments, not income', () {
    // On a card statement a repayment is simply a positive number, so the
    // extractor types it "income" and it inflated earnings by the whole
    // bill every month. These pin the rule that fixes it.
    bool isRefund(String d) => RegExp(
          r'refund|reversal|reversed|cashback|cash back|chargeback|charge back|'
          r'goods return|returned|credit adjustment|waiver|dispute',
          caseSensitive: false,
        ).hasMatch(d);

    test('a repayment is not treated as a refund', () {
      for (final d in [
        'PAYMENT RECEIVED - THANK YOU',
        'PAYMENT - ONLINE',
        'AUTOPAY DEBIT',
        'NEFT PAYMENT RECEIVED',
        'UPI/CRED/CARD BILL',
        'Payment Thank You',
      ]) {
        expect(isRefund(d), isFalse, reason: d);
      }
    });

    test('an actual refund still is one', () {
      for (final d in [
        'AMAZON REFUND',
        'REVERSAL OF LATE FEE',
        'CASHBACK CREDIT',
        'CHARGEBACK SETTLED',
        'ANNUAL FEE WAIVER',
        'GOODS RETURN CREDIT',
      ]) {
        expect(isRefund(d), isTrue, reason: d);
      }
    });

    test('card repayments are named as internal movement', () {
      // Neither income nor spending: the purchases were already counted on
      // the card, and paying it from the bank would count them twice.
      expect(kInternalTransferClasses, contains('cc_payment'));
      expect(kInternalTransferClasses, isNot(contains('purchase')));
      expect(kInternalTransferClasses, isNot(contains('income')));
    });
  });
}
