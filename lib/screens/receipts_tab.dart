import 'dart:io';
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:screenshot/screenshot.dart';

import '../models/customer.dart';
import '../models/payment_status_helper.dart';
import '../services/excel_service.dart';
import '../services/settings_service.dart';
import '../services/cooldown_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/whatsapp_service.dart';
import '../services/accessibility_service.dart';
import '../services/license_service.dart';
import '../services/log_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/print_service.dart';
import '../services/receipt_service.dart';
import '../widgets/cooldown_fab.dart';

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

  late TabController _tabController;
  bool _waitingForWhatsApp = false;
  Completer<bool>? _whatsAppCompleter;
  StreamSubscription<bool>? _messageSentSubscription;
  StreamSubscription<bool>? _messageFailedSubscription;
  bool _isAccessibilityEnabled = false;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AccessibilityService.initialize();
    _messageSentSubscription = AccessibilityService.onMessageSent.listen((_) {
      if (AccessibilityService.activeSendingMode == 'receipt' && _isSending && _waitingForWhatsApp && _whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
        _waitingForWhatsApp = false;
        _whatsAppCompleter!.complete(true);
      }
    });
    _messageFailedSubscription = AccessibilityService.onMessageFailed.listen((_) {
      if (AccessibilityService.activeSendingMode == 'receipt' && _isSending && _waitingForWhatsApp && _whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
        _waitingForWhatsApp = false;
        _whatsAppCompleter!.complete(false);
      }
    });
    _tabController = TabController(
      length: 2, 
      vsync: this,
      initialIndex: widget.initialFilter == 'Sent' ? 1 : 0,
    );
    _checkAccessibility();
    _computeQueues();
  }

  void _computeQueues() {
    _pendingReceipts = widget.excelService.allCustomers.where((c) {
      String rst = c.receiptStatus.trim().toLowerCase();
      return c.isPaid && (rst != 'sent' && rst != 'message sent');
    }).toList();

    _submittedReceipts = widget.excelService.allCustomers.where((c) {
      String rst = c.receiptStatus.trim().toLowerCase();
      return c.isPaid && (rst == 'sent' || rst == 'message sent');
    }).toList();
  }

  /// Generates a professional sequential receipt number in YYYY-MM-NNN format.
  String _generateReceiptNo() {
    return ReceiptService.generateReceiptNo(widget.excelService.allCustomers);
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
    _messageSentSubscription?.cancel();
    _messageFailedSubscription?.cancel();
    if (_isAccessibilityEnabled) {
      AccessibilityService.setAutoSendMode(false);
    }
    if (AccessibilityService.activeSendingMode == 'receipt') {
      AccessibilityService.activeSendingMode = 'none';
    }
    _messageSentSubscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && AccessibilityService.activeSendingMode == 'receipt' && _isSending && _waitingForWhatsApp) {
      _waitingForWhatsApp = false;
      if (!_isAccessibilityEnabled) {
        _showSendConfirmationDialog();
      } else {
        if (_whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
          Future.delayed(const Duration(milliseconds: 1500), () {
            if (_whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
              _showSendConfirmationDialog();
            }
          });
        }
      }
    }
  }

  Future<void> _showSendConfirmationDialog() async {
    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Receipt Status'),
        content: const Text('Did you send the receipt in WhatsApp?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No / Cancelled'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Yes, Sent'),
          ),
        ],
      ),
    );
    if (_whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
      _whatsAppCompleter?.complete(result ?? false);
    }
  }

  Widget _buildReceiptWidget(Customer customer, String businessName) {
    if (customer.receiptNo.isEmpty) {
      customer.receiptNo = _generateReceiptNo();
    }
    return ReceiptCardWidget(
      customer: customer,
      businessName: businessName,
    );
  }

  void _runPreflightChecks(BuildContext context) async {
    bool isAccessible = await AccessibilityService.isEnabled();
    if (!isAccessible && context.mounted) {
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
    int remainingQuota = await CooldownService().getRemainingQuota();
    int currentDelaySeconds = await widget.settingsService.getInterBillDelaySeconds();
    if (currentDelaySeconds < 3) currentDelaySeconds = 3;
    int currentCooldownMinutes = await CooldownService().getCooldownDurationMinutes();
    if (defaultLimit > remainingQuota && remainingQuota > 0) {
      defaultLimit = remainingQuota;
    }

    int pendingCount = _pendingReceipts.length;
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
                        'Remaining quota: $remainingQuota receipts',
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

                      // ── Per-Receipt Send Timer (Min 3s floor, can only increase) ──
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
                                    'Per-Receipt Timer (Delay)',
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
                              _startSending(limit, delaySeconds: selectedDelay);
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

  Future<void> _startSending(int limit, {int? delaySeconds}) async {
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

    AccessibilityService.activeSendingMode = 'receipt';
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
        _waitingForWhatsApp = true;
        _whatsAppCompleter = Completer<bool>();
        final currentCompleter = _whatsAppCompleter!;

        StreamSubscription? sub;
        sub = AccessibilityService.onMessageSent.listen((_) {
          if (AccessibilityService.activeSendingMode == 'receipt' && !currentCompleter.isCompleted) {
            currentCompleter.complete(true);
          }
        });
        StreamSubscription? failSub;
        failSub = AccessibilityService.onMessageFailed.listen((_) {
          if (AccessibilityService.activeSendingMode == 'receipt' && !currentCompleter.isCompleted) {
            currentCompleter.complete(false);
          }
        });

        bool whatsAppOpened = await WhatsAppService.sendImage(
          mobile: customer.mobile,
          imagePath: receiptPath,
          useBusinessApp: useBusiness,
        );

        if (!whatsAppOpened) throw Exception("Could not open WhatsApp");

        // Use a longer timeout or rely on AppLifecycleState
        Timer timeoutTimer = Timer(const Duration(seconds: 45), () {
          if (!currentCompleter.isCompleted) {
            currentCompleter.complete(false);
          }
        });

        bool sent = await currentCompleter.future;
        timeoutTimer.cancel();
        await sub.cancel();
        await failSub.cancel();
        _waitingForWhatsApp = false;

        if (sent) {
          customer.receiptStatus = 'Sent';
          sentInSession++;
          await LogService().writeLog(customer.mobile, "Receipt Sent");
          await CooldownService().recordMessageSent();
          if (await CooldownService().isCooldownActive()) {
            if (mounted) {
              setState(() {
                _isSending = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Batch limit reached. Pausing sending for cooldown.')),
              );
            }
            break;
          }
        } else {
          throw Exception("Timeout or failed to send");
        }
      } catch (e) {
        await LogService().writeLog(customer.mobile, "Receipt Failed - $e");
      }

      await widget.excelService.saveCustomers(customers: widget.excelService.allCustomers, notify: false);

      if (!_isSending || !mounted) break;

      if (mounted) {
        setState(() {
          _currentIndex++;
        });
      }
      
      if (_currentIndex < _pendingReceipts.length && sentInSession < limit) {
        int baseSec = delaySeconds ?? (await widget.settingsService.getInterBillDelaySeconds());
        if (baseSec < 3) baseSec = 3;
        int organicJitterMs = Random().nextInt(1200); // 0 to 1.2s temporal jitter
        int totalDelayMs = (baseSec * 1000) + organicJitterMs;
        int remainingSeconds = (totalDelayMs / 1000).round();
        while (remainingSeconds > 0 && _isSending) {
          await Future.delayed(const Duration(seconds: 1));
          remainingSeconds--;
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
      _computeQueues();
      widget.excelService.triggerNotify();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Receipt sending completed!')));
    }
    WakelockPlus.disable();
  }

  void _showEditPaymentDialog(BuildContext context, Customer customer) {
    TextEditingController amountCtrl = TextEditingController(text: customer.amountPaid.isNotEmpty ? customer.amountPaid : customer.billAmount);
    TextEditingController txCtrl = TextEditingController(text: customer.transactionId);
    if (customer.receiptNo.isEmpty) {
      customer.receiptNo = _generateReceiptNo();
    }
    TextEditingController receiptNoCtrl = TextEditingController(text: customer.receiptNo);
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
                      controller: receiptNoCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Receipt No.', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    const SizedBox(height: 8),
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
                    DropdownButtonFormField<String>(
                      initialValue: paymentStatus,
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
                SizedBox(
                  width: double.maxFinite,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.print, color: Colors.blue, size: 16),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.blue),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            ),
                            onPressed: () async {
                              Navigator.pop(context);
                              await PrintService().printReceipt(customer: customer, settingsService: widget.settingsService);
                            },
                            label: const Text('Print', style: TextStyle(color: Colors.blue)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E676),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            ),
                            onPressed: () async {
                              setState(() {
                                if (paymentStatus == 'Unpaid') {
                                  customer.paymentStatus = PaymentStatusHelper.pending;
                                } else {
                                  customer.paymentStatus = PaymentStatusHelper.successful;
                                }
                                customer.receiptNo = receiptNoCtrl.text.trim();
                                customer.amountPaid = amountCtrl.text;
                                customer.transactionId = txCtrl.text;
                                customer.paymentMethod = paymentMethod;
                                customer.paymentDate = "${paymentDate.day.toString().padLeft(2, '0')}/${paymentDate.month.toString().padLeft(2, '0')}/${paymentDate.year}";
                              });
                              await widget.excelService.saveCustomers(customers: widget.excelService.allCustomers);
                              _computeQueues();
                              if (context.mounted) Navigator.pop(context);
                            },
                            child: const Text('Save', style: TextStyle(color: Colors.black)),
                          ),
                        ],
                      ),
                    ],
                  ),
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
              return Dismissible(
                key: Key('receipt_${c.mobile}_$index'),
                background: Container(
                  color: const Color(0xFF00E676),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 24),
                  child: const Icon(Icons.check_circle, color: Colors.black, size: 32),
                ),
                secondaryBackground: Container(
                  color: Colors.blue,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  child: const Icon(Icons.print, color: Colors.white, size: 32),
                ),
                confirmDismiss: (direction) async {
                  if (direction == DismissDirection.startToEnd) {
                    if (c.receiptStatus != 'Sent') {
                      setState(() {
                        c.receiptStatus = 'Sent';
                      });
                      await widget.excelService.saveCustomers();
                      _computeQueues();
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Receipt already marked as sent')));
                    }
                    return false;
                  } else if (direction == DismissDirection.endToStart) {
                    await PrintService().printReceipt(customer: c, settingsService: widget.settingsService);
                    return false;
                  }
                  return false;
                },
                child: ListTile(
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
                                                  await widget.excelService.saveCustomers();
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
                                                  await widget.excelService.saveCustomers();
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
            _computeQueues();
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
          ? CooldownFab(
              label: 'Send Receipts',
              iconData: Icons.send,
              baseColor: _isAccessibilityEnabled ? const Color(0xFF00E676) : Colors.grey,
              onCooldownAction: () => _showCooldownDialog(context),
              onNormalAction: _isAccessibilityEnabled ? () {
                _runPreflightChecks(context);
              } : () async {
                await AccessibilityService.showGuidanceDialog(context);
                bool check = await AccessibilityService.isEnabled();
                if (mounted) setState(() { _isAccessibilityEnabled = check; });
              },
            )
          : null,
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
          '''To prevent WhatsApp from flagging your account as a bot, a cooldown lock is active between batches.

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

}
