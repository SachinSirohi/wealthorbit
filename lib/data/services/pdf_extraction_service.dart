import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Service for PDF password testing and text extraction.
///
/// All syncfusion work runs in a background isolate via [compute] — PDF parsing
/// is synchronous, CPU-heavy work, and running it on the UI isolate blocks the
/// thread (chaining it across many statements caused ANRs / "app hung").
class PdfExtractionService {

  /// Test if a password can open a PDF. Returns true if it works.
  static Future<bool> testPassword(Uint8List pdfBytes, String password) =>
      compute(_testPasswordWorker, (pdfBytes, password));

  /// Check if a PDF requires a password.
  static Future<bool> isPasswordProtected(Uint8List pdfBytes) =>
      compute(_isProtectedWorker, pdfBytes);

  /// Extract text from a PDF. Returns the text, or null if extraction yields
  /// nothing. Throws if the document can't be opened (e.g. wrong password) —
  /// callers rely on this to detect a bad password.
  static Future<String?> extractText(Uint8List pdfBytes, {String? password}) async {
    try {
      final text = await compute(_extractTextWorker, (pdfBytes, password));
      debugPrint('✅ Extracted ${text?.length ?? 0} characters from PDF');
      return text;
    } catch (e) {
      debugPrint('❌ Failed to open PDF (wrong password?): $e');
      rethrow;
    }
  }

  /// Get the PDF page count (0 on failure).
  static Future<int> getPageCount(Uint8List pdfBytes, {String? password}) =>
      compute(_pageCountWorker, (pdfBytes, password));

  /// Test a password against several PDFs; returns (successes, tested).
  static Future<(int, int)> testPasswordOnMultiple(
    List<Uint8List> pdfList,
    String password, {
    int maxToTest = 5,
  }) async {
    int success = 0;
    int tested = 0;
    for (final pdf in pdfList.take(maxToTest)) {
      tested++;
      if (await testPassword(pdf, password)) success++;
    }
    return (success, tested);
  }
}

// ─── Isolate workers (top-level, run via compute) ──────────────────────────

bool _testPasswordWorker((Uint8List, String) args) {
  final (bytes, password) = args;
  try {
    PdfDocument(inputBytes: bytes, password: password).dispose();
    return true;
  } catch (_) {
    return false;
  }
}

bool _isProtectedWorker(Uint8List bytes) {
  try {
    PdfDocument(inputBytes: bytes).dispose();
    return false; // opened without a password
  } catch (_) {
    return true;
  }
}

/// Opens the document (rethrows on failure → bad password), then extracts all
/// pages. Returns null if the document opened but yielded no text.
String? _extractTextWorker((Uint8List, String?) args) {
  final (bytes, password) = args;
  final document = (password != null && password.isNotEmpty)
      ? PdfDocument(inputBytes: bytes, password: password)
      : PdfDocument(inputBytes: bytes);
  try {
    final buffer = StringBuffer();
    final extractor = PdfTextExtractor(document);
    for (int i = 0; i < document.pages.count; i++) {
      buffer.writeln(extractor.extractText(startPageIndex: i, endPageIndex: i));
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? null : text;
  } catch (_) {
    return null; // opened fine, but extraction failed
  } finally {
    document.dispose();
  }
}

int _pageCountWorker((Uint8List, String?) args) {
  final (bytes, password) = args;
  try {
    final document = (password != null && password.isNotEmpty)
        ? PdfDocument(inputBytes: bytes, password: password)
        : PdfDocument(inputBytes: bytes);
    final count = document.pages.count;
    document.dispose();
    return count;
  } catch (_) {
    return 0;
  }
}
