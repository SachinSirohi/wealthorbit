import 'package:flutter/foundation.dart';
import 'package:enough_mail/enough_mail.dart';
import '../models/discovered_source.dart';
import 'secure_vault.dart';

/// Service for interacting with IMAP servers to fetch bank statements
class ImapService {
  /// When provided, this account is used instead of the primary stored one —
  /// lets callers sync each of several connected mailboxes.
  final EmailAccount? account;

  ImapService({this.account});

  ImapClient? _client;
  bool _isConnecting = false;

  // Cache of fetched message headers (UID, ENVELOPE only)
  List<MimeMessage> _cachedHeaders = [];
  // Discovery is heavy (fetch + parse hundreds of envelopes). Cache the result
  // STATICALLY (keyed by mailbox) so the discovery, password and extraction
  // screens — each of which builds its own ImapService — share one result
  // instead of re-scanning the whole mailbox on the UI isolate every time.
  static final Map<String, List<DiscoveredSource>> _sourceCache = {};
  // The raw headers behind a cached discovery — restored on a cache hit so
  // searchStatementEmails() (which filters _cachedHeaders) still finds emails.
  static final Map<String, List<MimeMessage>> _headerCacheByAccount = {};
  static final Map<String, DateTime> _discoveryAt = {};
  // Cache of full messages with body
  Map<int, MimeMessage> _fullMessageCache = {};

