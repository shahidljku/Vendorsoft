import 'dart:async';
import 'dart:math';
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
  List<Customer> _eligibleCustomers = [];
  final Set<String> _selectedMobiles = {};
  String _template = '';
  bool _isSending = false;
  int _currentIndex = 0;
  bool _waitingForWhatsApp = false;
  Completer<bool>? _whatsAppCompleter;
  StreamSubscription<bool>? _messageSentSubscription;
  bool _isAccessibilityEnabled = false;

  Timer? _cooldownTimer;
  Duration _remainingCooldown = Duration.zero;
  int _usedQuota = 0;
  bool get _isCooldownActive => _remainingCooldown.inSeconds > 0;

  @override
  void initState() {
    super.initState();
    _loadTemplateAndCheck();
    _checkCooldownTicker();
    _messageSentSubscription = AccessibilityService.onMessageSent.listen((_) {
      if (AccessibilityService.activeSendingMode == 'reminder' && _isSending && _waitingForWhatsApp && _whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
        _waitingForWhatsApp = false;
        _whatsAppCompleter!.complete(true);
      }
    });
  }

  Future<void> _checkCooldownTicker() async {
    Duration remaining = await CooldownService().getRemainingCooldown();
    int used = await CooldownService().getUsedQuota();
    if (mounted) {
      setState(() {
        _remainingCooldown = remaining;
        _usedQuota = used;
      });
      _startCooldownTicker();
    }
  }

  void _startCooldownTicker() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_remainingCooldown.inSeconds <= 1 && _remainingCooldown.inSeconds > 0) {
        Duration remaining = await CooldownService().getRemainingCooldown();
        int used = await CooldownService().getUsedQuota();
        if (mounted) {
          setState(() {
            _remainingCooldown = remaining;
            _usedQuota = used;
          });
        }
      } else if (_remainingCooldown.inSeconds > 1) {
        if (mounted) {
          setState(() {
            _remainingCooldown = _remainingCooldown - const Duration(seconds: 1);
          });
        }
      } else {
        if (timer.tick % 3 == 0) {
          int used = await CooldownService().getUsedQuota();
          Duration remaining = await CooldownService().getRemainingCooldown();
          if (mounted && (used != _usedQuota || remaining != _remainingCooldown)) {
            setState(() {
              _usedQuota = used;
              _remainingCooldown = remaining;
            });
          }
        }
      }
    });
  }



  @override
  void dispose() {
    _cooldownTimer?.cancel();
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
    if (c.isPaid) return true;
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

      // Simple 15-day rule: Unpaid bills sent 15+ days ago (or sent status without explicit date)
      if (isSentStatus) {
        if (days == null || days >= 15) {
          filtered.add(c);
        }
      }
    }

    setState(() {
      _eligibleCustomers = filtered;
      _selectedMobiles.clear();
      // Auto-select ALL unpaid users sent 15+ days ago right away
      for (Customer c in filtered) {
        _selectedMobiles.add(c.mobile);
      }
    });
  }

  void _toggleSelection(Customer c) {
    if (_isSending) return;
    setState(() {
      if (_selectedMobiles.contains(c.mobile)) {
        _selectedMobiles.remove(c.mobile);
      } else {
        _selectedMobiles.add(c.mobile);
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
    
    String month;
    if (c.monthNm.isNotEmpty && c.monthNm != 'null' && c.monthNm != '-') {
      month = c.monthNm;
    } else {
      DateTime? dt = _parseDateStr(c.vouchDate) ?? _parseDateStr(c.sentTime) ?? DateTime.now();
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      month = '${months[dt.month - 1]}-${dt.year}';
    }

    String bizName = LicenseService().getBusinessName();

    return _template
        .replaceAll('{custName}', name)
        .replaceAll('{billNo}', billNo)
        .replaceAll('{balance}', bal)
        .replaceAll('{monthNm}', month)
        .replaceAll('{businessName}', bizName);
  }

  Future<void> _startSendingReminders() async {
    if (await CooldownService().isCooldownActive()) {
      Duration remaining = await CooldownService().getRemainingCooldown();
      int mins = remaining.inMinutes + 1;
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2C2C2C),
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
                SizedBox(width: 10),
                Text('WhatsApp Rest Active', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: Text(
              'Batch limit reached (15 messages in the last 40 minutes).\n\nTo protect your free WhatsApp account from being banned, automatic sending is paused. Please wait $mins minutes before sending the next batch.',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
                child: const Text('OK', style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
        );
      }
      return;
    }

    List<Customer> toSend = _eligibleCustomers.where((c) => _selectedMobiles.contains(c.mobile)).toList();
    if (toSend.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No customers selected!')));
      return;
    }

    if (!_isAccessibilityEnabled) {
      if (!mounted) return;
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
          // 1. Mark customer status so they never get spammed in future sessions
          c.status = 'Reminder Sent';
          await LogService().writeLog(c.mobile, "Payment Reminder Sent ($msg)");
          await CooldownService().recordMessageSent();

          // 2. Remove customer from the active list right away
          if (mounted) {
            setState(() {
              _selectedMobiles.remove(c.mobile);
              _eligibleCustomers.removeWhere((item) => item.mobile == c.mobile);
            });
          }

          // 3. Stop immediately if batch limit of 15 messages has been hit
          if (await CooldownService().isCooldownActive()) {
            await _checkCooldownTicker();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Batch limit of 15 reached! Pausing automatically to prevent WhatsApp ban.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 5),
              ));
            }
            break;
          }
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
        int baseSec = (delayMs / 1000).round();
        // Minimal safe base delay: at least 4 seconds so WhatsApp does not flag speed
        if (baseSec < 4) baseSec = 4;
        // Jitter: add 0 to 3 seconds of randomized variation to avoid robotic pattern detection
        int jitterSec = Random().nextInt(4);
        int remainingSec = baseSec + jitterSec;
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

    // Save all updated statuses ('Reminder Sent') back to Excel immediately
    await widget.excelService.saveCustomers();

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

        // Simple Info & Instructions Banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF161B22),
          child: const Row(
            children: [
              Icon(Icons.info_outline, color: Color(0xFF00E676), size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Simple 15-Day Rule: Unpaid bills sent 15+ days ago are auto-selected below.\n• Tap or long press any user to deselect them if needed.',
                  style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.3),
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
                    'No unpaid customers sent bills 15+ days ago.',
                    style: TextStyle(color: Colors.grey, fontSize: 15),
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
                            : (isChecked
                                ? (isStopped ? Colors.red.withValues(alpha: 0.15) : const Color(0xFF2A2A2A))
                                : const Color(0xFF1A1A1A)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isChecked ? const Color(0xFF00E676) : Colors.white12,
                          width: isChecked ? 1.5 : 1,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: _isSending ? null : () => _toggleSelection(c),
                        onLongPress: _isSending ? null : () => _toggleSelection(c),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Row(
                            children: [
                              Icon(
                                isChecked ? Icons.check_circle : Icons.radio_button_unchecked,
                                color: isChecked ? const Color(0xFF00E676) : Colors.grey,
                                size: 24,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            c.custName.isNotEmpty ? c.custName : c.mobile,
                                            style: TextStyle(
                                              color: !isChecked
                                                  ? Colors.grey
                                                  : (isStopped ? Colors.white : Colors.white),
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                              decoration: !isChecked ? TextDecoration.lineThrough : null,
                                            ),
                                          ),
                                        ),
                                        if (isStopped)
                                          Container(
                                            margin: const EdgeInsets.only(left: 6),
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.red,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: const Text('Stopped / No', style: TextStyle(color: Colors.white, fontSize: 10)),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Text('Due: ₹${c.clBalance.isNotEmpty ? c.clBalance : c.billAmount}', style: TextStyle(color: isChecked ? Colors.orangeAccent : Colors.grey, fontWeight: FontWeight.w600, fontSize: 13)),
                                        const SizedBox(width: 12),
                                        Text('Bill #${c.billNo.isNotEmpty ? c.billNo : "N/A"}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                        const Spacer(),
                                        Text(
                                          days != null ? '$days days ago' : '15+ days ago',
                                          style: TextStyle(color: isChecked ? Colors.orangeAccent : Colors.grey, fontSize: 12, fontWeight: FontWeight.w500),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
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
                    const Icon(Icons.check_circle, color: Color(0xFF00E676), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Selected: ${_selectedMobiles.length} of ${_eligibleCustomers.length} eligible',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isCooldownActive ? Colors.orangeAccent : const Color(0xFF00E676),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: (_selectedMobiles.isEmpty && !_isCooldownActive)
                          ? null
                          : _startSendingReminders,
                      icon: Icon(_isCooldownActive ? Icons.timer : Icons.send, color: Colors.black, size: 18),
                      label: Text(
                        _isCooldownActive ? 'Cooldown (${CooldownService.formatDuration(_remainingCooldown)})' : 'Send Reminders ($_usedQuota/30)',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
