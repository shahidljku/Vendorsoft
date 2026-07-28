import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/main_layout.dart';
import 'screens/pin_lock_screen.dart';
import 'screens/activation_screen.dart';
import 'screens/license_expired_screen.dart';
import 'screens/time_discrepancy_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/account_deactivated_screen.dart';
import 'screens/device_banned_screen.dart';
import 'screens/maintenance_screen.dart';
import 'screens/offline_locked_screen.dart';
import 'screens/device_transferred_screen.dart';
import 'screens/subscription_reminder_dialog.dart';
import 'services/settings_service.dart';
import 'services/security_service.dart';
import 'services/license_service.dart';
import 'services/excel_service.dart';
import 'services/clock_guard_service.dart';
import 'services/trial_service.dart';
import 'services/firebase_installation_service.dart';
import 'services/config_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'services/push_notification_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'screens/update_required_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  PushNotificationService().initialize();
  runApp(const ImageSenderApp());
}

class ImageSenderApp extends StatefulWidget {
  const ImageSenderApp({super.key});

  @override
  State<ImageSenderApp> createState() => _ImageSenderAppState();
}

class _ImageSenderAppState extends State<ImageSenderApp>
    with WidgetsBindingObserver {

  final SettingsService _settingsService = SettingsService();
  final LicenseService _licenseService = LicenseService();
  final ExcelService _excelService = ExcelService();
  final ClockGuardService _clockGuardService = ClockGuardService();
  final TrialService _trialService = TrialService();
  late final SecurityService _securityService;

  ThemeMode _themeMode = ThemeMode.dark;
  bool _isLocked = true;
  bool _isLoading = true;
  bool _pinEnabled = false;
  bool _hasPinSet = false;
  bool _hasAcceptedTerms = false;

  bool _isLicensed = false;
  bool _isExpired = false;
  bool _isClockTrustworthy = true;
  bool _isTrialActive = false;
  bool _isDeactivated = false;
  bool _isBanned = false;
  bool _isMaintenanceMode = false;
  bool _isOfflineLocked = false;
  bool _isSuperseded = false;
  String _maintenanceMessage = '';
  bool _isUpdateRequired = false;

  @override
  void initState() {
    super.initState();
    _securityService = SecurityService(_settingsService);
    WidgetsBinding.instance.addObserver(this);
    _licenseService.onLicenseRevoked.listen((reason) {
      if (mounted) {
        if (reason == 'DEACTIVATED') {
          setState(() {
            _isDeactivated = true;
          });
        } else if (reason == 'RESTORED') {
          if (_isDeactivated) {
            setState(() {
              _isDeactivated = false;
            });
          }
          if (_isBanned) {
            setState(() {
              _isBanned = false;
            });
          }
          if (_isOfflineLocked) {
            setState(() {
              _isOfflineLocked = false;
            });
          }
          _loadSettings(isLifecycleReload: true);
        } else if (reason == 'BANNED') {
          setState(() {
            _isBanned = true;
          });
        } else if (reason == 'OFFLINE_LOCKED' || reason == 'OFFLINE_EXPIRED') {
          setState(() {
            _isOfflineLocked = true;
          });
        } else if (reason == 'SUPERSEDED') {
          setState(() {
            _isSuperseded = true;
            _isOfflineLocked = false;
          });
        } else if (reason == 'REVOKED') {
          setState(() {
            _isSuperseded = false;
            _isDeactivated = false;
            _isBanned = false;
            _isOfflineLocked = false;
          });
          _loadSettings(isLifecycleReload: true);
        } else {
          _loadSettings(isLifecycleReload: true);
        }
      }
    });

    ConfigService().onConfigUpdated.listen((_) {
      if (mounted) {
        _checkAppVersion();
        setState(() {
          _isMaintenanceMode = ConfigService().isMaintenanceMode;
          _maintenanceMessage = ConfigService().maintenanceMessage;
        });
      }
    });
    ConfigService().startBackgroundPolling();
    LicenseService().startBackgroundPolling();
    _loadSettings();
  }

  Future<void> _checkAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
      final requiresUpdate = ConfigService().isUpdateRequired(currentVersion);
      if (mounted && requiresUpdate != _isUpdateRequired) {
        setState(() {
          _isUpdateRequired = requiresUpdate;
        });
      }
    } catch (e) {
      debugPrint('Failed to check app version: $e');
    }
  }

  Future<void> _initTimeGuard() async {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    ConfigService().stopBackgroundPolling();
    LicenseService().stopBackgroundPolling();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
      _clockGuardService.checkClockIntegrity().then((ok) {
        if (mounted && ok != _isClockTrustworthy) {
          setState(() {
            _isClockTrustworthy = ok;
          });
        }
      });
      if (!_isOfflineLocked && _isLicensed) {
        _licenseService.pollOnlineSubscriptionStatus();
      }
    }
  }

  Future<void> _loadSettings({bool isLifecycleReload = false}) async {
    String themeStr = await _settingsService.getThemeMode();
    _pinEnabled = await _securityService.isPinEnabled();
    _hasPinSet = await _securityService.hasPinSet();
    _hasAcceptedTerms = await _settingsService.getHasAcceptedTerms();

    // Fetch remote global system config
    await ConfigService().fetchSystemConfig();

    // Silently login to Firebase anonymously to get CustomerId / Device ID token
    try {
      await FirebaseInstallationService().registerInstallationIfNeeded();
    } catch (e) {
      debugPrint('Firebase init error (offline?): $e');
    }

    // Try to silently migrate legacy RSA license to Cloudflare backend
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final token = await user.getIdToken();
        if (token != null) {
          await _licenseService.migrateLegacyLicenseToServer(token);
        }
      }
    } catch (e) {
      debugPrint('Legacy migration warning: $e');
    }

    // 1. Evaluate Valid Paid License first (Priority Rule #1)
    _isLicensed = await _licenseService.isLicensed();
    if (_isLicensed) {
      _isExpired = _licenseService.isLicenseExpired();
    }

    // Check system clock integrity independently
    _isClockTrustworthy = await _clockGuardService.checkClockIntegrity();

    // 2. If unlicensed (and not expired paid key), check 30-Day First-Install Trial (Priority Rule #2)
    if (!_isLicensed && _isClockTrustworthy) {
      _isTrialActive = await _trialService.checkTrialState();
      if (_trialService.isClockDiscrepancy) {
        _isClockTrustworthy = false;
      }
    } 

    String? lastUri = await _settingsService.getLastExcelUri();
    String? lastName = await _settingsService.getLastExcelFileName();
    if (lastUri != null && lastUri.isNotEmpty && lastName != null) {
      // Prevent unintended background reloads from overwriting in-memory state
      if (!isLifecycleReload || _excelService.allCustomers.isEmpty) {
        await _excelService.loadFromUri(lastUri, lastName);
      }
    }

    await _checkAppVersion();

    setState(() {
      _themeMode = _parseThemeMode(themeStr);
      _isLocked = _pinEnabled && _hasPinSet;
      _isMaintenanceMode = ConfigService().isMaintenanceMode;
      _maintenanceMessage = ConfigService().maintenanceMessage;
      _isLoading = false;
    });

    if (!isLifecycleReload && _hasAcceptedTerms && _isLicensed && !_isExpired && !_isOfflineLocked && !_isBanned && !_isSuperseded && !_isDeactivated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkAndShowReminder();
      });
    }
  }

  Future<void> _checkAndShowReminder() async {
    final shouldShow = await _licenseService.shouldShowExpiryReminder();
    if (shouldShow && mounted) {
      await _licenseService.markExpiryReminderShown();
      showDialog(
        context: context,
        builder: (context) => SubscriptionReminderDialog(
          daysRemaining: _licenseService.getDaysRemaining(),
          onRenew: () {
            // Placeholder: currently just closes the dialog. Will integrate with Razorpay later.
          },
        ),
      );
    }
  }

  ThemeMode _parseThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;  
      default:
        return ThemeMode.system;
    }
  }

  void _onThemeChanged() {
    _loadSettings();
  }

  void _onPinSuccess() {
    setState(() {
      _isLocked = false;
    });
  }

  Widget _buildLicenseExpiredScreen() {
    final info = _licenseService.getLicenseInfo();
    return LicenseExpiredScreen(
      deviceId: info?['deviceId'] ?? 'Unknown',
      customerName: info?['companyName'] ?? info?['customerName'] ?? 'Unknown',
      licenseNumber: info?['licenseNumber'] ?? 'Unknown',
      expiryDate: info?['expiryDate'] ?? 'Unknown',
      onActivateLicense: () async {
        await _licenseService.removeLicense();
        setState(() {
          _isLicensed = false;
          _isExpired = false;
          _isTrialActive = false;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          scaffoldBackgroundColor: const Color(0xFF0B1014),
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFF0B3D30), // Dark green background
          body: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/icon/app_icon.png', width: 160, height: 160),
                    const SizedBox(height: 24),
                    const Text(
                      'Vendor\nSoftware',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 40,
                child: Center(
                  child: CircularProgressIndicator(color: Color(0xFF00E676)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'VendorSoft',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        if (_isBanned) {
          return const DeviceBannedScreen();
        }
        return Stack(
          children: [
            if (child != null) child,
            if (_isUpdateRequired)
              Positioned.fill(
                child: UpdateRequiredScreen(
                  apkDownloadUrl: ConfigService().apkDownloadUrl,
                  latestVersion: ConfigService().latestVersion,
                ),
              )
            else if (_isDeactivated)
              const Positioned.fill(
                child: AccountDeactivatedScreen(),
              )
            else if (_isSuperseded)
              const Positioned.fill(
                child: DeviceTransferredScreen(),
              )
            else if (_isMaintenanceMode)
              Positioned.fill(
                child: MaintenanceScreen(message: _maintenanceMessage),
              ),
          ],
        );
      },
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF0F4F8),
        primaryColor: const Color(0xFF00E676),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00E676), brightness: Brightness.light),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B1014), // Pure dark
        primaryColor: const Color(0xFF00E676),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00E676), brightness: Brightness.dark),
        appBarTheme: const AppBarTheme(
          elevation: 0, 
          backgroundColor: Color(0xFF0B1014),
          foregroundColor: Colors.white,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF161B22), // Dark card background
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00E676), // Neon green
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ),
      home: !_hasAcceptedTerms
          ? OnboardingScreen(
              settingsService: _settingsService,
              onCompleted: () async {
                setState(() => _isLoading = true);
                await _loadSettings();
                setState(() {
                  _hasAcceptedTerms = true;
                });
              },
            )
          : !_isClockTrustworthy
          ? TimeDiscrepancyScreen(
              isRtcReset: _clockGuardService.isRtcResetDetected,
              isForwardJump: _clockGuardService.isForwardJumpDetected,
              isRollback: _clockGuardService.isRollbackDetected || _trialService.isClockDiscrepancy,
              onRetry: () async {
                setState(() { _isLoading = true; });
                await _loadSettings();
              },
            )
          : _isOfflineLocked
              ? OfflineLockedScreen(
                  isRetrying: _isLoading,
                  onRetry: () async {
                    setState(() { _isLoading = true; });
                    await _licenseService.pollOnlineSubscriptionStatus(force: true);
                    setState(() { _isLoading = false; });
                  },
                )
          : (!_isLicensed && !_isTrialActive)
              ? ActivationScreen(
                  licenseService: _licenseService,
                  onActivated: () {
                    setState(() {
                      _isLicensed = true;
                      _isExpired = _licenseService.isLicenseExpired();
                      _isTrialActive = false;
                    });
                  },
                )
              : (_isLicensed && _isExpired)
                      ? _buildLicenseExpiredScreen()
                  : _isLocked
                      ? PinLockScreen(
                          securityService: _securityService,
                          isSetup: !_hasPinSet,
                          onSuccess: _onPinSuccess,
                        )
                      : MainLayout(
                          settingsService: _settingsService,
                          excelService: _excelService,
                          onThemeChanged: _onThemeChanged,
                          isTrialActive: !_isLicensed && _isTrialActive,
                          trialDaysRemaining: _trialService.daysRemaining,
                          onActivateRequested: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ActivationScreen(
                                  licenseService: _licenseService,
                                  onActivated: () {
                                    Navigator.pop(context);
                                    setState(() {
                                      _isLicensed = true;
                                      _isExpired = _licenseService.isLicenseExpired();
                                      _isTrialActive = false;
                                    });
                                  },
                                ),
                              ),
                            );
                          },
                        ),
    );
  }
}