  /// Connect to IMAP server using stored credentials
  Future<bool> connect({String? host, int? port}) async {
    if (_client != null && _client!.isConnected) return true;
    if (_isConnecting) return false;

    _isConnecting = true;
    try {
      final email = account?.email ?? await SecureVault.getGmailEmail();
      final password = account?.password ?? await SecureVault.getGmailPassword();

      if (email == null || password == null) {
        throw Exception('Email credentials not found');
      }

      final finalHost = host ?? _detectHost(email);
      final finalPort = port ?? 993;

      debugPrint('🔌 Connecting to IMAP: $finalHost:$finalPort for $email');
      
      _client = ImapClient(isLogEnabled: false);
      
      await _client!.connectToServer(finalHost, finalPort, isSecure: true);
      await _client!.login(email, password);
      
      // Select inbox immediately after login
      final mailboxes = await _client!.listMailboxes();
      final inbox = mailboxes.firstWhere(
        (m) => m.name.toLowerCase() == 'inbox', 
        orElse: () => mailboxes.first
      );
      await _client!.selectMailbox(inbox);
      
      debugPrint('✅ IMAP Connected successfully');
      return true;
    } catch (e) {
      debugPrint('❌ IMAP Connection failed: $e');
      _client = null;
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  /// Disconnect from IMAP server
  Future<void> disconnect() async {
    _cachedHeaders = [];
    _fullMessageCache = {};
    if (_client != null && _client!.isConnected) {
      try {
        await _client!.logout();
      } catch (e) {
        // Ignore logout errors
      } finally {
        _client = null;
      }
    }
  }

  /// Check connection status
  bool get isConnected => _client != null && _client!.isConnected;

  /// Discover statement senders from inbox using optimized search
  /// Format a DateTime as an IMAP SEARCH date (e.g. `12-Jun-2024`).
  static String _imapDate(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day}-${months[d.month - 1]}-${d.year}';
  }

  /// Fetch `(UID ENVELOPE)` headers for a set of sequence ids, in chunks so a
  /// large 24-month result set can't blow up a single FETCH command.
  Future<List<MimeMessage>> _fetchHeadersChunked(List<int> ids, {int cap = 2000}) async {
    ids.sort();
    final capped = ids.length > cap ? ids.sublist(ids.length - cap) : ids;
    final out = <MimeMessage>[];
    for (var i = 0; i < capped.length; i += 200) {
      final chunk = capped.sublist(i, i + 200 > capped.length ? capped.length : i + 200);
      try {
        final fr = await _client!.fetchMessages(
          MessageSequence.fromIds(chunk, isUid: false), '(UID ENVELOPE)');
        out.addAll(fr.messages);
      } catch (e) {
        debugPrint('⚠️ Header chunk fetch failed (${chunk.first}..${chunk.last}): $e');
      }
    }
    return out;
  }

  /// Default window: 24 months — statements live deep in the mailbox, far
  /// beyond the most recent few hundred emails.
  Future<List<DiscoveredSource>> discoverStatementSenders({int daysBack = 730}) async {
    if (!isConnected) throw Exception('Not connected to IMAP');

    // Reuse a recent discovery instead of re-fetching/parsing hundreds of
    // envelopes again (the discovery, password and extraction screens all call
    // this — repeating it on the UI isolate was a primary ANR cause).
    final cacheKey = account?.email ?? 'default';
    final cached = _sourceCache[cacheKey];
    final cachedAt = _discoveryAt[cacheKey];
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(minutes: 15)) {
      debugPrint('✅ Reusing cached discovery (${cached.length} sources)');
      // Restore the headers behind this discovery so searchStatementEmails()
      // still finds per-sender emails (otherwise extraction sees 0 and imports
      // nothing — the "100% / 0 transactions in 3s" bug).
      _cachedHeaders = _headerCacheByAccount[cacheKey] ?? _cachedHeaders;
      return cached;
    }

    try {
      debugPrint('🔍 Searching for statement emails (last $daysBack days)...');

      List<MimeMessage> messages = [];

      // Make sure the inbox is the selected mailbox for everything below.
      try {
        final mailboxes = await _client!.listMailboxes();
        final inbox = mailboxes.firstWhere(
          (m) => m.name.toLowerCase() == 'inbox',
          orElse: () => mailboxes.first,
        );
        await _client!.selectMailbox(inbox);
      } catch (e) {
        debugPrint('⚠️ Could not (re)select inbox: $e');
      }

      // STRATEGY 0a: Gmail-native search across the FULL window. X-GM-RAW
      // runs a real Gmail query server-side — subject keywords + attachments
      // + age — instead of scanning only the most recent N emails.
      try {
        final months = (daysBack / 30).ceil();
        final res = await _client!.searchMessages(
          searchCriteria:
              'X-GM-RAW "subject:(statement OR estatement OR e-statement OR summary OR transaction) has:attachment newer_than:${months}m"',
        );
        final ids = res.matchingSequence?.toList() ?? <int>[];
        debugPrint('📬 Gmail X-GM-RAW matched ${ids.length} messages');
        if (ids.isNotEmpty) {
          messages = await _fetchHeadersChunked(ids);
          debugPrint('✅ Strategy 0a (Gmail deep search): ${messages.length} headers');
        }
      } catch (e) {
        debugPrint('⚠️ Strategy 0a (X-GM-RAW) unavailable: $e');
      }

      // STRATEGY 0b: generic IMAP SEARCH fallback — per-keyword SINCE search,
      // merged. Works on any IMAP server (Outlook/Yahoo/iCloud).
      if (messages.isEmpty) {
        try {
          final since = _imapDate(DateTime.now().subtract(Duration(days: daysBack)));
          final ids = <int>{};
          for (final term in ['statement', 'summary', 'transaction']) {
            try {
              final r = await _client!
                  .searchMessages(searchCriteria: 'SINCE $since SUBJECT "$term"');
              ids.addAll(r.matchingSequence?.toList() ?? const <int>[]);
            } catch (e) {
              debugPrint('⚠️ SEARCH "$term" failed: $e');
            }
          }
          debugPrint('📬 IMAP SEARCH matched ${ids.length} messages');
          if (ids.isNotEmpty) {
            messages = await _fetchHeadersChunked(ids.toList());
            debugPrint('✅ Strategy 0b (IMAP deep search): ${messages.length} headers');
          }
        } catch (e) {
          debugPrint('⚠️ Strategy 0b failed: $e');
        }
      }

      // STRATEGY 1: Manual Sequence (recent-window fallback)
      if (messages.isEmpty) {
      try {
        debugPrint('Trying Strategy 1: Manual Sequence...');
        final mailboxes = await _client!.listMailboxes();
        final inbox = mailboxes.firstWhere(
          (m) => m.name.toLowerCase() == 'inbox',
          orElse: () => mailboxes.first
        );
        final selectedInbox = await _client!.selectMailbox(inbox);
        final totalMessages = selectedInbox.messagesExists;

        if (totalMessages > 0) {
          final start = totalMessages - 500 > 0 ? totalMessages - 500 + 1 : 1;
          final sequence = MessageSequence.fromRange(start, totalMessages);

          // Parenthesized list — bare 'UID ENVELOPE' is rejected by some IMAP
          // servers (incl. Gmail), which silently forced the no-UID fallback.
          final fetchResult = await _client!.fetchMessages(sequence, '(UID ENVELOPE)');
          if (fetchResult.messages.isNotEmpty) {
            messages = fetchResult.messages;
            debugPrint('✅ Strategy 1 success: Fetched ${messages.length} messages');
          }
        }
      } catch (e) {
        debugPrint('⚠️ Strategy 1 failed: $e');
      }
      }

      // STRATEGY 2: Recent Messages with UID (Fallback)
      if (messages.isEmpty) {
        try {
          debugPrint('Trying Strategy 2: Recent Messages ((UID ENVELOPE))...');
          final fetchResult = await _client!.fetchRecentMessages(
            messageCount: 500,
            criteria: '(UID ENVELOPE)'
          );
          if (fetchResult.messages.isNotEmpty) {
            messages = fetchResult.messages;
            debugPrint('✅ Strategy 2 success: Fetched ${messages.length} messages');
          }
        } catch (e) {
          debugPrint('⚠️ Strategy 2 failed: $e');
        }
      }

      // STRATEGY 3: Recent Messages (Original Working Method - No UID guarantee)
      if (messages.isEmpty) {
        try {
          debugPrint('Trying Strategy 3: Recent Messages (ENVELOPE only)...');
          final fetchResult = await _client!.fetchRecentMessages(
            messageCount: 500, 
            criteria: 'ENVELOPE'
          );
          messages = fetchResult.messages;
          debugPrint('✅ Strategy 3 success: Fetched ${messages.length} messages');
        } catch (e) {
          debugPrint('❌ All strategies failed: $e');
        }
      }

      _cachedHeaders = messages;
       
      // Log filter stats
      debugPrint('🔍 Filtering ${messages.length} messages for keywords...');
      
      // Group by sender, filtering for statement-related keywords
      final Map<String, List<MimeMessage>> senderMap = {};
      
      for (final msg in _cachedHeaders) {
        final fromList = msg.from;
        final from = (fromList != null && fromList.isNotEmpty ? fromList.first.email : '').toLowerCase();
        if (from.isEmpty) continue;
        
        // Check if subject contains statement-related keywords
        final subject = msg.decodeSubject()?.toLowerCase() ?? '';
        final isMatch = subject.contains('statement') ||
            subject.contains('e-statement') ||
            subject.contains('summary') ||
            subject.contains('transaction') ||
            subject.contains('credit card') ||
            subject.contains('bank');
            
        if (isMatch) {
          senderMap.putIfAbsent(from, () => []);
          senderMap[from]!.add(msg);
        }
      }
      
      // Convert to DiscoveredSource list
      final sources = <DiscoveredSource>[];
      
      for (final entry in senderMap.entries) {
        final senderEmail = entry.key;
        final emails = entry.value;
        
        if (emails.isNotEmpty) {
          emails.sort((a, b) {
            final dateA = a.decodeDate() ?? DateTime(2000);
            final dateB = b.decodeDate() ?? DateTime(2000);
            return dateB.compareTo(dateA);
          });

          final firstUid = emails.first.uid?.toString() ?? '';
          
          sources.add(DiscoveredSource(
            senderEmail: senderEmail,
            senderName: DiscoveredSource.guessNameFromEmail(senderEmail),
            statementCount: emails.length,
            sampleMessageIds: [firstUid],
          ));
        }
      }
      
      sources.sort((a, b) => b.statementCount.compareTo(a.statementCount));
      
      debugPrint('✅ Found ${sources.length} statement sources');
      _sourceCache[cacheKey] = sources;
      _headerCacheByAccount[cacheKey] = _cachedHeaders;
      _discoveryAt[cacheKey] = DateTime.now();
      return sources;

    } catch (e) {
      debugPrint('❌ Discovery failed: $e');
      return [];
    }
  }

