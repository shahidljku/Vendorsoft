import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:image_sender/services/license_service.dart';
import '../services/payment_service.dart';
import '../services/transfer_service.dart';
import '../services/registration_service.dart';
import '../services/settings_service.dart';
import '../main.dart';
import 'transfer_pending_screen.dart';

class ActivationScreen extends StatefulWidget {
  final LicenseService licenseService;
  final VoidCallback onActivated;

  const ActivationScreen({
    super.key,
    required this.licenseService,
    required this.onActivated,
  });

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _licenseController = TextEditingController();
  String _deviceId = 'Loading...';
  bool _isLoading = true;
  String _errorMessage = '';
  List<dynamic> _plans = [];
  bool _wasCancelled = false;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    _loadDeviceId();
    _loadPlans();
    _checkCancelledState();
    _startPolling();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (mounted && !_isLoading) {
        await widget.licenseService.pollOnlineSubscriptionStatus(force: true);
        final isLic = await widget.licenseService.isLicensed();
        final isDemo = await widget.licenseService.isDemoMode();
        if (isLic && !isDemo && mounted) {
          timer.cancel();
          widget.onActivated();
        }
      }
    });
  }

  Future<void> _checkCancelledState() async {
    const storage = const FlutterSecureStorage();
    final val = await storage.read(key: 'was_cancelled_on_device');
    if (mounted) {
      setState(() {
        _wasCancelled = val == 'true';
      });
    }
  }

  Future<void> _logout() async {
    setState(() => _isLoading = true);
    const storage = const FlutterSecureStorage();
    await storage.delete(key: 'was_cancelled_on_device');
    
    // Log out from the server to invalidate the device session/FCM token
    try {
      await RegistrationService().logoutFromServer();
    } catch(e) {}
    
    await FirebaseAuth.instance.signOut();
    
    // Reset terms acceptance so they are forced back to OnboardingScreen to register a new account
    await SettingsService().setHasAcceptedTerms(false);
    
    if (mounted) {
      // Use UniqueKey to force Flutter to completely destroy and rebuild the ImageSenderApp state
      runApp(ImageSenderApp(key: UniqueKey()));
    }
  }

  Future<void> _loadPlans() async {
    try {
      final url = Uri.parse('https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1/plans');
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && mounted) {
          setState(() {
            _plans = data['data'] ?? [];
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to load dynamic plans: $e');
    }
  }

  Future<void> _loadDeviceId() async {
    final id = await widget.licenseService.getDeviceId();
    setState(() {
      _deviceId = id;
      _isLoading = false;
    });
  }

  void _verifyLicense() async {
    final key = _licenseController.text.trim();
    if (key.isEmpty) {
      setState(() => _errorMessage = 'Please enter a license key');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    final success = await widget.licenseService.verifyAndSaveLicense(key);

    if (!mounted) return;

    if (success) {
      widget.onActivated();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Invalid license key for this device.';
      });
    }
  }

  void _copyDeviceId() {
    Clipboard.setData(ClipboardData(text: _deviceId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device ID copied to clipboard')),
    );
  }

  void _buyPlan(String planId) {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    PaymentService().initiateCheckout(
      context,
      planId: planId,
      onResult: (success, message) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message ?? 'Activation successful!'), backgroundColor: const Color(0xFF00E676)),
          );
          widget.onActivated();
        } else if (message != null && message.isNotEmpty) {
          setState(() => _errorMessage = message);
        }
      },
    );
  }



  @override
  void dispose() {
    _pollingTimer?.cancel();
    _licenseController.dispose();
    PaymentService().dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      appBar: AppBar(
        title: const Text('App Activation'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Instant Online Activation',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 12),
              if (_plans.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: CircularProgressIndicator(color: Color(0xFF00E676)),
                  ),
                )
              else
                ..._plans.map((plan) {
                  final isRecommended = plan['planId'] == 'PRO_YEARLY';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: isRecommended ? const Color(0xFF00E676) : Colors.white12, width: isRecommended ? 1.5 : 1.0),
                      ),
                      color: const Color(0xFF161B22),
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  plan['planName']?.toString().toUpperCase() ?? 'PLAN',
                                  style: TextStyle(
                                    color: isRecommended ? const Color(0xFF00E676) : Colors.white70,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                                if (isRecommended)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(color: const Color(0xFF00E676), borderRadius: BorderRadius.circular(12)),
                                    child: const Text('RECOMMENDED', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 10)),
                                  )
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text('₹${((plan['amountPaise'] ?? 0) / 100).toStringAsFixed(0)}', style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
                                Text(' / ${plan['planId'] == 'PRO_YEARLY' ? 'year' : 'month'}', style: const TextStyle(color: Colors.grey, fontSize: 14)),
                              ],
                            ),
                            if (plan['description'] != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                                child: Text(plan['description'], style: const TextStyle(color: Colors.white54, fontSize: 12, fontStyle: FontStyle.italic)),
                              ),
                            const SizedBox(height: 12),
                            if (plan['features'] != null)
                              ...List<String>.from(plan['features']).map((f) => _buildFeatureRow(f)),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: isRecommended
                                  ? ElevatedButton(
                                      onPressed: _isLoading ? null : () => _buyPlan(plan['planId']),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF00E676),
                                        foregroundColor: Colors.black,
                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      child: const Text('Activate Annual License Now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                    )
                                  : OutlinedButton(
                                      onPressed: _isLoading ? null : () => _buyPlan(plan['planId']),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        side: const BorderSide(color: Colors.white38),
                                        padding: const EdgeInsets.symmetric(vertical: 14),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      child: const Text('Activate Monthly License', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              /* 
              // TODO(Agent): The manual prepaid license key activation section has been temporarily 
              // commented out. The user plans to replace this flow with "Google Sign-In" 
              // in the future. Do not add Google Sign-In yet until the user explicitly requests it.
              const SizedBox(height: 28),
              const Center(
                child: Text(
                  'Or activate manually with a prepaid license key:',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              ),
              const SizedBox(height: 12),
              */
              const SizedBox(height: 28),
              Card(
                elevation: 0,
                color: const Color(0xFF161B22),
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      /*
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF00E676).withValues(alpha: 0.1),
                        ),
                        child: const Icon(
                          Icons.lock_outline,
                          size: 60,
                          color: Color(0xFF00E676),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Secure Activation',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Please send the Device ID below to the developer to receive your license key.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade600, height: 1.4),
                      ),
                      const SizedBox(height: 32),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white12,
                          ),
                        ),
                        child: Column(
                          children: [
                            const Text(
                              'YOUR DEVICE ID',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Text(
                                    _deviceId,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy, color: Color(0xFF00E676)),
                                  onPressed: _isLoading ? null : _copyDeviceId,
                                  tooltip: 'Copy Device ID',
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        controller: _licenseController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Enter License Key',
                          labelStyle: const TextStyle(color: Colors.grey),
                          prefixIcon: const Icon(Icons.key, color: Colors.grey),
                          errorText: _errorMessage.isEmpty ? null : _errorMessage,
                          enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white24), borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFF00E676)), borderRadius: BorderRadius.circular(12)),
                        ),
                        maxLines: 2,
                        enabled: !_isLoading,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _verifyLicense,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: const Color(0xFF00E676),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  height: 24,
                                  width: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.black,
                                  ),
                                )
                              : const Text(
                                  'Verify & Activate',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      */
                      if (_errorMessage.isNotEmpty) ...[
                        Text(
                          _errorMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.redAccent.shade100, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_wasCancelled) ...[
                        Text(
                          'Your subscription has expired or been cancelled. Please select a plan to continue.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.redAccent.shade100, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 16),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _isLoading ? null : _logout,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            foregroundColor: Colors.grey,
                            side: const BorderSide(color: Colors.grey),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text(
                            'Logout / Switch Account',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF00E676), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
