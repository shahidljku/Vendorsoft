import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/customer.dart';
import '../services/log_service.dart';
import '../services/excel_service.dart';
import '../services/whatsapp_service.dart';
import '../services/accessibility_service.dart';
import '../services/settings_service.dart';
import '../services/cooldown_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class SendingScreen extends StatefulWidget {

  final List<Customer> queue;

  final ExcelService excelService;

  final DateTime? scheduledStart;

  const SendingScreen(
      {
        super.key,
        required this.queue,
        required this.excelService,
        this.scheduledStart,
      }
      );

  @override
  State<SendingScreen> createState() =>
      _SendingScreenState();
}


class _SendingScreenState
    extends State<SendingScreen>
    with WidgetsBindingObserver {


  int currentIndex = 0;
  bool isSending = false;
  bool isPaused = false;
  bool _waitingForWhatsApp = false;
  Completer<bool>? _whatsAppCompleter;
  StreamSubscription<bool>? _messageSentSubscription;

  bool _accessibilityEnabled = false;
  int _countdownSeconds = 0;
  bool _useWhatsAppBusiness = false;
  bool _isSleeping = false;
  bool _isWaitingForSchedule = false;
  LogService logService = LogService();
  int _sendingSessionId = 0;

  /// Completer used to block the loop while paused.
  Completer<void>? _pauseCompleter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AccessibilityService.initialize();
    _messageSentSubscription = AccessibilityService.onMessageSent.listen((_) {
      if (AccessibilityService.activeSendingMode == 'bill' && isSending && _waitingForWhatsApp && _whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
        _waitingForWhatsApp = false;
        _whatsAppCompleter!.complete(true);
      }
    });
    
    requestPermission();
    _checkAccessibility();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settingsService = SettingsService();
    _useWhatsAppBusiness = await settingsService.getUseWhatsAppBusiness();

  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSentSubscription?.cancel();
    if (_accessibilityEnabled) {
      AccessibilityService.setAutoSendMode(false);
    }
    if (AccessibilityService.activeSendingMode == 'bill') {
      AccessibilityService.activeSendingMode = 'none';
    }
    WakelockPlus.disable();
    super.dispose();
  }

  /// Detects when the app returns to foreground after WhatsApp.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && AccessibilityService.activeSendingMode == 'bill' && isSending && _waitingForWhatsApp) {
      _waitingForWhatsApp = false;

      // The accessibility broadcast receiver should have completed the completer already.
      // If it hasn't, and accessibility is enabled, we still wait or assume sent as a fallback.
      // For manual mode, we definitely show the dialog.
      if (!_accessibilityEnabled) {
        // Manual mode: show confirmation dialog
        _showSendConfirmationDialog();
      } else {
        // Fallback for accessibility if broadcast failed or user cancelled/encountered error
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

  Future<void> _checkAccessibility() async {
    _accessibilityEnabled = await AccessibilityService.isEnabled();
    if (mounted) setState(() {});
  }

  Future<void> _showSendConfirmationDialog() async {
    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Message Status'),
        content: const Text('Did you send the message in WhatsApp?'),
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

    _whatsAppCompleter?.complete(result ?? false);
  }

  Future<void> requestPermission() async {

    if (await Permission.photos.isDenied) {
      await Permission.photos.request();
    }

    if (await Permission.storage.isDenied) {
      await Permission.storage.request();
    }

    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

  }

  Future<void> processQueue(int sessionId) async {

    while (currentIndex < widget.queue.length) {

      // Check if stopped
      if (!isSending || _sendingSessionId != sessionId) {
        return;
      }

      // Check if paused — wait until resumed
      if (isPaused) {
        _pauseCompleter = Completer<void>();
        await _pauseCompleter!.future;
        if (!isSending || _sendingSessionId != sessionId) {
          return;
        }
      }

      // Check if we need to wait for a scheduled start time
      if (widget.scheduledStart != null) {
        while (DateTime.now().isBefore(widget.scheduledStart!) && isSending && _sendingSessionId == sessionId) {
          if (!_isWaitingForSchedule && mounted) {
            setState(() { _isWaitingForSchedule = true; });
          }
          await Future.delayed(const Duration(seconds: 1));
        }
        if (_isWaitingForSchedule && mounted) {
          setState(() { _isWaitingForSchedule = false; });
        }
        if (!isSending || _sendingSessionId != sessionId) return;
      }



      Customer customer = widget.queue[currentIndex];

      setState(() {
        customer.status = "Processing";
      });

      try {
        // Check if image file exists before sending
        File imageFile = File(customer.resolvedImagePath);
        if (!await imageFile.exists()) {
          throw Exception("Image not found: ${customer.resolvedImagePath}");
        }

        // Validate phone number before trying to send
        String cleanedPhone = customer.mobile.replaceAll(RegExp(r'[^0-9]'), '');
        if (cleanedPhone.length != 10) {
           throw Exception("please enter 10 digit number");
        }

        // ── WhatsApp Integration ──
        if (_accessibilityEnabled) {
          await AccessibilityService.setAutoSendMode(true);
        }

        bool whatsAppOpened = await WhatsAppService.sendImage(
          mobile: customer.mobile,
          imagePath: customer.resolvedImagePath,
          useBusinessApp: _useWhatsAppBusiness,
        );

        if (!whatsAppOpened) {
          throw Exception("Could not open WhatsApp");
        }

        _waitingForWhatsApp = true;
        _whatsAppCompleter = Completer<bool>();

        setState(() {
          customer.status = "Waiting";
        });

        // Add timeout to prevent infinite hang if Accessibility Service fails
        Timer timeoutTimer = Timer(const Duration(seconds: 45), () {
          if (_whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
            _whatsAppCompleter!.complete(false);
          }
        });

        bool wasSent = await _whatsAppCompleter!.future;
        timeoutTimer.cancel();

        if (!isSending || _sendingSessionId != sessionId) {
          setState(() {
            customer.status = "Pending";
          });
          return;
        }

        if (wasSent) {
          setState(() {
            customer.status = "Sent";
            customer.sentTime = DateTime.now().toString();
          });
          await logService.writeLog(customer.mobile, "Sent");
          await CooldownService().recordMessageSent();
          if (await CooldownService().isCooldownActive()) {
            if (mounted) {
              setState(() {
                isSending = false;
              });
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Cooldown limit reached (30 messages). Pausing sending.')),
              );
            }
            WakelockPlus.disable();
            break;
          }
        } else {
          throw Exception("User cancelled in WhatsApp");
        }

      } on WhatsAppException catch (e) {
        setState(() {
          customer.status = "Failed";
          customer.lastError = e.message;
        });
        await logService.writeLog(customer.mobile, "Failed - ${e.message}");
      } catch (e) {
        setState(() {
          customer.status = "Failed";
          customer.lastError = e.toString();
        });
        await logService.writeLog(customer.mobile, "Failed - $e");
      }

      // Always save to Excel after processing the customer, whether success or failure
      bool saved = await widget.excelService.saveCustomers(
        notify: false,
      );

      if (!isSending || _sendingSessionId != sessionId || !mounted) break;

      if (!saved && customer.status == "Sent") {
        setState(() {
          customer.status = "Failed";
          customer.lastError = "Excel save error";
        });
        await logService.writeLog(customer.mobile, "Failed - Excel save error");
      }

      // Advance to next customer
      currentIndex++;

      // Fetch dynamic jitter delay (5 to 10 seconds)
      if (currentIndex < widget.queue.length && isSending && _sendingSessionId == sessionId) {
        int delayMs = CooldownService.getJitterDelayMilliseconds();
        int remainingSeconds = (delayMs / 1000).round();
        
        while (remainingSeconds > 0 && isSending && _sendingSessionId == sessionId) {
          if (isPaused) {
            _pauseCompleter = Completer<void>();
            await _pauseCompleter!.future;
            if (!isSending || _sendingSessionId != sessionId) break;
          }

          if (mounted) {
            setState(() {
              _countdownSeconds = remainingSeconds;
            });
          }
          
          await Future.delayed(const Duration(seconds: 1));
          remainingSeconds--;
        }
        
        if (mounted) {
          setState(() {
            _countdownSeconds = 0;
          });
        }
      }

      if (mounted) {
        setState(() {});
      }
    }

    // All customers processed
    if (currentIndex >= widget.queue.length) {
      if (_accessibilityEnabled) {
        await AccessibilityService.setAutoSendMode(false);
      }
      AccessibilityService.activeSendingMode = 'none';

      setState(() {
        isSending = false;
      });
      widget.excelService.triggerNotify();

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'Queue Completed',
            ),
          ),
        );
      }
      WakelockPlus.disable();
    }
  }


  void startSending() {

    if (isSending) {
      return;
    }

    AccessibilityService.activeSendingMode = 'bill';

    setState(() {
      isSending = true;
      isPaused = false;
    });

    WakelockPlus.enable();

    _sendingSessionId++;
    processQueue(_sendingSessionId);
  }


  void stopSending() {
    if (_accessibilityEnabled) {
      AccessibilityService.setAutoSendMode(false);
    }
    AccessibilityService.activeSendingMode = 'none';

    setState(() {
      isSending = false;
      isPaused = false;
      _waitingForWhatsApp = false;
      _isSleeping = false;
      _isWaitingForSchedule = false;
    });

    if (_pauseCompleter != null && !_pauseCompleter!.isCompleted) {
      _pauseCompleter!.complete();
    }
    // If waiting for WhatsApp, cancel it
    if (_whatsAppCompleter != null && !_whatsAppCompleter!.isCompleted) {
      _whatsAppCompleter!.complete(false);
    }
    WakelockPlus.disable();
  }

  void pauseSending() {
    if (_accessibilityEnabled) {
      AccessibilityService.setAutoSendMode(false);
    }

    setState(() {
      isPaused = true;
    });
  }


  void resumeSending() {

    if (!isPaused) {
      return;
    }

    if (currentIndex >= widget.queue.length) {
      return;
    }

    setState(() {
      isPaused = false;
    });

    if (_pauseCompleter != null && !_pauseCompleter!.isCompleted) {
      _pauseCompleter!.complete();
    }
  }

  void retryFailed() {

    List<Customer> failed =
    widget.queue.where(
            (c) =>
        c.status == "Failed"
    ).toList();

    if (failed.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'No Failed Customers',
          ),
        ),
      );
      return;
    }

    if (isSending) {
      isSending = false;
      if (_pauseCompleter != null && !_pauseCompleter!.isCompleted) {
        _pauseCompleter!.complete();
      }
    }

    for (var c in failed) {
      c.status = "Pending";
      c.sentTime = "";
    }

    setState(() {
      widget.queue.clear();
      widget.queue.addAll(failed);
      currentIndex = 0;
      isPaused = false;
    });

    startSending();
  }



  @override
  Widget build(BuildContext context) {
    if (widget.queue.isEmpty) {

      return Scaffold(

        appBar: AppBar(
          title: const Text("Sending"),
        ),

        body: const Center(

          child: Text(

            "No Customers",

            style: TextStyle(
              fontSize: 20,
            ),

          ),

        ),

      );

    }
    if (currentIndex >= widget.queue.length) {
      int sentCount = widget.queue.where((c) => c.status == 'Sent').length;
      int failedCount = widget.queue.where((c) => c.status == 'Failed').length;
      int skippedCount = widget.queue.length - sentCount - failedCount;

      return Scaffold(
        backgroundColor: const Color(0xFF0B1014),
        appBar: AppBar(
          title: const Text('Sending Summary'),
          centerTitle: true,
          elevation: 0,
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: sentCount == widget.queue.length 
                        ? const Color(0xFF00E676).withValues(alpha: 0.1) 
                        : Colors.orange.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    sentCount == widget.queue.length ? Icons.task_alt : Icons.assignment_turned_in,
                    size: 80,
                    color: sentCount == widget.queue.length ? const Color(0xFF00E676) : Colors.orange,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Queue Completed',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Processed ${widget.queue.length} customers',
                  style: const TextStyle(fontSize: 16, color: Colors.white70),
                ),
                const SizedBox(height: 32),
                Card(
                  color: const Color(0xFF161B22),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _buildSummaryRow('Successfully Sent', sentCount.toString(), const Color(0xFF00E676), Icons.check_circle),
                        const Divider(color: Colors.white12, height: 24),
                        _buildSummaryRow('Failed', failedCount.toString(), Colors.red, Icons.error),
                        if (skippedCount > 0) ...[
                          const Divider(color: Colors.white12, height: 24),
                          _buildSummaryRow('Skipped', skippedCount.toString(), Colors.grey, Icons.skip_next),
                        ]
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Back to Home', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    if (failedCount > 0) ...[
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            retryFailed();
                            setState(() {}); // refresh the UI after retrying
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Retry Failed', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }


    Customer customer =
    widget.queue[currentIndex];


    return Scaffold(

      appBar: AppBar(

        title:
        const Text("Sending"),

        actions: [
          // Accessibility toggle indicator
          IconButton(
            icon: Icon(
              _accessibilityEnabled
                  ? Icons.flash_on
                  : Icons.flash_off,
              color: _accessibilityEnabled
                  ? Colors.amber
                  : null,
            ),
            tooltip: _accessibilityEnabled
                ? 'Auto-Send: ON'
                : 'Auto-Send: OFF (tap to enable)',
            onPressed: () async {
              if (!_accessibilityEnabled) {
                await AccessibilityService.showGuidanceDialog(context);
                bool check = await AccessibilityService.isEnabled();
                if (mounted) setState(() { _accessibilityEnabled = check; });
              }
            },
          ),
        ],

      ),

      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Current Customer Card
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 4,
              shadowColor: Colors.black26,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Sending to',
                          style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.bold),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _getStatusColor(customer.status).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            customer.status,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _getStatusColor(customer.status),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      customer.mobile,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    // Image Preview
                    Container(
                      height: 180,
                      width: 180,
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Builder(
                          builder: (context) {
                            File file = File(customer.resolvedImagePath);
                            if (!file.existsSync()) {
                              return Center(
                                child: Icon(Icons.image_not_supported, size: 60, color: Colors.grey.withValues(alpha: 0.5)),
                              );
                            }
                            try {
                              return Image.file(file, fit: BoxFit.cover);
                            } catch (e) {
                              return Center(
                                child: Icon(Icons.broken_image, size: 60, color: Colors.grey.withValues(alpha: 0.5)),
                              );
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Progress Section
            Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Queue Progress', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(
                      '${currentIndex + 1} of ${widget.queue.length}',
                      style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: widget.queue.isEmpty ? 0 : (currentIndex + 1) / widget.queue.length,
                    minHeight: 12,
                    backgroundColor: Colors.grey.withValues(alpha: 0.2),
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Status Messages
            if (_waitingForWhatsApp)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Waiting for WhatsApp...',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent),
                    ),
                  ],
                ),
              ),

            if (_countdownSeconds > 0)
              Text(
                'Next customer in $_countdownSeconds seconds...',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orangeAccent),
              ),

            if (_isSleeping)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.bedtime, color: Colors.deepPurple),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Sleeping based on schedule...',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.deepPurple),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),

            if (_isWaitingForSchedule && widget.scheduledStart != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.schedule, color: Colors.blueAccent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Scheduled to start at ${TimeOfDay.fromDateTime(widget.scheduledStart!).format(context)}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),

            const Spacer(),

            // Controls
            Wrap(
              spacing: 16,
              runSpacing: 16,
              alignment: WrapAlignment.center,

              children: [

                ElevatedButton(

                  onPressed:
                  isSending
                      ? null
                      : startSending,

                  child:
                  const Text(

                    'Start',

                  ),

                ),



                ElevatedButton(

                  onPressed:

                  (isSending && !isPaused)

                      ? pauseSending

                      : null,


                  child:

                  const Text(

                    'Pause',

                  ),

                ),




                ElevatedButton(

                  onPressed:

                  isPaused

                      ? resumeSending

                      : null,


                  child:

                  const Text(

                    'Resume',

                  ),

                ),




                ElevatedButton(

                  onPressed:

                  stopSending,


                  child:

                  const Text(

                    'Stop',

                  ),

                ),




                ElevatedButton(

                  onPressed:

                  isSending ? null : retryFailed,


                  child:

                  const Text(

                    'Retry Failed',

                  ),

                ),

              ],

            ),



          ],

        ),

      ),

    );

  }

  Color _getStatusColor(String status) {
    switch (status) {
      case "Sent":
        return Colors.green;
      case "Processing":
        return Colors.orange;
      case "Waiting":
        return Colors.blue;
      case "Failed":
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  Widget _buildSummaryRow(String label, String value, Color color, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
          ),
        ),
      ],
    );
  }

}
