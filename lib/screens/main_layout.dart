import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/settings_service.dart';
import '../services/excel_service.dart';
import '../services/print_service.dart';
import 'package:excel/excel.dart' hide Border;
import 'dashboard_tab.dart';
import 'logs_tab.dart';
import 'customers_tab.dart';
import 'bills_tab.dart';
import 'settings_tab.dart';
import 'receipts_tab.dart';
import 'reports_tab.dart';
import 'reminders_modal.dart';
import '../services/transfer_service.dart';
import '../services/license_service.dart';
import '../services/push_notification_service.dart';

class MainLayout extends StatefulWidget {
  final SettingsService settingsService;
  final ExcelService excelService;
  final VoidCallback onThemeChanged;
  final bool isTrialActive;
  final int trialDaysRemaining;
  final VoidCallback? onActivateRequested;

  const MainLayout({
    super.key,
    required this.settingsService,
    required this.excelService,
    required this.onThemeChanged,
    this.isTrialActive = false,
    this.trialDaysRemaining = 0,
    this.onActivateRequested,
  });

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> with WidgetsBindingObserver {
  int _currentIndex = 0;
  late final ExcelService _excelService = widget.excelService;
  String _queueInitialFilter = 'All';
  int _navKey = 0;
  String? _excelFileName;
  String? _connectedPrinterName;
  bool _directPrintEnabled = false;

  bool _isPollingTransfers = false;
  late final StreamSubscription _fcmSubscription;
  
  String _currentPlanName = '';
  int _daysLeft = 0;
  bool _isLifetime = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fcmSubscription = PushNotificationService().onMessageStream.listen((_) {
      if (mounted) _pollTransfers();
    });
    _checkPermissions(isStartup: true);
    _loadFileName();
    _loadPrinterStatus();
    _pollTransfers();
    _loadPlanInfo();
  }
  