  /// Fetch the full body for a cached header, preferring its UID and falling
  /// back to its mailbox sequence number (valid within this session) when the
  /// server returned headers without UIDs. This is the universal fetch path —
  /// extraction/preview must never silently skip a message just because the
  /// discovery fetch had no UID.
  Future<MimeMessage?> fetchFullMessageFor(MimeMessage header) async {
    if (!isConnected) throw Exception('Not connected to IMAP');

    final uid = header.uid;
    if (uid != null && uid != 0) {
      return fetchFullMessage(uid);
    }

    final seq = header.sequenceId;
    if (seq == null || seq == 0) {
      debugPrint('⚠️ Header has neither UID nor sequence id');
      return null;
    }
    // Negative keys namespace sequence-fetched messages away from UID keys.
    if (_fullMessageCache.containsKey(-seq)) return _fullMessageCache[-seq];

    try {
      debugPrint('📥 Fetching full message by sequence #$seq (no UID)...');
      final sequence = MessageSequence.fromId(seq, isUid: false);
      final fetchResult = await _client!.fetchMessages(sequence, 'BODY.PEEK[]');
      if (fetchResult.messages.isNotEmpty) {
        final fullMessage = fetchResult.messages.first;
        _fullMessageCache[-seq] = fullMessage;
        return fullMessage;
      }
    } catch (e) {
      debugPrint('❌ Sequence fetch failed for #$seq: $e');
    }
    return null;
  }

