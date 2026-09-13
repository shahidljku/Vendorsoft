import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'sending_screen.dart';
import '../models/customer.dart';
import '../models/payment_status_helper.dart';
import '../models/batch_summary.dart';
import '../services/excel_service.dart';
import '../services/accessibility_service.dart';
import '../services/whatsapp_service.dart';
import '../services/settings_service.dart';
import '../services/cooldown_service.dart';
import '../services/print_service.dart';
import '../services/receipt_service.dart';
import '../services/license_service.dart';
import '../services/transaction_ledger.dart';
import '../widgets/cooldown_fab.dart';

class BillsTab extends StatefulWidget {
  final SettingsService settingsService;
  final ExcelService excelService;
  final String? initialFilter;
  final int navKey;

  const BillsTab({
    super.key,
    required this.settingsService,
    required this.excelService,
    this.initialFilter,
    this.navKey = 0,
  });

  @override
  State<BillsTab> createState() => _BillsTabState();
}

class _BillsTabState extends State<BillsTab> with WidgetsBindingObserver {
  late String _statusFilter;
  String _collectionManFilter = 'All';
  String _searchQuery = '';
  bool _isSearching = false;
  final TextEditingController _searchCtrl = TextEditingController();
  bool _isAccessibilityEnabled = false;

  static const int _manualSendTimeoutSeconds = 15;

  bool _isSingleSending = false;
  Customer? _singleSendingCustomer;
  String _singleSendMode = 'none'; // 'none', 'bill', or 'receipt'
  StreamSubscription<bool>? _singleSendSubscription;
  Timer? _singleSendTimeout;

  Timer? _debounce;
  
  // Caches
  List<Customer> _cachedFilteredCustomers = [];
  int _allCount = 0;
  int _pendingBillsCount = 0;
  int _failedBillsCount = 0;
  int _sentBillsCount = 0;
  List<String> _cmNames = ['All'];


  @override
  void initState() {
    super.initState();
    _statusFilter = widget.initialFilter ?? 'All';
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibility();
    _calculateData();
    widget.excelService.addListener(_calculateData);
  }

  void _cleanupSingleSend() {
    _singleSendTimeout?.cancel();
    _singleSendTimeout = null;
    _singleSendSubscription?.cancel();
    _singleSendSubscription = null;
    _singleSendingCustomer = null;
    _singleSendMode = 'none';
    if (AccessibilityService.activeSendingMode == 'receipt' || AccessibilityService.activeSendingMode == 'bill') {
      AccessibilityService.activeSendingMode = 'none';
    }
    if (mounted && _isSingleSending) {
      setState(() { 
        _isSingleSending = false; 
      });
    }
  }

