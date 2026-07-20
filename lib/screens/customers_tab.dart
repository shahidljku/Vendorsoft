import 'dart:io';
import 'package:flutter/material.dart';
import '../models/customer.dart';
import '../models/payment_status_helper.dart';
import '../services/excel_service.dart';
import '../services/accessibility_service.dart';
import '../services/settings_service.dart';
import '../services/license_service.dart';
import 'license_expired_screen.dart';

class CustomersTab extends StatefulWidget {
  final SettingsService settingsService;
  final ExcelService excelService;
  final String? initialFilter;
  final int navKey;

  const CustomersTab({
    super.key,
    required this.settingsService,
    required this.excelService,
    this.initialFilter,
    this.navKey = 0,
  });

  @override
  State<CustomersTab> createState() => _CustomersTabState();
}

class _CustomersTabState extends State<CustomersTab> with WidgetsBindingObserver {
  late String _statusFilter;
  String _collectionManFilter = 'All';
  String _searchQuery = '';
  bool _isSearching = false;
  final TextEditingController _searchCtrl = TextEditingController();
  bool _isAccessibilityEnabled = false;

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
    if (mounted) {
      setState(() {
        _isAccessibilityEnabled = enabled;
      });
    }
  }

  @override
  void didUpdateWidget(CustomersTab oldWidget) {
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
        String st = c.status.trim().toLowerCase();
        String rst = c.receiptStatus.trim().toLowerCase();
        if (_statusFilter == 'Pending Bills') return st == 'pending' || st == 'waiting' || st == 'processing';
        if (_statusFilter == 'Sent Bills') return st == 'sent' || st == 'message sent';
        if (_statusFilter == 'Failed Bills') return st == 'failed';
        if (_statusFilter == 'Unpaid Bills') return !c.isPaid;
        if (_statusFilter == 'Receipts Pending') return c.isPaid && rst != 'sent';
        return true;
      }).toList();
    }
    if (_collectionManFilter != 'All') {
      result = result.where((c) => c.cmName == _collectionManFilter).toList();
    }
    if (_searchQuery.isNotEmpty) {
      String q = _searchQuery.toLowerCase().trim();
      if (q == 'unpaid') {
        result = result.where((c) => !c.isPaid).toList();
      } else if (q == 'failed') {
        result = result.where((c) => c.status.trim().toLowerCase() == 'failed').toList();
      } else if (q == 'pending') {
        result = result.where((c) {
          String st = c.status.trim().toLowerCase();
          return st == 'pending' || st == 'waiting' || st == 'processing';
        }).toList();
      } else if (q == 'sent') {
        result = result.where((c) {
          String st = c.status.trim().toLowerCase();
          String rst = c.receiptStatus.trim().toLowerCase();
          return st == 'sent' || st == 'message sent' || rst == 'sent';
        }).toList();
      } else {
        result = result.where((c) => c.custName.toLowerCase().contains(q) || c.mobile.contains(q) || c.billNo.toLowerCase().contains(q)).toList();
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      /*
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddCustomerDialog(context),
        backgroundColor: const Color(0xFF00E676),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.person_add),
        label: const Text('Add Customer', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      */
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
            : const Text('Customers', style: TextStyle(fontWeight: FontWeight.w600)),
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
          int unpaidCount = widget.excelService.allCustomers.where((c) => !c.isPaid).length;
          int receiptPendingCount = widget.excelService.allCustomers.where((c) {
            String rst = c.receiptStatus.trim().toLowerCase();
            return c.isPaid && (rst != 'sent' && rst != 'message sent');
          }).length;

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
                _buildFilterTab('Unpaid Bills', unpaidCount, Colors.orange),
                const SizedBox(width: 8),
                _buildFilterTab('Receipts Pending', receiptPendingCount, Colors.blue),
                const SizedBox(width: 8),
                _buildFilterTab('Pending Bills', pendingBillsCount, Colors.orangeAccent),
                const SizedBox(width: 8),
                _buildFilterTab('Sent Bills', sentBillsCount, Colors.green),
                const SizedBox(width: 8),
                _buildFilterTab('Failed Bills', failedBillsCount, Colors.red),
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
        color: Colors.blue,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.info_outline, color: Colors.white, size: 32),
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
              /*
              IconButton(
                icon: const Icon(Icons.edit_outlined, color: Colors.white54, size: 20),
                tooltip: 'Edit Customer',
                onPressed: () => _showAddCustomerDialog(context, customer),
              ),
              */
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          customer.custName.isEmpty ? 'Unknown Contact' : customer.custName,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 6),
                        Text(customer.mobile, style: const TextStyle(fontSize: 16, color: Colors.grey)),
                      ],
                    ),
                  ),
                  /*
                  IconButton(
                    icon: const Icon(Icons.edit, color: Color(0xFF00E676), size: 28),
                    tooltip: 'Edit Customer Details',
                    onPressed: () {
                      Navigator.pop(context);
                      _showAddCustomerDialog(context, customer);
                    },
                  ),
                  */
                ],
              ),
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
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    if (!customer.isPaid) {
                      _showPaymentDialog(context, customer);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: customer.isPaid ? Colors.grey.withValues(alpha: 0.2) : const Color(0xFF00E676),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    elevation: 0,
                  ),
                  child: Text(
                    customer.isPaid ? 'Payment Completed' : 'Mark as Paid', 
                    style: TextStyle(
                      color: customer.isPaid ? Colors.white54 : Colors.black,
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
                      await widget.excelService.saveCustomers();
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
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
                  onPressed: () async {
                    setState(() {
                      customer.paymentStatus = PaymentStatusHelper.successful;
                      customer.amountPaid = amountCtrl.text;
                      customer.transactionId = txCtrl.text;
                      customer.paymentMethod = paymentMethod;
                      customer.paymentDate = "${paymentDate.day.toString().padLeft(2, '0')}/${paymentDate.month.toString().padLeft(2, '0')}/${paymentDate.year}";
                    });
                    await widget.excelService.saveCustomers();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Save', style: TextStyle(color: Colors.black)),
                ),
              ],
            );
          }
        );
      },
    );
  }

  // ignore: unused_element
  Future<void> _showAddCustomerDialog(BuildContext context, [Customer? existingCustomer]) async {
    // DEMO LIMIT DISABLED — uncomment to restore 50-customer cap
    // if (existingCustomer == null) {
    //   if (await LicenseService().isDemoMode() && widget.excelService.allCustomers.length >= 50) {
    //     if (!context.mounted) return;
    //     _showDemoLimitExpiredDialog(context);
    //     return;
    //   }
    // }

    final TextEditingController mobileCtrl = TextEditingController(text: existingCustomer?.mobile ?? '');
    final TextEditingController nameCtrl = TextEditingController(text: existingCustomer?.custName ?? '');
    final TextEditingController custNoCtrl = TextEditingController(text: existingCustomer?.custNo ?? '');
    final TextEditingController billNoCtrl = TextEditingController(text: existingCustomer?.billNo ?? '');
    final TextEditingController billAmountCtrl = TextEditingController(text: existingCustomer?.billAmount ?? '');
    final TextEditingController clBalanceCtrl = TextEditingController(text: existingCustomer?.clBalance ?? '');
    final TextEditingController messageCtrl = TextEditingController(text: existingCustomer?.message ?? '');

    // Load available agents (from Excel + Settings)
    Set<String> agentSet = {'All', 'UNKNOWN'};
    for (var c in widget.excelService.allCustomers) {
      if (c.cmName.isNotEmpty) agentSet.add(c.cmName);
    }
    List<String> savedAgents = await widget.settingsService.getSavedCollectionMen();
    for (var a in savedAgents) {
      agentSet.add(a);
    }
    List<String> agentList = agentSet.toList()..sort();
    String selectedAgent = existingCustomer?.cmName.isNotEmpty == true ? existingCustomer!.cmName : (agentList.length > 1 ? agentList[1] : 'UNKNOWN');
    if (!agentList.contains(selectedAgent)) {
      agentList.add(selectedAgent);
    }

    // Load available items (from Settings)
    List<String> savedItems = await widget.settingsService.getSavedItems();
    String selectedItem = 'None';
    if (existingCustomer != null && existingCustomer.message.isNotEmpty) {
      for (var item in savedItems) {
        String cleanItem = item.contains('|') ? item.split('|')[0].trim() : item.trim();
        if (cleanItem.toLowerCase() == existingCustomer.message.trim().toLowerCase() || item.trim().toLowerCase() == existingCustomer.message.trim().toLowerCase()) {
          selectedItem = item;
          break;
        }
      }
    }

    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF161B22),
              title: Row(
                children: [
                  Icon(existingCustomer == null ? Icons.person_add : Icons.edit, color: const Color(0xFF00E676)),
                  const SizedBox(width: 8),
                  Text(existingCustomer == null ? 'Add New Customer' : 'Edit Customer', style: const TextStyle(color: Colors.white)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: mobileCtrl,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Mobile Number', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    TextField(
                      controller: nameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Customer Name *', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    TextField(
                      controller: custNoCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Customer No', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    TextField(
                      controller: billNoCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Bill No', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    TextField(
                      controller: billAmountCtrl,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Bill Amount', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    TextField(
                      controller: clBalanceCtrl,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Closing Balance', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    const SizedBox(height: 16),
                    
                    // Collection Man (Agent) with inline + Add New Agent
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            key: ValueKey(selectedAgent),
                            initialValue: selectedAgent,
                            dropdownColor: const Color(0xFF161B22),
                            decoration: const InputDecoration(labelText: 'Collection Man / Agent', labelStyle: TextStyle(color: Colors.grey)),
                            items: agentList.map((a) => DropdownMenuItem(value: a, child: Text(a, style: const TextStyle(color: Colors.white)))).toList(),
                            onChanged: (val) => setDialogState(() => selectedAgent = val ?? selectedAgent),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.add_circle, color: Color(0xFF00E676), size: 28),
                          tooltip: 'Add New Agent without clearing form',
                          onPressed: () async {
                            String? newAgent = await _showAddAgentDialog(context);
                            if (newAgent != null && newAgent.isNotEmpty) {
                              await widget.settingsService.addSavedCollectionMan(newAgent);
                              setDialogState(() {
                                if (!agentList.contains(newAgent)) {
                                  agentList.add(newAgent);
                                }
                                selectedAgent = newAgent;
                              });
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Item Selection with inline + Add New Item
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            key: ValueKey(selectedItem),
                            initialValue: selectedItem,
                            dropdownColor: const Color(0xFF161B22),
                            decoration: const InputDecoration(labelText: 'Select Item / Product', labelStyle: TextStyle(color: Colors.grey)),
                            items: ['None', ...savedItems].map((i) => DropdownMenuItem(value: i, child: Text(i, style: const TextStyle(color: Colors.white)))).toList(),
                            onChanged: (val) {
                              setDialogState(() {
                                selectedItem = val ?? 'None';
                                if (selectedItem != 'None') {
                                  String cleanName = selectedItem.contains('|') ? selectedItem.split('|')[0].trim() : selectedItem.trim();
                                  if (messageCtrl.text.isEmpty) {
                                    messageCtrl.text = cleanName;
                                  }
                                  if (selectedItem.contains('|')) {
                                    final parts = selectedItem.split('|');
                                    if (parts.length > 1 && billAmountCtrl.text.isEmpty) {
                                      billAmountCtrl.text = parts[1];
                                    }
                                  }
                                }
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.add_shopping_cart, color: Color(0xFF00E676), size: 28),
                          tooltip: 'Add New Item without clearing form',
                          onPressed: () async {
                            String? newItem = await _showAddItemDialog(context);
                            if (newItem != null && newItem.isNotEmpty) {
                              await widget.settingsService.addSavedItem(newItem);
                              setDialogState(() {
                                if (!savedItems.contains(newItem)) {
                                  savedItems.add(newItem);
                                }
                                selectedItem = newItem;
                                if (newItem.contains('|')) {
                                  final parts = newItem.split('|');
                                  if (parts.length > 1 && billAmountCtrl.text.isEmpty) {
                                    billAmountCtrl.text = parts[1];
                                  }
                                }
                              });
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: messageCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Custom Note / Message', labelStyle: TextStyle(color: Colors.grey)),
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
                    if (nameCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Customer Name is required')));
                      return;
                    }

                    String finalMsg = messageCtrl.text.trim();
                    if (finalMsg.isEmpty && selectedItem != 'None') {
                      finalMsg = selectedItem.contains('|') ? selectedItem.split('|')[0].trim() : selectedItem.trim();
                    }

                    if (existingCustomer != null) {
                      existingCustomer.mobile = mobileCtrl.text.trim();
                      existingCustomer.custName = nameCtrl.text.trim();
                      existingCustomer.custNo = custNoCtrl.text.trim();
                      existingCustomer.billNo = billNoCtrl.text.trim();
                      existingCustomer.billAmount = billAmountCtrl.text.trim();
                      existingCustomer.clBalance = clBalanceCtrl.text.trim();
                      existingCustomer.cmName = selectedAgent;
                      existingCustomer.message = finalMsg;
                    } else {
                      final newCust = Customer(
                        mobile: mobileCtrl.text.trim(),
                        custName: nameCtrl.text.trim(),
                        custNo: custNoCtrl.text.trim(),
                        billNo: billNoCtrl.text.trim(),
                        billAmount: billAmountCtrl.text.trim(),
                        clBalance: clBalanceCtrl.text.trim(),
                        cmName: selectedAgent,
                        message: finalMsg,
                        status: 'Pending',
                        imagePath: '',
                        sentTime: '',
                      );
                      widget.excelService.allCustomers.add(newCust);
                    }

                    await widget.excelService.saveCustomers();
                    if (context.mounted) Navigator.pop(context);
                    setState(() {});
                  },
                  child: Text(existingCustomer == null ? 'Add Customer' : 'Save Changes', style: const TextStyle(color: Colors.black)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<String?> _showAddAgentDialog(BuildContext context) async {
    final TextEditingController nameCtrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: const Text('Add New Agent', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: 'Agent Name (e.g. Rajesh - C101)', labelStyle: TextStyle(color: Colors.grey)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
              onPressed: () {
                if (nameCtrl.text.trim().isNotEmpty) {
                  Navigator.pop(context, nameCtrl.text.trim());
                }
              },
              child: const Text('Add Agent', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _showAddItemDialog(BuildContext context) async {
    final TextEditingController nameCtrl = TextEditingController();
    final TextEditingController rateCtrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: const Text('Add New Item / Product', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Item Name (e.g. Water Jar 20L)', labelStyle: TextStyle(color: Colors.grey)),
              ),
              TextField(
                controller: rateCtrl,
                style: const TextStyle(color: Colors.white),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Price / Rate (₹)', labelStyle: TextStyle(color: Colors.grey)),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
              onPressed: () {
                if (nameCtrl.text.trim().isNotEmpty) {
                  String itemStr = "${nameCtrl.text.trim()}|${rateCtrl.text.trim()}";
                  Navigator.pop(context, itemStr);
                }
              },
              child: const Text('Add Item', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );
  }

  // ignore: unused_element
  void _showDemoLimitExpiredDialog(BuildContext context) async {
    String deviceId = await LicenseService().getDeviceId();
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LicenseExpiredScreen(
          deviceId: deviceId,
          customerName: LicenseService().getBusinessName(),
          licenseNumber: 'DEMO-50-LIMIT',
          expiryDate: 'Limit Reached (50 Max)',
          onActivateLicense: () async {
            // Can enter license code right from here
          },
        ),
      ),
    );
  }
}

