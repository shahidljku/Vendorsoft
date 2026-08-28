import 'dart:async';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/security_service.dart';
import '../services/license_service.dart';
import '../services/accessibility_service.dart';
import '../services/excel_service.dart';
import '../services/backup_service.dart';
import '../services/print_service.dart';
import 'package:flutter/services.dart';
import 'pin_lock_screen.dart';
import '../widgets/subscription_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../widgets/system_diagnostics_modal.dart';
import '../widgets/settings_auxiliary_modals.dart';
import 'help_and_faq_screen.dart';
import '../services/trial_service.dart';

class SettingsTab extends StatefulWidget {
  final SettingsService settingsService;
  final VoidCallback onThemeChanged;
  final ExcelService? excelService;

  const SettingsTab({
    super.key,
    required this.settingsService,
    required this.onThemeChanged,
    this.excelService,
  });

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> with WidgetsBindingObserver {
  late SecurityService _securityService;
  bool _pinEnabled = false;
  bool _hasPinSet = false;
  bool _autoSendEnabled = false;
  bool _useWhatsAppBusiness = false;
  int _sendLimit = 50;
  int _delayBetween = 10000;
  int _delayNext = 10000;
  String _printerWidth = '58mm';
  String? _selectedPrinterName;
  bool _directPrintEnabled = false;
  
  bool _isLoading = true;
  bool _waitingForAccessibility = false;
  String _dynamicVersion = '';
  String _dynamicAppName = '';
  String _currentPlanName = 'Free Trial';
  int _daysLeft = 0;
  StreamSubscription? _licenseSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _securityService = SecurityService(widget.settingsService);
    _licenseSubscription = LicenseService().onLicenseRevoked.listen((event) {
      if (mounted && (event == 'RESTORED' || event == 'REVOKED' || event == 'UPDATED')) {
        _loadSettings();
      }
    });
    _loadSettings();
  }

