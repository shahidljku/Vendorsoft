import 'dart:io';
import 'package:flutter/material.dart';
import 'sending_screen.dart';
import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/accessibility_service.dart';
import '../services/settings_service.dart';
import 'package:permission_handler/permission_handler.dart';

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
  bool _isBatteryOptimized = false;

  @override
  void initState() {
    super.initState();
    _statusFilter = widget.initialFilter ?? 'All';
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibility();
    }
  }

  void _checkAccessibility() async {
    bool enabled = await AccessibilityService.isEnabled();
    bool batteryOptimized = !(await Permission.ignoreBatteryOptimizations.isGranted);
    if (mounted) {
      setState(() {
        _isAccessibilityEnabled = enabled;
        _isBatteryOptimized = batteryOptimized;
      });
    }
  }

  @override
  void didUpdateWidget(BillsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.navKey != oldWidget.navKey) {
      if (widget.initialFilter != null) {
        setState(() {
          _statusFilter = widget.initialFilter!;
        });
      }
    }
  }

  List<Customer> get filteredCustomers {
    List<Customer> result = widget.excelService.allCustomers;
    if (_statusFilter != 'All') {
      result = result.where((c) {
        if (_statusFilter == 'Pending Bills') return c.status.toLowerCase() == 'pending' || c.status == 'Waiting';
        if (_statusFilter == 'Sent Bills') return c.status == 'Sent' || c.status == 'Message Sent';
        if (_statusFilter == 'Failed Bills') return c.status == 'Failed';
        if (_statusFilter == 'Unpaid Bills') return c.paymentStatus != 'Successful';
        if (_statusFilter == 'Receipts Pending') return c.paymentStatus == 'Successful' && c.receiptStatus != 'Sent';
        return true;
      }).toList();
    }
    if (_collectionManFilter != 'All') {
      result = result.where((c) => c.cmName == _collectionManFilter).toList();
    }
    if (_searchQuery.isNotEmpty) {
      String q = _searchQuery.toLowerCase().trim();
      if (q == 'unpaid') {
        result = result.where((c) => c.paymentStatus != 'Successful').toList();
      } else if (q == 'failed') {
        result = result.where((c) => c.status.toLowerCase() == 'failed').toList();
      } else if (q == 'pending') {
        result = result.where((c) => c.status.toLowerCase() == 'pending' || c.status == 'Waiting').toList();
      } else if (q == 'sent') {
        result = result.where((c) => c.status.toLowerCase() == 'sent' || c.receiptStatus.toLowerCase() == 'sent').toList();
      } else {
        result = result.where((c) => c.custName.toLowerCase().contains(q) || c.mobile.contains(q) || c.billNo.toLowerCase().contains(q)).toList();
      }
    }
    return result;
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
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Search Name/Mobile/Bill No...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              )
            : const Text('Bills', style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: false,
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchCtrl.clear();
                  _searchQuery = '';
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
      body: ListenableBuilder(
        listenable: widget.excelService,
        builder: (context, _) {
          List<Customer> customers = filteredCustomers;
          int allCount = widget.excelService.allCustomers.length;
          int pendingBillsCount = widget.excelService.allCustomers.where((c) => c.status.toLowerCase() == 'pending' || c.status == 'Waiting').length;
          int failedBillsCount = widget.excelService.allCustomers.where((c) => c.status == 'Failed').length;
          int sentBillsCount = widget.excelService.allCustomers.where((c) => c.status == 'Sent' || c.status == 'Message Sent').length;
          int unpaidCount = widget.excelService.allCustomers.where((c) => c.paymentStatus != 'Successful').length;
          int receiptPendingCount = widget.excelService.allCustomers.where((c) => c.paymentStatus == 'Successful' && c.receiptStatus != 'Sent').length;

          // Compute unique collection men
          Set<String> cmNames = {'All'};
          for (var c in widget.excelService.allCustomers) {
            if (c.cmName.isNotEmpty) cmNames.add(c.cmName);
          }
          if (!cmNames.contains(_collectionManFilter)) {
            // Delay resetting filter slightly to avoid build issues
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _collectionManFilter = 'All');
            });
          }

          return Column(
            children: [
          // Filter Tabs
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _buildFilterTab('All', allCount, const Color(0xFF00E676)),
                const SizedBox(width: 8),
                _buildFilterTab('Pending Bills', pendingBillsCount, Colors.orangeAccent),
                const SizedBox(width: 8),
                _buildFilterTab('Failed Bills', failedBillsCount, Colors.redAccent),
                const SizedBox(width: 8),
                _buildFilterTab('Sent Bills', sentBillsCount, Colors.blueAccent),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),

          // Collection Man Dropdown
          if (cmNames.length > 1)
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
                      items: cmNames.map((name) {
                        return DropdownMenuItem<String>(
                          value: name,
                          child: Text(name, style: const TextStyle(color: Colors.white)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => _collectionManFilter = val);
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
                    onPressed: () {
                      AccessibilityService.openSettings();
                    },
                    child: const Text('ENABLE'),
                  ),
                ],
              ),
            ),
            

          
          // Queue List
          Expanded(
            child: customers.isEmpty
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
                    itemCount: customers.length,
                    itemBuilder: (context, index) {
                      Customer customer = customers[index];
                      return _buildCustomerItem(context, customer, index + 1);
                    },
                  ),
          ),
        ],
      );
    }),
    floatingActionButton: FloatingActionButton.extended(
        onPressed: _isAccessibilityEnabled ? () {
          _runPreflightChecks(context);
        } : () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please enable accessibility first')),
          );
          AccessibilityService.openSettings();
        },
        backgroundColor: _isAccessibilityEnabled ? const Color(0xFF00E676) : Colors.grey,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.send),
        label: const Text('Send Bills'),
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
    if (customer.status == 'Sent') billStatusColor = const Color(0xFF00E676);
    else if (customer.status == 'Failed') billStatusColor = Colors.red;
    else if (customer.status.toLowerCase() == 'pending') billStatusColor = Colors.orange;

    Color receiptStatusColor = Colors.grey;
    String receiptText = '';
    if (customer.paymentStatus == 'Successful') {
      if (customer.receiptStatus == 'Sent') {
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
        color: Colors.blue,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.info_outline, color: Colors.white, size: 32),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          if (customer.paymentStatus != 'Successful') {
            _showPaymentDialog(context, customer);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Already marked as paid')));
          }
          return false;
        } else if (direction == DismissDirection.endToStart) {
          _showCustomerTimelineCard(context, customer);
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
                width: 24,
                child: Text(
                  index.toString(),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontWeight: FontWeight.bold),
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
                    Row(
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
                    isSuccess: customer.paymentStatus == 'Successful',
                    isFailed: false,
                  ),
                  _buildTimelineLine(isActive: customer.paymentStatus == 'Successful'),
                  _buildTimelineNode(
                    title: 'Receipt',
                    status: (customer.receiptStatus.isEmpty && customer.paymentStatus != 'Successful') ? '-' : (customer.receiptStatus.isEmpty ? 'Pending' : customer.receiptStatus),
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
                      if (customer.paymentStatus == 'Successful') ...[
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
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    if (customer.paymentStatus != 'Successful') {
                      _showPaymentDialog(context, customer);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: customer.paymentStatus == 'Successful' ? Colors.grey.withValues(alpha: 0.2) : const Color(0xFF00E676),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    elevation: 0,
                  ),
                  child: Text(
                    customer.paymentStatus == 'Successful' ? 'Payment Completed' : 'Mark as Paid', 
                    style: TextStyle(
                      color: customer.paymentStatus == 'Successful' ? Colors.white54 : Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              if (customer.status == 'Failed') ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      setState(() {
                        customer.status = 'Pending';
                        customer.lastError = '';
                      });
                      await widget.excelService.saveCustomers(widget.excelService.allCustomers);
                      if (context.mounted) Navigator.pop(context);
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.orange),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('Retry Sending Bill', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
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
                      value: paymentMethod,
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
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
                  onPressed: () async {
                    setState(() {
                      customer.paymentStatus = 'Successful';
                      customer.amountPaid = amountCtrl.text;
                      customer.transactionId = txCtrl.text;
                      customer.paymentMethod = paymentMethod;
                      customer.paymentDate = "${paymentDate.day.toString().padLeft(2, '0')}/${paymentDate.month.toString().padLeft(2, '0')}/${paymentDate.year}";
                    });
                    await widget.excelService.saveCustomers(widget.excelService.allCustomers);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Save', style: TextStyle(color: Colors.black)),
                ),
              ],
            );
          }
        );
      }
    );
  }

  void _runPreflightChecks(BuildContext context) async {
    List<Customer> pendingQueue = filteredCustomers
        .where((c) => c.status.toLowerCase() == 'pending' || c.status == 'waiting')
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
          content: const Text('There are no pending bills in the current filter list.', style: TextStyle(color: Colors.white70)),
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
    TextEditingController limitCtrl = TextEditingController(text: defaultLimit.toString());
    bool setAsDefault = false;
    
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      builder: (BuildContext bc) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(bc).viewInsets.bottom),
          child: SafeArea(
            child: StatefulBuilder(
              builder: (context, setSheetState) {
                return Wrap(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        controller: limitCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Send Limit (Required)',
                          labelStyle: TextStyle(color: Colors.grey),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00E676))),
                        ),
                        onChanged: (val) {
                          setSheetState(() {
                            int? parsed = int.tryParse(val);
                            if (parsed != null && parsed > 30) {
                              limitCtrl.text = '30';
                              limitCtrl.selection = TextSelection.fromPosition(const TextPosition(offset: 2));
                            }
                          });
                        },
                      ),
                    ),
                    CheckboxListTile(
                      title: const Text('Set this limit as default', style: TextStyle(color: Colors.white70)),
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
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: limitCtrl.text.isEmpty ? Colors.grey.shade800 : const Color(0xFF00E676),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListTile(
                        leading: Icon(Icons.play_arrow, color: limitCtrl.text.isEmpty ? Colors.grey : Colors.black),
                        title: Text('Start Now', style: TextStyle(color: limitCtrl.text.isEmpty ? Colors.grey : Colors.black, fontWeight: FontWeight.bold)),
                        onTap: limitCtrl.text.isEmpty ? null : () async {
                          int limit = int.tryParse(limitCtrl.text) ?? defaultLimit;
                          if (limit > 50) limit = 50;
                          
                          if (setAsDefault) {
                            await widget.settingsService.setDefaultSendLimit(limit);
                          }
                          
                          if (context.mounted) {
                            Navigator.pop(context);
                            _startSending(null, limit);
                          }
                        },
                      ),
                    ),
                  ],
                );
              }
            ),
          ),
        );
      },
    );
  }

  void _startSending(TimeOfDay? timeOfDay, int? limit) async {
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

    // Use customers that are pending AND match the current Collection Man filter
    List<Customer> pendingQueue = filteredCustomers
        .where((c) => c.status.toLowerCase() == 'pending' || c.status == 'waiting')
        .toList();

    if (limit != null && limit > 0 && pendingQueue.length > limit) {
      pendingQueue = pendingQueue.take(limit).toList();
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SendingScreen(
          queue: pendingQueue,
          excelService: widget.excelService,
          scheduledStart: scheduledStart,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }
}
