import 'dart:async';
import 'package:flutter/material.dart';
import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/settings_service.dart';
import '../services/cooldown_service.dart';
import '../services/license_service.dart';
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

class _DashboardTabState extends State<DashboardTab> {
  String? excelFileName;
  Timer? _cooldownTimer;
  bool _isCooldown = false;
  Duration _remainingCooldown = Duration.zero;
  bool _isDemoMode = true;

  final TextEditingController _cmSearchController = TextEditingController();
  String _cmTimeFilter = 'All Time';

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _cmSearchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initPreloadedData();
    _startCooldownTimer();
  }

  void _startCooldownTimer() {
    _checkCooldown();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) => _checkCooldown());
  }

  Future<void> _checkCooldown() async {
    bool active = await CooldownService().isCooldownActive();
    Duration remaining = await CooldownService().getRemainingCooldown();
    if (mounted && (_isCooldown != active || _remainingCooldown.inSeconds != remaining.inSeconds)) {
      setState(() {
        _isCooldown = active;
        _remainingCooldown = remaining;
      });
    }
  }

  Future<void> _initPreloadedData() async {
    String? lastName = await widget.settingsService.getLastExcelFileName();
    bool demo = await LicenseService().isDemoMode();
    if (mounted) {
      setState(() {
        excelFileName = lastName;
        _isDemoMode = demo;
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
          int sent = currentCustomers.where((c) {
            String st = c.status.trim().toLowerCase();
            return st == 'sent' || st == 'message sent';
          }).length;
          int pending = currentCustomers.where((c) {
            String st = c.status.trim().toLowerCase();
            return st == 'pending' || st == 'processing' || st == 'waiting';
          }).length;


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
                if (_isDemoMode)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
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
                        currentCustomers.where((c) {
                          String pst = c.paymentStatus.trim().toLowerCase();
                          String rst = c.receiptStatus.trim().toLowerCase();
                          return (pst == 'successful' || pst.contains('success') || pst == 'paid') &&
                                 (rst != 'sent' && rst != 'message sent');
                        }).length.toString(), 
                        Icons.receipt, 
                        Colors.purple, 
                        onTap: () => widget.onNavigateToReceipts('Pending'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildStatCard(
                        'Sent Receipts', 
                        currentCustomers.where((c) {
                          String pst = c.paymentStatus.trim().toLowerCase();
                          String rst = c.receiptStatus.trim().toLowerCase();
                          return (pst == 'successful' || pst.contains('success') || pst == 'paid') &&
                                 (rst == 'sent' || rst == 'message sent');
                        }).length.toString(), 
                        Icons.check_circle, 
                        const Color(0xFF00E676), 
                        onTap: () => widget.onNavigateToReceipts('Sent'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildCollectionManSection(currentCustomers),
                
                // Quick Actions
                const Text(' Quick Actions', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildQuickAction(
                        _isCooldown ? 'Cooldown (${CooldownService.formatDuration(_remainingCooldown)})' : 'Send Bills',
                        _isCooldown ? Icons.timer : Icons.send_rounded,
                        _isCooldown ? Colors.orange : const Color(0xFF00E676),
                        _isCooldown ? () => _showCooldownDialog(context) : () => widget.onNavigateToQueue('Pending Bills'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildQuickAction(
                        _isCooldown ? 'Cooldown (${CooldownService.formatDuration(_remainingCooldown)})' : 'Send Receipts',
                        _isCooldown ? Icons.timer : Icons.receipt_long,
                        _isCooldown ? Colors.orange : Colors.blue,
                        _isCooldown ? () => _showCooldownDialog(context) : () => widget.onNavigateToReceipts('Pending'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildQuickAction(
                        _isCooldown ? 'Cooldown (${CooldownService.formatDuration(_remainingCooldown)})' : 'Payment Reminders (યાદી)',
                        _isCooldown ? Icons.timer : Icons.notifications_active,
                        _isCooldown ? Colors.orange : const Color(0xFF00E676),
                        _isCooldown ? () => _showCooldownDialog(context) : () => RemindersModal.show(context, widget.excelService, widget.settingsService),
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

  void _showCooldownDialog(BuildContext context) {
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
          'To prevent WhatsApp from flagging your account as a bot, a cooldown lock is active between batches of 30 messages.\n\nTime remaining: ${CooldownService.formatDuration(_remainingCooldown)}',
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

  Widget _buildQuickAction(String title, IconData icon, Color color, VoidCallback onTap) {
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
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ),
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

  Widget _buildCollectionManSection(List<Customer> currentCustomers) {
    if (currentCustomers.isEmpty) return const SizedBox.shrink();

    // 1. Compute aggregate statistics
    final Map<String, _CmStat> statsMap = {};
    for (var c in currentCustomers) {
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

      double bill = double.tryParse(c.billAmount.replaceAll(',', '').trim()) ?? 0.0;
      double paid = double.tryParse(c.amountPaid.replaceAll(',', '').trim()) ?? 0.0;
      String pst = c.paymentStatus.trim().toLowerCase();
      bool isPaid = pst == 'successful' || pst.contains('success') || pst == 'paid';
      if (paid == 0.0 && isPaid && bill > 0.0) {
        paid = bill;
      }

      // Apply time filter
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

    // 2. Filter by search query
    String query = _cmSearchController.text.trim().toLowerCase();
    List<_CmStat> filteredStats = statsMap.values.where((s) {
      if (query.isEmpty) return true;
      return s.cmName.toLowerCase().contains(query) || s.cmCode.toLowerCase().contains(query);
    }).toList();

    filteredStats.sort((a, b) => b.assignedCount.compareTo(a.assignedCount));

    double totalCollectedAll = statsMap.values.fold(0.0, (sum, item) => sum + item.collected);
    double totalBillAll = statsMap.values.fold(0.0, (sum, item) => sum + item.totalBill);
    double overallRecovery = totalBillAll > 0 ? ((totalCollectedAll / totalBillAll) * 100).clamp(0.0, 100.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: false,
              tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E676).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.support_agent, color: Color(0xFF00E676), size: 22),
              ),
              title: const Text(
                'Collection Man (CM) Analytics',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              subtitle: Text(
                '${statsMap.length} Active Agents • ₹${totalCollectedAll.toStringAsFixed(0)} Collected (${overallRecovery.toStringAsFixed(0)}% recovery)',
                style: const TextStyle(color: Color(0xFF00E676), fontSize: 12, fontWeight: FontWeight.w600),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Search & Filter Row
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
                                    setState(() => _cmTimeFilter = val);
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (filteredStats.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(
                            child: Text('No Collection Agents found matching search.', style: TextStyle(color: Colors.grey, fontSize: 13)),
                          ),
                        )
                      else
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: filteredStats.length,
                          separatorBuilder: (context, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final stat = filteredStats[index];
                            double rec = stat.totalBill > 0 ? ((stat.collected / stat.totalBill) * 100).clamp(0.0, 100.0) : 0.0;
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.03),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(stat.cmName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                            if (stat.cmCode.isNotEmpty && stat.cmName != 'Route Code: ${stat.cmCode}')
                                              Text('Code: ${stat.cmCode}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                                          ],
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () => widget.onNavigateToCustomers(stat.cmName.isNotEmpty && stat.cmName != 'Unassigned Route' ? stat.cmName : 'All'),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF00E676).withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Text('Filter Route', style: TextStyle(color: Color(0xFF00E676), fontSize: 11, fontWeight: FontWeight.bold)),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('Assigned: ${stat.assignedCount} customers', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                      Text('Collected: ₹${stat.collected.toStringAsFixed(0)} / ₹${stat.totalBill.toStringAsFixed(0)} (${rec.toStringAsFixed(0)}%)',
                                          style: TextStyle(color: rec >= 80 ? const Color(0xFF00E676) : (rec >= 50 ? Colors.orangeAccent : Colors.redAccent), fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: stat.totalBill > 0 ? (stat.collected / stat.totalBill).clamp(0.0, 1.0) : 0.0,
                                      minHeight: 5,
                                      backgroundColor: Colors.white12,
                                      valueColor: AlwaysStoppedAnimation<Color>(rec >= 80 ? const Color(0xFF00E676) : (rec >= 50 ? Colors.orangeAccent : Colors.redAccent)),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
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
