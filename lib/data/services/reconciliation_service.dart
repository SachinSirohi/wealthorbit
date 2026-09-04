import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart';
import '../database/database.dart';
import '../repositories/app_repository.dart';
import 'fx_service.dart';
import 'gemini_service.dart';

/// AI-assisted transfer / credit-card payment matching.
///
/// 1. Refresh FX (rates come from FxService, never the LLM).
/// 2. Exact-amount heuristic (same currency, ±3 days).
/// 3. LLM graph match on leftovers; auto-apply ≥0.85, queue 0.50–0.85.
class ReconciliationService {
  final AppRepository repository;
  ReconciliationService(this.repository);

  static const autoApplyThreshold = 0.85;
  static const reviewThreshold = 0.50;
  static const maxCandidates = 80;

  /// Run the full matching pass. Returns a short status for UI/logs.
  Future<String> run({int daysBack = 45}) async {
    await FxService.refresh(repository);

    final heuristic = await repository.detectInterAccountTransfers();
    debugPrint('🤝 Heuristic transfers: $heuristic');

    // Movement rules that need no AI: statement-classed transfers (card
    // bills, own-account moves, cross-currency remittances), broker funding
    // and payouts, ATM cash, and EMI instalments against loans.
    final classed = await repository.detectClassedTransfers();
    final broker = await repository.convertBrokerFunding();
    final atm = await repository.convertAtmWithdrawals();
    final emi = await repository.linkEmiPayments();
    debugPrint('🤝 Classed=$classed broker=$broker atm=$atm emi=$emi');

    final appliedPatterns = await _applyLearnedPatterns(daysBack: daysBack);
    debugPrint('🤝 Pattern transfers: $appliedPatterns');

    final ai = await _runAiGraphMatch(daysBack: daysBack);
    debugPrint('🤝 AI graph: auto=${ai.$1} suggested=${ai.$2}');

    final parts = <String>[];
    final applied = heuristic + classed + appliedPatterns + ai.$1;
    if (applied > 0) parts.add('$applied transfers applied');
    if (broker > 0) parts.add('$broker broker contributions');
    if (atm > 0) parts.add('$atm cash withdrawals');
    if (emi > 0) parts.add('$emi EMIs applied');
    if (ai.$2 > 0) parts.add('${ai.$2} suggestions queued');
    return parts.isEmpty ? 'No new transfer matches' : parts.join(' · ');
  }

  Future<int> _applyLearnedPatterns({required int daysBack}) async {
    final patterns = await repository.getAllTransferPatterns();
    if (patterns.isEmpty) return 0;
    final txs = await repository.getUnmatchedIncomeExpense(daysBack: daysBack);
    final expenses = txs.where((t) => t.type == 'expense').toList();
    final incomes = txs.where((t) => t.type == 'income').toList();
    final consumed = <String>{};
    int applied = 0;

    for (final out in expenses) {
      if (consumed.contains(out.id)) continue;
      final hay = '${out.description} ${out.merchant ?? ''}'.toLowerCase();
      TransferPattern? hit;
      for (final p in patterns) {
        if (hay.contains(p.pattern)) {
          hit = p;
          break;
        }
      }
      if (hit == null) continue;

      Transaction? match;
      for (final inc in incomes) {
        if (consumed.contains(inc.id)) continue;
        if (inc.accountId != hit.targetAccountId) continue;
        if (!_amountsCompatible(out, inc)) continue;
        if (inc.transactionDate.difference(out.transactionDate).inDays.abs() > 5) {
          continue;
        }
        match = inc;
        break;
      }
      if (match == null) continue;

      final ok = await repository.applyTransferPair(
        fromTxnId: out.id,
        toTxnId: match.id,
        kind: hit.kind,
      );
      if (ok) {
        consumed..add(out.id)..add(match.id);
        applied++;
      }
    }
    return applied;
  }

  Future<(int auto, int suggested)> _runAiGraphMatch({required int daysBack}) async {
    final accounts = await repository.getAllAccounts();
    if (accounts.length < 2) return (0, 0);

    final txs = await repository.getUnmatchedIncomeExpense(daysBack: daysBack);
    if (txs.length < 2) return (0, 0);

    final clipped = txs.take(maxCandidates).toList();
    final accountPayload = accounts
        .map((a) => {
              'id': a.id,
              'name': a.name,
              'type': a.type,
              'currency': a.currencyCode,
            })
        .toList();
    final candidatePayload = clipped
        .map((t) => {
              'id': t.id,
              'date': t.transactionDate.toIso8601String().split('T').first,
              'amountSource': t.amountSource,
              'currency': t.currencyCode,
              'amountBase': t.amountBase,
              'type': t.type,
              'description': t.description,
              'merchant': t.merchant,
              'accountId': t.accountId,
            })
        .toList();

    List<Map<String, dynamic>> pairs;
    try {
      pairs = await GeminiService.matchTransferPairs(
        accounts: accountPayload,
        candidates: candidatePayload,
      );
    } catch (e) {
      debugPrint('⚠️ AI transfer match failed: $e');
      return (0, 0);
    }

    int auto = 0;
    int suggested = 0;
    final used = <String>{};

    for (final pair in pairs) {
      final fromId = pair['fromTxnId']?.toString();
      final toId = pair['toTxnId']?.toString();
      final kind = (pair['kind'] ?? 'own_transfer').toString();
      final confidence = (pair['confidence'] as num?)?.toDouble() ?? 0;
      final reason = pair['reason']?.toString();

      if (fromId == null || toId == null) continue;
      if (used.contains(fromId) || used.contains(toId)) continue;
      if (confidence < reviewThreshold) continue;
      if (await repository.wasMatchRejected(fromId, toId)) continue;

      final from = await repository.getTransactionById(fromId);
      final to = await repository.getTransactionById(toId);
      if (from == null || to == null) continue;
      if (!_validatePair(from, to, kind, accounts)) continue;

      if (confidence >= autoApplyThreshold && kind != 'duplicate_spend') {
        final ok = await repository.applyTransferPair(
          fromTxnId: fromId,
          toTxnId: toId,
          kind: kind,
        );
        if (ok) {
          used..add(fromId)..add(toId);
          auto++;
          final needle = _patternNeedle(from.description, from.merchant);
          if (needle != null) {
            await repository.upsertTransferPattern(
              pattern: needle,
              targetAccountId: to.accountId,
              kind: kind,
            );
          }
        }
      } else {
        await repository.insertSuggestedMatch(SuggestedMatchesCompanion.insert(
          id: const Uuid().v4(),
          fromTxnId: fromId,
          toTxnId: toId,
          kind: kind,
          confidence: confidence,
          reason: Value(reason),
        ));
        used..add(fromId)..add(toId);
        suggested++;
      }
    }
    return (auto, suggested);
  }

