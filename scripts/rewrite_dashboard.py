import os
import re

file_path = r'e:\image_sender\lib\screens\dashboard_tab.dart'

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add CooldownButton import
content = content.replace(
    "import '../services/trial_service.dart';",
    "import '../services/trial_service.dart';\nimport '../widgets/cooldown_button.dart';"
)

# 2. Add cached variables
state_vars = """
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
"""
content = content.replace("  String _cmTimeFilter = 'All Time';", state_vars)

# 3. Add listener in initState and _calculateMetrics
init_logic = """
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
"""

content = re.sub(
    r'@override\s+void initState\(\) \{.*?super\.dispose\(\);\s*\}',
    init_logic.strip(),
    content,
    flags=re.DOTALL
)

# 4. Modify build() to remove ListenableBuilder and calculation loops
build_repl = """
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
                      'Let\\'s get started by loading your customers from an Excel file. Make sure your customers.xlsx file is in Internal Storage > VendSoft.',
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
"""

content = re.sub(
    r'@override\s+Widget build\(BuildContext context\) \{.*?// ── Tab 1:',
    build_repl.strip() + '\n\n  // ── Tab 1:',
    content,
    flags=re.DOTALL
)

# 5. Fix _buildMainDashboardTab (remove arguments and calculations)
main_tab_repl = """
  // ── Tab 1: Main Overview Dashboard ──
  Widget _buildMainDashboardTab() {
    return SingleChildScrollView(
"""

content = re.sub(
    r'// ── Tab 1: Main Overview Dashboard ──\s+Widget _buildMainDashboardTab\(.*?return SingleChildScrollView\(',
    main_tab_repl.strip() + '\n      padding: const EdgeInsets.all(16),',
    content,
    flags=re.DOTALL
)

# Replace variables in main tab
content = content.replace('total.toString()', '_totalCustomers.toString()')
content = content.replace('pending.toString()', '_pendingCount.toString()')
content = content.replace('pendingCollectionAmount.toStringAsFixed(0)', '_pendingCollectionAmount.toStringAsFixed(0)')
content = content.replace('pendingReceiptsCount.toString()', '_pendingReceiptsCount.toString()')
content = content.replace('sentReceiptsCount.toString()', '_sentReceiptsCount.toString()')
content = content.replace('value: progress,', 'value: _progress,')
content = content.replace('$progressPercent%', '$_progressPercent%')
content = content.replace('$sent of $total customers', '$_sentCount of $_totalCustomers customers')
content = content.replace('$sent bills', '$_sentCount bills')
content = content.replace('$sentReceiptsCount receipts', '$_sentReceiptsCount receipts')

# 6. Replace Quick Actions with CooldownButton
quick_actions_repl = """
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
"""
content = re.sub(
    r'Row\(\s+children: \[\s+Expanded\(\s+child: _buildQuickAction\(.*?\]\s+\),\s+const SizedBox\(height: 24\),',
    quick_actions_repl.strip() + '\n          const SizedBox(height: 24),',
    content,
    flags=re.DOTALL
)

# 7. Remove _buildQuickAction
content = re.sub(
    r'Widget _buildQuickAction\(String label, IconData icon, Color color, VoidCallback onTap\) \{.*?\n  \}\n',
    '',
    content,
    flags=re.DOTALL
)

# 8. Fix _buildCollectionManDashboardTab
cm_tab_repl = """
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
"""

content = re.sub(
    r'// ── Tab 2: Dedicated Collection Man Dashboard \(Item 3\) ──\s+Widget _buildCollectionManDashboardTab.*?const SizedBox\(height: 18\),',
    cm_tab_repl.strip() + '\n',
    content,
    flags=re.DOTALL
)

# Ensure cmTimeFilter triggers _calculateMetrics
content = content.replace(
    'setState(() => _cmTimeFilter = val);',
    'setState(() { _cmTimeFilter = val; _calculateMetrics(); });'
)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
