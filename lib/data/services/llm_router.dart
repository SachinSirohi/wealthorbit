import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'secure_vault.dart';

/// Which engine answered a request.
enum LlmProvider { gemini, qwen }

/// Routes every LLM call to Gemini first, falling back to the self-hosted
/// Qwen only for the call that failed.
///
/// Gemini is markedly faster and more accurate on statement extraction, but
/// its free tier is rate- and quota-limited. Two mechanisms keep requests
/// inside it: calls are paced apart, and when one model reports quota
/// exhaustion that model is put on ice while the next one in the rotation
/// takes over — free-tier quota is per-model, so rotating buys real headroom.
///
/// The fallback is deliberately NOT sticky. A quota rejection says nothing
/// about the next request, which may be a minute later or against a
/// different model, so every call starts at Gemini again. Sticking to Qwen
/// after one 429 would surrender the better engine for the rest of a long
/// import because of a single busy moment.
class LlmRouter {
  /// Free-tier models in preference order. Quota is tracked per model, so a
  /// rotation multiplies the headroom available before Qwen is needed. Lite
  /// variants sit lower: they are cheaper on quota but weaker at extraction.
  static const geminiModels = <String>[
    'gemini-2.5-flash',
    'gemini-2.0-flash',
    'gemini-2.5-flash-lite',
    'gemini-2.0-flash-lite',
  ];

  /// Minimum gap between two Gemini requests. Free-tier limits are per
  /// minute, so a short pace keeps a burst of statement windows inside them
  /// instead of tripping a 429 on the third call and wasting the quota.
  static Duration pacing = const Duration(seconds: 4);

  /// How long a model sits out after reporting quota exhaustion, when the
  /// API does not tell us itself.
  static Duration defaultCooldown = const Duration(minutes: 2);

  static const _geminiEndpoint = 'https://generativelanguage.googleapis.com/v1beta/models';

  /// Per-model "not before" times, set when a model reports quota trouble.
  static final Map<String, DateTime> _cooldownUntil = {};
  static DateTime? _lastGeminiCallAt;

  /// Which engine served the most recent call — surfaced in diagnostics so
  /// it is visible when everything has quietly been running on the fallback.
  static LlmProvider? lastProvider;
  static String? lastModel;

  /// Reset pacing and cooldown state. Tests only.
  @visibleForTesting
  static void reset() {
    _cooldownUntil.clear();
    _lastGeminiCallAt = null;
    lastProvider = null;
    lastModel = null;
  }

  /// The next Gemini model that is not sitting out a cooldown.
  static String? nextAvailableModel({DateTime? now}) {
    final t = now ?? DateTime.now();
    for (final model in geminiModels) {
      final until = _cooldownUntil[model];
      if (until == null || t.isAfter(until)) return model;
    }
    return null;
  }

  /// Put [model] on ice. [retryAfter] is honoured when the API supplies it.
  static void markExhausted(String model, {Duration? retryAfter, DateTime? now}) {
    final t = now ?? DateTime.now();
    _cooldownUntil[model] = t.add(retryAfter ?? defaultCooldown);
    debugPrint('⏳ $model out of quota — resting until ${_cooldownUntil[model]}');
  }

  /// True when a Gemini failure is about quota or rate limits, rather than a
  /// bad key or a malformed request. Only these are worth rotating on; a 400
  /// or 403 will fail identically on every other model.
  static bool isQuotaFailure(int statusCode, String body) {
    if (statusCode == 429) return true;
    final b = body.toLowerCase();
    return b.contains('resource_exhausted') ||
        b.contains('quota') ||
        b.contains('rate limit');
  }

