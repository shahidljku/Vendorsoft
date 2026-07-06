import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screenshot/screenshot.dart';

import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/settings_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/whatsapp_service.dart';
import '../services/accessibility_service.dart';
import '../services/license_service.dart';
import '../services/log_service.dart';
import 'package:permission_handler/permission_handler.dart';

class ReceiptsTab extends StatefulWidget {
  final SettingsService settingsService;
  final ExcelService excelService;
  final String initialFilter;
  final int navKey;

  const ReceiptsTab({
    super.key,
    required this.settingsService,
    required this.excelService,
    this.initialFilter = 'Pending',
    this.navKey = 0,
  });

  @override
  State<ReceiptsTab> createState() => _ReceiptsTabState();
}

class _ReceiptsTabState extends State<ReceiptsTab> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _isSending = false;
  int _currentIndex = 0;
  List<Customer> _pendingReceipts = [];
  List<Customer> _submittedReceipts = [];
  final ScreenshotController _screenshotController = ScreenshotController();

  String _getCurrentDateFormatted() {
    final now = DateTime.now();
    final day = now.day.toString().padLeft(2, '0');
    final month = now.month.toString().padLeft(2, '0');
    final year = now.year.toString();
    return '$day/$month/$year';
  }
  late TabController _tabController;
  bool _waitingForWhatsApp = false;
  Completer<bool>? _whatsAppCompleter;
  bool _isAccessibilityEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AccessibilityService.initialize();
    _tabController = TabController(
      length: 2, 
      vsync: this,
      initialIndex: widget.initialFilter == 'Sent' ? 1 : 0,
    );
    _checkAccessibility();
    _refreshQueue();
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
  void didUpdateWidget(ReceiptsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.navKey != oldWidget.navKey) {
      _tabController.index = widget.initialFilter == 'Sent' ? 1 : 0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibility();
      if (_waitingForWhatsApp) {
        _waitingForWhatsApp = false;
        if (_whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
          _whatsAppCompleter!.complete(true);
        }
      }
    }
  }

  void _refreshQueue() {
    setState(() {
      _pendingReceipts = widget.excelService.allCustomers
          .where((c) => c.paymentStatus == 'Successful' && c.receiptStatus != 'Sent')
          .toList();
      _submittedReceipts = widget.excelService.allCustomers
          .where((c) => c.paymentStatus == 'Successful' && c.receiptStatus == 'Sent')
          .toList();
    });
  }

  Widget _buildReceiptWidget(Customer customer, String businessName) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 450,
          color: Colors.white,
          child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Top dark blue bar
          Container(height: 16, color: const Color(0xFF02295B)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              children: [
                const SizedBox(height: 8),
                _buildDashedLine(),
                const SizedBox(height: 16),
                const Text(
                  'PAYMENT RECEIPT',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF02295B),
                  ),
                ),
                const SizedBox(height: 16),
                _buildDashedLine(),
                const SizedBox(height: 16),
                
                // Rows
                _buildReceiptRow(Icons.business, Colors.blue, 'Party Name', customer.custName.isNotEmpty ? customer.custName : customer.mobile),
                const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                _buildReceiptRow(Icons.calendar_month, Colors.green, 'Date', customer.paymentDate.isNotEmpty ? customer.paymentDate : _getCurrentDateFormatted()),
                const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                _buildReceiptRow(Icons.receipt_long, Colors.orange, 'Bill No.', customer.billNo.isNotEmpty ? customer.billNo : 'N/A'),
                const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                _buildReceiptRow(Icons.currency_rupee, Colors.blueAccent, 'Payment', '₹${customer.amountPaid}'),
                const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                _buildReceiptRow(Icons.account_balance_wallet, Colors.purpleAccent, 'Mode', customer.paymentMethod.isNotEmpty ? customer.paymentMethod : 'Online'),
                const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                _buildReceiptRow(Icons.assignment_ind, Colors.pinkAccent, 'Transaction', customer.transactionId.isNotEmpty ? customer.transactionId : 'N/A'),
                
                const SizedBox(height: 20),
                
                // Payment Status Box
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9F5EB),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.verified_user, color: Color(0xFF1B9347), size: 40),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('PAYMENT STATUS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1B9347))),
                          Text('SUCCESSFUL', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1B9347))),
                        ],
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),
                const Text(
                  'Thank you for your payment.',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(child: Divider(color: Colors.green.shade300, thickness: 1.5)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(Icons.spa, color: Colors.green.shade700, size: 24),
                    ),
                    Expanded(child: Divider(color: Colors.green.shade300, thickness: 1.5)),
                  ],
                ),
                
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.receipt, color: Color(0xFF02295B), size: 36),
                    const SizedBox(width: 12),
                    Text(
                      businessName.isNotEmpty ? businessName : 'Vendor Software',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
                    ),
                  ],
                ),
                
                const SizedBox(height: 20),
                _buildDashedLine(),
                const SizedBox(height: 12),
                const Text(
                  'Developed by Imtiyaz Khanusia',
                  style: TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          // Bottom dark blue bar
          Container(height: 16, color: const Color(0xFF02295B)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptRow(IconData icon, Color iconColor, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 28),
        const SizedBox(width: 16),
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
          ),
        ),
        const Text(
          ':',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
          ),
        ),
      ],
    );
  }

  Widget _buildDashedLine() {
    return Row(
      children: List.generate(
        40,
        (index) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: const Color(0xFF02295B),
            height: 2,
          ),
        ),
      ),
    );
  }

  void _runPreflightChecks(BuildContext context) async {
    bool isAccessible = await AccessibilityService.isEnabled();
    if (!isAccessible && mounted) {
      bool? proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: const Text('Auto-Sending Disabled', style: TextStyle(color: Colors.white)),
          content: const Text(
              'Accessibility is OFF. Messages will not send automatically. You will have to tap the send button manually in WhatsApp for each receipt.\n\nDo you want to continue anyway?',
              style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
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
                          if (limit > 30) limit = 30;
                          if (setAsDefault) {
                            await widget.settingsService.setDefaultSendLimit(limit);
                          }
                          if (context.mounted) Navigator.pop(context);
                          _startSending(limit);
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

  Future<void> _startSending(int limit) async {
    if (_pendingReceipts.isEmpty) return;
    
    setState(() {
      _isSending = true;
      _currentIndex = 0;
    });

    WakelockPlus.enable();

    final String businessName = LicenseService().getBusinessName();
    final bool useBusiness = await widget.settingsService.getUseWhatsAppBusiness();
    
    if (await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }
    final dir = Directory('/storage/emulated/0/VendSoft/receipts');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    int sentInSession = 0;

    while (_currentIndex < _pendingReceipts.length && _isSending && sentInSession < limit) {
      Customer customer = _pendingReceipts[_currentIndex];
      
      try {
        // Automatically assign current date and default mode if they are blank in Excel
        if (customer.paymentDate.isEmpty) {
          final now = DateTime.now();
          customer.paymentDate = "${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}";
        }
        if (customer.paymentMethod.isEmpty) {
          customer.paymentMethod = 'Online';
        }

        final imageBytes = await _screenshotController.captureFromWidget(
          _buildReceiptWidget(customer, businessName),
          delay: const Duration(milliseconds: 100),
        );
        
        final now = DateTime.now();
        String ddmmyy = "${now.day.toString().padLeft(2, '0')}${now.month.toString().padLeft(2, '0')}${now.year.toString().substring(2)}";
        String identifier = customer.billNo.isNotEmpty ? customer.billNo : customer.mobile;
        identifier = identifier.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        String receiptPath = '${dir.path}/receipt_${identifier}_$ddmmyy.png';
        File receiptFile = File(receiptPath);
        await receiptFile.writeAsBytes(imageBytes);

        await AccessibilityService.setAutoSendMode(true);
        bool whatsAppOpened = await WhatsAppService.sendImage(
          mobile: customer.mobile,
          imagePath: receiptPath,
          useBusinessApp: useBusiness,
        );

        if (!whatsAppOpened) throw Exception("Could not open WhatsApp");

        _waitingForWhatsApp = true;
        _whatsAppCompleter = Completer<bool>();
        final currentCompleter = _whatsAppCompleter!;

        StreamSubscription? sub;
        sub = AccessibilityService.onMessageSent.listen((_) {
          if (!currentCompleter.isCompleted) currentCompleter.complete(true);
        });

        // Use a longer timeout or rely on AppLifecycleState
        Timer timeoutTimer = Timer(const Duration(seconds: 45), () {
          if (!currentCompleter.isCompleted) {
            currentCompleter.complete(false);
          }
        });

        bool sent = await currentCompleter.future;
        timeoutTimer.cancel();
        await sub.cancel();
        _waitingForWhatsApp = false;

        if (sent) {
          customer.receiptStatus = 'Sent';
          await LogService().writeLog(customer.mobile, "Receipt Sent");
        } else {
          throw Exception("Timeout or failed to send");
        }
      } catch (e) {
        await LogService().writeLog(customer.mobile, "Receipt Failed - $e");
      }

      await widget.excelService.saveCustomers(widget.excelService.allCustomers);

      if (mounted) {
        setState(() {
          _currentIndex++;
        });
      }
      sentInSession++;
      
      if (_currentIndex < _pendingReceipts.length && sentInSession < limit) {
        int delayMs = await widget.settingsService.getDelayBetweenCustomers();
        int remainingSeconds = (delayMs / 1000).round();
        while (remainingSeconds > 0 && _isSending) {
          await Future.delayed(const Duration(seconds: 1));
          remainingSeconds--;
        }
      }
    }

    if (mounted) {
      setState(() {
        _isSending = false;
      });
      _refreshQueue();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Receipt sending completed!')));
    }
    WakelockPlus.disable();
  }

  void _showEditPaymentDialog(BuildContext context, Customer customer) {
    TextEditingController amountCtrl = TextEditingController(text: customer.amountPaid.isNotEmpty ? customer.amountPaid : customer.billAmount);
    TextEditingController txCtrl = TextEditingController(text: customer.transactionId);
    String paymentMethod = customer.paymentMethod.isNotEmpty ? customer.paymentMethod : 'Online';
    String paymentStatus = 'Successful';
    DateTime paymentDate = DateTime.now();
    if (customer.paymentDate.isNotEmpty) {
      try {
        final parts = customer.paymentDate.split('/');
        if (parts.length == 3) {
          paymentDate = DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
        }
      } catch (_) {}
    }
    
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Theme.of(context).cardColor,
              title: const Text('Edit Payment Details', style: TextStyle(color: Colors.white)),
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
                    DropdownButtonFormField<String>(
                      value: paymentStatus,
                      dropdownColor: Theme.of(context).cardColor,
                      decoration: const InputDecoration(labelText: 'Payment Status', labelStyle: TextStyle(color: Colors.grey)),
                      items: ['Successful', 'Unpaid'].map((m) => DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(color: Colors.white)))).toList(),
                      onChanged: (val) {
                        if (val != null) setDialogState(() => paymentStatus = val);
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
                      if (paymentStatus == 'Unpaid') {
                        customer.paymentStatus = 'Pending';
                      } else {
                        customer.paymentStatus = 'Successful';
                      }
                      customer.amountPaid = amountCtrl.text;
                      customer.transactionId = txCtrl.text;
                      customer.paymentMethod = paymentMethod;
                      customer.paymentDate = "${paymentDate.day.toString().padLeft(2, '0')}/${paymentDate.month.toString().padLeft(2, '0')}/${paymentDate.year}";
                    });
                    await widget.excelService.saveCustomers(widget.excelService.allCustomers);
                    _refreshQueue();
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

  Widget _buildList(List<Customer> list, bool isPending) {
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long, size: 80, color: Colors.grey.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(isPending ? 'No pending receipts' : 'No submitted receipts', style: const TextStyle(fontSize: 18, color: Colors.grey)),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_isSending && isPending)
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.blueAccent.withValues(alpha: 0.1),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Sending Receipts...', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    Text('$_currentIndex / ${_pendingReceipts.length}', style: const TextStyle(color: Colors.blueAccent)),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _pendingReceipts.isEmpty ? 0 : _currentIndex / _pendingReceipts.length,
                  backgroundColor: Colors.blueAccent.withValues(alpha: 0.2),
                  color: Colors.blueAccent,
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            itemBuilder: (context, index) {
              Customer c = list[index];
              bool isCurrent = _isSending && isPending && index == _currentIndex;
              return ListTile(
                onTap: isPending && !_isSending ? () {
                  _showEditPaymentDialog(context, c);
                } : null,
                leading: CircleAvatar(
                  backgroundColor: isCurrent ? Colors.blueAccent : (isPending ? Colors.orangeAccent : Colors.green),
                  child: Icon(isPending ? Icons.receipt : Icons.check, color: Colors.white),
                ),
                title: Text(c.custName.isNotEmpty ? c.custName : c.mobile, style: const TextStyle(color: Colors.white)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Amount: ₹${c.amountPaid}', style: const TextStyle(color: Colors.green)),
                    if (c.billNo.isNotEmpty) Text('Bill No: ${c.billNo}', style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                  ],
                ),
                trailing: isCurrent 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isPending && !_isSending)
                          IconButton(
                            icon: const Icon(Icons.edit, color: Colors.blueAccent),
                            onPressed: () => _showEditPaymentDialog(context, c),
                          ),
                        IconButton(
                          icon: const Icon(Icons.remove_red_eye, color: Colors.grey),
                          onPressed: () {
                            showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: Colors.transparent,
                            contentPadding: EdgeInsets.zero,
                            content: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildReceiptWidget(c, LicenseService().getBusinessName()),
                                  if (!isPending) ...[
                                    const SizedBox(height: 16),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.green, // WhatsApp green
                                              padding: const EdgeInsets.symmetric(vertical: 12),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                            icon: const Icon(Icons.share, color: Colors.white),
                                            label: const Text('Share', style: TextStyle(color: Colors.white)),
                                            onPressed: () async {
                                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generating receipt...')));
                                              try {
                                                bool updated = false;
                                                if (c.paymentDate.isEmpty) {
                                                  final now = DateTime.now();
                                                  c.paymentDate = "${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}";
                                                  updated = true;
                                                }
                                                if (c.paymentMethod.isEmpty) {
                                                  c.paymentMethod = 'Online';
                                                  updated = true;
                                                }
                                                if (updated) {
                                                  await widget.excelService.saveCustomers(widget.excelService.allCustomers);
                                                }
                                                
                                                final imageBytes = await _screenshotController.captureFromWidget(
                                                  _buildReceiptWidget(c, LicenseService().getBusinessName()),
                                                  delay: const Duration(milliseconds: 100),
                                                );
                                                if (await Permission.manageExternalStorage.isDenied) {
                                                  await Permission.manageExternalStorage.request();
                                                }
                                                final dir = Directory('/storage/emulated/0/VendSoft/receipts');
                                                if (!await dir.exists()) await dir.create(recursive: true);
                                                final now = DateTime.now();
                                                String ddmmyy = "${now.day.toString().padLeft(2, '0')}${now.month.toString().padLeft(2, '0')}${now.year.toString().substring(2)}";
                                                String identifier = c.billNo.isNotEmpty ? c.billNo : c.mobile;
                                                identifier = identifier.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
                                                String receiptPath = '${dir.path}/receipt_${identifier}_$ddmmyy.png';
                                                await File(receiptPath).writeAsBytes(imageBytes);
                                                
                                                bool useBusiness = await widget.settingsService.getUseWhatsAppBusiness();
                                                await WhatsAppService.sendImage(
                                                  mobile: c.mobile,
                                                  imagePath: receiptPath,
                                                  useBusinessApp: useBusiness,
                                                );
                                                if (context.mounted) Navigator.pop(context);
                                              } catch (e) {
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to share: $e')));
                                                }
                                              }
                                            }
                                          )
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.blue, // Download blue
                                              padding: const EdgeInsets.symmetric(vertical: 12),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                            icon: const Icon(Icons.download, color: Colors.white),
                                            label: const Text('Download', style: TextStyle(color: Colors.white)),
                                            onPressed: () async {
                                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saving...')));
                                              try {
                                                bool updated = false;
                                                if (c.paymentDate.isEmpty) {
                                                  final now = DateTime.now();
                                                  c.paymentDate = "${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}";
                                                  updated = true;
                                                }
                                                if (c.paymentMethod.isEmpty) {
                                                  c.paymentMethod = 'Online';
                                                  updated = true;
                                                }
                                                if (updated) {
                                                  await widget.excelService.saveCustomers(widget.excelService.allCustomers);
                                                }
                                                
                                                final imageBytes = await _screenshotController.captureFromWidget(
                                                  _buildReceiptWidget(c, LicenseService().getBusinessName()),
                                                  delay: const Duration(milliseconds: 100),
                                                );
                                                if (await Permission.manageExternalStorage.isDenied) {
                                                  await Permission.manageExternalStorage.request();
                                                }
                                                final dir = Directory('/storage/emulated/0/VendSoft/receipts');
                                                if (!await dir.exists()) await dir.create(recursive: true);
                                                String receiptPath = '${dir.path}/receipt_${c.mobile}_${DateTime.now().millisecondsSinceEpoch}.png';
                                                await File(receiptPath).writeAsBytes(imageBytes);
                                                
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $receiptPath')));
                                                }
                                              } catch (e) {
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to download: $e')));
                                                }
                                              }
                                            }
                                          )
                                        )
                                      ]
                                    )
                                  ]
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
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
        title: const Text('Receipts', style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00E676),
          labelColor: const Color(0xFF00E676),
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(text: 'Pending Receipts'),
            Tab(text: 'Submitted Receipts'),
          ],
        ),
      ),
      body: ListenableBuilder(
        listenable: widget.excelService,
        builder: (context, _) {
          if (!_isSending) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _refreshQueue());
          }
          return TabBarView(
            controller: _tabController,
            children: [
              _buildList(_pendingReceipts, true),
              _buildList(_submittedReceipts, false),
            ],
          );
        },
      ),
      floatingActionButton: _pendingReceipts.isNotEmpty && !_isSending
          ? FloatingActionButton.extended(
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
              label: const Text('Send Receipts'),
            )
          : null,
    );
  }
}