  @override
  void dispose() {
    widget.excelService.removeListener(_calculateData);
    _cleanupSingleSend();
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibility();
      if (_isSingleSending && _singleSendingCustomer != null) {
        final targetCustomer = _singleSendingCustomer!;
        final sendMode = _singleSendMode;
        Future.delayed(const Duration(milliseconds: 1000), () {
          if (mounted && _isSingleSending) {
            _cleanupSingleSend();
            if (sendMode == 'bill') {
              _showBillSentConfirmation(targetCustomer);
            } else {
              _showReceiptSentConfirmation(targetCustomer);
            }
          }
        });
      }
    }
  }

  Future<void> _showBillSentConfirmation(Customer customer) async {
    if (!mounted || customer.status == 'Sent' || customer.status == 'Message Sent') return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: const Text('Bill Status', style: TextStyle(color: Colors.white)),
        content: Text(
          'Did you send the bill for ${customer.custName.isNotEmpty ? customer.custName : customer.mobile} in WhatsApp?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No / Cancelled', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
            child: const Text('Yes, Sent', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    final ledger = TransactionLedger();
    await ledger.initialize();
    final period = customer.monthNm.isNotEmpty ? customer.monthNm : DateTime.now().toIso8601String().substring(0, 7);
    final billId = customer.billNo.isNotEmpty ? customer.billNo : 'BILL_${customer.custNo}';
    final tx = await ledger.stageTransaction(
      customer: customer,
      billId: billId,
      billingPeriod: period,
    );

    if (result == true && mounted) {
      await ledger.markConfirmed(tx.transactionId, diagnosticNote: "Manual send confirmed by vendor");
      setState(() {
        customer.status = 'Sent';
        customer.sentTime = DateTime.now().toIso8601String();
      });
      await widget.excelService.saveCustomers();
      await CooldownService().recordMessageSent();
      _calculateData();
    } else if (result == false && mounted) {
      await ledger.markUncertain(tx.transactionId, reason: "Manual send marked cancelled or not sent by vendor");
    }
  }

  Future<void> _showReceiptSentConfirmation(Customer customer) async {
    if (!mounted || customer.receiptStatus == 'Sent') return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: const Text('Receipt Status', style: TextStyle(color: Colors.white)),
        content: Text(
          'Did you send the receipt for ${customer.custName.isNotEmpty ? customer.custName : customer.mobile} in WhatsApp?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No / Cancelled', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
            child: const Text('Yes, Sent', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      setState(() {
        customer.receiptStatus = 'Sent';
        customer.sentTime = DateTime.now().toIso8601String();
      });
      await widget.excelService.saveCustomers();
      _calculateData();
    }
  }

  void _checkAccessibility() async {
    bool enabled = await AccessibilityService.isEnabled();
    if (mounted) {
      setState(() {
        _isAccessibilityEnabled = enabled;
      });
    }
  }

  @override
  void didUpdateWidget(BillsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.navKey != oldWidget.navKey) {
      if (widget.initialFilter != null) {
        _statusFilter = widget.initialFilter!;
        _calculateData();
      }
    }
  }

  void _calculateData() {
    List<Customer> allCustomers = widget.excelService.allCustomers;
    
    // Tab Counts
    int pending = 0;
    int failed = 0;
    int sent = 0;
    
    Set<String> cmSet = {'All'};

    for (var c in allCustomers) {
      String st = c.status.trim().toLowerCase();
      
      if (st == 'pending' || st == 'waiting' || st == 'processing') pending++;
      if (st == 'failed') failed++;
      if (st == 'sent' || st == 'message sent') sent++;
      
      if (c.cmName.isNotEmpty) cmSet.add(c.cmName);
    }
    
    // Now filter list
    List<Customer> result = allCustomers;
    if (_statusFilter != 'All') {
      result = result.where((c) {
        String st = c.status.trim().toLowerCase();
        String pst = c.paymentStatus.trim().toLowerCase();
        String rst = c.receiptStatus.trim().toLowerCase();
        if (_statusFilter == 'Pending Bills') return st == 'pending' || st == 'waiting' || st == 'processing';
        if (_statusFilter == 'Sent Bills') return st == 'sent' || st == 'message sent';
        if (_statusFilter == 'Failed Bills') return st == 'failed';
        if (_statusFilter == 'Unpaid Bills') return pst != 'successful' && !pst.contains('success') && pst != 'paid';
        if (_statusFilter == 'Receipts Pending') return (pst == 'successful' || pst.contains('success') || pst == 'paid') && rst != 'sent';
        return true;
      }).toList();
    }
    if (_collectionManFilter != 'All') {
      result = result.where((c) => c.cmName == _collectionManFilter).toList();
    }
    if (_searchQuery.isNotEmpty) {
      String q = _searchQuery.toLowerCase().trim();
      result = result.where((c) => c.billNo.toLowerCase().contains(q)).toList();
    }
    
    if (mounted) {
      setState(() {
        _allCount = allCustomers.length;
        _pendingBillsCount = pending;
        _failedBillsCount = failed;
        _sentBillsCount = sent;
        _cmNames = cmSet.toList();
        
        if (!_cmNames.contains(_collectionManFilter)) {
          _collectionManFilter = 'All';
        }
        
        _cachedFilteredCustomers = result;
      });
    }
  }

  void _onSearchChanged(String val) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    if (val.isEmpty) {
      _searchQuery = '';
      _calculateData();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchQuery = val;
      _calculateData();
    });
  }

  void _onSearchSubmitted(String val) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _searchQuery = val;
    _calculateData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        title: _isSearching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Search Bill No...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                onChanged: _onSearchChanged,
                onSubmitted: _onSearchSubmitted,
              )
            : const Text('Bills', style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: false,
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              if (_debounce?.isActive ?? false) _debounce!.cancel();
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchCtrl.clear();
                  _searchQuery = '';
                  _calculateData();
                }
              });
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: const Color(0xFF161B22),
            onSelected: (val) {
              if (val == 'Refresh') {
                setState(() {});
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                const PopupMenuItem<String>(
                  value: 'Refresh',
                  child: Text('Refresh Customers', style: TextStyle(color: Colors.white)),
                ),
              ];
            },
          ),
        ],
      ),
      body: Column(
            children: [
          // Filter Tabs
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _buildFilterTab('All', _allCount, const Color(0xFF00E676)),
                const SizedBox(width: 8),
                _buildFilterTab('Pending Bills', _pendingBillsCount, Colors.orangeAccent),
                const SizedBox(width: 8),
                _buildFilterTab('Failed Bills', _failedBillsCount, Colors.redAccent),
                const SizedBox(width: 8),
                _buildFilterTab('Sent Bills', _sentBillsCount, Colors.blueAccent),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),

          // Collection Man Dropdown
          if (_cmNames.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Text('Collection Man: ', style: TextStyle(color: Colors.grey)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      value: _collectionManFilter,
                      isExpanded: true,
                      dropdownColor: Theme.of(context).cardColor,
                      underline: Container(),
                      items: _cmNames.map((name) {
                        return DropdownMenuItem<String>(
                          value: name,
                          child: Text(name, style: const TextStyle(color: Colors.white)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _collectionManFilter = val);
                          _calculateData();
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1, color: Colors.white12),

          // Accessibility Warning
          if (!_isAccessibilityEnabled)
            Container(
              color: Colors.red.withValues(alpha: 0.2),
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.red),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Accessibility is disabled. You cannot send messages.',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await AccessibilityService.showGuidanceDialog(context);
                      bool check = await AccessibilityService.isEnabled();
                      if (mounted) setState(() { _isAccessibilityEnabled = check; });
                    },
                    child: const Text('ENABLE'),
                  ),
                ],
              ),
            ),
            

          
          // Queue List
          Expanded(
            child: _cachedFilteredCustomers.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.inbox_outlined, size: 80, color: Colors.grey.withValues(alpha: 0.3)),
                        const SizedBox(height: 16),
                        const Text('No customers found', style: TextStyle(fontSize: 18, color: Colors.grey)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _cachedFilteredCustomers.length,
                    itemBuilder: (context, index) {
                      Customer customer = _cachedFilteredCustomers[index];
                      return _buildCustomerItem(context, customer, index + 1);
                    },
                  ),
          ),
        ],
      ),
    floatingActionButton: CooldownFab(
      iconData: Icons.send,
      label: 'Send Bills',
      baseColor: const Color(0xFF00E676),
      onCooldownAction: () => _showCooldownDialog(context),
      onNormalAction: () {
        if (_isAccessibilityEnabled) {
          _runPreflightChecks(context);
        } else {
          AccessibilityService.showGuidanceDialog(context).then((_) async {
            bool check = await AccessibilityService.isEnabled();
            if (mounted) setState(() { _isAccessibilityEnabled = check; });
          });
        }
      },
    ),
    );
  }

  void _showCooldownDialog(BuildContext context) async {
    Duration remaining = await CooldownService().getRemainingCooldown();
    int configuredMinutes = await CooldownService().getCooldownDurationMinutes();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.timer_outlined, color: Colors.orange),
            SizedBox(width: 8),
            Text('Cooldown Active', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A safety cooldown pause of $configuredMinutes min is active to protect your WhatsApp account from rate limiting.',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.hourglass_top, color: Colors.orangeAccent, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Time remaining: ${CooldownService.formatDuration(remaining)}',
                    style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await CooldownService().clearCooldown();
              if (c.mounted) {
                Navigator.pop(c);
              }
              if (context.mounted) {
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cooldown reset. You can resume sending.')),
                );
              }
            },
            child: const Text('Reset Cooldown', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(c),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
            child: const Text('OK', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterTab(String label, int count, Color activeColor) {
    bool isSelected = _statusFilter == label;
    return GestureDetector(
      onTap: () {
        setState(() {
          _statusFilter = label;
        });
        _calculateData();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ($count)',
            style: TextStyle(
              color: isSelected ? activeColor : Colors.grey,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 4),
          if (isSelected)
            Container(
              height: 2,
              width: 40,
              color: activeColor,
            ),
        ],
      ),
    );
  }

  Widget _buildCustomerItem(BuildContext context, Customer customer, int index) {
    Color billStatusColor = Colors.grey;
    String st = customer.status.trim().toLowerCase();
    if (st == 'sent' || st == 'message sent') {
      billStatusColor = const Color(0xFF00E676);
    } else if (st == 'failed') {
      billStatusColor = Colors.red;
    } else if (st == 'pending' || st == 'waiting' || st == 'processing') {
      billStatusColor = Colors.orange;
    }

    Color receiptStatusColor = Colors.grey;
    String receiptText = '';
    String rst = customer.receiptStatus.trim().toLowerCase();
    if (customer.isPaid) {
      if (rst == 'sent') {
        receiptStatusColor = const Color(0xFF00E676);
        receiptText = 'Receipt Sent';
      } else {
        receiptStatusColor = Colors.blue;
        receiptText = 'Receipt Pending';
      }
    } else {
      receiptText = 'Unpaid';
      receiptStatusColor = Colors.orangeAccent;
    }

    Widget buildBadge(String text, Color color) {
      return Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      );
    }

    return Dismissible(
      key: Key('customer_${customer.mobile}_$index'),
      background: Container(
        color: const Color(0xFF00E676),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 24),
        child: const Icon(Icons.payment, color: Colors.black, size: 32),
      ),
      secondaryBackground: Container(
        color: const Color(0xFF25D366),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.send, color: Colors.white, size: 32),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          if (!customer.isPaid) {
            _showPaymentDialog(context, customer);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Already marked as paid')));
          }
          return false;
        } else if (direction == DismissDirection.endToStart) {
          _sendSingleBillToWhatsApp(context, customer);
          return false;
        }
        return false;
      },
      child: InkWell(
        onTap: () => _showCustomerTimelineCard(context, customer),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    index.toString(),
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontWeight: FontWeight.bold, fontSize: 14),
                    maxLines: 1,
                  ),
                ),
              ),
              const CircleAvatar(
                backgroundColor: Colors.white12,
                radius: 20,
                child: Icon(Icons.person, color: Colors.white54, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      customer.custName.isNotEmpty ? customer.custName : 'Unknown Contact',
                      style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        buildBadge('Bill: ${customer.status}', billStatusColor),
                        buildBadge(receiptText, receiptStatusColor),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text((value == null || value.isEmpty) ? '-' : value, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showCustomerTimelineCard(BuildContext context, Customer customer) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 24,
            right: 24,
            top: 32,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: Name and Mobile
              Text(
                customer.custName.isEmpty ? 'Unknown Contact' : customer.custName,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 6),
              Text(customer.mobile, style: const TextStyle(fontSize: 16, color: Colors.grey)),
              const SizedBox(height: 32),

              // Timeline
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTimelineNode(
                    title: 'Bill',
                    status: customer.status.isEmpty ? 'Pending' : customer.status,
                    isSuccess: customer.status == 'Sent',
                    isFailed: customer.status == 'Failed',
                  ),
                  _buildTimelineLine(isActive: customer.status == 'Sent'),
                  _buildTimelineNode(
                    title: 'Payment',
                    status: customer.paymentStatus.isNotEmpty ? customer.paymentStatus : 'Unpaid',
                    isSuccess: customer.isPaid,
                    isFailed: false,
                  ),
                  _buildTimelineLine(isActive: customer.isPaid),
                  _buildTimelineNode(
                    title: 'Receipt',
                    status: (customer.receiptStatus.isEmpty && !customer.isPaid) ? '-' : (customer.receiptStatus.isEmpty ? 'Pending' : customer.receiptStatus),
                    isSuccess: customer.receiptStatus == 'Sent',
                    isFailed: customer.receiptStatus == 'Failed',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Divider(color: Colors.white12),
              
              // Scrollable Details
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 16),
                      _buildDetailRow('Customer No', customer.custNo),
                      _buildDetailRow('Bill No', customer.billNo),
                      _buildDetailRow('Bill Amount', customer.billAmount),
                      _buildDetailRow('Cl Balance', customer.clBalance),
                      _buildDetailRow('Collection Man', '${customer.cmCode} - ${customer.cmName}'),
                      _buildDetailRow('Month', customer.monthNm),
                      _buildDetailRow('Vouch Date', customer.vouchDate),
                      _buildDetailRow('Yes/No', customer.yesNo),
                      const Divider(color: Colors.white12, height: 24),
                      if (customer.status == 'Sent') _buildDetailRow('Sent Time', customer.sentTime),
                      if (customer.status == 'Failed') _buildDetailRow('Error', customer.lastError),
                      if (customer.isPaid) ...[
                        _buildDetailRow('Amount Paid', customer.amountPaid),
                        _buildDetailRow('Transaction ID', customer.transactionId),
                        _buildDetailRow('Payment Method', customer.paymentMethod),
                      ],
                      const Divider(color: Colors.white12, height: 24),
                      _buildDetailRow('Image Path', customer.resolvedImagePath),
                      const SizedBox(height: 12),
                      if (customer.resolvedImagePath.isNotEmpty)
                        Builder(builder: (context) {
                          bool exists = false;
                          try {
                            exists = File(customer.resolvedImagePath).existsSync();
                          } catch (_) {}
                          
                          if (exists) {
                            File file = File(customer.resolvedImagePath);
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: MediaQuery.of(context).size.width,
                                child: Image.file(file, height: 150, fit: BoxFit.cover, errorBuilder: (c, e, s) {
                                  return const Center(child: Text('Corrupt image file', style: TextStyle(color: Colors.grey)));
                                }),
                              ),
                            );
                          } else {
                            return const Center(
                              child: Column(
                                children: [
                                  Icon(Icons.image_not_supported, color: Colors.grey, size: 40),
                                  SizedBox(height: 8),
                                  Text('Image not found', style: TextStyle(color: Colors.grey)),
                                ],
                              ),
                            );
                          }
                        }),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),

              // Actions
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.flash_on, color: Colors.black),
                  onPressed: () {
                    Navigator.pop(context);
                    _sendSingleBillToWhatsApp(context, customer, manualFallback: false);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                  ),
                  label: const Text(
                    'Auto-Send Bill (1-Tap)',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.touch_app_outlined, color: Color(0xFF25D366)),
                  onPressed: () {
                    Navigator.pop(context);
                    _sendSingleBillToWhatsApp(context, customer, manualFallback: true);
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF25D366)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  label: const Text(
                    'Send Manually (Fallback)',
                    style: TextStyle(
                      color: Color(0xFF25D366),
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.print, color: Colors.white),
                  onPressed: () async {
                    Navigator.pop(context);
                    await PrintService().printBill(customer: customer, settingsService: widget.settingsService);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                  ),
                  label: const Text(
                    'Print Bill',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  void _sendSingleBillToWhatsApp(BuildContext context, Customer customer, {bool manualFallback = false}) async {
    if (_isSingleSending) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A bill is already being sent. Please wait.')),
        );
      }
      return;
    }

    // Validate phone number
    if (customer.mobile.isEmpty || customer.mobile.length < 10) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No phone number — this customer is cash-only. Use "Mark Payment" to record payment directly.')),
        );
      }
      return;
    }

    // Validate image exists
    String imagePath = customer.resolvedImagePath;
    bool imageExists = false;
    if (imagePath.isNotEmpty) {
      try {
        imageExists = File(imagePath).existsSync();
      } catch (_) {}
    }

    if (!imageExists) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bill image not found for this customer.')),
        );
      }
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    bool useBusinessApp = await widget.settingsService.getUseWhatsAppBusiness();
    final ledger = TransactionLedger();
    await ledger.initialize();
    final period = customer.monthNm.isNotEmpty ? customer.monthNm : DateTime.now().toIso8601String().substring(0, 7);
    final billId = customer.billNo.isNotEmpty ? customer.billNo : 'BILL_${customer.custNo}';

    // ── MANUAL FALLBACK FLOW ──
    if (manualFallback) {
      await AccessibilityService.setAutoSendMode(false);
      AccessibilityService.activeSendingMode = 'none';

      _cleanupSingleSend();
      _singleSendingCustomer = customer;
      _singleSendMode = 'bill';
      setState(() { _isSingleSending = true; });

      try {
        await WhatsAppService.sendImage(
          mobile: customer.mobile,
          imagePath: imagePath,
          useBusinessApp: useBusinessApp,
        );

        _singleSendTimeout = Timer(const Duration(seconds: _manualSendTimeoutSeconds), () {
          _cleanupSingleSend();
        });

        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('Opened WhatsApp for ${customer.custName.isNotEmpty ? customer.custName : customer.mobile}. Send manually and return.')),
          );
        }
      } catch (e) {
        _cleanupSingleSend();
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text('Failed to open WhatsApp: $e')),
          );
        }
      }
      return;
    }

    // ── AUTO-SEND FLOW ──
    bool isAccessible = await AccessibilityService.isEnabled();
    if (!isAccessible) {
      if (context.mounted) {
        bool? enable = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Theme.of(ctx).cardColor,
            title: const Text('Accessibility Disabled', style: TextStyle(color: Colors.white)),
            content: const Text(
              'Auto-send requires the Accessibility Service. Would you like to enable it now, or send manually?',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Send Manually', style: TextStyle(color: Colors.orange)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
                child: const Text('Enable Accessibility', style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
        );
        if (enable == true) {
          await AccessibilityService.showGuidanceDialog(context);
          return;
        } else if (enable == false) {
          _sendSingleBillToWhatsApp(context, customer, manualFallback: true);
          return;
        } else {
          return;
        }
      }
    }

    // Stage transaction in ledger
    final tx = await ledger.stageTransaction(
      customer: customer,
      billId: billId,
      billingPeriod: period,
    );
    await ledger.markInFlight(tx.transactionId);

    _cleanupSingleSend();
    _singleSendingCustomer = customer;
    _singleSendMode = 'bill';
    setState(() { _isSingleSending = true; });

    // Enable auto-send with transaction metadata
    await AccessibilityService.setAutoSendMode(
      true,
      transactionId: tx.transactionId,
      customerName: customer.custName,
      customerPhone: customer.mobile,
    );
    AccessibilityService.activeSendingMode = 'bill';

    StreamSubscription<AccessibilityTransactionEvent>? txSub;
    StreamSubscription<AccessibilityTransactionEvent>? failSub;
    StreamSubscription<AccessibilityTransactionEvent>? cbSub;

    void cleanupListeners() {
      txSub?.cancel();
      failSub?.cancel();
      cbSub?.cancel();
      _cleanupSingleSend();
      AccessibilityService.setAutoSendMode(false);
      AccessibilityService.activeSendingMode = 'none';
    }

    txSub = AccessibilityService.onTransactionConfirmed.listen((event) async {
      if (event.transactionId == tx.transactionId) {
        cleanupListeners();
        await ledger.markConfirmed(tx.transactionId);
        if (mounted) {
          setState(() {
            customer.status = "Sent";
            customer.sentTime = DateTime.now().toIso8601String();
          });
          await widget.excelService.saveCustomers();
          await CooldownService().recordMessageSent();
          _calculateData();
          messenger.showSnackBar(
            SnackBar(
              content: Text('Bill sent to ${customer.custName.isNotEmpty ? customer.custName : customer.mobile}!'),
              backgroundColor: const Color(0xFF00E676),
            ),
          );
        }
      }
    });

    failSub = AccessibilityService.onTransactionFailed.listen((event) async {
      if (event.transactionId == tx.transactionId) {
        cleanupListeners();
        await ledger.markFailed(tx.transactionId, error: event.reason ?? "Send failed");
        if (mounted) {
          setState(() {
            customer.status = "Failed";
            customer.lastError = event.reason ?? "Send failed";
          });
          await widget.excelService.saveCustomers();
          _calculateData();
          messenger.showSnackBar(
            SnackBar(
              content: Text('Send failed: ${event.reason}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    });

    cbSub = AccessibilityService.onCircuitBreakerTripped.listen((event) async {
      cleanupListeners();
      await ledger.markUncertain(tx.transactionId, reason: event.reason ?? "Circuit breaker tripped");
      if (mounted) {
        _calculateData();
        messenger.showSnackBar(
          SnackBar(
            content: Text('Safety alert: ${event.reason}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });

    try {
      await WhatsAppService.sendImage(
        mobile: customer.mobile,
        imagePath: imagePath,
        useBusinessApp: useBusinessApp,
      );

      _singleSendTimeout = Timer(const Duration(seconds: _manualSendTimeoutSeconds), () {
        cleanupListeners();
      });
    } catch (e) {
      cleanupListeners();
      await ledger.markFailed(tx.transactionId, error: e.toString());
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to launch WhatsApp: $e')),
        );
      }
    }
  }

  Widget _buildTimelineNode({required String title, required String status, required bool isSuccess, required bool isFailed}) {
    Color color = isSuccess ? const Color(0xFF00E676) : (isFailed ? Colors.red : Colors.grey);
    IconData icon = isSuccess ? Icons.check_circle : (isFailed ? Icons.error : Icons.radio_button_unchecked);
    return Expanded(
      flex: 2,
      child: Column(
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          Text(status, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildTimelineLine({required bool isActive}) {
    return Expanded(
      flex: 3,
      child: Container(
        margin: const EdgeInsets.only(top: 16),
        height: 2,
        color: isActive ? const Color(0xFF00E676) : Colors.grey.withValues(alpha: 0.2),
      ),
    );
  }

  void _showPaymentDialog(BuildContext context, Customer customer) {
    TextEditingController amountCtrl = TextEditingController(text: customer.billAmount);
    TextEditingController txCtrl = TextEditingController();
    String paymentMethod = 'Online';
    DateTime paymentDate = DateTime.now();
    
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Theme.of(context).cardColor,
              title: const Text('Mark Payment Successful', style: TextStyle(color: Colors.white)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: amountCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Amount Paid', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: txCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Transaction ID (Optional)', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: paymentMethod,
                      dropdownColor: Theme.of(context).cardColor,
                      decoration: const InputDecoration(labelText: 'Payment Method', labelStyle: TextStyle(color: Colors.grey)),
                      items: ['Online', 'Cash'].map((m) => DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(color: Colors.white)))).toList(),
                      onChanged: (val) {
                        if (val != null) setDialogState(() => paymentMethod = val);
                      },
                    ),
                    const SizedBox(height: 16),
                    InkWell(
                      onTap: () async {
                        DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: paymentDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) {
                          setDialogState(() => paymentDate = picked);
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Payment Date',
                          labelStyle: TextStyle(color: Colors.grey),
                        ),
                        child: Text(
                          "${paymentDate.day.toString().padLeft(2, '0')}/${paymentDate.month.toString().padLeft(2, '0')}/${paymentDate.year}",
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white30),
                  ),
                  onPressed: () async {
                    setState(() {
                      customer.paymentStatus = PaymentStatusHelper.successful;
                      customer.amountPaid = amountCtrl.text;
                      customer.transactionId = txCtrl.text;
                      customer.paymentMethod = paymentMethod;
                      customer.paymentDate = "${paymentDate.day.toString().padLeft(2, '0')}/${paymentDate.month.toString().padLeft(2, '0')}/${paymentDate.year}";
                      if (customer.receiptNo.isEmpty) {
                        customer.receiptNo = ReceiptService.generateReceiptNo(widget.excelService.allCustomers);
                      }
                    });
                    await widget.excelService.saveCustomers();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Save', style: TextStyle(color: Colors.white)),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                  icon: const Icon(Icons.send_rounded, color: Colors.black, size: 18),
                  onPressed: () async {
                    final amount = amountCtrl.text.trim();
                    final txId = txCtrl.text.trim();
                    final method = paymentMethod;
                    final date = paymentDate;

                    Navigator.pop(context);
                    await _handleSaveAndSendReceipt(customer, amount, txId, method, date);
                  },
                  label: const Text('Save & Send', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          }
        );
      }
    );
  }

  Future<void> _handleSaveAndSendReceipt(
    Customer customer,
    String amount,
    String txId,
    String paymentMethod,
    DateTime paymentDate,
  ) async {
    // 1. Update customer payment fields immediately
    final formattedDate = "${paymentDate.day.toString().padLeft(2, '0')}/${paymentDate.month.toString().padLeft(2, '0')}/${paymentDate.year}";
    setState(() {
      customer.paymentStatus = PaymentStatusHelper.successful;
      customer.amountPaid = amount.isNotEmpty ? amount : customer.billAmount;
      customer.transactionId = txId;
      customer.paymentMethod = paymentMethod;
      customer.paymentDate = formattedDate;
      if (customer.receiptNo.isEmpty) {
        customer.receiptNo = ReceiptService.generateReceiptNo(widget.excelService.allCustomers);
      }
    });

    await widget.excelService.saveCustomers();
    _calculateData();

    // 2. Validate phone number
    String cleanMobile = customer.mobile.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanMobile.length < 10) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment saved, but customer has no valid 10-digit mobile to send receipt.')),
        );
      }
      return;
    }

    // 3. Show progress notice
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Generating receipt for ${customer.custName.isNotEmpty ? customer.custName : customer.mobile}...'),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    try {
      // 4. Generate Receipt Image
      final businessName = LicenseService().getBusinessName();
      final receiptPath = await ReceiptService.generateReceiptImageFile(customer, businessName);

      // 5. Setup single send state & WhatsApp launcher
      _cleanupSingleSend();
      _singleSendingCustomer = customer;
      setState(() {
        _isSingleSending = true;
      });

      AccessibilityService.activeSendingMode = 'receipt';
      if (_isAccessibilityEnabled) {
        await AccessibilityService.setAutoSendMode(true);
      }

      _singleSendSubscription = AccessibilityService.onMessageSent.listen((_) async {
        if (AccessibilityService.activeSendingMode == 'receipt') {
          _cleanupSingleSend();
          if (mounted) {
            setState(() {
              customer.receiptStatus = 'Sent';
              customer.sentTime = DateTime.now().toIso8601String();
            });
            await widget.excelService.saveCustomers();
            _calculateData();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Receipt sent to ${customer.custName.isNotEmpty ? customer.custName : customer.mobile}')),
            );
          }
        }
      });

      bool useBusiness = await widget.settingsService.getUseWhatsAppBusiness();
      await WhatsAppService.sendImage(
        mobile: customer.mobile,
        imagePath: receiptPath,
        useBusinessApp: useBusiness,
      );

      _singleSendTimeout = Timer(const Duration(seconds: _manualSendTimeoutSeconds), () {
        _cleanupSingleSend();
      });
    } catch (e) {
      _cleanupSingleSend();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to generate or send receipt: $e')),
        );
      }
    }
  }

  void _runPreflightChecks(BuildContext context) async {
    List<Customer> pendingQueue = _cachedFilteredCustomers
        .where((c) {
          String st = c.status.toLowerCase();
          if (_statusFilter == 'Failed Bills') return st == 'failed';
          return st == 'pending' || st == 'waiting';
        })
        .toList();

    if (pendingQueue.isEmpty) {
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange),
              SizedBox(width: 8),
              Text('Nothing to Send', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Text(
            _statusFilter == 'Failed Bills'
                ? 'There are no failed bills in the current filter list.'
                : 'There are no pending bills in the current filter list.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK', style: TextStyle(color: Color(0xFF00E676)))),
          ],
        ),
      );
      return;
    }

    int missingPhone = 0;
    int missingImage = 0;

    for (var c in pendingQueue) {
      if (c.mobile.isEmpty || c.mobile.length < 10) missingPhone++;
      bool imageExists = false;
      if (c.resolvedImagePath.isNotEmpty) {
        try {
          imageExists = File(c.resolvedImagePath).existsSync();
        } catch (_) {}
      }
      if (!imageExists) missingImage++;
    }

    if (missingPhone > 0 || missingImage > 0) {
      bool? proceed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: const Row(
            children: [
              Icon(Icons.error_outline, color: Colors.red),
              SizedBox(width: 8),
              Text('Smart Warning', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('We detected missing data in your pending list:', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              if (missingPhone > 0)
                Text('• $missingPhone customers have invalid/missing phone numbers.', style: const TextStyle(color: Colors.orange)),
              if (missingImage > 0)
                Text('• $missingImage customers have missing image files.', style: const TextStyle(color: Colors.orange)),
              const SizedBox(height: 16),
              const Text('Do you want to continue sending to the others?', style: TextStyle(color: Colors.white)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(c, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Continue Anyway', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    if (context.mounted) {
      _showStartOptions(context);
    }
  }

  void _showStartOptions(BuildContext context) async {
    int defaultLimit = await widget.settingsService.getDefaultSendLimit();
    int remainingQuota = await CooldownService().getRemainingQuota();
    int currentDelaySeconds = await widget.settingsService.getInterBillDelaySeconds();
    int currentCooldownMinutes = await CooldownService().getCooldownDurationMinutes();
    if (defaultLimit > remainingQuota && remainingQuota > 0) {
      defaultLimit = remainingQuota;
    }

    // Pending count in current view
    int pendingCount = _cachedFilteredCustomers
        .where((c) {
          String st = c.status.toLowerCase();
          if (_statusFilter == 'Failed Bills') return st == 'failed';
          return st == 'pending' || st == 'waiting';
        })
        .length;

    int initialLimit = defaultLimit > 0 ? defaultLimit : (pendingCount > 0 ? (pendingCount < 5 ? pendingCount : 5) : 5);
    if (initialLimit > remainingQuota && remainingQuota > 0) {
      initialLimit = remainingQuota;
    }

    TextEditingController limitCtrl = TextEditingController(text: initialLimit.toString());
    bool setAsDefault = false;
    
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext bc) {
        int selectedDelay = currentDelaySeconds;
        int selectedCooldown = currentCooldownMinutes;

        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(bc).viewInsets.bottom + MediaQuery.of(bc).viewPadding.bottom + 16,
            left: 20,
            right: 20,
            top: 24,
          ),
          child: SafeArea(
            child: StatefulBuilder(
              builder: (context, setSheetState) {
                void selectPreset(int count) {
                  int target = count;
                  if (target > remainingQuota && remainingQuota > 0) target = remainingQuota;
                  setSheetState(() {
                    limitCtrl.text = target.toString();
                  });
                }

                int allTarget = pendingCount;
                if (allTarget > remainingQuota && remainingQuota > 0) allTarget = remainingQuota;

                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Select Batch Size',
                            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$pendingCount Pending',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Conservative delivery keeps sending stable. Remaining quota: $remainingQuota',
                        style: const TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                      const SizedBox(height: 14),

                      // Presets
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildPresetChip('Next 5', 5, limitCtrl, () => selectPreset(5)),
                          _buildPresetChip('Next 10', 10, limitCtrl, () => selectPreset(10)),
                          _buildPresetChip('Next 20', 20, limitCtrl, () => selectPreset(20)),
                          _buildPresetChip('All ($allTarget)', allTarget, limitCtrl, () => selectPreset(allTarget)),
                        ],
                      ),
                      const SizedBox(height: 12),

                      TextField(
                        controller: limitCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Custom Batch Limit (Max $remainingQuota)',
                          labelStyle: const TextStyle(color: Colors.grey),
                          enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00E676))),
                        ),
                        onChanged: (val) {
                          setSheetState(() {
                            int? parsed = int.tryParse(val);
                            if (parsed != null && parsed > remainingQuota && remainingQuota > 0) {
                              limitCtrl.text = remainingQuota.toString();
                              limitCtrl.selection = TextSelection.fromPosition(TextPosition(offset: limitCtrl.text.length));
                            }
                          });
                        },
                      ),

                      const SizedBox(height: 16),
                      const Divider(color: Colors.white12, height: 1),
                      const SizedBox(height: 16),

                      // ── Per-Image Send Timer (Min 3s floor, can only increase) ──
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.speed, color: Color(0xFF00E676), size: 16),
                                  SizedBox(width: 6),
                                  Text(
                                    'Per-Image Timer (Delay)',
                                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Min safe: 3s (Increase if WhatsApp flags)',
                                style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                              ),
                            ],
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove, size: 18),
                                  color: selectedDelay <= 3 ? Colors.grey.shade600 : Colors.white,
                                  padding: const EdgeInsets.all(4),
                                  constraints: const BoxConstraints(),
                                  tooltip: selectedDelay <= 3 ? 'Cannot decrease below 3s for safety' : 'Decrease',
                                  onPressed: selectedDelay <= 3
                                      ? null
                                      : () {
                                          setSheetState(() {
                                            if (selectedDelay > 3) selectedDelay--;
                                          });
                                        },
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  child: Text(
                                    '${selectedDelay}s',
                                    style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.add, size: 18),
                                  color: Colors.white,
                                  padding: const EdgeInsets.all(4),
                                  constraints: const BoxConstraints(),
                                  tooltip: 'Increase delay',
                                  onPressed: () {
                                    setSheetState(() {
                                      selectedDelay++;
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _buildTimerPresetChip('3s (Fastest)', 3, selectedDelay, () {
                            setSheetState(() => selectedDelay = 3);
                          }),
                          _buildTimerPresetChip('5s (Safe)', 5, selectedDelay, () {
                            setSheetState(() => selectedDelay = 5);
                          }),
                          _buildTimerPresetChip('8s (Extra Caution)', 8, selectedDelay, () {
                            setSheetState(() => selectedDelay = 8);
                          }),
                        ],
                      ),

                      const SizedBox(height: 16),
                      const Divider(color: Colors.white12, height: 1),
                      const SizedBox(height: 16),

                      // ── Batch Cooldown Duration (Can increase / decrease) ──
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.hourglass_top, color: Colors.orangeAccent, size: 16),
                                  SizedBox(width: 6),
                                  Text(
                                    'Cooldown Period',
                                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Pause between batches (Adjust up or down)',
                                style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                              ),
                            ],
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove, size: 18),
                                  color: selectedCooldown <= 5 ? Colors.grey.shade600 : Colors.white,
                                  padding: const EdgeInsets.all(4),
                                  constraints: const BoxConstraints(),
                                  tooltip: 'Decrease cooldown',
                                  onPressed: selectedCooldown <= 5
                                      ? null
                                      : () {
                                          setSheetState(() {
                                            if (selectedCooldown > 5) selectedCooldown -= 5;
                                          });
                                        },
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  child: Text(
                                    '${selectedCooldown}m',
                                    style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.add, size: 18),
                                  color: Colors.white,
                                  padding: const EdgeInsets.all(4),
                                  constraints: const BoxConstraints(),
                                  tooltip: 'Increase cooldown',
                                  onPressed: () {
                                    setSheetState(() {
                                      selectedCooldown += 5;
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _buildCooldownPresetChip('10 min', 10, selectedCooldown, () {
                            setSheetState(() => selectedCooldown = 10);
                          }),
                          _buildCooldownPresetChip('20 min', 20, selectedCooldown, () {
                            setSheetState(() => selectedCooldown = 20);
                          }),
                          _buildCooldownPresetChip('30 min', 30, selectedCooldown, () {
                            setSheetState(() => selectedCooldown = 30);
                          }),
                          _buildCooldownPresetChip('45 min', 45, selectedCooldown, () {
                            setSheetState(() => selectedCooldown = 45);
                          }),
                        ],
                      ),

                      const SizedBox(height: 12),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Set this limit as default', style: TextStyle(color: Colors.white70, fontSize: 14)),
                        value: setAsDefault,
                        activeColor: const Color(0xFF00E676),
                        checkColor: Colors.black,
                        onChanged: (val) {
                          setSheetState(() {
                            setAsDefault = val ?? false;
                          });
                        },
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.play_arrow, color: Colors.black),
                          label: const Text('Start Batch', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: limitCtrl.text.isEmpty ? Colors.grey.shade800 : const Color(0xFF00E676),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: limitCtrl.text.isEmpty ? null : () async {
                            int limit = int.tryParse(limitCtrl.text) ?? defaultLimit;
                            if (limit > remainingQuota && remainingQuota > 0) limit = remainingQuota;
                            
                            if (setAsDefault) {
                              await widget.settingsService.setDefaultSendLimit(limit);
                            }

                            // Persist user-selected timer and cooldown preferences
                            await widget.settingsService.setInterBillDelaySeconds(selectedDelay);
                            await CooldownService().setCooldownDurationMinutes(selectedCooldown);
                            
                            if (context.mounted) {
                              Navigator.pop(context);
                              _startSending(null, limit, delaySeconds: selectedDelay);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                );
              }
            ),
          ),
        );
      },
    );
  }

  Widget _buildPresetChip(String label, int value, TextEditingController controller, VoidCallback onTap) {
    bool isSelected = controller.text == value.toString();
    return ActionChip(
      label: Text(label),
      labelStyle: TextStyle(
        color: isSelected ? Colors.black : Colors.white,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 13,
      ),
      backgroundColor: isSelected ? const Color(0xFF00E676) : const Color(0xFF21262D),
      side: BorderSide(color: isSelected ? const Color(0xFF00E676) : Colors.white24),
      onPressed: onTap,
    );
  }

  Widget _buildTimerPresetChip(String label, int value, int selectedValue, VoidCallback onTap) {
    bool isSelected = selectedValue == value;
    return ActionChip(
      label: Text(label),
      labelStyle: TextStyle(
        color: isSelected ? Colors.black : Colors.white70,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 11,
      ),
      backgroundColor: isSelected ? const Color(0xFF00E676) : const Color(0xFF21262D),
      side: BorderSide(color: isSelected ? const Color(0xFF00E676) : Colors.white12),
      onPressed: onTap,
    );
  }

  Widget _buildCooldownPresetChip(String label, int value, int selectedValue, VoidCallback onTap) {
    bool isSelected = selectedValue == value;
    return ActionChip(
      label: Text(label),
      labelStyle: TextStyle(
        color: isSelected ? Colors.black : Colors.white70,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 11,
      ),
      backgroundColor: isSelected ? Colors.orangeAccent : const Color(0xFF21262D),
      side: BorderSide(color: isSelected ? Colors.orangeAccent : Colors.white12),
      onPressed: onTap,
    );
  }

  void _startSending(TimeOfDay? timeOfDay, int? limit, {int? delaySeconds}) async {
    bool isAccessible = await AccessibilityService.isEnabled();
    if (!isAccessible && mounted) {
      bool? proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: const Text('Auto-Sending Disabled', style: TextStyle(color: Colors.white)),
          content: const Text(
              'Accessibility is OFF. Messages will not send automatically. You will have to tap the send button manually in WhatsApp for each message.\n\nDo you want to continue anyway?',
              style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
              child: const Text('Continue', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    DateTime? scheduledStart;
    if (timeOfDay != null) {
      final now = DateTime.now();
      scheduledStart = DateTime(now.year, now.month, now.day, timeOfDay.hour, timeOfDay.minute);
      if (scheduledStart.isBefore(now)) {
        scheduledStart = scheduledStart.add(const Duration(days: 1));
      }
    }

    if (!mounted) return;

    // Use customers that are pending (or failed, if in Failed Bills tab) AND match the current Collection Man filter
    List<Customer> pendingQueue = _cachedFilteredCustomers
        .where((c) {
          String st = c.status.toLowerCase();
          if (_statusFilter == 'Failed Bills') return st == 'failed';
          return st == 'pending' || st == 'waiting';
        })
        .toList();

    if (limit != null && limit > 0 && pendingQueue.length > limit) {
      pendingQueue = pendingQueue.take(limit).toList();
    }

    if (!mounted) return;

    final summary = await Navigator.push<BatchSummary>(
      context,
      MaterialPageRoute(
        builder: (context) => SendingScreen(
          queue: pendingQueue,
          excelService: widget.excelService,
          scheduledStart: scheduledStart,
          delaySeconds: delaySeconds,
        ),
      ),
    );

    if (mounted) {
      _calculateData();
      if (summary != null && (summary.confirmed > 0 || summary.failed > 0 || summary.uncertain > 0 || summary.wasHalted)) {
        _showBatchSummaryDialog(context, summary);
      }
    }
  }

  void _showBatchSummaryDialog(BuildContext context, BatchSummary summary) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              summary.hasFailuresOrUncertain ? Icons.info_outline : Icons.check_circle_outline,
              color: summary.hasFailuresOrUncertain ? Colors.orange : const Color(0xFF00E676),
              size: 28,
            ),
            const SizedBox(width: 10),
            const Text('Batch Report', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (summary.wasHalted)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.shield_outlined, color: Colors.red, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Halted: ${summary.haltReason}',
                          style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
              _buildReportRow('Total in Batch', summary.totalQueued.toString(), Colors.white70),
              const Divider(color: Colors.white12, height: 16),
              _buildReportRow('Confirmed Sent', summary.confirmed.toString(), const Color(0xFF00E676)),
              const Divider(color: Colors.white12, height: 16),
              _buildReportRow('Failed', summary.failed.toString(), summary.failed > 0 ? Colors.red : Colors.white70),
              const Divider(color: Colors.white12, height: 16),
              _buildReportRow('Uncertain / Quarantined', summary.uncertain.toString(), summary.uncertain > 0 ? Colors.orange : Colors.white70),
              if (summary.skipped > 0) ...[
                const Divider(color: Colors.white12, height: 16),
                _buildReportRow('Skipped (Already Sent)', summary.skipped.toString(), Colors.grey),
              ],
              if (summary.uncertain > 0) ...[
                const SizedBox(height: 12),
                const Text(
                  'Note: Uncertain bills are quarantined in the ledger to avoid duplicates. You can review them in the list or send them manually.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (summary.failed > 0 || summary.uncertain > 0)
            TextButton(
              onPressed: () {
                Navigator.pop(c);
                setState(() {
                  _statusFilter = 'Failed Bills';
                });
                _calculateData();
              },
              child: const Text('View Issues', style: TextStyle(color: Colors.orange)),
            ),
          ElevatedButton(
            onPressed: () => Navigator.pop(c),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
            ),
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildReportRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
