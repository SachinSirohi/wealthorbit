import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/theme/wo_design.dart';
import '../database/database.dart';
import '../repositories/app_repository.dart';
import 'secure_vault.dart';

/// Encrypted phone-migration backup (`.wobak`).
///
/// Payload is gzip(json header + sqlite). AES-256-GCM with a key derived from
/// the user's passphrase mixed with an app pepper, so a generic decrypt tool
/// cannot open the file even if it guesses AES-GCM. Restore only works inside
/// WealthOrbit with the same passphrase.
class BackupService {
  static const _magic = 'WOBAK01';
  static const _pepper = 'WealthOrbit.backup.v1.nripfm';
  static const _kdfIterations = 120000;
  static const minPassphraseLength = 8;

  static final _aes = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _kdfIterations,
    bits: 256,
  );

  static Future<File> exportToTempFile(String passphrase) async {
    _assertPassphrase(passphrase);
    final repo = await AppRepository.getInstance();
    await repo.checkpointWal();

    final dbFile = await wealthOrbitDatabaseFile();
    if (!await dbFile.exists()) {
      throw BackupException('No local database to export.');
    }
    final sqlite = await dbFile.readAsBytes();
    final vault = await SecureVault.exportAll();

    final header = utf8.encode(jsonEncode({
      'v': 1,
      'app': 'wealthorbit',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'vault': vault,
    }));
    final builder = BytesBuilder(copy: false);
    builder.add(_u32(header.length));
    builder.add(header);
    builder.add(sqlite);
    final plaintext = Uint8List.fromList(gzip.encode(builder.takeBytes()));

    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _kdf.deriveKeyFromPassword(
      password: '$_pepper\n$passphrase',
      nonce: salt,
    );
    final box = await _aes.encrypt(plaintext, secretKey: key, nonce: nonce);

    final out = BytesBuilder(copy: false);
    out.add(utf8.encode(_magic));
    out.add(salt);
    out.add(box.concatenation());

    final tmp = await getTemporaryDirectory();
    final stamp = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final file = File('${tmp.path}/wealthorbit-backup-$stamp.wobak');
    await file.writeAsBytes(out.takeBytes(), flush: true);
    return file;
  }

  /// Decrypts [bytes] and replaces the local database + vault. Caller must
  /// restart the app afterwards.
  static Future<void> restoreFromBytes(Uint8List bytes, String passphrase) async {
    _assertPassphrase(passphrase);
    final payload = await _decrypt(bytes, passphrase);

    final headerLen = _readU32(payload, 0);
    if (headerLen <= 0 || headerLen > payload.length - 4) {
      throw BackupException('Backup file is corrupted.');
    }
    final headerJson = jsonDecode(utf8.decode(payload.sublist(4, 4 + headerLen)));
    if (headerJson is! Map || headerJson['app'] != 'wealthorbit') {
      throw BackupException('This file is not a WealthOrbit backup.');
    }
    final vaultRaw = headerJson['vault'];
    final vault = <String, String>{};
    if (vaultRaw is Map) {
      vaultRaw.forEach((k, v) {
        if (k is String && v is String) vault[k] = v;
      });
    }
    final sqlite = payload.sublist(4 + headerLen);
    if (sqlite.length < 16) {
      throw BackupException('Backup is missing the database.');
    }

    await AppRepository.closeForRestore();

    final dbFile = await wealthOrbitDatabaseFile();
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('${dbFile.path}$suffix');
      if (await f.exists()) await f.delete();
    }
    await dbFile.writeAsBytes(sqlite, flush: true);
    await SecureVault.restoreAll(vault);
  }

  static Future<void> showExportFlow(BuildContext context) async {
    final passphrase = await _promptPassphrase(
      context,
      title: 'Export encrypted backup',
      subtitle:
          'Choose a passphrase you will remember. Accounts, PDF passwords, mail passwords, and transactions are packed into a .wobak file that only WealthOrbit can open.',
      confirm: true,
    );
    if (passphrase == null || !context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(child: CircularProgressIndicator(color: WoColors.gold)),
    );
    try {
      final file = await exportToTempFile(passphrase);
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/octet-stream')],
        subject: 'WealthOrbit backup',
        text: 'Encrypted WealthOrbit backup. Restore it in the app with your passphrase.',
      );
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  static Future<void> showImportFlow(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WoColors.surface,
        title: Text('Replace data on this phone?', style: WoText.title()),
        content: Text(
          'Restoring a backup overwrites accounts, transactions, statement sources, PDF passwords, and mail passwords on this device.',
          style: WoText.body(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (picked == null || !context.mounted) return;
    final file = picked.files.single;
    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null || bytes.length < 40) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read that file.')),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final passphrase = await _promptPassphrase(
      context,
      title: 'Restore backup',
      subtitle: 'Enter the passphrase you chose when you exported this file.',
      confirm: false,
    );
    if (passphrase == null || !context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(child: CircularProgressIndicator(color: WoColors.gold)),
    );
    try {
      await restoreFromBytes(Uint8List.fromList(bytes), passphrase);
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: WoColors.surface,
          title: Text('Backup restored', style: WoText.title()),
          content: Text(
            'WealthOrbit will close. Open the app again to use your restored accounts and passwords.',
            style: WoText.body(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      exit(0);
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  static void _assertPassphrase(String passphrase) {
    if (passphrase.length < minPassphraseLength) {
      throw BackupException('Passphrase must be at least $minPassphraseLength characters.');
    }
  }

  static Future<Uint8List> _decrypt(Uint8List bytes, String passphrase) async {
    final magic = utf8.encode(_magic);
    if (bytes.length < magic.length + 16 + 12 + 16 + 1 ||
        !_startsWith(bytes, magic)) {
      throw BackupException('This is not a WealthOrbit backup.');
    }
    var offset = magic.length;
    final salt = bytes.sublist(offset, offset + 16);
    offset += 16;
    final box = SecretBox.fromConcatenation(
      bytes.sublist(offset),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );

    final key = await _kdf.deriveKeyFromPassword(
      password: '$_pepper\n$passphrase',
      nonce: salt,
    );
    try {
      final clear = await _aes.decrypt(box, secretKey: key);
      return Uint8List.fromList(gzip.decode(clear));
    } catch (_) {
      throw BackupException('Could not decrypt. Check the passphrase.');
    }
  }

  static Future<String?> _promptPassphrase(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool confirm,
  }) {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          backgroundColor: WoColors.surface,
          title: Text(title, style: WoText.title()),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subtitle, style: WoText.body()),
                const SizedBox(height: 16),
                TextField(
                  controller: first,
                  obscureText: true,
                  style: GoogleFonts.inter(color: WoColors.textHi),
                  decoration: InputDecoration(
                    labelText: 'Passphrase',
                    labelStyle: TextStyle(color: WoColors.textMid),
                  ),
                ),
                if (confirm) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: second,
                    obscureText: true,
                    style: GoogleFonts.inter(color: WoColors.textHi),
                    decoration: InputDecoration(
                      labelText: 'Confirm passphrase',
                      labelStyle: TextStyle(color: WoColors.textMid),
                    ),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: GoogleFonts.inter(color: WoColors.orange, fontSize: 13)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final a = first.text;
                if (a.length < minPassphraseLength) {
                  setSheet(() => error = 'Use at least $minPassphraseLength characters.');
                  return;
                }
                if (confirm && a != second.text) {
                  setSheet(() => error = 'Passphrases do not match.');
                  return;
                }
                Navigator.pop(ctx, a);
              },
              child: Text(confirm ? 'Export' : 'Restore'),
            ),
          ],
        ),
      ),
    );
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => rng.nextInt(256)));
  }

  static List<int> _u32(int value) => [
        (value >> 24) & 0xff,
        (value >> 16) & 0xff,
        (value >> 8) & 0xff,
        value & 0xff,
      ];

  static int _readU32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
}

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}
