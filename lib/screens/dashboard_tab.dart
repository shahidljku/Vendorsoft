import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/settings_service.dart';
import '../services/cooldown_service.dart';
import '../services/license_service.dart';
import '../services/trial_service.dart';
import '../widgets/cooldown_button.dart';
import '../widgets/subscription_dialog.dart';
import 'reminders_modal.dart';

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

class _DashboardTabState extends State<DashboardTab> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? excelFileName;
  bool _isDemoMode = true;
  bool _isTrialActive = false;
  int _trialDaysRemaining = 0;
  bool _isLifetime = false;
  int _licenseDaysRemaining = 0;
  String _lastBackupDateText = 'Checking...';

  final TextEditingController _cmSearchController = TextEditingController();

  String _cmTimeFilter = 'All Time';

  // Cached Metrics
  int _totalCustomers = 0;
  int _sentCount = 0;
  int _pendingCount = 0;
  double _progress = 0.0;
  int _progressPercent = 0;
  double _pendingCollectionAmount = 0.0;
  int _pendingReceiptsCount = 0;
  int _sentReceiptsCount = 0;
  Map<String, _CmStat> _cmStatsMap = {};
  int _totalAssignedAll = 0;
  double _totalCollectedAll = 0.0;
  double _totalBillAll = 0.0;
  double _totalPendingAll = 0.0;
  double _overallRecovery = 0.0;


  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initPreloadedData();
    _checkLastBackupDate();
    
    _calculateMetrics();
    widget.excelService.addListener(_calculateMetrics);
  }

  @override
  void dispose() {
    widget.excelService.removeListener(_calculateMetrics);
    _cmSearchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _calculateMetrics() {
    List<Customer> currentCustomers = widget.excelService.allCustomers;
    
    int total = currentCustomers.length;
    int sent = 0;
    int pending = 0;
    double pendingCollectionAmount = 0.0;
    int pendingReceiptsCount = 0;
    int sentReceiptsCount = 0;
    Map<String, _CmStat> statsMap = {};

    for (var c in currentCustomers) {
      String st = c.status.trim().toLowerCase();
      if (st == 'sent' || st == 'message sent') {
        sent++;
      } else if (st == 'pending' || st == 'processing' || st == 'waiting') {
        pending++;
      }

      double bill = double.tryParse(c.billAmount.replaceAll(',', '').trim()) ?? 0.0;
      double paid = double.tryParse(c.amountPaid.replaceAll(',', '').trim()) ?? 0.0;
      String rst = c.receiptStatus.trim().toLowerCase();
      bool isPaid = c.isPaid;

      if (paid < bill && !isPaid) {
        pendingCollectionAmount += (bill - paid).clamp(0.0, double.infinity);
      }
      if (isPaid && (rst != 'sent' && rst != 'message sent')) {
        pendingReceiptsCount++;
      } else if (isPaid && (rst == 'sent' || rst == 'message sent')) {
        sentReceiptsCount++;
      }

      // CM grouping
      String name = c.cmName.trim();
      String code = c.cmCode.trim();
      if (name.isEmpty && code.isEmpty) {
        name = 'Unassigned Route';
      } else if (name.isEmpty) {
        name = 'Route Code: $code';
      }
      String key = name.toLowerCase();

      final stat = statsMap.putIfAbsent(key, () => _CmStat(cmCode: code, cmName: name));
      stat.assignedCount++;

      if (paid == 0.0 && isPaid && bill > 0.0) {
        paid = bill;
      }

      bool includeInMoneyStats = true;
      if (_cmTimeFilter == 'Pending Only' && (isPaid && paid >= bill)) {
        includeInMoneyStats = false;
      } else if (_cmTimeFilter == 'This Month') {
        final now = DateTime.now();
        String monthPrefix = '${now.year}-${now.month.toString().padLeft(2, '0')}';
        if (!c.paymentDate.contains(monthPrefix) && !c.vouchDate.contains(monthPrefix)) {
          includeInMoneyStats = false;
        }
      }

      if (includeInMoneyStats) {
        stat.totalBill += bill;
        stat.collected += paid;
        stat.pending += (bill - paid).clamp(0.0, double.infinity);
      }
    }

    double progress = total > 0 ? (sent / total) : 0.0;
    
    int tAssigned = statsMap.values.fold(0, (sum, item) => sum + item.assignedCount);
    double tCollected = statsMap.values.fold(0.0, (sum, item) => sum + item.collected);
    double tBill = statsMap.values.fold(0.0, (sum, item) => sum + item.totalBill);
    double tPending = statsMap.values.fold(0.0, (sum, item) => sum + item.pending);
    double overallRec = tBill > 0 ? ((tCollected / tBill) * 100).clamp(0.0, 100.0) : 0.0;

    if (mounted) {
      setState(() {
        _totalCustomers = total;
        _sentCount = sent;
        _pendingCount = pending;
        _pendingCollectionAmount = pendingCollectionAmount;
        _pendingReceiptsCount = pendingReceiptsCount;
        _sentReceiptsCount = sentReceiptsCount;
        _progress = progress;
        _progressPercent = (progress * 100).toInt();
        
        _cmStatsMap = statsMap;
        _totalAssignedAll = tAssigned;
        _totalCollectedAll = tCollected;
        _totalBillAll = tBill;
        _totalPendingAll = tPending;
        _overallRecovery = overallRec;
      });
    }
  }



  Future<void> _initPreloadedData() async {
    String? lastName = await widget.settingsService.getLastExcelFileName();
    bool demo = await LicenseService().isDemoMode();
    bool trialActive = TrialService().isTrialActive;
    int trialDays = TrialService().daysRemaining;
    
    bool isLifetime = false;
    int licenseDays = 0;
    if (!demo) {
      final info = LicenseService().getLicenseInfo();
      if (info?['customerType'] == 'Lifetime') {
        isLifetime = true;
      } else {
        licenseDays = LicenseService().getDaysRemaining();
      }
    }

    if (mounted) {
      setState(() {
        excelFileName = lastName;
        _isDemoMode = demo;
        _isTrialActive = trialActive;
        _trialDaysRemaining = trialDays;
        _isLifetime = isLifetime;
        _licenseDaysRemaining = licenseDays;
      });
    }
  }

  Future<void> _checkLastBackupDate() async {
    try {
      final backupDir = Directory('/storage/emulated/0/VendSoft/backups');
      if (backupDir.existsSync()) {
        final files = backupDir.listSync().whereType<File>().toList();
        if (files.isNotEmpty) {
          files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
          final lastMod = files.first.lastModifiedSync();
          final formatted = '${lastMod.day.toString().padLeft(2, '0')}/${lastMod.month.toString().padLeft(2, '0')}/${lastMod.year} ${lastMod.hour.toString().padLeft(2, '0')}:${lastMod.minute.toString().padLeft(2, '0')}';
          if (mounted) {
            setState(() => _lastBackupDateText = formatted);
          }
          return;
        }
      }
      if (mounted) {
        setState(() => _lastBackupDateText = 'No recent backups found');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _lastBackupDateText = 'Unavailable');
      }
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
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00E676),
          labelColor: const Color(0xFF00E676),
          unselectedLabelColor: Colors.grey,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          tabs: const [
            Tab(icon: Icon(Icons.dashboard_outlined, size: 18), text: 'Main Overview'),
            Tab(icon: Icon(Icons.support_agent, size: 18), text: 'Collection Men'),
          ],
        ),
      ),
      body: widget.excelService.allCustomers.isEmpty
          ? Center(
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
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _buildMainDashboardTab(),
                _buildCollectionManDashboardTab(),
              ],
            ),
    );
  }

  // ── Tab 1: Main Overview Dashboard ──
  Widget _buildMainDashboardTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isDemoMode)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.orange.shade900.withValues(alpha: 0.35), const Color(0xFF161B22)],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.workspace_premium, color: Colors.orangeAccent, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Demo Trial Active (Max 50 Customers)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 3),
                        Text('Upgrade to Yearly (₹9,499) or Monthly (₹799)', style: TextStyle(color: Colors.grey.shade300, fontSize: 11)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => SubscriptionDialog.showPlans(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Upgrade', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),
            
          if (!_isDemoMode && !_isLifetime && _licenseDaysRemaining <= 7)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _licenseDaysRemaining <= 0 ? Colors.red.shade900.withValues(alpha: 0.35) : Colors.orange.shade900.withValues(alpha: 0.35),
                    const Color(0xFF161B22)
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _licenseDaysRemaining <= 0 ? Colors.redAccent.withValues(alpha: 0.5) : Colors.orangeAccent.withValues(alpha: 0.5)
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _licenseDaysRemaining <= 0 ? Icons.error_outline : Icons.warning_amber_rounded,
                    color: _licenseDaysRemaining <= 0 ? Colors.redAccent : Colors.orangeAccent,
                    size: 32
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _licenseDaysRemaining <= 0 ? 'Subscription Expired' : 'Subscription Expiring Soon',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _licenseDaysRemaining <= 0 ? 'Your plan has expired. Please renew to continue using VendSoft.' : 'Your plan expires in $_licenseDaysRemaining days.',
                          style: TextStyle(color: Colors.grey.shade300, fontSize: 11)
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => SubscriptionDialog.showPlans(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Renew', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),

          // Overall Progress Card
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
                      Text('$_progressPercent%', style: const TextStyle(color: Color(0xFF00E676), fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 8,
                      backgroundColor: Colors.grey.withValues(alpha: 0.2),
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E676)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('$_sentCount of $_totalCustomers customers completed', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Main Stats Grid
          Row(
            children: [
              Expanded(child: _buildStatCard('Total Customers', _totalCustomers.toString(), Icons.people, Colors.blue, onTap: () => widget.onNavigateToCustomers('All'))),
              const SizedBox(width: 10),
              Expanded(child: _buildStatCard('Pending Bills', _pendingCount.toString(), Icons.access_time, Colors.orange, onTap: () => widget.onNavigateToQueue('Pending Bills'))),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildStatCard('Pending Receipts', _pendingReceiptsCount.toString(), Icons.receipt, Colors.purple, onTap: () => widget.onNavigateToReceipts('Pending'))),
              const SizedBox(width: 10),
              Expanded(child: _buildStatCard('Sent Receipts', _sentReceiptsCount.toString(), Icons.check_circle, const Color(0xFF00E676), onTap: () => widget.onNavigateToReceipts('Sent'))),
            ],
          ),
          const SizedBox(height: 18),

          // Polished Operational Information Section (Item 4)
          const Text(' Operational Information', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  _buildOperationalRow(Icons.account_balance_wallet_outlined, 'Pending Collection Amount', '₹${_pendingCollectionAmount.toStringAsFixed(0)}', Colors.orangeAccent),
                  const Divider(color: Colors.white12, height: 20),
                  _buildOperationalRow(Icons.description_outlined, 'Bills Sent Today', '$_sentCount bills dispatched', Colors.blueAccent),
                  const Divider(color: Colors.white12, height: 20),
                  _buildOperationalRow(Icons.receipt_long_outlined, 'Receipts Sent Today', '$_sentReceiptsCount receipts delivered', const Color(0xFF00E676)),
                  const Divider(color: Colors.white12, height: 20),
                  _buildOperationalRow(Icons.backup_outlined, 'Last Backup Snapshot', _lastBackupDateText, Colors.purpleAccent),
                  if (_isTrialActive) ...[
                    const Divider(color: Colors.white12, height: 20),
                    _buildOperationalRow(Icons.timer_outlined, 'Trial Status Remaining', '$_trialDaysRemaining Days remaining', Colors.amberAccent),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Quick Actions
          const Text(' Quick Actions', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: CooldownButton(
                  label: 'Send Bills',
                  iconData: Icons.send_rounded,
                  baseColor: const Color(0xFF00E676),
                  onCooldownAction: () => _showCooldownDialog(context),
                  onNormalAction: () => widget.onNavigateToQueue('Pending Bills'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CooldownButton(
                  label: 'Send Receipts',
                  iconData: Icons.receipt_long,
                  baseColor: Colors.blue,
                  onCooldownAction: () => _showCooldownDialog(context),
                  onNormalAction: () => widget.onNavigateToReceipts('Pending'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: CooldownButton(
                  label: 'Payment Reminders (યાદી)',
                  iconData: Icons.notifications_active,
                  baseColor: const Color(0xFF00E676),
                  onCooldownAction: () => _showCooldownDialog(context),
                  onNormalAction: () => RemindersModal.show(context, widget.excelService, widget.settingsService),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Tab 2: Dedicated Collection Man Dashboard (Item 3) ──
  Widget _buildCollectionManDashboardTab() {
    String query = _cmSearchController.text.trim().toLowerCase();
    List<_CmStat> filteredStats = _cmStatsMap.values.where((s) {
      if (query.isEmpty) return true;
      return s.cmName.toLowerCase().contains(query) || s.cmCode.toLowerCase().contains(query);
    }).toList();

    filteredStats.sort((a, b) => b.collected.compareTo(a.collected));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Summary Cards specific to Collection Men
          Row(
            children: [
              Expanded(child: _buildStatCard('Total Collection Men', _cmStatsMap.length.toString(), Icons.support_agent, const Color(0xFF00E676))),
              const SizedBox(width: 10),
              Expanded(child: _buildStatCard('Customers Assigned', _totalAssignedAll.toString(), Icons.group_work, Colors.blue)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildStatCard('Pending Amount', '₹${_totalPendingAll.toStringAsFixed(0)}', Icons.pending_actions, Colors.orange)),
              const SizedBox(width: 10),
              Expanded(child: _buildStatCard('Collected Amount', '₹${_totalCollectedAll.toStringAsFixed(0)}', Icons.payments, Colors.purple)),
            ],
          ),
          const SizedBox(height: 10),
          _buildStatCard('Overall Recovery Progress', '${_overallRecovery.toStringAsFixed(1)}%', Icons.trending_up, const Color(0xFF00E676)),
          const SizedBox(height: 18),


          // Search & Filter Bar
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _cmSearchController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search Agent Name or Code...',
                    hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                    prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 18),
                    suffixIcon: _cmSearchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, color: Colors.grey, size: 18),
                            onPressed: () => setState(() => _cmSearchController.clear()),
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButtonHideUnderline(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: DropdownButton<String>(
                    value: _cmTimeFilter,
                    dropdownColor: const Color(0xFF161B22),
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                    icon: const Icon(Icons.filter_list, color: Color(0xFF00E676), size: 18),
                    items: ['All Time', 'This Month', 'Pending Only'].map((filter) {
                      return DropdownMenuItem<String>(
                        value: filter,
                        child: Text(filter),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null && val != _cmTimeFilter) {
                        setState(() { _cmTimeFilter = val; _calculateMetrics(); });
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Collection Man Ranking List
          const Text(' Collection Man Ranking', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          if (filteredStats.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('No Collection Agents found matching criteria.', style: TextStyle(color: Colors.grey, fontSize: 14)),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filteredStats.length,
              separatorBuilder: (context, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final stat = filteredStats[index];
                double rec = stat.totalBill > 0 ? ((stat.collected / stat.totalBill) * 100).clamp(0.0, 100.0) : 0.0;
                int rank = index + 1;

                return GestureDetector(
                  onTap: () {
                    String targetName = (stat.cmName.isNotEmpty && stat.cmName != 'Unassigned Route' && !stat.cmName.startsWith('Route Code:'))
                        ? stat.cmName
                        : 'All';
                    widget.onNavigateToCustomers(targetName);
                  },
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: rank == 1 ? Colors.amber.withValues(alpha: 0.2) : (rank == 2 ? Colors.grey.withValues(alpha: 0.2) : const Color(0xFF00E676).withValues(alpha: 0.15)),
                                  shape: BoxShape.circle,
                                ),
                                child: Text('#$rank', style: TextStyle(color: rank == 1 ? Colors.amber : (rank == 2 ? Colors.grey.shade300 : const Color(0xFF00E676)), fontWeight: FontWeight.bold, fontSize: 13)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(stat.cmName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                                    if (stat.cmCode.isNotEmpty && stat.cmName != 'Route Code: ${stat.cmCode}')
                                      Text('Code: ${stat.cmCode} • Assigned: ${stat.assignedCount} customers', style: const TextStyle(color: Colors.grey, fontSize: 12))
                                    else
                                      Text('Assigned: ${stat.assignedCount} customers', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Collected: ₹${stat.collected.toStringAsFixed(0)} / ₹${stat.totalBill.toStringAsFixed(0)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              Text('${rec.toStringAsFixed(1)}% Recovery',
                                  style: TextStyle(color: rec >= 80 ? const Color(0xFF00E676) : (rec >= 50 ? Colors.orangeAccent : Colors.redAccent), fontSize: 13, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: stat.totalBill > 0 ? (stat.collected / stat.totalBill).clamp(0.0, 1.0) : 0.0,
                              minHeight: 6,
                              backgroundColor: Colors.white12,
                              valueColor: AlwaysStoppedAnimation<Color>(rec >= 80 ? const Color(0xFF00E676) : (rec >= 50 ? Colors.orangeAccent : Colors.redAccent)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildOperationalRow(IconData icon, String title, String value, Color color) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showCooldownDialog(BuildContext context) async {
    Duration remaining = await CooldownService().getRemainingCooldown();
    if (!context.mounted) return;
    
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: const Row(
          children: [
            Icon(Icons.timer_outlined, color: Colors.orange),
            SizedBox(width: 8),
            Text('Cooldown Active', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          '''To prevent WhatsApp from flagging your account as a bot, a cooldown lock is active between batches of 30 messages.

Time remaining: ${CooldownService.formatDuration(remaining)}''',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('OK', style: TextStyle(color: Color(0xFF00E676))),
          ),
        ],
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
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class _CmStat {
  final String cmCode;
  final String cmName;
  int assignedCount = 0;
  double totalBill = 0.0;
  double collected = 0.0;
  double pending = 0.0;

  _CmStat({required this.cmCode, required this.cmName});
}
