import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'core/amount_sanity.dart';
import 'core/theme/wo_design.dart';
import 'data/services/secure_vault.dart';
import 'data/services/notification_service.dart';
import 'data/services/background_service.dart';
import 'data/services/gemini_service.dart';
import 'data/repositories/app_repository.dart';
import 'data/services/fx_service.dart';
import 'data/services/demo_data_service.dart';
import 'data/services/diagnostics_service.dart';
import 'features/security/screens/app_lock_screen.dart';
import 'navigation/app_router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Fonts are bundled in assets/google_fonts/ — never fetch from the network
  // (runtime fetching crashed with unhandled exceptions on flaky connections).
  GoogleFonts.config.allowRuntimeFetching = false;

  // Keep diagnostic logging alive in release builds: debugPrint is a no-op
  // there, which made on-device debugging impossible (logcat showed nothing
  // while sync/extraction visibly ran).
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        // ignore: avoid_print
        print(message);
      }
    };
  }

  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Color(0xFFF5F6FA),
    systemNavigationBarIconBrightness: Brightness.dark,
  ));

  // Initialize local notifications (used by background tasks & insights)
  try {
    await NotificationService().initialize();
  } catch (e) {
    debugPrint('Notification init error: $e');
  }

  // Wire up scheduled statement processing if the user has connected email
  // and enabled automation. Tasks are also (de)registered when the user
  // toggles automation in StatementAutomationScreen.
  try {
    if (await SecureVault.hasEmailCredentials()) {
      await BackgroundService.initialize();
      await BackgroundService.registerTasks();
      await Permission.ignoreBatteryOptimizations.request();
      // One-shot catch-up: older builds crashed the worker on a 32-bit
      // notification id, so statements sat unprocessed for months.
      // v402 re-queues AI timeouts after thinking was disabled.
      try {
        final repo = await AppRepository.getInstance();
        if (!await repo.getBoolSetting('catchup_sync_v402')) {
          for (final item in await repo.getAllStatementQueue()) {
            if (item.status == 'failed' || item.status == 'processing') {
              await repo.updateStatementQueueStatus(item.id, 'pending');
            }
          }
          await BackgroundService.executeNow(BackgroundService.statementProcessingTask);
          await repo.setAppSetting('catchup_sync_v402', 'true');
        }
      } catch (e) {
        debugPrint('Catch-up sync schedule error: $e');
      }
    }
  } catch (e) {
    debugPrint('Background service init error: $e');
  }

  // Check if onboarding is complete (with error handling)
  bool onboardingComplete = false;
  try {
    onboardingComplete = await SecureVault.isOnboardingComplete();
  } catch (e) {
    debugPrint('Error checking onboarding status: $e');
    onboardingComplete = false;
  }

  // App-lock preference + currency setup
  bool biometricEnabled = false;
  try {
    final repo = await AppRepository.getInstance();
    biometricEnabled = await repo.getBoolSetting('biometric_enabled');

    // Theme: Light by default (brand direction); user choice persisted in settings.
    final savedTheme = await repo.getAppSetting('theme_mode') ?? 'light';
    final mode = WoThemeMode.values.firstWhere(
      (m) => m.name == savedTheme,
      orElse: () => WoThemeMode.system,
    );
    WoTheme.apply(mode,
        WidgetsBinding.instance.platformDispatcher.platformBrightness);

    // Data maintenance: merge per-sender duplicate accounts & sources, and
    // retype credit-card accounts (idempotent, cheap — run every launch).
    // Each step is isolated so one FK failure cannot skip FX seeding.
    try {
      await repo.mergeDuplicateAccounts();
    } catch (e) {
      debugPrint('mergeDuplicateAccounts skipped: $e');
    }
    try {
      await repo.mergeDuplicateSources();
    } catch (e) {
      debugPrint('mergeDuplicateSources skipped: $e');
    }
    try {
      await repo.retypeCardAccounts();
    } catch (e) {
      debugPrint('retypeCardAccounts skipped: $e');
    }
    try {
      await repo.retypeBrokerageAccounts();
    } catch (e) {
      debugPrint('retypeBrokerageAccounts skipped: $e');
    }

    // One-shot (v4.1.0): repair the statement pipeline.
    //  * accounts the old loose card heuristic flipped to credit_card (and
    //    re-signed as debt) go back to being bank accounts;
    //  * every statement that failed or imported nothing is re-queued, now
    //    that PDF passwords resolve across all key spaces and statements are
    //    windowed instead of clipped.
    try {
      if (!await repo.getBoolSetting('pipeline_repair_v410')) {
        final fixed = await repo.repairMiscardedAccounts();
        final requeued = await repo.requeueFailedStatements();
        await repo.setAppSetting('pipeline_repair_v410', 'true');
        debugPrint('🩹 Pipeline repair: $fixed account(s) retyped, '
            '$requeued statement(s) re-queued');
      }
    } catch (e) {
      debugPrint('pipeline_repair_v410 skipped: $e');
    }

    // One-shot (v4.1.1): v4.1.0's card repair retyped accounts to `bank`
    // without checking the balance, which moved deeply negative card ledgers
    // into the cash total. Put those back.
    try {
      if (!await repo.getBoolSetting('card_retype_guard_v411')) {
        int n = 0;
        for (final a in await repo.getAllAccounts()) {
          if (a.type != 'bank') continue;
          if (a.balance >= -AmountSanity.maxForCurrency(a.currencyCode) * 0.1) {
            continue;
          }
          await repo.updateAccountType(a.id, 'credit_card');
          n++;
          debugPrint('↩️ ${a.name} back to credit_card (balance ${a.balance})');
        }
        await repo.setAppSetting('card_retype_guard_v411', 'true');
        if (n > 0) debugPrint('🩹 Reverted $n mis-retyped account(s)');
      }
    } catch (e) {
      debugPrint('card_retype_guard_v411 skipped: $e');
    }

    // One-shot: remove AI-misparsed mega-amounts (e.g. Travclan ₹billions)
    // and reset affected account closing anchors so balances can recover.
    try {
      if (!await repo.getBoolSetting('absurd_tx_quarantine_v1')) {
        final n = await repo.quarantineAbsurdTransactions();
        await repo.setAppSetting('absurd_tx_quarantine_v1', 'true');
        debugPrint('🧹 Absurd-tx quarantine removed $n rows');
      }
    } catch (e) {
      debugPrint('absurd_tx_quarantine skipped: $e');
    }

    // Built-in Qwen key so extraction works without a Google Gemini key.
    try {
      await GeminiService.seedDefaultKey();
    } catch (e) {
      debugPrint('AI key seed error: $e');
    }

    // Marketing/demo builds only (flutter build … --dart-define=DEMO=true):
    // seeds a fully fictional dataset for screenshots.
    if (const bool.fromEnvironment('DEMO')) {
      await DemoDataService.seed(repo);
    }

    // Leave a health report behind on every launch. The release build cannot
    // be inspected with `run-as`, and a periodic WorkManager job refuses to
    // be forced early, so an ordinary app open is the reliable way to make
    // the ledger's state readable over ADB:
    //   adb shell cat /sdcard/Android/data/<pkg>/files/wo_diagnostics.json
    try {
      final db = AppRepository.database;
      if (db != null) await DiagnosticsService.dump(db, repo);
    } catch (e) {
      debugPrint('Diagnostics dump skipped: $e');
    }

    // Ensure FX rates are populated, repair any pre-multi-currency data once,
    // then refresh live rates in the background.
    await FxService.ensureSeeded(repo);
    if (!await repo.getBoolSetting('currency_repaired_v1')) {
      await repo.repairCurrencies();
      await repo.setAppSetting('currency_repaired_v1', 'true');
    }
    // DEMO builds use the fixed fallback rates only — skipping the live refresh
    // keeps every screen's conversions identical for reproducible screenshots.
    if (!const bool.fromEnvironment('DEMO')) {
      FxService.refresh(repo).then((_) => repo.repairCurrencies());
    }
  } catch (e) {
    debugPrint('Startup currency/setting error: $e');
  }

  runApp(
    ProviderScope(
      child: WealthOrbitApp(
        onboardingComplete: onboardingComplete,
        biometricEnabled: biometricEnabled,
      ),
    ),
  );
}

