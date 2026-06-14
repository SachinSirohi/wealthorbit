import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'core/theme/wo_design.dart';
import 'data/services/secure_vault.dart';
import 'data/services/notification_service.dart';
import 'data/services/background_service.dart';
import 'data/repositories/app_repository.dart';
import 'data/services/fx_service.dart';
import 'data/services/demo_data_service.dart';
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
    await repo.mergeDuplicateAccounts();
    await repo.mergeDuplicateSources();
    await repo.retypeCardAccounts();

    // Marketing/demo builds only (flutter build … --dart-define=DEMO=true):
    // seeds a fully fictional dataset for screenshots.
    if (const bool.fromEnvironment('DEMO')) {
      await DemoDataService.seed(repo);
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
