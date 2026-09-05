/// Keyword rules that assign a category from a statement narration.
///
/// The AI supplies a `category_hint` per line, but a quarter of an imported
/// ledger still arrives uncategorised — the hint is missing, unrecognised,
/// or the line is too terse to guess from. Categorising those by hand is not
/// realistic at a thousand rows, and every uncategorised transaction is one
/// that no budget, no 50/30/20 split and no coach narrative can see.
///
/// These are deliberately conservative: a rule fires only on a distinctive
/// merchant or service name. Anything ambiguous is left uncategorised rather
/// than filed somewhere plausible-looking but wrong. User-taught merchant
/// mappings always take precedence over anything here.
library;

class MerchantRules {
  /// Ordered most-specific first. The first pattern that matches wins.
  static final List<({RegExp pattern, String categoryId})> _rules = [
    // ── Income ──────────────────────────────────────────────────────────
    _r(r'\bsalary\b|\bpayroll\b|sal cr\b|\bwages\b|\bstipend\b', 'cat_salary'),
    _r(r'\bdividend\b|\binterest credit\b|int\.?\s?cr\b|\bfd interest\b', 'cat_interest'),
    _r(r'\brefund\b|\breversal\b|\bcashback\b|\bchargeback\b', 'cat_refund'),

    // ── Fees & charges ──────────────────────────────────────────────────
    _r(r'\bservice charge\b|\bannual fee\b|\bjoining fee\b|\blate payment\b|'
       r'\bfx (fee|markup)\b|\bmarkup fee\b|\bgst\b|\bvat\b|\bprocessing fee\b|'
       r'\bsms charge\b|\bamc\b', 'cat_fees'),

    // ── Housing & utilities ─────────────────────────────────────────────
    _r(r'\brent\b|\bejari\b|\bejari\b|\btenancy\b|\bhousing\b', 'cat_housing'),
    _r(r'\bdewa\b|\bsewa\b|\baddc\b|\betisalat\b|\bdu\b(?!bai)|\bdu telecom\b|'
       r'\bairtel\b|\bjio\b|\bvodafone\b|\bvi recharge\b|\btata power\b|'
       r'\badani electricity\b|\bbses\b|\bmahanagar gas\b|\bbroadband\b|'
       r'\belectricity\b|\bwater bill\b|\bgas bill\b', 'cat_utilities'),

    // ── Groceries ───────────────────────────────────────────────────────
    _r(r'\bcarrefour\b|\blulu\b|\bspinneys\b|\bunion coop\b|\bwaitrose\b|'
       r'\bchoithrams\b|\bviva\b|\bnesto\b|\bbigbasket\b|\bblinkit\b|'
       r'\bzepto\b|\bdmart\b|\breliance fresh\b|\bmore retail\b|'
       r'\bgrocer|\bsupermarket\b|\bhypermarket\b', 'cat_groceries'),

    // ── Dining ──────────────────────────────────────────────────────────
    _r(r'\bswiggy\b|\bzomato\b|\btalabat\b|\bdeliveroo\b|\bnoon food\b|'
       r'\bstarbucks\b|\bcosta\b|\btim hortons\b|\bmcdonald|\bkfc\b|'
       r'\bpizza\b|\bburger\b|\brestaurant\b|\bcafe\b|\bcoffee\b|'
       r'\bbakery\b|\bdine\b|\beatery\b', 'cat_dining'),

    // ── Transport ───────────────────────────────────────────────────────
    _r(r'\buber\b|\bcareem\b|\bola\b|\brapido\b|\blyft\b|\bbolt\b|'
       r'\bsalik\b|\bfastag\b|\bnol\b|\brta\b|\bparking\b|\bmetro\b|'
       r'\bpetrol\b|\bfuel\b|\benoc\b|\beppco\b|\badnoc\b|\bindian oil\b|'
       r'\bhp petrol\b|\bbharat petroleum\b|\birctc\b|\btaxi\b', 'cat_transport'),

    // ── Travel ──────────────────────────────────────────────────────────
    _r(r'\bemirates\b(?!\s*nbd)|\betihad\b|\bflydubai\b|\bindigo\b|'
       r'\bair india\b|\bvistara\b|\bqatar airways\b|\bbooking\.com\b|'
       r'\bagoda\b|\bairbnb\b|\bmakemytrip\b|\bcleartrip\b|\bexpedia\b|'
       r'\btravclan\b|\bhotel\b|\bairlines\b|\bairways\b', 'cat_travel'),

    // ── Subscriptions ───────────────────────────────────────────────────
    _r(r'\bnetflix\b|\bspotify\b|\bprime video\b|\bamazon prime\b|'
       r'\bdisney\b|\bhotstar\b|\byoutube premium\b|\bicloud\b|'
       r'\bgoogle one\b|\bmicrosoft 365\b|\boffice 365\b|\badobe\b|'
       r'\bopenai\b|\bchatgpt\b|\bcanva\b|\bsubscription\b', 'cat_subscriptions'),

    // ── Shopping ────────────────────────────────────────────────────────
    _r(r'\bamazon\b|\bnoon\.com\b|\bnoon\b|\bflipkart\b|\bmyntra\b|'
       r'\bajio\b|\bnamshi\b|\bsharaf dg\b|\bjumbo\b|\bikea\b|\bhome centre\b|'
       r'\bcentrepoint\b|\bmax fashion\b|\bh & m\b|\bzara\b|\bdecathlon\b|'
       r'\btanishq\b|\bmalabar\b|\bjoyalukkas\b|\bapple store\b', 'cat_shopping'),

    // ── Insurance ───────────────────────────────────────────────────────
    _r(r'\binsurance\b|\bpolicy premium\b|\btakaful\b|\bdaman\b|'
       r'\bmax life\b|\blic\b|\bhdfc ergo\b|\bstar health\b', 'cat_insurance'),

    // ── Leisure ─────────────────────────────────────────────────────────
    _r(r'\bcinema\b|\bvox\b|\breel cinemas\b|\bpvr\b|\binox\b|\bbookmyshow\b|'
       r'\bgym\b|\bfitness\b|\bspa\b|\bsalon\b|\bgolf\b', 'cat_leisure'),

    // ── Investments & savings ───────────────────────────────────────────
    _r(r'\bzerodha\b|\bgroww\b|\bupstox\b|\bangel one\b|\bcoin\b|'
       r'\bmutual fund\b|\bsip\b|\bnps\b|\bppf\b|\belss\b|\bsmallcase\b',
       'cat_investments'),

    // ── Debt ────────────────────────────────────────────────────────────
    _r(r'\bemi\b|\bloan\b|\binstalment\b|\binstallment\b|\bcredit card payment\b',
       'cat_debt'),
  ];

  static ({RegExp pattern, String categoryId}) _r(String p, String c) =>
      (pattern: RegExp(p, caseSensitive: false), categoryId: c);

  /// The category this narration implies, or null when nothing matches
  /// confidently. [type] narrows income lines to income categories.
  static String? categorise(String description, String? merchant, String type) {
    final text = '$description ${merchant ?? ''}'.toLowerCase();
    if (text.trim().isEmpty) return null;

    for (final rule in _rules) {
      if (!rule.pattern.hasMatch(text)) continue;
      final isIncomeCategory = _incomeCategories.contains(rule.categoryId);
      // An income line must not be filed as spending, and vice versa.
      if (type == 'income' && !isIncomeCategory) continue;
      if (type != 'income' && isIncomeCategory) continue;
      return rule.categoryId;
    }
    return null;
  }

  static const _incomeCategories = {
    'cat_salary',
    'cat_interest',
    'cat_refund',
    'cat_business',
    'cat_rent_income',
  };
}
