/// Parsing for the dates printed on bank statements.
///
/// `DateTime.tryParse` accepts ISO-8601 and nothing else, so every
/// `14-08-2026`, `14/08/2026` and `14-Aug-2026` came back null — and the
/// import fell back to `DateTime.now()`. Years of history collapsed onto
/// the current day: one month showed AED 391,204 of spend while the month
/// before it showed 137.51, and every average, budget and runway computed
/// from those months was wrong.
///
/// Two rules here matter as much as the formats:
///   * a date that cannot be read is NOT silently replaced with today —
///     the caller is told, and places the row using the statement's own
///     period instead;
///   * a date outside a plausible window is rejected rather than trusted,
///     which is how transactions dated 2028 got into a 2026 ledger.
library;

class StatementDate {
  /// Nothing before this is a real personal-finance statement line.
  static final DateTime earliest = DateTime(2000, 1, 1);

  /// A transaction cannot have happened after today. A couple of days of
  /// slack absorbs timezone differences between the statement and the phone.
  static Duration futureSlack = const Duration(days: 2);

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'sept': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// Parse a statement date in any format banks actually print.
  ///
  /// Returns null when the text cannot be read as a date, or when the date
  /// it yields is outside the plausible window. Day-first is preferred for
  /// ambiguous numeric dates (`03/04/2026`): these are UAE and Indian
  /// statements, where day-first is the convention.
  static DateTime? parse(String? raw, {DateTime? now}) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final today = now ?? DateTime.now();

    final candidate = _parseAnyFormat(text);
    if (candidate == null) return null;
    if (candidate.isBefore(earliest)) return null;
    if (candidate.isAfter(today.add(futureSlack))) return null;
    return candidate;
  }

  static DateTime? _parseAnyFormat(String text) {
    // ISO first — it is what the extraction prompt asks for.
    final iso = DateTime.tryParse(text);
    if (iso != null) return DateTime(iso.year, iso.month, iso.day);

    // 14-Aug-2026 · 14 Aug 2026 · 14Aug26 · Aug 14, 2026
    final named = RegExp(
      r'^(\d{1,2})[\s\-/.]*([A-Za-z]{3,9})[\s\-/.,]*(\d{2,4})$',
    ).firstMatch(text);
    if (named != null) {
      final month = _months[named.group(2)!.toLowerCase().substring(0, 3)];
      if (month != null) {
        return _build(
          int.parse(named.group(3)!),
          month,
          int.parse(named.group(1)!),
        );
      }
    }
    final namedFirst = RegExp(
      r'^([A-Za-z]{3,9})[\s\-/.]*(\d{1,2})[\s\-/.,]*(\d{2,4})$',
    ).firstMatch(text);
    if (namedFirst != null) {
      final month = _months[namedFirst.group(1)!.toLowerCase().substring(0, 3)];
      if (month != null) {
        return _build(
          int.parse(namedFirst.group(3)!),
          month,
          int.parse(namedFirst.group(2)!),
        );
      }
    }

    // Purely numeric, three parts: 14-08-2026 · 14/08/26 · 2026.08.14
    final numeric = RegExp(
      r'^(\d{1,4})[\-/.](\d{1,2})[\-/.](\d{1,4})$',
    ).firstMatch(text);
    if (numeric != null) {
      final a = int.parse(numeric.group(1)!);
      final b = int.parse(numeric.group(2)!);
      final c = int.parse(numeric.group(3)!);

      // Year-first when the leading part is unmistakably a year.
      if (numeric.group(1)!.length == 4) return _build(a, b, c);

      // Otherwise day-first unless the numbers rule it out. `13/05` can only
      // be day-first; `05/13` can only be month-first.
      if (a > 12 && b <= 12) return _build(c, b, a);
      if (b > 12 && a <= 12) return _build(c, a, b);
      return _build(c, b, a); // ambiguous → day-first (UAE / India)
    }

    // Compact 8-digit: 14082026 or 20260814
    final compact = RegExp(r'^(\d{8})$').firstMatch(text);
    if (compact != null) {
      final s = compact.group(1)!;
      final asYearFirst = _build(
          int.parse(s.substring(0, 4)), int.parse(s.substring(4, 6)), int.parse(s.substring(6)));
      if (asYearFirst != null) return asYearFirst;
      return _build(
          int.parse(s.substring(4)), int.parse(s.substring(2, 4)), int.parse(s.substring(0, 2)));
    }

    return null;
  }

  /// Build a date, rejecting impossible components and expanding 2-digit
  /// years. `26` is 2026; `98` is 1998.
  static DateTime? _build(int year, int month, int day) {
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    var y = year;
    if (y < 100) y += y <= 70 ? 2000 : 1900;
    if (y < 1900 || y > 2200) return null;
    final d = DateTime(y, month, day);
    // Rejects 31 February and similar, which DateTime would silently roll over.
    if (d.month != month || d.day != day) return null;
    return d;
  }
}
