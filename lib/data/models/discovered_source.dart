/// Model representing a discovered statement source from email scanning
class DiscoveredSource {
  final String senderEmail;
  final String senderName;
  final int statementCount;
  final List<String> sampleMessageIds; // UIDs of first 5 emails for password testing
  bool isSelected;

  DiscoveredSource({
    required this.senderEmail,
    required this.senderName,
    required this.statementCount,
    required this.sampleMessageIds,
    this.isSelected = false, // Default unselected - user chooses what to import
  });

  /// Guess bank name from sender email
  static String guessNameFromEmail(String email) {
    final lowerEmail = email.toLowerCase();
    
    // Indian Banks
    if (lowerEmail.contains('hdfc')) return 'HDFC Bank';
    if (lowerEmail.contains('icici')) return 'ICICI Bank';
    if (lowerEmail.contains('sbi') || lowerEmail.contains('statebank')) return 'State Bank of India';
    if (lowerEmail.contains('axis')) return 'Axis Bank';
    if (lowerEmail.contains('kotak')) return 'Kotak Mahindra Bank';
    if (lowerEmail.contains('indusind')) return 'IndusInd Bank';
    if (lowerEmail.contains('idfc')) return 'IDFC First Bank';
    if (lowerEmail.contains('yes')) return 'Yes Bank';
    if (lowerEmail.contains('pnb')) return 'Punjab National Bank';
    if (lowerEmail.contains('bob') || lowerEmail.contains('bankofbaroda')) return 'Bank of Baroda';
    
    // UAE Banks
    if (lowerEmail.contains('enbd') || lowerEmail.contains('emiratesnbd')) return 'Emirates NBD';
    if (lowerEmail.contains('adcb')) return 'ADCB';
    if (lowerEmail.contains('fab') || lowerEmail.contains('nbad')) return 'First Abu Dhabi Bank';
    if (lowerEmail.contains('mashreq')) return 'Mashreq Bank';
    if (lowerEmail.contains('dib')) return 'Dubai Islamic Bank';
    if (lowerEmail.contains('rakbank')) return 'RAKBank';
    if (lowerEmail.contains('cbd')) return 'Commercial Bank of Dubai';
    
    // Brokerages
    if (lowerEmail.contains('zerodha')) return 'Zerodha';
    if (lowerEmail.contains('groww')) return 'Groww';
    if (lowerEmail.contains('upstox')) return 'Upstox';
    if (lowerEmail.contains('angelone') || lowerEmail.contains('angelbroking')) return 'Angel One';
    if (lowerEmail.contains('paytm')) return 'Paytm Money';
    if (lowerEmail.contains('kite')) return 'Zerodha Kite';
    if (lowerEmail.contains('5paisa')) return '5Paisa';
    if (lowerEmail.contains('icicidirect')) return 'ICICI Direct';
    
    // Credit Cards / Wallets
    if (lowerEmail.contains('amex') || lowerEmail.contains('americanexpress')) return 'American Express';
    if (lowerEmail.contains('citi')) return 'Citibank';
    if (lowerEmail.contains('hsbc')) return 'HSBC';
    if (lowerEmail.contains('sc.com') || lowerEmail.contains('standardchartered')) return 'Standard Chartered';
    if (lowerEmail.contains('paypal')) return 'PayPal';
    
    // Extract domain name as fallback, skipping generic mail-infrastructure
    // subdomains so "statements@email.bank.com" becomes "Bank", not "Email".
    const generic = {
      'email', 'emails', 'mail', 'mails', 'e', 'em', 'smtp', 'mta',
      'info', 'news', 'newsletter', 'notify', 'notification', 'notifications',
      'alerts', 'alert', 'no-reply', 'noreply', 'donotreply', 'statements',
      'estatements', 'service', 'services', 'secure', 'comm', 'comms', 'crm',
    };
    final atIndex = email.indexOf('@');
    if (atIndex > 0) {
      final parts = email.substring(atIndex + 1).split('.');
      // Drop the TLD/ccTLD tail and find the first meaningful label.
      final labels = parts.length > 1 ? parts.sublist(0, parts.length - 1) : parts;
      final meaningful = labels.firstWhere(
        (p) => p.length > 2 && !generic.contains(p.toLowerCase()),
        orElse: () => labels.isNotEmpty ? labels.last : '',
      );
      if (meaningful.isNotEmpty) {
        return meaningful.substring(0, 1).toUpperCase() + meaningful.substring(1);
      }
    }

    return 'Unknown Source';
  }

  /// Get icon for this source type
  String get iconName {
    final lowerName = senderName.toLowerCase();
    if (lowerName.contains('bank') || lowerName.contains('nbd') || lowerName.contains('adcb')) {
      return 'account_balance';
    }
    if (lowerName.contains('zerodha') || lowerName.contains('groww') || lowerName.contains('upstox') || 
        lowerName.contains('angel') || lowerName.contains('paytm') || lowerName.contains('5paisa')) {
      return 'trending_up';
    }
    if (lowerName.contains('amex') || lowerName.contains('citi') || lowerName.contains('hsbc')) {
      return 'credit_card';
    }
    if (lowerName.contains('paypal')) {
      return 'payment';
    }
    return 'email';
  }
}
