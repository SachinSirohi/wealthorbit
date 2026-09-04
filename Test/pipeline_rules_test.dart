import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_orbit/core/amount_sanity.dart';
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
}
