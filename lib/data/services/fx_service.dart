import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../repositories/app_repository.dart';
import '../../core/utils/currency_utils.dart';
import 'secure_vault.dart';

/// Keeps the Currencies table's `rateToBase` (value of 1 unit of a currency in
/// the user's base currency) populated, so every cross-currency aggregate can
/// convert correctly. Seeds robust fallback rates, then best-effort refreshes
/// from a free, key-less endpoint.
class FxService {
  /// Ensure non-trivial rates exist (the DB ships every currency at 1.0).
  /// Always writes the fallback AED-relative table converted to the base.
  static Future<void> ensureSeeded(AppRepository repo) async {
    final base = await SecureVault.getBaseCurrency();
    final baseToAed = CurrencyUtils.fallbackRatesToAed[base] ?? 1.0;
    final currencies = await repo.getAllCurrencies();
    for (final c in currencies) {
      final toAed = CurrencyUtils.fallbackRatesToAed[c.code];
      if (toAed == null) continue;
      // rateToBase = (value of 1 unit in AED) / (value of 1 base unit in AED)
      final rateToBase = toAed / baseToAed;
      await repo.updateExchangeRate(c.code, rateToBase);
    }
    debugPrint('💱 FX seeded (base=$base)');
  }

  /// Best-effort live refresh. Safe to call fire-and-forget.
  static Future<void> refresh(AppRepository repo) async {
    try {
      final base = await SecureVault.getBaseCurrency();
      final url = Uri.parse('https://open.er-api.com/v6/latest/$base');
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final data = json.decode(res.body);
      final rates = (data['rates'] as Map?)?.cast<String, dynamic>();
      if (rates == null) return;
      // rates[X] = units of X per 1 base → rateToBase(X) = 1 / rates[X].
      for (final c in await repo.getAllCurrencies()) {
        final perBase = (rates[c.code] as num?)?.toDouble();
        if (perBase != null && perBase > 0) {
          await repo.updateExchangeRate(c.code, 1.0 / perBase);
        }
      }
      debugPrint('💱 FX refreshed live (base=$base)');
    } catch (e) {
      debugPrint('💱 FX live refresh skipped: $e');
    }
  }
}
