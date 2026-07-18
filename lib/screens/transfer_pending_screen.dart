import 'dart:async';
import 'package:flutter/material.dart';
import '../services/transfer_service.dart';
import '../services/license_service.dart';
import '../services/registration_service.dart';
import '../services/settings_service.dart';
import '../main.dart';
import 'onboarding_screen.dart';

class TransferPendingScreen extends StatefulWidget {
  final String transferId;
  final String customerId;
  final String mobileNumber;

  const TransferPendingScreen({
    Key? key,
    required this.transferId,
    required this.customerId,
    required this.mobileNumber,
  }) : super(key: key);

  @override
  State<TransferPendingScreen> createState() => _TransferPendingScreenState();
}

class _TransferPendingScreenState extends State<TransferPendingScreen> {
  Timer? _timer;
  bool _isLoading = false;
  String _status = 'PENDING';

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    // Poll every 5 seconds
    _timer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_isLoading) return;
      _isLoading = true;
      try {
        final data = await TransferService().pollTransferStatus(widget.transferId);
        if (data != null && mounted) {
          final status = data['status'] as String;
          if (status == 'APPROVED') {
            timer.cancel();
            setState(() {
              _status = 'APPROVED';
            });
            await _handleApproved();
          } else if (status == 'REJECTED') {
            timer.cancel();
            setState(() {
              _status = 'REJECTED';
            });
            _showError('Transfer was rejected by the old device.');
          }
        }
      } catch (e) {
        debugPrint('Polling error: $e');
      }
      _isLoading = false;
    });
  }

  Future<void> _handleApproved() async {
    // Attempt login to fetch the new lease token and hardware lock
    try {
      showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.orange)));
      
      await LicenseService().pollOnlineSubscriptionStatus();
      final success = await LicenseService().isLicensed();

      if (mounted) {
        Navigator.pop(context); // Close loading
        
        if (success) {
          // Since the user is successfully logging into an existing account, skip onboarding terms
          await SettingsService().setHasAcceptedTerms(true);
          
          // Navigate to main layout
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (ctx) => const ImageSenderApp(),
            ),
            (route) => false,
          );
        } else {
          _showError('Missing lease token in response or registration failed.');
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _showError('Failed to complete login: $e');
      }
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Transfer Failed', style: TextStyle(color: Colors.redAccent)),
        content: Text(msg, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (ctx) => const ImageSenderApp()),
                (route) => false,
              );
            },
            child: const Text('Go to Login', style: TextStyle(color: Colors.orange)),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Pending Approval', style: TextStyle(color: Colors.white)),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_status == 'PENDING') ...[
                const CircularProgressIndicator(color: Colors.orange),
                const SizedBox(height: 32),
                const Text(
                  'Waiting for Approval...',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Please open the VendSoft app on your old device and tap "Approve" to transfer your license to this device.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
                ),
              ] else if (_status == 'APPROVED') ...[
                const Icon(Icons.check_circle_outline, color: Colors.green, size: 64),
                const SizedBox(height: 32),
                const Text(
                  'Approved!',
                  style: TextStyle(color: Colors.green, fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Logging you in...',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ],
              const SizedBox(height: 48),
              if (_status == 'PENDING')
                TextButton(
                  onPressed: () async {
                    if (_isLoading) return;
                    _timer?.cancel();
                    setState(() => _isLoading = true);
                    await TransferService().cancelTransfer(widget.transferId);
                    if (mounted) {
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (ctx) => const ImageSenderApp()),
                        (route) => false,
                      );
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  ),
                  child: const Text('Cancel & Login Different Account', style: TextStyle(fontSize: 16)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
