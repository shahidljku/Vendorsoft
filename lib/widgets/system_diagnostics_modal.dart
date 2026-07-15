import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/settings_service.dart';
import '../services/license_service.dart';
import '../services/trial_service.dart';
import '../services/clock_guard_service.dart';
import '../services/accessibility_service.dart';

class SystemDiagnosticsModal extends StatefulWidget {
  final SettingsService settingsService;

  const SystemDiagnosticsModal({super.key, required this.settingsService});

  static Future<void> show(BuildContext context, SettingsService settingsService) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => SystemDiagnosticsModal(settingsService: settingsService),
      ),
    );
  }

  @override
  State<SystemDiagnosticsModal> createState() => _SystemDiagnosticsModalState();
}

class _SystemDiagnosticsModalState extends State<SystemDiagnosticsModal> {
  bool _isLoading = true;

  // Live queried parameters
  String _appName = '';
  String _packageName = '';
  String _version = '';
  String _buildNumber = '';
  String _androidVersion = '';
  int _sdkLevel = 0;
  String _deviceId = '';
  bool _isLicensed = false;
  bool _isTrialActive = false;
  int _trialRemainingDays = 0;
  bool _clockIntegrityOk = true;
  bool _accessibilityEnabled = false;
  bool _whatsAppInstalled = false;
  bool _whatsAppBusinessInstalled = false;
  String? _printerName;
  bool _storageAccessible = false;
  final String _backupFolderPath = '/storage/emulated/0/VendSoft/backups';
  bool _batteryOptimizationIgnored = false;

  @override
  void initState() {
    super.initState();
    _queryLiveDiagnostics();
  }

