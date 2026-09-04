/// Guards against AI mis-parsed statement amounts (e.g. Travclan ₹7.5B lines
/// that destroyed HDFC balances). Personal-finance ceilings — anything larger
/// is almost certainly a parse error, not a real spend.
class AmountSanity {
  /// Absolute max in the statement's own currency.
  static double maxForCurrency(String currencyCode) {
    switch (currencyCode.toUpperCase()) {
      case 'INR':
        return 5000000; // ₹50 lakh
      case 'USD':
        return 250000;
      case 'EUR':
      case 'GBP':
        return 200000;
      case 'AED':
      default:
        return 500000; // AED 5 lakh
    }
  }

  /// True when [amount] is positive and within the currency ceiling.
  static bool isPlausible(double amount, String currencyCode) {
    if (amount <= 0) return false;
    if (amount.isNaN || amount.isInfinite) return false;
    return amount <= maxForCurrency(currencyCode);
  }

  /// Below this fraction of the currency ceiling, an amount is ordinary
  /// money and the peer test may not touch it however large the multiple.
  static const _peerFloorFraction = 0.2;

  /// Reject a line that dwarfs its statement AND is itself a lot of money.
  ///
  /// The old rule was `amount > median * 200`, with no absolute floor. On a
  /// card statement of small purchases that is a very low bar: a median of
  /// AED 35 made anything over AED 7,000 "absurd", so a real AED 7,687
  /// jewellery purchase was silently discarded.
  ///
  /// Every mis-parse this guard was written for (the ₹7.5-billion Travclan
  /// lines and friends) sat far above [maxForCurrency] and was already
  /// rejected by [isPlausible]. So the peer test only needs to catch the
  /// rare wrong-by-orders-of-magnitude line that slips under the ceiling:
  /// 1000× the median, and at least a fifth of the ceiling in absolute
  /// terms. Ordinary large spending now survives.
  static bool isOutlierVsPeers(
    double amount,
    List<double> peerAmounts, {
    String currencyCode = 'AED',
  }) {
    final peers = peerAmounts.where((a) => a > 0 && a != amount).toList();
    if (peers.length < 3) return false;
    if (amount < maxForCurrency(currencyCode) * _peerFloorFraction) return false;
    peers.sort();
    final median = peers[peers.length ~/ 2];
    if (median <= 0) return false;
    return amount > median * 1000;
  }
}

/// Insurance / policy / survey mail that looks like a "statement" but is not a
/// bank ledger — skip rather than burning AI tokens / queue capacity.
bool isNonBankStatementSubject(String subject) {
  final s = subject.toLowerCase();
  return RegExp(
    r'life policy|insurance|premium|policy\s+\d|max life|survey|feedback|'
    r'newsletter|promotional|offer for you',
  ).hasMatch(s);
}