  Future<void> _loadPlanInfo() async {
    if (widget.isTrialActive) {
      _currentPlanName = 'Free Trial';
      _daysLeft = widget.trialDaysRemaining;
    } else {
      bool isLicensed = await LicenseService().isLicensed();
      if (isLicensed) {
        final info = LicenseService().getLicenseInfo();
        _daysLeft = LicenseService().getDaysRemaining();
        final pId = info?['planId'];
        if (pId == 'PRO_YEARLY') {
          _currentPlanName = 'Pro Annual';
        } else if (pId == 'PRO_MONTHLY') {
          _currentPlanName = 'Pro Monthly';
        } else if (info?['customerType'] == 'Lifetime') {
          _currentPlanName = 'Lifetime Access';
          _isLifetime = true;
        } else {
          _currentPlanName = pId ?? 'Active Plan';
        }
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _fcmSubscription.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pollTransfers();
      LicenseService().pollOnlineSubscriptionStatus();
    }
  }

  Future<void> _pollTransfers() async {
    if (_isPollingTransfers) return;
    _isPollingTransfers = true;
    try {
      final transfers = await TransferService().pollPendingTransfers();
      if (transfers.isNotEmpty && mounted) {
        _showTransferApprovalModal(transfers.first);
      }
    } catch (e) {
      debugPrint('Poll transfers error: $e');
    }
    _isPollingTransfers = false;
  }

  void _showTransferApprovalModal(Map<String, dynamic> transfer) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Device Transfer Request', style: TextStyle(color: Colors.orange)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Another device is trying to claim your active VendSoft license.',
              style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            Text('New Device: ${transfer['deviceModel']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            const Text(
              'If you approve this, your current device will be instantly deactivated. Do not approve unless you initiated this transfer on your new phone.',
              style: TextStyle(color: Colors.redAccent, fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await TransferService().rejectTransfer(transfer['transferId']);
            },
            child: const Text('Reject (Keep License Here)', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.black),
            onPressed: () async {
              Navigator.pop(ctx);
              showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.orange)));
              try {
                await TransferService().approveTransfer(transfer['transferId']);
                if (mounted) {
                  Navigator.pop(context); // close loading
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transfer approved. Your license was moved. Closing app...')));
                  await Future.delayed(const Duration(seconds: 2));
                  SystemNavigator.pop();
                }
              } catch (e) {
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red));
                }
              }
            },
            child: const Text('APPROVE TRANSFER', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _loadFileName() async {
    String? name = await widget.settingsService.getLastExcelFileName();
    if (mounted) {
      setState(() {
        _excelFileName = name;
      });
    }
  }

  Future<void> _loadPrinterStatus() async {
    final name = await widget.settingsService.getSelectedPrinterName();
    final direct = await widget.settingsService.getDirectPrintEnabled();
    if (mounted) {
      setState(() {
        _connectedPrinterName = name;
        _directPrintEnabled = direct;
      });
    }
  }

  Future<void> _showConnectPrinterDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator(color: Color(0xFF00E676))),
    );
    final btPrinters = await PrintService().getAvailableBluetoothPrinters();
    final sysPrinters = await PrintService().getAvailablePrinters();
    if (!mounted) return;
    Navigator.pop(context); // close loader

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Row(
          children: [
            Icon(Icons.print, color: Color(0xFF00E676)),
            SizedBox(width: 10),
            Text('Connect Thermal Printer', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
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
                    child: Text('No paired Bluetooth printers.\nGo to Android Bluetooth settings and pair your printer first.', style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.3)),
                  )
                else
                  ...btPrinters.map((p) => Card(
                        color: const Color(0xFF0B1014),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: const Icon(Icons.bluetooth_connected, color: Colors.blueAccent),
                          title: Text(p.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Text('MAC: ${p.macAdress} • Direct ESC/POS', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          onTap: () async {
                            Navigator.pop(context);
                            showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.blueAccent)));
                            final success = await PrintService().connectBluetoothPrinter(p, widget.settingsService);
                            if (mounted) Navigator.pop(context); // close loader
                            await _loadPrinterStatus();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(success ? 'Connected via Bluetooth: ${p.name}' : 'Failed to connect to ${p.name} via Bluetooth'),
                                  backgroundColor: success ? const Color(0xFF00E676) : Colors.redAccent,
                                ),
                              );
                            }
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
                      Text('System / USB / Network Printers', style: TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 14)),
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
                          subtitle: Text(p.location ?? p.model ?? 'System Print Spooler', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          onTap: () async {
                            Navigator.pop(context);
                            await PrintService().connectPrinter(p, widget.settingsService);
                            await _loadPrinterStatus();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Connected to system printer: ${p.name}'),
                                  backgroundColor: const Color(0xFF00E676),
                                ),
                              );
                            }
                          },
                        ),
                      )),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  void _showPrinterManageDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: Row(
          children: [
            const Icon(Icons.print, color: Color(0xFF00E676)),
            const SizedBox(width: 10),
            Expanded(child: Text(_connectedPrinterName ?? 'Thermal Printer', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status: ${_directPrintEnabled ? "Connected & Direct Print Enabled" : "Connected (Dialog Mode)"}', style: const TextStyle(color: Color(0xFF00E676), fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.play_circle_fill, color: Color(0xFF00E676)),
              title: const Text('Test Print', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: const Text('Send a test receipt to verify connection', style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () async {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sending test print...')));
                await PrintService().testPrint(settingsService: widget.settingsService);
              },
            ),
            const Divider(color: Colors.white24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.swap_horiz, color: Colors.blueAccent),
              title: const Text('Change Printer', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: const Text('Select a different thermal printer', style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                _showConnectPrinterDialog();
              },
            ),
            const Divider(color: Colors.white24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.print_disabled, color: Colors.redAccent),
              title: const Text('Disconnect Printer', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: const Text('Clear connected printer setting', style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () async {
                Navigator.pop(context);
                await PrintService().disconnectPrinter(widget.settingsService);
                await _loadPrinterStatus();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Thermal printer disconnected.'), backgroundColor: Colors.orangeAccent),
                  );
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Future<void> _importExcel() async {
    String? name = await _excelService.pickExcel();
    if (name != null) {
      if (_excelService.documentUri != null) {
        await widget.settingsService.setLastExcelUri(_excelService.documentUri!);
        await widget.settingsService.setLastExcelFileName(name);
      }
      if (mounted) {
        setState(() {
          _excelFileName = name;
        });
      }
    }
  }

  Future<void> _checkPermissions({required bool isStartup}) async {
    bool isFirstLaunch = await widget.settingsService.getIsFirstLaunch();
    
    // Check if essential permissions are granted
    bool hasStorage = await Permission.storage.isGranted || await Permission.manageExternalStorage.isGranted || await Permission.photos.isGranted;
    bool hasNotification = await Permission.notification.isGranted;
    bool needsPermission = !hasStorage || !hasNotification;

    if (!isFirstLaunch && !needsPermission) {
      return; // All good
    }

    if (isFirstLaunch && mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.rocket_launch, color: Color(0xFF00E676)),
              SizedBox(width: 12),
              Text('Welcome to VendSoft!', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          content: const SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'To ensure all features work smoothly right out of the box without interruptions later, please allow the following essential permissions on the next prompts:',
                  style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                ),
                SizedBox(height: 16),
                _PermissionInfoRow(icon: Icons.folder_open, title: 'Storage & Files', desc: 'Required to create your "VendSoft" folder, read customer Excel sheets, and save PDF receipts.'),
                SizedBox(height: 12),
                _PermissionInfoRow(icon: Icons.notifications_active, title: 'Notifications', desc: 'Required to show real-time status alerts and background message progress.'),
                SizedBox(height: 12),
                _PermissionInfoRow(icon: Icons.bluetooth_connected, title: 'Bluetooth', desc: 'Required to scan and connect to your native ESC/POS thermal printers.'),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text('Allow & Get Started', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      );
    } else if (needsPermission && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Requesting missing essential permissions...')),
      );
    }

    if (!mounted) return;

    try {
      if (!kIsWeb && Platform.isAndroid) {
        // Grouped native Android permission requests
        await [
          Permission.notification,
          Permission.photos,
          Permission.storage,
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.location
        ].request();

        // Request manage external storage separately as it opens settings
        if (!await Permission.manageExternalStorage.isGranted) {
          await Permission.manageExternalStorage.request();
        }
      }
    } catch (e) {
      debugPrint('Permission request error: $e');
    }

    bool finalHasStorage = await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted ||
        await Permission.photos.isGranted;

    bool created = false;
    try {
      final dir = Directory('/storage/emulated/0/VendSoft/images');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      
      final receiptsDir = Directory('/storage/emulated/0/VendSoft/receipts');
      if (!await receiptsDir.exists()) {
        await receiptsDir.create(recursive: true);
      }
      
      final excelFile = File('/storage/emulated/0/VendSoft/customers.xlsx');
      if (!await excelFile.exists()) {
        var excel = Excel.createExcel();
        String defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
        if (defaultSheet != 'Sheet1') {
          excel.rename(defaultSheet, 'Sheet1');
        }
        Sheet sheet = excel['Sheet1'];
        sheet.appendRow([
          TextCellValue('mobile_no'), TextCellValue('custname'), TextCellValue('YesNo'),
          TextCellValue('Status'), TextCellValue('jpg_Path'), TextCellValue('message'),
          TextCellValue('vouch_date'), TextCellValue('cust_no'), TextCellValue('bill_no'),
          TextCellValue('bill_amount'), TextCellValue('cl_balance'), TextCellValue('cm_code'),
          TextCellValue('cm_name'), TextCellValue('Month_nm'), TextCellValue('SentTime'),
          TextCellValue('PaymentStatus'), TextCellValue('AmountPaid'), TextCellValue('TransactionId'),
          TextCellValue('PaymentMethod'), TextCellValue('ReceiptStatus'), TextCellValue('PaymentDate'), TextCellValue('ReceiptNo'),
        ]);
        
        // Remove other sheets
        for (String sheetName in excel.tables.keys.toList()) {
          if (sheetName != 'Sheet1') {
            excel.delete(sheetName);
          }
        }
        
        List<int>? bytes = excel.encode();
        if (bytes != null) {
          await excelFile.writeAsBytes(bytes);
        }
      }
      
      created = true;
    } catch (e) {
      debugPrint('Folder setup warning: $e');
      created = finalHasStorage;
    }

    if (isFirstLaunch) {
      await widget.settingsService.setIsFirstLaunch(false);

      if (mounted && created) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF161B22),
            title: const Text('Setup Complete!', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: const Text(
              'A folder named "VendSoft" has been created in your Internal Storage.\n\nInside it, an empty "customers.xlsx" file has been generated for you. You can now add your customers to this file.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Got it', style: TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    }
  }

  void _navigateToQueue(String filter) {
    setState(() {
      _currentIndex = 2; // Bills tab index
      _queueInitialFilter = filter;
      _navKey++;
    });
  }

  String _receiptInitialFilter = 'Pending';
  void _navigateToReceipts(String filter) {
    setState(() {
      _currentIndex = 3; // Receipts tab index
      _receiptInitialFilter = filter;
      _navKey++;
    });
  }

  String _customerInitialFilter = 'All';
  void _navigateToCustomers(String filter) {
    setState(() {
      _currentIndex = 1; // Customers tab index
      _customerInitialFilter = filter;
      _navKey++;
    });
  }

  Widget _buildBody() {
    final stack = IndexedStack(
      index: _currentIndex,
      children: [
        DashboardTab(
          settingsService: widget.settingsService,
          excelService: _excelService,
          onNavigateToQueue: _navigateToQueue,
          onNavigateToReceipts: _navigateToReceipts,
          onNavigateToCustomers: _navigateToCustomers,
          onFileImported: _loadFileName,
        ),
        CustomersTab(
          settingsService: widget.settingsService,
          excelService: _excelService,
          initialFilter: _customerInitialFilter,
          navKey: _navKey,
        ),
        BillsTab(
          settingsService: widget.settingsService,
          excelService: _excelService,
          initialFilter: _queueInitialFilter,
          navKey: _navKey,
        ),
        ReceiptsTab(
          settingsService: widget.settingsService,
          excelService: _excelService,
          initialFilter: _receiptInitialFilter,
          navKey: _navKey,
        ),
        ReportsTab(
          excelService: _excelService,
        ),
        SettingsTab(
          settingsService: widget.settingsService,
          onThemeChanged: widget.onThemeChanged,
          excelService: _excelService,
        ),
      ],
    );

    if (!widget.isTrialActive) {
      return stack;
    }

    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            color: const Color(0xFF1B3C2B), // Dark green highlight
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.timer_outlined, color: Color(0xFF00E676), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'First-Install Trial Active (${widget.trialDaysRemaining} days left • 50-Customer Demo Limit)',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.onActivateRequested != null)
                  TextButton(
                    onPressed: widget.onActivateRequested,
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Upgrade', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
          ),
        ),
        Expanded(child: stack),
      ],
    );
  }

  DateTime? _lastPressedAt;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastPressedAt == null || now.difference(_lastPressedAt!) > const Duration(seconds: 2)) {
          _lastPressedAt = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Press back again to exit'),
              duration: Duration(seconds: 2),
            ),
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1014), // Very dark background matching the image
        drawer: Drawer(
          backgroundColor: const Color(0xFF161B22),
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              DrawerHeader(
                decoration: const BoxDecoration(
                  color: Color(0xFF0B1014),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Icon(Icons.inventory_2, size: 48, color: Color(0xFF00E676)),
                        if (_currentPlanName.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00E676).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.3)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(_currentPlanName, style: const TextStyle(color: Color(0xFF00E676), fontSize: 10, fontWeight: FontWeight.bold)),
                                Text(_isLifetime ? 'Unlimited' : '$_daysLeft Days Left', style: const TextStyle(color: Colors.white70, fontSize: 9)),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('VendSoft', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              // Highlighted Import Excel Option
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E676).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.5)),
                ),
                child: ListTile(
                  leading: const Icon(Icons.table_view, color: Color(0xFF00E676), size: 28),
                  title: const Text('Import from Excel', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(_excelFileName ?? 'Tap to pick customers.xlsx', style: const TextStyle(color: Color(0xFF00E676), fontSize: 12)),
                  trailing: const Icon(Icons.upload_file, color: Color(0xFF00E676)),
                  onTap: () {
                    Navigator.pop(context);
                    _importExcel();
                  },
                ),
              ),
              const Divider(color: Colors.white24, height: 1),
              ListTile(
                leading: const Icon(Icons.home, color: Colors.white70),
                title: const Text('Dashboard', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _currentIndex = 0);
                },
              ),
              ListTile(
                leading: const Icon(Icons.people, color: Colors.white70),
                title: const Text('Customers', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _currentIndex = 1);
                },
              ),
              ListTile(
                leading: const Icon(Icons.payment, color: Colors.white70),
                title: const Text('Bills', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _currentIndex = 2);
                },
              ),
              ListTile(
                leading: const Icon(Icons.receipt_long, color: Colors.white70),
                title: const Text('Receipts', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _currentIndex = 3);
                },
              ),
              ListTile(
                leading: const Icon(Icons.analytics, color: Colors.white70),
                title: const Text('Reports', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _currentIndex = 4);
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings, color: Colors.white70),
                title: const Text('Settings', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _currentIndex = 5);
                },
              ),
              const Divider(color: Colors.white24),
              // Payment Reminders
              ListTile(
                leading: const Icon(Icons.notifications_active, color: Colors.amberAccent),
                title: const Text('Payment Reminders (યાદી)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: const Text('Send Gujarati payment reminders', style: TextStyle(color: Colors.amberAccent, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  RemindersModal.show(context, _excelService, widget.settingsService);
                },
              ),
              const Divider(color: Colors.white24),
              // Thermal Printer Connect / Disconnect in Drawer
              ListTile(
                leading: Icon(
                  _connectedPrinterName != null ? Icons.print : Icons.print_disabled,
                  color: _connectedPrinterName != null ? const Color(0xFF00E676) : Colors.orangeAccent,
                ),
                title: Text(
                  _connectedPrinterName != null ? 'Printer: Connected' : 'Thermal Printer',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  _connectedPrinterName ?? 'Tap to Connect / Select Printer',
                  style: TextStyle(color: _connectedPrinterName != null ? const Color(0xFF00E676) : Colors.white54, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(context); // Close drawer
                  if (_connectedPrinterName != null) {
                    _showPrinterManageDialog();
                  } else {
                    _showConnectPrinterDialog();
                  }
                },
              ),
              const Divider(color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.list_alt, color: Colors.white70),
                title: const Text('Logs', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context); // Close drawer
                  Navigator.push(context, MaterialPageRoute(builder: (_) => LogsTab(settingsService: widget.settingsService)));
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline, color: Colors.white70),
                title: const Text('About App', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: const Color(0xFF161B22),
                      title: Row(
                        children: [
                          const Icon(Icons.inventory_2, size: 32, color: Color(0xFF00E676)),
                          const SizedBox(width: 16),
                          const Text('VendSoft', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('Version 1.0.0', style: TextStyle(color: Colors.white70, fontSize: 14)),
                          SizedBox(height: 16),
                          Text(
                            'VendSoft is a robust receipt and billing sender application.',
                            style: TextStyle(color: Colors.white, height: 1.5),
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('OK', style: TextStyle(color: Color(0xFF00E676))),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        body: _buildBody(),
        bottomNavigationBar: _currentIndex == 5 ? null : Theme(
          data: Theme.of(context).copyWith(
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
          ),
          child: BottomNavigationBar(
            backgroundColor: const Color(0xFF0B1014),
            type: BottomNavigationBarType.fixed,
            currentIndex: _currentIndex,
            selectedItemColor: const Color(0xFF00E676), // Neon green
            unselectedItemColor: Colors.white70,
            selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 12),
            elevation: 0,
            onTap: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                activeIcon: Icon(Icons.home),
                label: 'Dashboard',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.people_outline),
                activeIcon: Icon(Icons.people),
                label: 'Customers',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.payment_outlined),
                activeIcon: Icon(Icons.payment),
                label: 'Bills',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.receipt_long_outlined),
                activeIcon: Icon(Icons.receipt_long),
                label: 'Receipts',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.analytics_outlined),
                activeIcon: Icon(Icons.analytics),
                label: 'Reports',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionInfoRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;

  const _PermissionInfoRow({required this.icon, required this.title, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFF00E676), size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 2),
              Text(desc, style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.3)),
            ],
          ),
        ),
      ],
    );
  }
}