  Future<void> _queryLiveDiagnostics() async {
    // 1. Package info
    final packageInfo = await PackageInfo.fromPlatform();
    _appName = packageInfo.appName;
    _packageName = packageInfo.packageName;
    _version = packageInfo.version;
    _buildNumber = packageInfo.buildNumber;

    // 2. Device info
    try {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      _androidVersion = androidInfo.version.release;
      _sdkLevel = androidInfo.version.sdkInt;
    } catch (_) {
      _androidVersion = Platform.operatingSystemVersion;
    }

    // 3. Security / Device ID
    final licenseService = LicenseService();
    _deviceId = await licenseService.getDeviceId();

    // 4. License & Trial status
    _isLicensed = await licenseService.isLicensed();
    if (!_isLicensed) {
      final trialService = TrialService();
      await trialService.checkTrialState();
      _isTrialActive = trialService.isTrialActive;
      _trialRemainingDays = trialService.daysRemaining;
    }

    // 5. Clock integrity
    final clockGuard = ClockGuardService();
    _clockIntegrityOk = await clockGuard.checkClockIntegrity();

    // 6. Accessibility service
    _accessibilityEnabled = await AccessibilityService.isEnabled();

    // 7. WhatsApp availability via MethodChannel
    try {
      final res = await const MethodChannel('com.example.image_sender/whatsapp').invokeMethod('isInstalled');
      if (res is Map) {
        _whatsAppInstalled = res['whatsapp'] == true;
        _whatsAppBusinessInstalled = res['whatsappBusiness'] == true;
      }
    } catch (_) {}

    // 8. Printer status
    _printerName = await widget.settingsService.getSelectedPrinterName();

    // 9. Storage status
    final dir = Directory('/storage/emulated/0/VendSoft');
    _storageAccessible = dir.existsSync() || await Permission.storage.isGranted || await Permission.manageExternalStorage.isGranted;

    // 10. Battery optimization
    _batteryOptimizationIgnored = await Permission.ignoreBatteryOptimizations.isGranted;

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  String _formatPlaintextReport() {
    final buffer = StringBuffer();
    buffer.writeln('=== VENDORSOFT SYSTEM DIAGNOSTICS (LIVE) ===');
    buffer.writeln('App Name: $_appName');
    buffer.writeln('Package Name: $_packageName');
    buffer.writeln('Version: $_version (Build $_buildNumber)');
    buffer.writeln('Android Version: $_androidVersion (SDK $_sdkLevel)');
    buffer.writeln('Device ID: $_deviceId');
    buffer.writeln('License Status: ${_isLicensed ? "Commercial Paid License" : (_isTrialActive ? "First-Install Trial ($_trialRemainingDays days remaining)" : "Expired / Inactive")}');
    buffer.writeln('Clock Integrity: ${_clockIntegrityOk ? "Verified / Trustworthy" : "Suspicious Tampering Detected"}');
    buffer.writeln('Accessibility Service: ${_accessibilityEnabled ? "Enabled" : "Disabled"}');
    buffer.writeln('WhatsApp Regular Installed: $_whatsAppInstalled');
    buffer.writeln('WhatsApp Business Installed: $_whatsAppBusinessInstalled');
    buffer.writeln('Printer Status: ${_printerName != null ? "Connected ($_printerName)" : "Disconnected"}');
    buffer.writeln('Storage Status: ${_storageAccessible ? "Accessible (/storage/emulated/0/VendSoft)" : "Permission Needed"}');
    buffer.writeln('Backup Folder: $_backupFolderPath');
    buffer.writeln('Battery Optimization: ${_batteryOptimizationIgnored ? "Ignored (Unrestricted)" : "Optimized (Restricted)"}');
    buffer.writeln('============================================');
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF00E676)));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header & Copy Action
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.health_and_safety, color: Color(0xFF00E676), size: 24),
                  SizedBox(width: 10),
                  Text('System Diagnostics', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E676),
                  foregroundColor: const Color(0xFF0B1014),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Diagnostics', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                onPressed: () {
                  final text = _formatPlaintextReport();
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Live Diagnostics copied to clipboard!')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('All parameters queried live from your running Android system.', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 16),
          const Divider(color: Colors.white12),

          // Scrollable Content
          Expanded(
            child: ListView(
              children: [
                const Text('Quick Summary', style: TextStyle(color: Color(0xFF00E676), fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                _buildSummaryRow('App Version', 'v$_version'),
                _buildSummaryRow('License Status', _isLicensed ? 'Commercial Paid License' : (_isTrialActive ? 'First-Install Trial' : 'Expired / Activation Required'), isOk: _isLicensed || _isTrialActive),
                if (!_isLicensed && _isTrialActive)
                  _buildSummaryRow('Trial Remaining', '$_trialRemainingDays Days remaining', isOk: _trialRemainingDays > 5),
                _buildSummaryRow('Accessibility Service', _accessibilityEnabled ? 'Enabled (Ready for Auto-Send)' : 'Disabled (Tap Switch in Settings)', isOk: _accessibilityEnabled),
                _buildSummaryRow('WhatsApp Regular', _whatsAppInstalled ? 'Installed' : 'Not Installed', isOk: _whatsAppInstalled),
                _buildSummaryRow('WhatsApp Business', _whatsAppBusinessInstalled ? 'Installed' : 'Not Installed', isOk: _whatsAppBusinessInstalled),
                _buildSummaryRow('Thermal Printer', _printerName != null ? 'Connected ($_printerName)' : 'Not Connected', isOk: _printerName != null),
                _buildSummaryRow('Storage Status', _storageAccessible ? 'Accessible & Ready' : 'Permission Required', isOk: _storageAccessible),
                _buildSummaryRow('Backup Folder Location', _backupFolderPath, isOk: true),
                _buildSummaryRow('Battery Optimization', _batteryOptimizationIgnored ? 'Unrestricted (Ideal)' : 'Optimized (May stop long sending batches)', isOk: _batteryOptimizationIgnored),

                const SizedBox(height: 16),
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    collapsedIconColor: Colors.grey,
                    iconColor: const Color(0xFF00E676),
                    title: const Text('Advanced Technical Details', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Column(
                          children: [
                            _buildTechnicalRow('App Name', _appName),
                            _buildTechnicalRow('Package Name', _packageName),
                            _buildTechnicalRow('Build Number', _buildNumber),
                            _buildTechnicalRow('Android Version', 'Android $_androidVersion (SDK $_sdkLevel)'),
                            _buildTechnicalRow('Device ID', _deviceId),
                            _buildTechnicalRow('Clock Integrity', _clockIntegrityOk ? 'Monotonic Anchor Verified' : 'Clock Rollback / Tampering Detected'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value, {bool? isOk}) {
    Color valColor = Colors.white;
    IconData icon = Icons.check_circle_outline;
    Color iconColor = const Color(0xFF00E676);

    if (isOk == false) {
      valColor = Colors.orangeAccent;
      icon = Icons.info_outline;
      iconColor = Colors.orangeAccent;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13))),
          Flexible(child: Text(value, style: TextStyle(color: valColor, fontSize: 13, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildTechnicalRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Flexible(child: Text(value, style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'), textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}
