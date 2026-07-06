import 'package:flutter/material.dart';
import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/settings_service.dart';

class DashboardTab extends StatefulWidget {
  final SettingsService settingsService;
  final ExcelService excelService;
  final Function(String) onNavigateToQueue;
  final Function(String) onNavigateToReceipts;
  final Function(String) onNavigateToCustomers;
  final VoidCallback onFileImported;

  const DashboardTab({
    super.key,
    required this.settingsService,
    required this.excelService,
    required this.onNavigateToQueue,
    required this.onNavigateToReceipts,
    required this.onNavigateToCustomers,
    required this.onFileImported,
  });

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  String? excelFileName;
  List<Customer> customers = [];
  @override
  void dispose() {
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initPreloadedData();
  }

  Future<void> _initPreloadedData() async {
    String? lastName = await widget.settingsService.getLastExcelFileName();
    if (mounted) {
      setState(() {
        excelFileName = lastName;
        customers = widget.excelService.allCustomers;
      });
    }
  }

  Future<void> _importExcel() async {
    String? name = await widget.excelService.pickExcel();
    if (name != null) {
      if (widget.excelService.documentUri != null) {
        await widget.settingsService.setLastExcelUri(widget.excelService.documentUri!);
        await widget.settingsService.setLastExcelFileName(name);
      }
      if (mounted) {
        setState(() {
          excelFileName = name;
          customers = widget.excelService.allCustomers;
        });
        widget.onFileImported();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        title: const Text('Dashboard', style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: false,
      ),
      body: ListenableBuilder(
        listenable: widget.excelService,
        builder: (context, _) {
          List<Customer> currentCustomers = widget.excelService.allCustomers;
          int total = currentCustomers.length;
          int sent = currentCustomers.where((c) => c.status == 'Sent').length;
          int pending = currentCustomers.where((c) => c.status.toLowerCase() == 'pending' || c.status == 'Processing' || c.status == 'Waiting').length;


          double progress = total > 0 ? (sent / total) : 0.0;
          int progressPercent = (progress * 100).toInt();

          if (currentCustomers.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.rocket_launch, size: 80, color: Color(0xFF00E676)),
                    const SizedBox(height: 24),
                    const Text('Welcome to VendSoft!', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 16),
                    const Text(
                      'Let\'s get started by loading your customers from an Excel file. Make sure your customers.xlsx file is in Internal Storage > VendSoft.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 16, height: 1.5),
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton.icon(
                      onPressed: _importExcel,
                      icon: const Icon(Icons.folder_open, color: Colors.black),
                      label: const Text('Load Customers Excel', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Overall Progress (Compact Linear)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Overall Progress', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                            Text('$progressPercent%', style: const TextStyle(color: Color(0xFF00E676), fontSize: 16, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 8,
                            backgroundColor: Colors.grey.withValues(alpha: 0.2),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E676)),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('$sent of $total customers completed', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                
                // Stats Grid
                Row(
                  children: [
                    Expanded(child: _buildStatCard('Total Customers', total.toString(), Icons.people, Colors.blue, onTap: () => widget.onNavigateToCustomers('All'))),
                    const SizedBox(width: 8),
                    Expanded(child: _buildStatCard('Pending Bills', pending.toString(), Icons.access_time, Colors.orange, onTap: () => widget.onNavigateToQueue('Pending Bills'))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        'Pending Receipts', 
                        currentCustomers.where((c) => c.paymentStatus == 'Successful' && c.receiptStatus != 'Sent').length.toString(), 
                        Icons.receipt, 
                        Colors.purple, 
                        onTap: () => widget.onNavigateToReceipts('Pending'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildStatCard(
                        'Sent Receipts', 
                        currentCustomers.where((c) => c.paymentStatus == 'Successful' && c.receiptStatus == 'Sent').length.toString(), 
                        Icons.check_circle, 
                        const Color(0xFF00E676), 
                        onTap: () => widget.onNavigateToReceipts('Sent'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                
                // Quick Actions
                const Text(' Quick Actions', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildQuickAction(
                        'Send Bills',
                        Icons.send_rounded,
                        const Color(0xFF00E676),
                        () => widget.onNavigateToQueue('Pending Bills'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildQuickAction(
                        'Send Receipts',
                        Icons.receipt_long,
                        Colors.blue,
                        () => widget.onNavigateToReceipts('Pending'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
      );
    }),
    );
  }

  Widget _buildQuickAction(String title, IconData icon, Color color, VoidCallback onTap, {bool isWide = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 8),
            Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color iconColor, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: iconColor, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(title, style: TextStyle(color: Colors.grey.withValues(alpha: 0.8), fontSize: 13)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}
