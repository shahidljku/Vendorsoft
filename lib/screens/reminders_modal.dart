import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/settings_service.dart';
import '../services/whatsapp_service.dart';
import '../services/accessibility_service.dart';
import '../services/cooldown_service.dart';
import '../services/log_service.dart';
import '../services/license_service.dart';

class RemindersModal extends StatefulWidget {
  final ExcelService excelService;
  final SettingsService settingsService;

  const RemindersModal({
    super.key,
    required this.excelService,
    required this.settingsService,
  });

  static void show(BuildContext context, ExcelService excelService, SettingsService settingsService) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.88,
          child: RemindersModal(
            excelService: excelService,
            settingsService: settingsService,
          ),
        ),
      ),
    );
  }

  @override
  State<RemindersModal> createState() => _RemindersModalState();
}

class _RemindersModalState extends State<RemindersModal> {
  int _filterMode = 0; // 0: Sent 5+ Days, 1: Sent 15+ Days, 2: Any Unpaid 5+ Days, 3: All Unpaid & Sent
  List<Customer> _eligibleCustomers = [];
  final Set<String> _selectedMobiles = {};
  String _template = '';
  bool _isSending = false;
  int _currentIndex = 0;
  bool _waitingForWhatsApp = false;
  Completer<bool>? _whatsAppCompleter;
  StreamSubscription<bool>? _messageSentSubscription;
  bool _isAccessibilityEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadTemplateAndCheck();
    _messageSentSubscription = AccessibilityService.onMessageSent.listen((_) {
      if (AccessibilityService.activeSendingMode == 'reminder' && _isSending && _waitingForWhatsApp && _whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
        _waitingForWhatsApp = false;
        _whatsAppCompleter!.complete(true);
      }
    });
  }

  @override
  void dispose() {
    _messageSentSubscription?.cancel();
    if (AccessibilityService.activeSendingMode == 'reminder') {
      AccessibilityService.activeSendingMode = 'none';
    }
    super.dispose();
  }

  Future<void> _loadTemplateAndCheck() async {
    String tmpl = await widget.settingsService.getReminderTemplate();
    bool enabled = await AccessibilityService.isEnabled();
    if (mounted) {
      setState(() {
        _template = tmpl;
        _isAccessibilityEnabled = enabled;
      });
      _applyFilter();
    }
  }

  static bool isCustomerPaid(Customer c) {
    String pst = c.paymentStatus.trim().toLowerCase();
    if (pst == 'successful' || pst.contains('success') || pst == 'paid') return true;
    if (c.status.trim().toLowerCase() == 'paid') return true;
    if (c.clBalance.isNotEmpty) {
      double bal = double.tryParse(c.clBalance) ?? 1.0;
      if (bal <= 0) return true;
    }
    return false;
  }

  static int? getDaysSinceReference(Customer c) {
    if (c.sentTime.isNotEmpty) {
      DateTime? parsed = _parseDateStr(c.sentTime);
      if (parsed != null) {
        return DateTime.now().difference(parsed).inDays;
      }
    }
    if (c.vouchDate.isNotEmpty) {
      DateTime? parsed = _parseDateStr(c.vouchDate);
      if (parsed != null) {
        return DateTime.now().difference(parsed).inDays;
      }
    }
    return null;
  }

  static DateTime? _parseDateStr(String str) {
    try {
      String clean = str.split(' ')[0].trim();
      if (clean.contains('/')) {
        var parts = clean.split('/');
        if (parts.length == 3) {
          int day = int.tryParse(parts[0]) ?? 1;
          int month = int.tryParse(parts[1]) ?? 1;
          int year = int.tryParse(parts[2]) ?? 2026;
          if (year < 100) year += 2000;
          return DateTime(year, month, day);
        }
      } else if (clean.contains('-')) {
        var parts = clean.split('-');
        if (parts.length == 3) {
          if (parts[0].length == 4) {
            return DateTime.tryParse(clean);
          } else {
            int day = int.tryParse(parts[0]) ?? 1;
            int month = int.tryParse(parts[1]) ?? 1;
            int year = int.tryParse(parts[2]) ?? 2026;
            if (year < 100) year += 2000;
            return DateTime(year, month, day);
          }
        }
      }
    } catch (_) {}
    return null;
  }

  void _applyFilter() {
    List<Customer> all = widget.excelService.allCustomers;
    List<Customer> filtered = [];

    for (Customer c in all) {
      // 1. MUST IGNORE if already paid
      if (isCustomerPaid(c)) continue;

      String st = c.status.trim().toLowerCase();
      bool isSentStatus = st == 'sent' || st == 'message sent';
      int? days = getDaysSinceReference(c);

      if (_filterMode == 0) {
        // Sent Bills (5+ Days Ago)
        if (isSentStatus) {
          if (days == null || days >= 5) {
            filtered.add(c);
          }
        }
      } else if (_filterMode == 1) {
        // Sent Bills (15+ Days Ago)
        if (isSentStatus) {
          if (days != null && days >= 15) {
            filtered.add(c);
          }
        }
      } else if (_filterMode == 2) {
        // Any Unpaid Bill (5+ Days Ago)
        if (days == null || days >= 5) {
          filtered.add(c);
        }
      } else if (_filterMode == 3) {
        // All Unpaid & Sent Bills
        if (isSentStatus) {
          filtered.add(c);
        }
      }
    }

    setState(() {
      _eligibleCustomers = filtered;
      _selectedMobiles.clear();
      for (Customer c in filtered) {
        // If customer yesNo is 'No' or stopped taking newspaper, unselect by default to prevent angering them!
        if (c.yesNo.trim().toLowerCase() != 'no') {
          _selectedMobiles.add(c.mobile);
        }
      }
    });
  }

  void _showEditTemplateDialog() {
    TextEditingController ctrl = TextEditingController(text: _template);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        title: const Text('Edit Gujarati Reminder Template', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Available placeholders:\n{custName} = Customer Name\n{billNo} = Bill Number\n{balance} = Amount Due\n{monthNm} = Month\n{businessName} = Business Name',
                style: TextStyle(color: Colors.amberAccent, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 12,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF00E676))),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ctrl.text = SettingsService.defaultGujaratiReminderTemplate;
            },
            child: const Text('Reset Default', style: TextStyle(color: Colors.orangeAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
            onPressed: () async {
              String newTmpl = ctrl.text.trim();
              if (newTmpl.isNotEmpty) {
                await widget.settingsService.setReminderTemplate(newTmpl);
                if (mounted) {
                  setState(() {
                    _template = newTmpl;
                  });
                }
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save Template', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  String _formatMessageForCustomer(Customer c) {
    String name = c.custName.isNotEmpty ? c.custName : c.mobile;
    String billNo = c.billNo.isNotEmpty ? c.billNo : 'N/A';
    String bal = c.clBalance.isNotEmpty ? c.clBalance : (c.billAmount.isNotEmpty ? c.billAmount : '0');
    String month = c.monthNm.isNotEmpty ? c.monthNm : 'Current Month';
    String bizName = LicenseService().getBusinessName();

    return _template
        .replaceAll('{custName}', name)
        .replaceAll('{billNo}', billNo)
        .replaceAll('{balance}', bal)
        .replaceAll('{monthNm}', month)
        .replaceAll('{businessName}', bizName);
  }

  Future<void> _startSendingReminders() async {
    List<Customer> toSend = _eligibleCustomers.where((c) => _selectedMobiles.contains(c.mobile)).toList();
    if (toSend.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No customers selected!')));
      return;
    }

    if (!_isAccessibilityEnabled) {
      bool? proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text('Accessibility Disabled', style: TextStyle(color: Colors.white)),
          content: const Text(
            'Auto-sending is OFF. WhatsApp will open with the Gujarati reminder pre-filled for each customer, and you will need to tap Send manually in WhatsApp.\n\nContinue?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)), child: const Text('Continue', style: TextStyle(color: Colors.black))),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() {
      _isSending = true;
      _currentIndex = 0;
    });

    WakelockPlus.enable();
    bool useBusiness = await widget.settingsService.getUseWhatsAppBusiness();
    AccessibilityService.activeSendingMode = 'reminder';

    int sentCount = 0;
    while (_currentIndex < toSend.length && _isSending) {
      Customer c = toSend[_currentIndex];
      try {
        String msg = _formatMessageForCustomer(c);
        if (_isAccessibilityEnabled) {
          await AccessibilityService.setAutoSendMode(true);
        }

        _waitingForWhatsApp = true;
        _whatsAppCompleter = Completer<bool>();
        final currentCompleter = _whatsAppCompleter!;

        StreamSubscription? sub = AccessibilityService.onMessageSent.listen((_) {
          if (AccessibilityService.activeSendingMode == 'reminder' && !currentCompleter.isCompleted) {
            currentCompleter.complete(true);
          }
        });

        bool opened = await WhatsAppService.sendWhatsAppMessage(
          mobile: c.mobile,
          message: msg,
          useBusinessApp: useBusiness,
        );

        if (!opened) throw Exception("Could not open WhatsApp");

        Timer timeout = Timer(const Duration(seconds: 40), () {
          if (!currentCompleter.isCompleted) {
            currentCompleter.complete(false);
          }
        });

        bool sent = await currentCompleter.future;
        timeout.cancel();
        await sub.cancel();
        _waitingForWhatsApp = false;

        if (sent) {
          sentCount++;
          await LogService().writeLog(c.mobile, "Payment Reminder Sent ($msg)");
          await CooldownService().recordMessageSent();
        }
      } catch (e) {
        await LogService().writeLog(c.mobile, "Payment Reminder Failed - $e");
      }

      if (!_isSending || !mounted) break;

      setState(() {
        _currentIndex++;
      });

      if (_currentIndex < toSend.length) {
        int delayMs = await widget.settingsService.getDelayBetweenCustomers();
        int remainingSec = (delayMs / 1000).round();
        while (remainingSec > 0 && _isSending) {
          await Future.delayed(const Duration(seconds: 1));
          remainingSec--;
        }
      }
    }

    if (_isAccessibilityEnabled) {
      await AccessibilityService.setAutoSendMode(false);
    }
    AccessibilityService.activeSendingMode = 'none';

    if (mounted) {
      setState(() {
        _isSending = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Finished sending $sentCount payment reminders!')));
    }
    WakelockPlus.disable();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: const BoxDecoration(
            color: Color(0xFF02295B),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Row(
            children: [
              const Icon(Icons.notifications_active, color: Color(0xFF00E676), size: 28),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Send Payment Reminders (ચૂકવણી યાદી)', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('Strictly skips paid bills & safe preview checklist', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              if (!_isSending)
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
            ],
          ),
        ),

        // Safety Banner
        Container(
          padding: const EdgeInsets.all(12),
          color: const Color(0xFF3E2723),
          child: const Row(
            children: [
              Icon(Icons.shield, color: Colors.amberAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Safety Rule: Customers who have paid or who stopped newspaper (Yes/No = No) are ignored by default. Uncheck any customer below before sending if needed.',
                  style: TextStyle(color: Colors.amberAccent, fontSize: 12),
                ),
              ),
            ],
          ),
        ),

        // Filter Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFF2C2C2C),
          child: Row(
            children: [
              const Icon(Icons.filter_list, color: Colors.grey, size: 20),
              const SizedBox(width: 8),
              const Text('Filter: ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<int>(
                  value: _filterMode,
                  dropdownColor: const Color(0xFF2C2C2C),
                  isExpanded: true,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  underline: const SizedBox(),
                  onChanged: _isSending
                      ? null
                      : (val) {
                          if (val != null) {
                            setState(() => _filterMode = val);
                            _applyFilter();
                          }
                        },
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Sent Bills (Min 5 Days Ago)')),
                    DropdownMenuItem(value: 1, child: Text('Sent Bills (Min 15 Days Ago)')),
                    DropdownMenuItem(value: 2, child: Text('Any Unpaid Bill (Min 5 Days Ago)')),
                    DropdownMenuItem(value: 3, child: Text('All Unpaid & Sent Bills')),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Template Preview Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: const Color(0xFF1E1E1E),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Template: Gujarati Gentle Reminder (${_eligibleCustomers.length} eligible)',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
              TextButton.icon(
                onPressed: _isSending ? null : _showEditTemplateDialog,
                icon: const Icon(Icons.edit, size: 16, color: Color(0xFF00E676)),
                label: const Text('Edit Template', style: TextStyle(color: Color(0xFF00E676))),
              ),
            ],
          ),
        ),

        // Customer List
        Expanded(
          child: _eligibleCustomers.isEmpty
              ? const Center(
                  child: Text(
                    'No unpaid customers match this filter.',
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                )
              : ListView.builder(
                  itemCount: _eligibleCustomers.length,
                  itemBuilder: (context, index) {
                    Customer c = _eligibleCustomers[index];
                    bool isChecked = _selectedMobiles.contains(c.mobile);
                    bool isStopped = c.yesNo.trim().toLowerCase() == 'no';
                    int? days = getDaysSinceReference(c);

                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: _isSending && index == _currentIndex
                            ? Colors.blue.withValues(alpha: 0.2)
                            : (isStopped ? Colors.red.withValues(alpha: 0.15) : const Color(0xFF2A2A2A)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isChecked ? const Color(0xFF00E676) : Colors.transparent,
                        ),
                      ),
                      child: CheckboxListTile(
                        value: isChecked,
                        activeColor: const Color(0xFF00E676),
                        checkColor: Colors.black,
                        onChanged: _isSending || isStopped
                            ? null
                            : (val) {
                                setState(() {
                                  if (val == true) {
                                    _selectedMobiles.add(c.mobile);
                                  } else {
                                    _selectedMobiles.remove(c.mobile);
                                  }
                                });
                              },
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                c.custName.isNotEmpty ? c.custName : c.mobile,
                                style: TextStyle(
                                  color: isStopped ? Colors.redAccent : Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (isStopped)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.red,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('Stopped / No', style: TextStyle(color: Colors.white, fontSize: 10)),
                              ),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              Text('Due: ₹${c.clBalance.isNotEmpty ? c.clBalance : c.billAmount}', style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w600)),
                              const SizedBox(width: 12),
                              Text('Bill #${c.billNo.isNotEmpty ? c.billNo : "N/A"}', style: const TextStyle(color: Colors.grey)),
                              const Spacer(),
                              Text(
                                days != null ? '$days days since bill' : 'Bill Sent',
                                style: TextStyle(color: days != null && days >= 15 ? Colors.redAccent : Colors.lightBlueAccent, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),

        // Bottom Action Bar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Color(0xFF2C2C2C),
            border: Border(top: BorderSide(color: Colors.white12)),
          ),
          child: _isSending
              ? Row(
                  children: [
                    const CircularProgressIndicator(color: Color(0xFF00E676)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Sending reminder $_currentIndex of ${_selectedMobiles.length}...',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () => setState(() => _isSending = false),
                      child: const Text('Stop', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                )
              : Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() {
                          if (_selectedMobiles.length == _eligibleCustomers.where((c) => c.yesNo.trim().toLowerCase() != 'no').length) {
                            _selectedMobiles.clear();
                          } else {
                            for (var c in _eligibleCustomers) {
                              if (c.yesNo.trim().toLowerCase() != 'no') {
                                _selectedMobiles.add(c.mobile);
                              }
                            }
                          }
                        });
                      },
                      child: Text(
                        _selectedMobiles.length == _eligibleCustomers.where((c) => c.yesNo.trim().toLowerCase() != 'no').length ? 'Deselect All' : 'Select All',
                        style: const TextStyle(color: Colors.lightBlueAccent),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Selected: ${_selectedMobiles.length}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E676),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _selectedMobiles.isEmpty ? null : _startSendingReminders,
                      icon: const Icon(Icons.send, color: Colors.black),
                      label: const Text('Send Reminders', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