  @override
  void dispose() {
    _licenseSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForAccessibility) {
      _checkAccessibilityAfterReturn();
    }
  }

  Future<void> _checkAccessibilityAfterReturn() async {
    _waitingForAccessibility = false;
    final enabled = await AccessibilityService.isEnabled();
    if (enabled) {
      await widget.settingsService.setAutoSendEnabled(true);
      setState(() => _autoSendEnabled = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Accessibility enabled! Auto Send is ON.'),
            backgroundColor: Color(0xFF00E676),
          ),
        );
      }
    }
  }

  Future<void> _loadSettings() async {
    _pinEnabled = await _securityService.isPinEnabled();
    _hasPinSet = await _securityService.hasPinSet();
    _autoSendEnabled = await widget.settingsService.getAutoSendEnabled();
    _useWhatsAppBusiness = await widget.settingsService.getUseWhatsAppBusiness();
    
    _sendLimit = await widget.settingsService.getDefaultSendLimit();
    _delayBetween = await widget.settingsService.getDelayBetweenCustomers();
    _delayNext = await widget.settingsService.getDelayBeforeNext();
    _printerWidth = await widget.settingsService.getDefaultPrinterWidth();
    _selectedPrinterName = await widget.settingsService.getSelectedPrinterName();
    _directPrintEnabled = await widget.settingsService.getDirectPrintEnabled();

    final packageInfo = await PackageInfo.fromPlatform();
    _dynamicVersion = '${packageInfo.version} (Build ${packageInfo.buildNumber})';
    _dynamicAppName = packageInfo.appName;

    bool isLicensed = await LicenseService().isLicensed();
    if (isLicensed) {
      final info = LicenseService().getLicenseInfo();
      _daysLeft = LicenseService().getDaysRemaining();
      final pId = info?['planId'];
      if (pId == 'PRO_YEARLY' || pId == 'PRO_YEARLY_SOFT') {
        _currentPlanName = 'Pro Annual';
      } else if (pId == 'PRO_MONTHLY' || pId == 'PRO_MONTHLY_SOFT') {
        _currentPlanName = 'Pro Monthly';
      } else if (info?['customerType'] == 'Lifetime') {
        _currentPlanName = 'Lifetime Pro';
      } else {
        _currentPlanName = pId ?? 'Active Subscription';
      }
    } else {
      _currentPlanName = 'Free Trial';
      _daysLeft = TrialService().daysRemaining;
    }

    setState(() {
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _buildSettingsGroup(
            title: 'Current Subscription',
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E676).withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.workspace_premium, color: Color(0xFF00E676), size: 32),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_currentPlanName, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            _daysLeft > 9000 ? 'Lifetime Access' : '$_daysLeft Days Remaining', 
                            style: const TextStyle(color: Color(0xFF00E676), fontSize: 14, fontWeight: FontWeight.w500)
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E676).withValues(alpha: 0.1),
                        foregroundColor: const Color(0xFF00E676),
                        elevation: 0,
                      ),
                      onPressed: () async {
                        await SubscriptionDialog.showPlans(context);
                        if (mounted) {
                          _loadSettings();
                        }
                      },
                      child: const Text('Upgrade'),
                    )
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSettingsGroup(
            title: 'Profile & Business Details',
            children: [
              _buildSettingItem(
                icon: Icons.storefront,
                title: 'Edit Business Name',
                subtitle: LicenseService().getBusinessName(),
                onTap: () => _editBusinessName(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSettingsGroup(
            title: 'Sending Options',
            children: [
              _buildSwitchItem(
                icon: Icons.send_time_extension,
                title: 'Auto Send',
                subtitle: 'Automatically send messages',
                value: _autoSendEnabled,
                onChanged: (val) async {
                  if (val) {
                    bool isAccessible = await AccessibilityService.isEnabled();
                    if (!isAccessible) {
                      if (!context.mounted) return;
                      _waitingForAccessibility = true;
                      await AccessibilityService.showGuidanceDialog(context);
                      return;
                    }
                  }
                  setState(() => _autoSendEnabled = val);
                  await widget.settingsService.setAutoSendEnabled(val);
                },
              ),
              _buildSwitchItem(
                icon: Icons.business,
                title: 'WhatsApp Business',
                subtitle: 'Use Business app instead of personal',
                value: _useWhatsAppBusiness,
                onChanged: (val) async {
                  setState(() => _useWhatsAppBusiness = val);
                  await widget.settingsService.setUseWhatsAppBusiness(val);
                },
              ),
              _buildNumberItem(
                icon: Icons.speed,
                title: 'Send Limit',
                subtitle: 'Batch size limit',
                value: _sendLimit,
                onTap: () => _editNumber('Send Limit', _sendLimit, (val) async {
                  setState(() => _sendLimit = val);
                  await widget.settingsService.setDefaultSendLimit(val);
                }),
              ),
              _buildNumberItem(
                icon: Icons.hourglass_bottom,
                title: 'Delay Between (ms)',
                subtitle: 'Delay during sending',
                value: _delayBetween,
                onTap: () => _editNumber('Delay Between (ms)', _delayBetween, (val) async {
                  setState(() => _delayBetween = val);
                  await widget.settingsService.setDelayBetweenCustomers(val);
                }),
              ),
              _buildNumberItem(
                icon: Icons.timer,
                title: 'Delay Next (ms)',
                subtitle: 'Delay before next batch',
                value: _delayNext,
                onTap: () => _editNumber('Delay Next (ms)', _delayNext, (val) async {
                  setState(() => _delayNext = val);
                  await widget.settingsService.setDelayBeforeNext(val);
                }),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSettingsGroup(
            title: 'Printer & Receipts',
            children: [
              _buildSettingItem(
                icon: _selectedPrinterName != null ? Icons.print : Icons.print_disabled,
                title: _selectedPrinterName != null ? 'Connected Printer' : 'Connect Thermal Printer',
                subtitle: _selectedPrinterName ?? 'Tap to select system/Bluetooth printer',
                onTap: () => _showConnectOrManagePrinterDialog(),
              ),
              if (_selectedPrinterName != null) ...[
                _buildSwitchItem(
                  icon: Icons.flash_on,
                  title: 'Direct Thermal Print',
                  subtitle: 'Print instantly without showing OS print dialog',
                  value: _directPrintEnabled,
                  onChanged: (val) async {
                    setState(() => _directPrintEnabled = val);
                    await widget.settingsService.setDirectPrintEnabled(val);
                  },
                ),
                _buildSettingItem(
                  icon: Icons.play_circle_fill,
                  title: 'Run Test Print',
                  subtitle: 'Verify thermal printer layout & connection',
                  onTap: () async {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sending test print...')));
                    await PrintService().testPrint(settingsService: widget.settingsService);
                  },
                ),
              ],
              _buildDropdownItem(
                icon: Icons.receipt_long,
                title: 'Printer Roll Width',
                subtitle: 'Continuous auto-height paper size',
                value: _printerWidth,
                options: const ['58mm', '80mm', 'a4'],
                optionLabels: const {
                  '58mm': '58 mm (Roll)',
                  '80mm': '80 mm (Roll)',
                  'a4': 'A4 Page',
                },
                onChanged: (val) async {
                  if (val != null) {
                    setState(() => _printerWidth = val);
                    await widget.settingsService.setDefaultPrinterWidth(val);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSettingsGroup(
            title: 'Security',
            children: [
              _buildSwitchItem(
                icon: Icons.lock_outline,
                title: 'App Lock',
                subtitle: _pinEnabled ? 'PIN is enabled' : 'Require PIN to open app',
                value: _pinEnabled,
                onChanged: (val) async {
                  if (val) {
                    if (!_hasPinSet) {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PinLockScreen(
                            securityService: _securityService,
                            isSetup: true,
                            onSuccess: () => Navigator.pop(context),
                          ),
                        ),
                      );
                    } else {
                      await widget.settingsService.setPinEnabled(true);
                    }
                  } else {
                    if (_hasPinSet) {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => PinLockScreen(
                            securityService: _securityService,
                            isSetup: false,
                            onSuccess: () async {
                              final nav = Navigator.of(context);
                              await _securityService.removePin();
                              nav.pop();
                            },
                          ),
                        ),
                      );
                    }
                  }
                  _loadSettings();
                },
              ),
            ],
          ),

          _buildSettingsGroup(
            title: 'Database & Backup (Excel)',
            children: [
              _buildSettingItem(
                icon: Icons.backup_table,
                title: 'Export Customers Excel Backup',
                subtitle: 'Auto-generates clean .xlsx backup file in Internal Storage > VendSoft > backups',
                onTap: () async {
                  if (widget.excelService == null || widget.excelService!.allCustomers.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No customers loaded to back up.')),
                    );
                    return;
                  }
                  final file = await BackupService().createExcelBackup(widget.excelService!);
                  if (!context.mounted) return;
                  if (file != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Excel Backup created:\n${file.path}')),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Failed to create Excel backup.')),
                    );
                  }
                },
              ),
              _buildSettingItem(
                icon: Icons.restore_page,
                title: 'Restore Database from Excel (.xlsx)',
                subtitle: 'Pick any Excel sheet or backup to instantly load and update your customers',
                onTap: () async {
                  if (widget.excelService == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Excel service not available.')),
                    );
                    return;
                  }
                  bool success = await BackupService().restoreFromExcel(excelService: widget.excelService!);
                  if (!context.mounted) return;
                  if (success) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Restored ${widget.excelService!.allCustomers.length} customers successfully!')),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Restore cancelled or failed.')),
                    );
                  }
                },
              ),
            ],
          ),

          _buildSettingsGroup(
            title: 'About & License',
            children: [
              _buildSettingItem(
                icon: Icons.info_outline,
                title: 'App Version',
                subtitle: _dynamicVersion.isNotEmpty ? _dynamicVersion : 'Loading...',
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Current Version: $_dynamicVersion')),
                  );
                },
              ),
              _buildSettingItem(
                icon: Icons.health_and_safety_outlined,
                title: 'System Diagnostics',
                subtitle: 'Live runtime check (Device, Storage, License, Printer)',
                onTap: () => SystemDiagnosticsModal.show(context, widget.settingsService),
              ),

              _buildSettingItem(
                icon: Icons.key_off_outlined,
                title: 'Deactivate License',
                subtitle: 'Remove license from this device',
                onTap: () async {
                  bool confirm = await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: Theme.of(context).cardColor,
                      title: const Text('Deactivate License?', style: TextStyle(color: Colors.white)),
                      content: const Text('This will remove your license from this device. You will need to enter a valid license key to use the app again. The app will close.', style: TextStyle(color: Colors.white70)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                          onPressed: () => Navigator.pop(context, true), 
                          child: const Text('Deactivate', style: TextStyle(color: Colors.white))
                        ),
                      ],
                    ),
                  ) ?? false;
                  if (confirm) {
                    await LicenseService().removeLicense();
                    SystemNavigator.pop();
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSettingsGroup(
            title: 'Support & Legal Compliance',
            children: [
              _buildSettingItem(
                icon: Icons.menu_book,
                title: 'User Guide & FAQs',
                subtitle: 'Complete offline guide for newspaper vendors',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpAndFaqScreen())),
              ),
              _buildSettingItem(
                icon: Icons.support_agent,
                title: 'Contact Support',
                subtitle: 'WhatsApp, Phone Helpline, & Device ID copying',
                onTap: () => SettingsAuxiliaryModals.showContactSupport(context, widget.settingsService),
              ),
              _buildSettingItem(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacy & Data Policy',
                subtitle: 'Offline-first & local storage guarantee',
                onTap: () => SettingsAuxiliaryModals.showPrivacyDialog(context),
              ),
              _buildSettingItem(
                icon: Icons.gavel_outlined,
                title: 'Terms & Conditions',
                subtitle: 'Newspaper vendor operational terms',
                onTap: () => SettingsAuxiliaryModals.showTermsDialog(context),
              ),
              _buildSettingItem(
                icon: Icons.security_outlined,
                title: 'Permissions Used',
                subtitle: 'Storage, Accessibility, Alarms & Battery rationale',
                onTap: () => SettingsAuxiliaryModals.showPermissionsDialog(context),
              ),
              _buildSettingItem(
                icon: Icons.timer_outlined,
                title: 'Why Sending Pauses',
                subtitle: '30-message batch cooldown safety explanation',
                onTap: () => SettingsAuxiliaryModals.showWhySendingPausesDialog(context),
              ),
              _buildSettingItem(
                icon: Icons.code_outlined,
                title: 'Open Source Licenses',
                subtitle: 'View third-party software licenses',
                onTap: () => SettingsAuxiliaryModals.showOpenSourceLicensesExplanation(context, _dynamicAppName, _dynamicVersion),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }


  Future<void> _showConnectOrManagePrinterDialog() async {
    if (_selectedPrinterName != null) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: Row(
            children: [
              const Icon(Icons.print, color: Color(0xFF00E676)),
              const SizedBox(width: 10),
              Expanded(child: Text(_selectedPrinterName!, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.play_circle_fill, color: Color(0xFF00E676)),
                title: const Text('Test Print', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sending test print...')));
                  await PrintService().testPrint(settingsService: widget.settingsService);
                },
              ),
              ListTile(
                leading: const Icon(Icons.print_disabled, color: Colors.redAccent),
                title: const Text('Disconnect Printer', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  await PrintService().disconnectPrinter(widget.settingsService);
                  await _loadSettings();
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Printer disconnected')));
                },
              ),
            ],
          ),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator(color: Color(0xFF00E676))),
    );
    final btPrinters = await PrintService().getAvailableBluetoothPrinters();
    final sysPrinters = await PrintService().getAvailablePrinters();
    if (!mounted) return;
    Navigator.pop(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Connect Thermal Printer', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.bluetooth, color: Colors.blueAccent, size: 18),
                      SizedBox(width: 6),
                      Text('Bluetooth ESC/POS Printers', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  ),
                ),
                if (btPrinters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(left: 24, top: 4, bottom: 12),
                    child: Text('No paired Bluetooth printers.\nPair your thermal printer in Android Settings first.', style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.3)),
                  )
                else
                  ...btPrinters.map((p) => Card(
                        color: const Color(0xFF0B1014),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: const Icon(Icons.bluetooth_connected, color: Colors.blueAccent),
                          title: Text(p.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Text('MAC: ${p.macAdress}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          onTap: () async {
                            Navigator.pop(context);
                            showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.blueAccent)));
                            final success = await PrintService().connectBluetoothPrinter(p, widget.settingsService);
                            if (mounted) Navigator.pop(context);
                            await _loadSettings();
                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success ? 'Connected: ${p.name}' : 'Failed to connect via Bluetooth'), backgroundColor: success ? const Color(0xFF00E676) : Colors.redAccent));
                          },
                        ),
                      )),
                const SizedBox(height: 12),
                const Divider(color: Colors.white24),
                const SizedBox(height: 6),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.print, color: Color(0xFF00E676), size: 18),
                      SizedBox(width: 6),
                      Text('System / Network Printers', style: TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  ),
                ),
                if (sysPrinters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(left: 24, top: 4, bottom: 8),
                    child: Text('No system print services found.', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  )
                else
                  ...sysPrinters.map((p) => Card(
                        color: const Color(0xFF0B1014),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: const Icon(Icons.print, color: Color(0xFF00E676)),
                          title: Text(p.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Text(p.location ?? p.model ?? '', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          onTap: () async {
                            Navigator.pop(context);
                            await PrintService().connectPrinter(p, widget.settingsService);
                            await _loadSettings();
                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Connected to: ${p.name}'), backgroundColor: const Color(0xFF00E676)));
                          },
                        ),
                      )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _editNumber(String title, int currentValue, Function(int) onSave) {
    TextEditingController ctrl = TextEditingController(text: currentValue.toString());
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: Text('Edit $title', style: const TextStyle(color: Colors.white)),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: title,
              labelStyle: const TextStyle(color: Colors.grey),
              enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00E676))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                int? val = int.tryParse(ctrl.text);
                if (val != null) {
                  if (title == 'Send Limit' && val > 30) {
                    val = 30;
                  }
                  onSave(val);
                }
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
              child: const Text('Save', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSettingsGroup({required String title, required List<Widget> children}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.orange,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Card(
          color: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Column(
            children: [
              for (int i = 0; i < children.length; i++) ...[
                children[i],
                if (i < children.length - 1)
                  const Divider(height: 1, color: Colors.white12, indent: 56),
              ]
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSwitchItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeTrackColor: const Color(0xFF00E676).withValues(alpha: 0.5),
      activeThumbColor: const Color(0xFF00E676),
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.grey.withValues(alpha: 0.8), fontSize: 13)),
      secondary: Icon(icon, color: Colors.grey, size: 24),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }

  Widget _buildNumberItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required int value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: Colors.grey, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: Colors.grey.withValues(alpha: 0.8), fontSize: 13)),
                ],
              ),
            ),
            Text(value.toString(), style: const TextStyle(color: Color(0xFF00E676), fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            const Icon(Icons.edit, color: Colors.grey, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: Colors.grey, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: Colors.grey.withValues(alpha: 0.8), fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required String value,
    required List<String> options,
    required Map<String, String> optionLabels,
    required ValueChanged<String?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.grey, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: Colors.grey.withValues(alpha: 0.8), fontSize: 13)),
              ],
            ),
          ),
          DropdownButton<String>(
            value: options.contains(value) ? value : options.first,
            dropdownColor: const Color(0xFF161B22),
            underline: const SizedBox(),
            items: options.map((opt) {
              return DropdownMenuItem<String>(
                value: opt,
                child: Text(
                  optionLabels[opt] ?? opt,
                  style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 14),
                ),
              );
            }).toList(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  void _editBusinessName() {
    final TextEditingController ctrl = TextEditingController(text: LicenseService().getBusinessName());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Edit Business Name', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Business Name',
            labelStyle: TextStyle(color: Colors.white54),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.orange)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              if (ctrl.text.trim().isNotEmpty) {
                await LicenseService().setCustomBusinessName(ctrl.text.trim());
                if (mounted) {
                  setState(() {});
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Business Name Updated')),
                  );
                }
              }
            },
            child: const Text('Save', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );
  }
}
