import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/settings_service.dart';
import '../services/excel_service.dart';
import 'package:excel/excel.dart' hide Border;
import 'dashboard_tab.dart';
import 'logs_tab.dart';
import 'customers_tab.dart';
import 'bills_tab.dart';
import 'settings_tab.dart';
import 'receipts_tab.dart';
import 'reports_tab.dart';

class MainLayout extends StatefulWidget {
  final SettingsService settingsService;
  final ExcelService excelService;
  final VoidCallback onThemeChanged;

  const MainLayout({
    super.key,
    required this.settingsService,
    required this.excelService,
    required this.onThemeChanged,
  });

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _currentIndex = 0;
  late final ExcelService _excelService = widget.excelService;
  String _queueInitialFilter = 'All';
  int _navKey = 0;
  String? _excelFileName;

  @override
  void initState() {
    super.initState();
    _checkFirstLaunch();
    _loadFileName();
  }

  Future<void> _loadFileName() async {
    String? name = await widget.settingsService.getLastExcelFileName();
    if (mounted) {
      setState(() {
        _excelFileName = name;
      });
    }
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

  Future<void> _checkFirstLaunch() async {
    bool isFirstLaunch = await widget.settingsService.getIsFirstLaunch();
    if (isFirstLaunch && mounted) {
      bool hasPermission = false;
      if (await Permission.storage.request().isGranted) {
        hasPermission = true;
      } else if (await Permission.manageExternalStorage.request().isGranted) {
        hasPermission = true;
      }

      bool created = false;
      if (hasPermission) {
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
              TextCellValue('PaymentMethod'), TextCellValue('ReceiptStatus'), TextCellValue('PaymentDate'),
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
          created = false;
        }
      }

      if (mounted && created) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF161B22),
            title: const Text('Welcome to VendSoft!', style: TextStyle(color: Colors.white)),
            content: const Text(
              'A folder named "VendSoft" has been created in your Internal Storage.\n\nInside it, an empty "customers.xlsx" file has been generated for you. You can now add your customers to this file.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.settingsService.setIsFirstLaunch(false);
                },
                child: const Text('Got it', style: TextStyle(color: Color(0xFF00E676))),
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
    return IndexedStack(
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
              const DrawerHeader(
                decoration: BoxDecoration(
                  color: Color(0xFF0B1014),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(Icons.inventory_2, size: 48, color: Color(0xFF00E676)),
                    SizedBox(height: 16),
                    Text('VendSoft', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
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
              ListTile(
                leading: const Icon(Icons.insert_drive_file, color: Color(0xFF00E676)),
                title: Text(_excelFileName ?? 'No file selected', style: const TextStyle(color: Colors.white)),
                subtitle: const Text('Tap to change Excel File', style: TextStyle(color: Colors.white54)),
                onTap: () {
                  Navigator.pop(context); // Close drawer
                  _importExcel();
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