  /// Fetch a single email with full body for preview
  Future<MimeMessage?> fetchEmailForPreview(String senderEmail) async {
    if (!isConnected) throw Exception('Not connected to IMAP');

    try {
      final header = _cachedHeaders.where(
        (m) {
          final f = m.from;
          return (f != null && f.isNotEmpty ? f.first.email : '').toLowerCase() == senderEmail.toLowerCase();
        }
      ).firstOrNull;

      if (header == null) {
        debugPrint('⚠️ No cached header for $senderEmail');
        return null;
      }

      return await fetchFullMessageFor(header);
    } catch (e) {
      debugPrint('❌ Failed to fetch preview: $e');
      return null;
    }
  }

  /// Search for emails from specific senders
  Future<List<MimeMessage>> searchStatementEmails(List<String> senders, {int daysBack = 365}) async {
    if (!isConnected) throw Exception('Not connected to IMAP');

    final relevantMessages = _cachedHeaders.where((msg) {
      final f = msg.from;
      final from = (f != null && f.isNotEmpty ? f.first.email : '').toLowerCase();
      return senders.any((s) => from.contains(s.toLowerCase()));
    }).toList();
    
    // Sort by date descending (newest first)
    relevantMessages.sort((a, b) {
      final dateA = a.decodeDate() ?? DateTime(2000);
      final dateB = b.decodeDate() ?? DateTime(2000);
      return dateB.compareTo(dateA);
    });
    
    return relevantMessages;
  }

  /// Download a specific message with full body
  Future<MimeMessage?> fetchFullMessage(int uid) async {
    if (!isConnected) throw Exception('Not connected to IMAP');
    
    // Check cache first
    if (_fullMessageCache.containsKey(uid)) {
      return _fullMessageCache[uid];
    }
    
    try {
      // CRITICAL: must use uidFetchMessage — enough_mail's fetchMessages()
      // ALWAYS issues a sequence-number FETCH and ignores isUid, so fetching
      // by UID through it asks for "message #<uid>" (out of range) and returns
      // nothing. This single bug made every body/PDF fetch fail silently.
      final fetchResult = await _client!.uidFetchMessage(uid, 'BODY.PEEK[]');
      if (fetchResult.messages.isNotEmpty) {
        final msg = fetchResult.messages.first;
        _fullMessageCache[uid] = msg;
        return msg;
      }
      debugPrint('⚠️ UID FETCH for $uid returned no message');
    } catch (e) {
      debugPrint('❌ Failed to fetch message $uid: $e');
    }
    return null;
  }

