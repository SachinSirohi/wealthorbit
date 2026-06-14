import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service for local notifications (budget alerts, goal reminders, etc.)
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();
  
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    const androidSettings = AndroidInitializationSettings('@mipmap/launcher_icon');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    
    await _notifications.initialize(initSettings);
    _isInitialized = true;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // BUDGET ALERTS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<void> showBudgetWarning({
    required String categoryName,
    required int percentUsed,
  }) async {
    String title;
    String body;
    
    if (percentUsed >= 100) {
      title = '🚨 Budget Exceeded!';
      body = 'You\'ve exceeded your $categoryName budget by ${percentUsed - 100}%';
    } else if (percentUsed >= 90) {
      title = '⚠️ Budget Critical';
      body = '$categoryName budget is at $percentUsed%. Only ${100 - percentUsed}% remaining!';
    } else if (percentUsed >= 70) {
      title = '📊 Budget Alert';
      body = '$categoryName budget is at $percentUsed%. Consider reducing spending.';
    } else {
      return; // No alert needed
    }
    
    await _showNotification(
      id: categoryName.hashCode,
      title: title,
      body: body,
      channel: 'budget_alerts',
      channelName: 'Budget Alerts',
    );
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // GOAL ALERTS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<void> showGoalShortfallAlert({
    required String goalName,
    required double shortfallPercent,
  }) async {
    await _showNotification(
      id: goalName.hashCode,
      title: '📈 Goal Shortfall Alert',
      body: '$goalName is ${shortfallPercent.toStringAsFixed(0)}% behind schedule. Consider increasing SIP.',
      channel: 'goal_alerts',
      channelName: 'Goal Alerts',
    );
  }
  
  Future<void> showGoalAchieved({required String goalName}) async {
    await _showNotification(
      id: goalName.hashCode + 1000,
      title: '🎉 Goal Achieved!',
      body: 'Congratulations! You\'ve reached your $goalName goal!',
      channel: 'goal_alerts',
      channelName: 'Goal Alerts',
    );
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // SIP REMINDERS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<void> showSipReminderDue({
    required String sipName,
    required double amount,
    required String currency,
  }) async {
    await _showNotification(
      id: sipName.hashCode + 2000,
      title: '💰 SIP Due Tomorrow',
      body: '$sipName: $currency ${amount.toStringAsFixed(0)} will be debited tomorrow.',
      channel: 'sip_reminders',
      channelName: 'SIP Reminders',
    );
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // EMI REMINDERS
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<void> showEmiDueReminder({
    required String loanName,
    required double amount,
    required String currency,
  }) async {
    await _showNotification(
      id: loanName.hashCode + 3000,
      title: '🏦 EMI Due',
      body: '$loanName EMI of $currency ${amount.toStringAsFixed(0)} is due in 3 days.',
      channel: 'emi_reminders',
      channelName: 'EMI Reminders',
    );
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // STATEMENT PROCESSING
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<void> showStatementProcessed({
    required String bankName,
    required int transactionCount,
  }) async {
    await _showNotification(
      id: DateTime.now().millisecondsSinceEpoch,
      title: '✅ Statement Processed',
      body: '$bankName: $transactionCount transactions imported successfully.',
      channel: 'statement_processing',
      channelName: 'Statement Processing',
    );
  }
  
  Future<void> showStatementError({
    required String bankName,
    required String error,
  }) async {
    await _showNotification(
      id: DateTime.now().millisecondsSinceEpoch,
      title: '❌ Statement Error',
      body: 'Failed to process $bankName statement: $error',
      channel: 'statement_processing',
      channelName: 'Statement Processing',
    );
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // ANOMALY DETECTION
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<void> showAnomalyDetected({
    required String description,
  }) async {
    await _showNotification(
      id: DateTime.now().millisecondsSinceEpoch,
      title: '🔍 Unusual Activity Detected',
      body: description,
      channel: 'anomaly_detection',
      channelName: 'Anomaly Detection',
    );
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // EXIT RULES (Real Estate)
  // ═══════════════════════════════════════════════════════════════════════════
  
  Future<void> showExitRuleTriggered({
    required String propertyName,
    required String message,
  }) async {
    await _showNotification(
      id: propertyName.hashCode + 5000,
      title: '🏠 Exit Target Reached!',
      body: '$propertyName: $message',
      channel: 'exit_rules',
      channelName: 'Property Exit Alerts',
    );
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // EXTRACTION PROGRESS (ongoing — visible after leaving the app)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Fixed id so repeated calls update the SAME notification (a live progress
  /// bar) instead of stacking new ones.
  static const int extractionProgressId = 777001;

  /// Show/update an ongoing progress notification while statements import. It's
  /// `ongoing` (non-dismissible) and `onlyAlertOnce` (no repeated buzzing), so
  /// the user always knows extraction is running even if they switch apps.
  Future<void> showExtractionProgress({
    required int current,
    required int total,
    String? bankName,
  }) async {
    if (!_isInitialized) await initialize();
    final max = total > 0 ? total : 1;
    final android = AndroidNotificationDetails(
      'extraction_progress',
      'Statement Extraction',
      channelDescription: 'Progress while importing your statements',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: max,
      progress: current.clamp(0, max),
      icon: '@mipmap/launcher_icon',
    );
    final details = NotificationDetails(
      android: android,
      iOS: const DarwinNotificationDetails(
          presentAlert: false, presentBadge: false, presentSound: false),
    );
    final body = (bankName != null && bankName.isNotEmpty)
        ? '$current of $total · $bankName'
        : '$current of $total statements';
    await _notifications.show(
        extractionProgressId, 'Importing your statements…', body, details);
  }

  /// Replace the ongoing progress notification with a final "done" one.
  Future<void> completeExtractionProgress({required int imported}) async {
    await _notifications.cancel(extractionProgressId);
    await _showNotification(
      id: extractionProgressId + 1,
      title: 'Statements imported',
      body: imported > 0
          ? '$imported transactions added — tap to review.'
          : 'Import finished.',
      channel: 'extraction_progress',
      channelName: 'Statement Extraction',
    );
  }

  /// Clear the ongoing progress notification (e.g. on cancel/error).
  Future<void> cancelExtractionProgress() async {
    await _notifications.cancel(extractionProgressId);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // HELPER
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
    required String channel,
    required String channelName,
  }) async {
    if (!_isInitialized) await initialize();
    
    final androidDetails = AndroidNotificationDetails(
      channel,
      channelName,
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
    );
    
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    
    await _notifications.show(id, title, body, details);
  }
  
  /// Cancel all notifications
  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }
  
  /// Cancel notification by ID
  Future<void> cancel(int id) async {
    await _notifications.cancel(id);
  }
}
