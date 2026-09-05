/// Tells a credit-card statement from a bank statement by reading the
/// document, rather than guessing from who sent it.
///
/// Banks send both kinds from lookalike addresses, and the app was routing
/// on the sender's name — so Wio's card statement and Wio's account
/// statement both landed in one "Wio" bank account. On a card statement a
/// repayment is a POSITIVE number:
///
///     Credit Repayment            +4,561.23
///     Garden fresh                   -30.00
///
/// Imported into a bank account, that repayment reads as income, and every
/// month's earnings gain the size of the card bill. The document itself is
/// unambiguous where the sender is not: only a card statement quotes a
/// credit limit, a minimum payment and a payment due date.
library;

enum StatementKind { creditCard, bank }

class StatementKindDetector {
  /// Phrases that appear on card statements and essentially never on a
  /// current-account statement.
  static final List<RegExp> _cardMarkers = [
    RegExp(r'credit\s*limit', caseSensitive: false),
    RegExp(r'available\s*credit', caseSensitive: false),
    RegExp(r'min(imum)?\.?\s*(payment|amount)\s*due', caseSensitive: false),
    RegExp(r'payment\s*due\s*date', caseSensitive: false),
    RegExp(r'credit\s*statement', caseSensitive: false),
    RegExp(r'total\s*to\s*pay', caseSensitive: false),
    RegExp(r'card\s*number', caseSensitive: false),
    RegExp(r'statement\s*of\s*(your\s*)?credit\s*card', caseSensitive: false),
    RegExp(r'cash\s*limit', caseSensitive: false),
    RegExp(r'reward\s*points', caseSensitive: false),
  ];

  /// Phrases specific to a deposit account. Used only to break a tie: a card
  /// statement may legitimately mention an IBAN for making the payment.
  static final List<RegExp> _bankMarkers = [
    RegExp(r'\bopening\s*balance\b', caseSensitive: false),
    RegExp(r'\bclosing\s*balance\b', caseSensitive: false),
    RegExp(r'\bavailable\s*balance\b', caseSensitive: false),
    RegExp(r'\bsavings?\s*account\b', caseSensitive: false),
    RegExp(r'\bcurrent\s*account\b', caseSensitive: false),
    RegExp(r'\bvalue\s*date\b', caseSensitive: false),
    // A real Emirates NBD savings statement scored only one marker and so
    // stayed in the credit-card account it had been aimed at, where its
    // balance was stored as debt. These are what that document actually
    // says: an account number, an IBAN, a branch, an interest payout.
    RegExp(r'\baccount\s*(no\.?|number)\b', caseSensitive: false),
    RegExp(r'\biban\b', caseSensitive: false),
    RegExp(r'\bbranch\b', caseSensitive: false),
    RegExp(r'\binterest\s*payout\b', caseSensitive: false),
    RegExp(r'\bstatement\s*of\s*account\b', caseSensitive: false),
    RegExp(r'\bdeposit\b', caseSensitive: false),
  ];

  /// How many card phrases must appear before a document counts as a card
  /// statement. Two, because one can appear in boilerplate — the real
  /// samples score 3–7 for cards and 0 for a bank statement, so the
  /// separation is wide and the threshold is not delicately placed.
  static const cardMarkerThreshold = 2;

  static int cardScore(String text) =>
      _cardMarkers.where((r) => r.hasMatch(text)).length;

  static int bankScore(String text) =>
      _bankMarkers.where((r) => r.hasMatch(text)).length;

  /// What kind of statement this is, or null when the text gives no clear
  /// answer — in which case the caller should keep the account it has
  /// rather than move the import somewhere on a guess.
  static StatementKind? detect(String text) {
    if (text.trim().length < 200) return null;
    final card = cardScore(text);
    if (card >= cardMarkerThreshold) {
      // A card statement quoting an IBAN for payments still scores here;
      // only an overwhelming deposit-account vocabulary overrides it.
      if (bankScore(text) >= card + 2) return StatementKind.bank;
      return StatementKind.creditCard;
    }
    if (bankScore(text) >= 2) return StatementKind.bank;
    return null;
  }
}
