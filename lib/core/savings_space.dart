/// Recognises money moving between a current account and a savings pot held
/// at the same bank — Wio's "Saving Spaces", Revolut Vaults, Monzo Pots.
///
/// On a Wio statement a fixed deposit looks like this:
///
///     Sirohi Sachin ... to Fixed Saving Space      -80,507.00
///     Fixed Saving Space to Sirohi Sachin ...       80,507.00
///     Interest applied from Fixed Saving Space          318.67
///
/// Read literally that is 80,507 of spending followed by 80,507 of income,
/// every time money is parked. It is neither: the money never left the
/// user. Worse, the balance sitting in those pots — the fixed deposits —
/// appeared nowhere at all, because nothing modelled them.
///
/// The interest line is the exception and must stay income: that is money
/// genuinely earned.
library;

class SavingsSpaceMove {
  /// The pot's name as printed, e.g. "Fixed Saving Space".
  final String pot;

  /// True when money is going INTO the pot (out of the current account).
  final bool intoPot;

  const SavingsSpaceMove({required this.pot, required this.intoPot});
}

class SavingsSpace {
  /// Words that mark one side of a transfer as a savings pot rather than a
  /// person or a merchant. Deliberately narrow: a false positive would hide
  /// real spending, which is worse than missing a pot.
  static final RegExp _potWords =
      RegExp(r'saving|space|vault|\bpot\b|deposit', caseSensitive: false);

  /// "Interest applied from Fixed Saving Space" names a pot but is not a
  /// movement between accounts — it is interest earned, and must stay income.
  static final RegExp _interest = RegExp(
      r'\binterest\b|\bprofit\b|\bapplied from\b',
      caseSensitive: false);

  /// The pot movement this description represents, or null.
  static SavingsSpaceMove? detect(String description) {
    final text = description.trim();
    if (text.isEmpty) return null;
    if (_interest.hasMatch(text)) return null;

    final match = RegExp(r'^(.*?)\s+to\s+(.*)$', caseSensitive: false)
        .firstMatch(text);
    if (match == null) return null;

    final left = match.group(1)!.trim();
    final right = match.group(2)!.trim();
    if (left.isEmpty || right.isEmpty) return null;

    final leftIsPot = _isPot(left);
    final rightIsPot = _isPot(right);
    // Exactly one side must look like a pot. "Saving to Saving" tells us
    // nothing, and neither does a payment between two people.
    if (leftIsPot == rightIsPot) return null;

    return rightIsPot
        ? SavingsSpaceMove(pot: _clean(right), intoPot: true)
        : SavingsSpaceMove(pot: _clean(left), intoPot: false);
  }

  static bool _isPot(String side) {
    if (!_potWords.hasMatch(side)) return false;
    // A pot name is short. "Transfer to Ahmed Saving Trading LLC" is a
    // payment to a company that happens to contain the word.
    final words = side.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    return words <= 4;
  }

  static String _clean(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// A stable account name for the pot, e.g. "Wio · Fixed Saving Space".
  static String accountName(String bankName, String pot) =>
      '$bankName · $pot';
}
