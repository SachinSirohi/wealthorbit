import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A connected email account used for statement discovery (IMAP).
class EmailAccount {
  final String email;
  final String password;
  final String provider;

  const EmailAccount({required this.email, required this.password, required this.provider});

  Map<String, String> toJson() => {'email': email, 'password': password, 'provider': provider};

  factory EmailAccount.fromJson(Map<String, dynamic> json) => EmailAccount(
        email: (json['email'] ?? '') as String,
        password: (json['password'] ?? '') as String,
        provider: (json['provider'] ?? 'gmail') as String,
      );
}

/// Secure vault for storing sensitive data (API keys, PDF passwords)
class SecureVault {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );

  // Keys
  static const _geminiApiKey = 'gemini_api_key';
  static const _baseCurrency = 'base_currency';
  static const _onboardingComplete = 'onboarding_complete';

  // ═══════════════════════════════════════════════════════════════════════════
  // GEMINI API KEY
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Store the user's Gemini API key
  static Future<void> setGeminiApiKey(String key) async {
    await _storage.write(key: _geminiApiKey, value: key);
  }
  
  /// Get the stored Gemini API key
  static Future<String?> getGeminiApiKey() async {
    return await _storage.read(key: _geminiApiKey);
  }
  
  /// Check if Gemini API key is configured
  static Future<bool> hasGeminiApiKey() async {
    final key = await _storage.read(key: _geminiApiKey);
    return key != null && key.isNotEmpty;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PDF PASSWORDS (Per Bank)
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Store a PDF password for a specific bank/sender
  static Future<void> setPdfPassword(String sourceId, String password) async {
    await _storage.write(key: 'pdf_pwd_$sourceId', value: password);
  }
  
  /// Get PDF password for a specific bank/sender
  static Future<String?> getPdfPassword(String sourceId) async {
    return await _storage.read(key: 'pdf_pwd_$sourceId');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // USER PREFERENCES
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Set base currency
  static Future<void> setBaseCurrency(String currencyCode) async {
    await _storage.write(key: _baseCurrency, value: currencyCode);
  }
  
  /// Get base currency (default: AED)
  static Future<String> getBaseCurrency() async {
    final currency = await _storage.read(key: _baseCurrency);
    return currency ?? 'AED';
  }
  
  /// Set onboarding complete flag
  static Future<void> setOnboardingComplete(bool complete) async {
    await _storage.write(key: _onboardingComplete, value: complete.toString());
  }
  
  // Check onboarding completion
  static Future<bool> isOnboardingComplete() async {
    final currency = await _storage.read(key: _baseCurrency);
    final apiKey = await _storage.read(key: _geminiApiKey);
    return currency != null && apiKey != null;
  }
  
  // ── Email accounts (IMAP) — supports MULTIPLE accounts ────────────────────
  // Stored as a JSON list under 'email_accounts'. The legacy single-account
  // keys (email_address / email_app_password / email_provider) are migrated
  // into the list on first read and kept in sync for backward compatibility.

  static const _emailAccountsKey = 'email_accounts';

  static Future<List<EmailAccount>> getEmailAccounts() async {
    final raw = await _storage.read(key: _emailAccountsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw) as List;
        return decoded
            .whereType<Map>()
            .map((m) => EmailAccount.fromJson(m.cast<String, dynamic>()))
            .where((a) => a.email.isNotEmpty && a.password.isNotEmpty)
            .toList();
      } catch (_) {
        return [];
      }
    }
    // Migrate legacy single-account storage into the list.
    final legacyEmail = await _storage.read(key: 'email_address');
    final legacyPassword = await _storage.read(key: 'email_app_password');
    if (legacyEmail != null && legacyEmail.isNotEmpty && legacyPassword != null && legacyPassword.isNotEmpty) {
      final account = EmailAccount(
        email: legacyEmail,
        password: legacyPassword,
        provider: await _storage.read(key: 'email_provider') ?? 'gmail',
      );
      await _saveEmailAccounts([account]);
      return [account];
    }
    return [];
  }

  static Future<void> _saveEmailAccounts(List<EmailAccount> accounts) async {
    await _storage.write(
      key: _emailAccountsKey,
      value: json.encode(accounts.map((a) => a.toJson()).toList()),
    );
    // Mirror the first account into the legacy keys for old call sites.
    if (accounts.isEmpty) {
      await _storage.delete(key: 'email_address');
      await _storage.delete(key: 'email_app_password');
      await _storage.delete(key: 'email_provider');
    } else {
      await _storage.write(key: 'email_address', value: accounts.first.email);
      await _storage.write(key: 'email_app_password', value: accounts.first.password);
      await _storage.write(key: 'email_provider', value: accounts.first.provider);
    }
  }

  /// Add (or update) an email account. Matches on the email address.
  static Future<void> addEmailAccount(String email, String appPassword, String provider) async {
    final accounts = await getEmailAccounts();
    accounts.removeWhere((a) => a.email.toLowerCase() == email.toLowerCase());
    accounts.add(EmailAccount(email: email, password: appPassword, provider: provider));
    await _saveEmailAccounts(accounts);
  }

  static Future<void> removeEmailAccount(String email) async {
    final accounts = await getEmailAccounts();
    accounts.removeWhere((a) => a.email.toLowerCase() == email.toLowerCase());
    await _saveEmailAccounts(accounts);
  }

  /// Legacy API: sets/overwrites the FIRST account (and adds to the list).
  static Future<void> setEmailCredentials(String email, String appPassword, String provider) async {
    await addEmailAccount(email, appPassword, provider);
  }

  static Future<Map<String, String?>> getEmailCredentials() async {
    final accounts = await getEmailAccounts();
    final first = accounts.isNotEmpty ? accounts.first : null;
    return {'email': first?.email, 'password': first?.password, 'provider': first?.provider};
  }

  static Future<void> clearEmailCredentials() async {
    await _storage.delete(key: _emailAccountsKey);
    await _saveEmailAccounts(const []);
  }

  // Individual getters for IMAP service (first/primary account)
  static Future<String?> getGmailEmail() async {
    final accounts = await getEmailAccounts();
    return accounts.isNotEmpty ? accounts.first.email : null;
  }

  static Future<String?> getGmailPassword() async {
    final accounts = await getEmailAccounts();
    return accounts.isNotEmpty ? accounts.first.password : null;
  }

  static Future<bool> hasEmailCredentials() async {
    return (await getEmailAccounts()).isNotEmpty;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // UTILITIES
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Clear all stored data (for logout/reset)
  static Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