  bool _validatePair(
    Transaction a,
    Transaction b,
    String kind,
    List<Account> accounts,
  ) {
    if (a.accountId == b.accountId) return false;
    if (a.type == 'transfer' || b.type == 'transfer') return false;
    if (a.transactionDate.difference(b.transactionDate).inDays.abs() > 5) {
      return false;
    }
    if (!_amountsCompatible(a, b)) return false;

    final byId = {for (final x in accounts) x.id: x};
    final aAcc = byId[a.accountId];
    final bAcc = byId[b.accountId];
    if (kind == 'duplicate_spend') {
      return aAcc?.type == 'credit_card' && bAcc?.type == 'credit_card';
    }
    if (kind == 'cc_payment') {
      final hasCc = aAcc?.type == 'credit_card' || bAcc?.type == 'credit_card';
      if (!hasCc) return false;
    }
    return true;
  }

  bool _amountsCompatible(Transaction a, Transaction b) {
    if (a.currencyCode == b.currencyCode) {
      final diff = (a.amountSource - b.amountSource).abs();
      if (diff <= 0.01) return true;
      final larger = a.amountSource > b.amountSource ? a.amountSource : b.amountSource;
      return larger > 0 && diff / larger <= 0.01;
    }
    final larger = a.amountBase > b.amountBase ? a.amountBase : b.amountBase;
    if (larger <= 0) return false;
    return (a.amountBase - b.amountBase).abs() / larger <= 0.03;
  }

  /// A needle specific enough to re-apply safely. The old version learned
  /// bare rails like `upi` or `neft`, so one accepted match taught the app
  /// that EVERY UPI debit pairs with that account. Now the needle is the
  /// counterparty phrase (rail words and reference numbers stripped), and
  /// nothing shorter than 6 characters is ever learned.
  String? _patternNeedle(String description, String? merchant) {
    final text = '$description ${merchant ?? ''}'.toLowerCase();
    final cleaned = text
        .replaceAll(RegExp(r'\b(upi|neft|imps|rtgs|ach|nach|pos|ref|txn|trf|transfer|payment|to|from|by|via)\b'), ' ')
        .replaceAll(RegExp(r'[0-9]{3,}'), ' ')
        .replaceAll(RegExp(r'[^a-z ]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final words = cleaned.split(' ').where((w) => w.length >= 3).take(3).toList();
    final needle = words.join(' ');
    return needle.length >= 6 ? needle : null;
  }

  Future<bool> acceptSuggestion(String suggestionId) async {
    final s = await repository.getSuggestedMatch(suggestionId);
    if (s == null || s.status != 'pending') return false;

    // A duplicate spend is ONE purchase that reached two cards — no money
    // moved between them. Accepting it marks the second row instead of
    // converting the pair into a transfer, which the matcher's own rules
    // forbid but this path used to do anyway.
    if (s.kind == 'duplicate_spend') {
      final ok = await repository.markDuplicateSpend(
        keepId: s.fromTxnId,
        dupeId: s.toTxnId,
      );
      if (ok) await repository.updateSuggestedMatchStatus(suggestionId, 'accepted');
      return ok;
    }

    final ok = await repository.applyTransferPair(
      fromTxnId: s.fromTxnId,
      toTxnId: s.toTxnId,
      kind: s.kind,
    );
    if (ok) {
      await repository.updateSuggestedMatchStatus(suggestionId, 'accepted');
      final from = await repository.getTransactionById(s.fromTxnId);
      if (from != null) {
        final needle = _patternNeedle(from.description, from.merchant);
        if (needle != null) {
          final to = await repository.getTransactionById(s.toTxnId);
          // to may already be deleted; use transferAccountId on from after apply
          final applied = await repository.getTransactionById(s.fromTxnId);
          final targetId = applied?.transferAccountId ?? to?.accountId;
          if (targetId != null) {
            await repository.upsertTransferPattern(
              pattern: needle,
              targetAccountId: targetId,
              kind: s.kind,
            );
          }
        }
      }
    }
    return ok;
  }

  Future<void> rejectSuggestion(String suggestionId) async {
    await repository.updateSuggestedMatchStatus(suggestionId, 'rejected');
  }
}