  /// A retry delay named in a Gemini error body ("retryDelay": "37s").
  static Duration? parseRetryDelay(String body) {
    final m = RegExp(r'"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"').firstMatch(body);
    if (m == null) return null;
    final seconds = double.tryParse(m.group(1)!);
    if (seconds == null) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// Run a completion: Gemini first, Qwen only if Gemini could not answer.
  static Future<String> complete({
    required String system,
    required String user,
    required bool jsonMode,
    required double temperature,
    required int maxTokens,
    required Duration timeout,
    required Future<String> Function() qwenFallback,
  }) async {
    final geminiKey = await SecureVault.getGeminiApiKey();
    if (geminiKey != null && geminiKey.isNotEmpty) {
      try {
        final text = await _completeWithGemini(
          apiKey: geminiKey,
          system: system,
          user: user,
          jsonMode: jsonMode,
          temperature: temperature,
          maxTokens: maxTokens,
          timeout: timeout,
        );
        lastProvider = LlmProvider.gemini;
        return text;
      } catch (e) {
        // Fall through to Qwen for THIS call only. The next one tries Gemini
        // again — see the class comment.
        debugPrint('↩️ Gemini unavailable, using Qwen for this call: ${_short(e)}');
      }
    }

    final text = await qwenFallback();
    lastProvider = LlmProvider.qwen;
    lastModel = 'qwen-14b';
    return text;
  }

  /// Try each non-resting model in turn. Rotating on a quota rejection is
  /// the whole point: the next model has its own allowance.
  static Future<String> _completeWithGemini({
    required String apiKey,
    required String system,
    required String user,
    required bool jsonMode,
    required double temperature,
    required int maxTokens,
    required Duration timeout,
  }) async {
    Object? lastError;

    for (var attempt = 0; attempt < geminiModels.length; attempt++) {
      final model = nextAvailableModel();
      if (model == null) {
        throw Exception('Every Gemini model is resting out a quota cooldown');
      }

      await _pace();
      try {
        final text = await _callGemini(
          apiKey: apiKey,
          model: model,
          system: system,
          user: user,
          jsonMode: jsonMode,
          temperature: temperature,
          maxTokens: maxTokens,
          timeout: timeout,
        );
        lastModel = model;
        debugPrint('✨ Gemini $model answered (${text.length} chars)');
        return text;
      } on _GeminiQuotaException catch (e) {
        markExhausted(model, retryAfter: e.retryAfter);
        lastError = e;
        // straight on to the next model — its quota is separate
      } catch (e) {
        lastError = e;
        // A non-quota failure will repeat on every model; stop here.
        break;
      }
    }
    throw Exception('Gemini failed: ${_short(lastError ?? 'unknown')}');
  }

  /// Hold requests [pacing] apart so a burst stays inside per-minute limits.
  static Future<void> _pace() async {
    final last = _lastGeminiCallAt;
    if (last != null) {
      final since = DateTime.now().difference(last);
      if (since < pacing) await Future<void>.delayed(pacing - since);
    }
    _lastGeminiCallAt = DateTime.now();
  }

  static Future<String> _callGemini({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    required bool jsonMode,
    required double temperature,
    required int maxTokens,
    required Duration timeout,
  }) async {
    final body = <String, dynamic>{
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': user}
          ]
        }
      ],
      'systemInstruction': {
        'parts': [
          {'text': system}
        ]
      },
      'generationConfig': {
        'temperature': temperature,
        'maxOutputTokens': maxTokens,
        if (jsonMode) 'responseMimeType': 'application/json',
        // 2.5 models think by default, which burns latency and output tokens
        // on work this task does not need. Ignored by models without it.
        'thinkingConfig': {'thinkingBudget': 0},
      },
    };

    final response = await http
        .post(
          Uri.parse('$_geminiEndpoint/$model:generateContent'),
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          body: json.encode(body),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (isQuotaFailure(response.statusCode, response.body)) {
        throw _GeminiQuotaException(
          model,
          retryAfter: parseRetryDelay(response.body),
        );
      }
      throw Exception('Gemini HTTP ${response.statusCode}: ${_short(response.body)}');
    }

    return extractText(response.body);
  }

  /// Pull the answer out of a Gemini response, with the finish reason when
  /// there is no text — "MAX_TOKENS" and "SAFETY" are the ones that matter.
  @visibleForTesting
  static String extractText(String responseBody) {
    final decoded = json.decode(responseBody);
    if (decoded is! Map) throw Exception('Gemini returned a malformed payload');

    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      final block = decoded['promptFeedback']?['blockReason'];
      throw Exception(block == null
          ? 'Gemini returned no candidates'
          : 'Gemini blocked the prompt ($block)');
    }

    final first = candidates.first as Map;
    final parts = first['content']?['parts'];
    final buffer = StringBuffer();
    if (parts is List) {
      for (final part in parts) {
        if (part is Map && part['text'] is String) buffer.write(part['text']);
      }
    }
    final text = buffer.toString();
    if (text.trim().isEmpty) {
      final reason = first['finishReason'] ?? 'unknown';
      throw Exception('Gemini returned no text (finishReason: $reason)');
    }
    return text;
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}

class _GeminiQuotaException implements Exception {
  final String model;
  final Duration? retryAfter;
  _GeminiQuotaException(this.model, {this.retryAfter});
  @override
  String toString() =>
      'Gemini $model hit its quota${retryAfter == null ? '' : ' (retry in ${retryAfter!.inSeconds}s)'}';
}