class WealthOrbitApp extends StatefulWidget {
  final bool onboardingComplete;
  final bool biometricEnabled;

  const WealthOrbitApp({
    super.key,
    required this.onboardingComplete,
    required this.biometricEnabled,
  });

  @override
  State<WealthOrbitApp> createState() => _WealthOrbitAppState();
}

class _WealthOrbitAppState extends State<WealthOrbitApp>
    with WidgetsBindingObserver {
  late bool _unlocked = !widget.biometricEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WoTheme.revision.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WoTheme.revision.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
    _syncSystemChrome();
  }

  @override
  void didChangePlatformBrightness() {
    // Follow OS theme when in System mode.
    WoTheme.apply(WoTheme.mode,
        WidgetsBinding.instance.platformDispatcher.platformBrightness);
  }

  void _syncSystemChrome() {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: WoTheme.isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: WoColors.bg,
      systemNavigationBarIconBrightness:
          WoTheme.isDark ? Brightness.light : Brightness.dark,
    ));
  }

  @override
  Widget build(BuildContext context) {
    _syncSystemChrome();
    return MaterialApp.router(
      title: 'WealthOrbit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: WoTheme.isDark ? Brightness.dark : Brightness.light,
        primaryColor: WoColors.gold,
        scaffoldBackgroundColor: WoColors.bg,
        colorScheme: (WoTheme.isDark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
          primary: WoColors.gold,
          secondary: WoColors.indigo,
          surface: WoColors.surface,
          error: WoColors.red,
        ),
        textTheme: GoogleFonts.poppinsTextTheme(
          (WoTheme.isDark ? ThemeData.dark() : ThemeData.light()).textTheme,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: WoColors.bg,
          elevation: 0,
        ),
        datePickerTheme: DatePickerThemeData(
          backgroundColor: WoColors.surface,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: WoColors.surfaceHi,
          contentTextStyle: GoogleFonts.inter(color: WoColors.textHi, fontSize: 13),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      routerConfig: AppRouter.createRouter(onboardingComplete: widget.onboardingComplete),
      builder: (context, child) {
        if (_unlocked) return child ?? const SizedBox.shrink();
        return AppLockScreen(onUnlocked: () => setState(() => _unlocked = true));
      },
    );
  }
}