  /// Extract PDF attachments from a message
  Future<List<Uint8List>> extractPdfAttachments(MimeMessage message) async {
    final pdfs = <Uint8List>[];
    
    try {
      // KEY FIX: Use findContentInfo() to get attachment info first
      final contentInfos = message.findContentInfo();
      
      for (final contentInfo in contentInfos) {
        final mediaType = contentInfo.mediaType;
        final filename = contentInfo.fileName?.toLowerCase() ?? '';
        
        // Check for PDF attachments
        if (mediaType?.sub == MediaSubtype.applicationPdf || 
            filename.endsWith('.pdf') ||
            (mediaType?.text.contains('pdf') ?? false)) {
          
          // Get the part fetch ID (e.g., "1.2", "2", etc.)
          final fetchId = contentInfo.fetchId;
          
          if (fetchId.isNotEmpty) {
            // Fetch the part content from server if not already available
            final part = await _fetchPart(message, fetchId);
            
            if (part != null) {
              final data = part.decodeContentBinary();
              if (data != null && data.isNotEmpty) {
                pdfs.add(Uint8List.fromList(data));
                debugPrint('📎 Found PDF: $filename (${data.length} bytes)');
              }
            }
          }
        }
      }
    } catch (e, stackTrace) {
      debugPrint('⚠️ Error extracting attachments: $e');
      debugPrint(stackTrace.toString());
    }
    
    return pdfs;
  }

