/// Multi-currency helpers: which currency a bank reports in, fallback FX
/// rates relative to AED, and consistent symbol formatting.
library;

import 'package:intl/intl.dart';

class CurrencyUtils {
  CurrencyUtils._();

  static const symbols = {
    'AED': 'AED ',
    'USD': '\$',
    'INR': '₹',
    'EUR': '€',
    'GBP': '£',
    'SAR': 'SAR ',
  };

  /// Fallback "value of 1 unit in AED" used when live FX is unavailable.
  /// (AED is USD-pegged at ~3.6725.)
  static const fallbackRatesToAed = {
    'AED': 1.0,
    'USD': 3.6725,
    'INR': 0.0441,
    'EUR': 3.97,
    'GBP': 4.64,
    'SAR': 0.979,
  };

  static const _inrHints = [
    'hdfc', 'icici', 'sbi', 'state bank', 'axis', 'kotak', 'zerodha', 'groww',
    'upstox', 'indusind', 'yes bank', 'idfc', 'idbi', 'pnb', 'canara', 'rbl',
    'federal bank', 'bank of baroda', 'paytm', 'cred', '.in', 'india', 'inr',
  ];
  static const _aedHints = [
    'emirates nbd', 'enbd', 'emiratesnbd', 'adcb', 'mashreq', 'fab', 'bankfab',
    'first abu dhabi', 'dib', 'dubai islamic', 'rakbank', 'rak bank', 'cbd',
    'commercial bank of dubai', 'wio', 'deem', 'noon', 'liv.', '.ae', 'uae',
  ];
  static const _usdHints = ['paypal', 'wise', 'chase', 'citi', 'bofa', 'wells fargo', '.com bank'];

  /// Best-guess reporting currency for a bank, from its name and/or sender email.
  static String currencyForBank(String text) {
    final s = text.toLowerCase();
    for (final h in _inrHints) {
      if (s.contains(h)) return 'INR';
    }
    for (final h in _aedHints) {
      if (s.contains(h)) return 'AED';
    }
    for (final h in _usdHints) {
      if (s.contains(h)) return 'USD';
    }
    return 'AED';
  }

  /// Heuristic: does this bank/sender text refer to a CREDIT CARD product?
  static bool isCreditCardHint(String text) {
    final s = text.toLowerCase();
    return s.contains('card') || s.contains('credit');
  }

  static String symbolFor(String code) => symbols[code] ?? '$code ';

  /// Format [amount] in [code]'s own currency, e.g. `₹91,630` / `AED 4,041`.
  static String format(double amount, String code, {int decimals = 0}) {
    return NumberFormat.currency(symbol: symbolFor(code), decimalDigits: decimals).format(amount);
  }

  /// Compact form, e.g. `₹1.2L`-style not needed; use compact: `AED 4.0K`.
  static String formatCompact(double amount, String code) {
    return NumberFormat.compactCurrency(symbol: symbolFor(code), decimalDigits: 1).format(amount);
  }
}