  /// Fetch a specific part of a message by its fetch ID
  Future<MimePart?> _fetchPart(MimeMessage message, String fetchId) async {
    try {
      // First check if the part is already available in the message
      final existingPart = message.getPart(fetchId);
      if (existingPart != null && existingPart.decodeContentBinary() != null) {
        return existingPart;
      }
      
      // If not available, fetch it from the server — by UID (uidFetchMessage)
      // when present, else by mailbox sequence number (fetchMessages).
      if (_client != null && _client!.isConnected) {
        final criteria = 'BODY.PEEK[$fetchId]';
        FetchImapResult? fetchResult;
        if (message.uid != null && message.uid != 0) {
          fetchResult = await _client!.uidFetchMessage(message.uid!, criteria);
        } else if (message.sequenceId != null && message.sequenceId != 0) {
          fetchResult = await _client!.fetchMessages(
              MessageSequence.fromId(message.sequenceId!, isUid: false), criteria);
        }
        if (fetchResult != null && fetchResult.messages.isNotEmpty) {
          // The fetched message should now contain the part data
          final fetchedMessage = fetchResult.messages.first;
          return fetchedMessage.getPart(fetchId);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error fetching part $fetchId: $e');
    }
    return null;
  }

  /// Get all attachment info from a message
  List<AttachmentInfo> getAttachmentInfo(MimeMessage message) {
    final attachments = <AttachmentInfo>[];
    
    try {
      final contentInfos = message.findContentInfo();
      
      for (final info in contentInfos) {
        final filename = info.fileName ?? 'unnamed';
        final size = info.size ?? 0;
        final mediaType = info.mediaType;
        
        attachments.add(AttachmentInfo(
          filename: filename,
          size: size,
          contentType: mediaType?.toString() ?? 'application/octet-stream',
          fetchId: info.fetchId,
        ));
      }
    } catch (e) {
      debugPrint('⚠️ Error getting attachment info: $e');
    }
    
    return attachments;
  }

  /// Get plain text body from email
  String getEmailBody(MimeMessage message) {
    try {
      // Try to get plain text first
      final plainText = message.decodeTextPlainPart();
      if (plainText != null && plainText.trim().isNotEmpty) {
        return plainText.trim();
      }

      // Fallback to HTML (strip tags)
      final html = message.decodeTextHtmlPart();
      if (html != null && html.isNotEmpty) {
        String text = _stripHtmlTags(html);

        if (text.isNotEmpty) {
          return text;
        }
      }

      return 'Email body is empty or could not be decoded.';
    } catch (e) {
      debugPrint('⚠️ Error decoding email body: $e');
      return 'Error loading email content: ${e.toString().split('\n').first}';
    }
  }

  /// Raw HTML body for rich rendering (password hints often live in styled
  /// tables/bold text). Falls back to a wrapped plain-text body.
  String? getEmailHtml(MimeMessage message) {
    try {
      final html = message.decodeTextHtmlPart();
      if (html != null && html.trim().isNotEmpty) return html;
      final plain = message.decodeTextPlainPart();
      if (plain != null && plain.trim().isNotEmpty) {
        return '<pre style="white-space:pre-wrap;font-family:sans-serif">${plain.replaceAll('<', '&lt;')}</pre>';
      }
    } catch (e) {
      debugPrint('⚠️ Error decoding email HTML: $e');
    }
    return null;
  }

  /// Strip HTML tags to get plain text
  String _stripHtmlTags(String html) {
    return html
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'&amp;', caseSensitive: false), '&')
        .replaceAll(RegExp(r'&lt;', caseSensitive: false), '<')
        .replaceAll(RegExp(r'&gt;', caseSensitive: false), '>')
        .replaceAll(RegExp(r'&quot;', caseSensitive: false), '"')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Fetch the latest message for a specific sender.
  ///
  /// Strategy: the discovery cache is checked FIRST (it is what produced the
  /// statement counts shown to the user, so if a count exists the message is
  /// in the cache). A server-side SEARCH only runs as a fallback, and is
  /// isolated so a SEARCH failure can never mask a cache hit.
  Future<MimeMessage?> fetchLatestMessageForSender(String senderEmail) async {
    if (!isConnected) throw Exception('Not connected to IMAP');

    // 1. Warm cache from discovery — most reliable path.
    try {
      final cached = _cachedHeaders.where(
        (m) {
          final f = m.from;
          return (f != null && f.isNotEmpty ? f.first.email : '').toLowerCase() == senderEmail.toLowerCase();
        },
      ).toList();

      if (cached.isNotEmpty) {
        cached.sort((a, b) {
          final dateA = a.decodeDate() ?? DateTime(2000);
          final dateB = b.decodeDate() ?? DateTime(2000);
          return dateB.compareTo(dateA);
        });

        final bestCached = cached.firstWhere(
          (m) => m.uid != null && m.uid != 0,
          orElse: () => cached.first,
        );

        debugPrint('✅ Cache hit for $senderEmail (UID ${bestCached.uid} / seq ${bestCached.sequenceId})');
        final full = await fetchFullMessageFor(bestCached);
        if (full != null) return full;
      }
    } catch (e) {
      debugPrint('⚠️ Cache lookup failed for $senderEmail: $e');
    }

    // 2. Fallback: precise server-side SEARCH (isolated — some servers
    // reject the criteria; that must not abort the whole lookup).
    try {
      debugPrint('🎯 SEARCHING latest message for $senderEmail via server...');
      final searchResult =
          await _client!.searchMessages(searchCriteria: 'FROM "$senderEmail"');

      final sequence = searchResult.matchingSequence;
      if (sequence != null && sequence.isNotEmpty) {
        final uidFetch = await _client!.fetchMessages(sequence, '(UID)');
        final uids = uidFetch.messages.map((m) => m.uid ?? 0).where((id) => id != 0).toList();

        if (uids.isNotEmpty) {
          uids.sort();
          debugPrint('✅ Server search found ${uids.length} messages; using UID ${uids.last}');
          return await fetchFullMessage(uids.last);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Server SEARCH failed for $senderEmail: $e');
    }

    return null;
  }

  /// Helper to detect IMAP host from email domain
  String _detectHost(String email) {
    if (email.contains('@gmail.com')) return 'imap.gmail.com';
    if (email.contains('@outlook.com') || email.contains('@hotmail.com')) return 'outlook.office365.com';
    if (email.contains('@yahoo.com')) return 'imap.mail.yahoo.com';
    return 'imap.gmail.com';
  }
}

/// Helper class for attachment info
class AttachmentInfo {
  final String filename;
  final int size;
  final String contentType;
  final String? fetchId;

  AttachmentInfo({
    required this.filename,
    required this.size,
    required this.contentType,
    this.fetchId,
  });
}
