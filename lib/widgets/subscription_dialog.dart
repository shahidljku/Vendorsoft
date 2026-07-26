// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/license_service.dart';
import '../services/whatsapp_service.dart';
import '../services/payment_service.dart';

import 'dart:convert';
import 'package:http/http.dart' as http;

class SubscriptionDialog {
  /// Show modal dialog displaying subscription plans dynamically from the server
  static Future<void> showPlans(BuildContext context, {String? deviceId}) async {
    final resolvedDeviceId = deviceId ?? await LicenseService().getDeviceId();

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        bool isLoading = true;
        List<dynamic> plans = [];
        String? errorMessage;

        return StatefulBuilder(
          builder: (context, setState) {
            if (isLoading && plans.isEmpty) {
              // Fetch plans
              http.get(Uri.parse('https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1/plans'))
                  .timeout(const Duration(seconds: 10))
                  .then((response) {
                if (response.statusCode == 200) {
                  final data = jsonDecode(response.body);
                  if (data['success'] == true) {
                    setState(() {
                      plans = data['data'] ?? [];
                      isLoading = false;
                    });
                  } else {
                    setState(() {
                      errorMessage = 'Failed to load plans.';
                      isLoading = false;
                    });
                  }
                } else {
                  setState(() {
                    errorMessage = 'Server error.';
                    isLoading = false;
                  });
                }
              }).catchError((e) {
                setState(() {
                  errorMessage = 'Network error: $e';
                  isLoading = false;
                });
              });
            }

            if (isLoading) {
              return const Dialog(
                backgroundColor: Color(0xFF161B22),
                child: Padding(
                  padding: EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFF00E676)),
                      SizedBox(height: 16),
                      Text('Loading Plans...', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              );
            }

            if (errorMessage != null) {
              return Dialog(
                backgroundColor: const Color(0xFF161B22),
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                      const SizedBox(height: 16),
                      Text(errorMessage!, style: const TextStyle(color: Colors.white)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      )
                    ],
                  ),
                ),
              );
            }

            return Dialog(
              backgroundColor: const Color(0xFF161B22),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(color: const Color(0xFF00E676).withValues(alpha: 0.3)),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00E676).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.workspace_premium, color: Color(0xFF00E676), size: 28),
                            ),
                            const SizedBox(width: 12),
                            const Text(
                              'Upgrade Plan',
                              style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Unlock unlimited customers, premium thermal printing, and WhatsApp automation without limits.',
                      style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 20),

                    ...plans.map((plan) {
                      final title = plan['planName'] ?? plan['name'] ?? 'Plan';
                      final price = plan['amountPaise'] != null ? '₹${(plan['amountPaise'] / 100).toInt()}' : '₹${plan['priceINR'] ?? 0}';
                      final duration = plan['description'] ?? plan['duration'] ?? 'Subscription';
                      final features = List<String>.from(plan['features'] ?? []);
                      final planId = plan['planId'] ?? '';
                      final isPopular = planId == 'PRO_YEARLY';
                      
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: _buildPlanCard(
                          context: context,
                          title: title,
                          price: price,
                          duration: duration,
                          features: features,
                          isPopular: isPopular,
                          deviceId: resolvedDeviceId,
                          planName: title,
                          amount: plan['priceINR']?.toString() ?? '0',
                          planId: planId,
                        ),
                      );
                    }),

                    // Device ID info block
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.phone_android, color: Colors.grey, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Your Device ID: $resolvedDeviceId',
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, color: Color(0xFF00E676), size: 18),
                            tooltip: 'Copy Device ID',
                            constraints: const BoxConstraints(),
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: resolvedDeviceId));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Device ID copied to clipboard')));
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static Widget _buildPlanCard({
    required BuildContext context,
    required String title,
    required String price,
    required String duration,
    required List<String> features,
    required bool isPopular,
    required String deviceId,
    required String planName,
    required String amount,
    required String planId,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isPopular ? const Color(0xFF00E676).withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isPopular ? const Color(0xFF00E676) : Colors.white12,
          width: isPopular ? 2 : 1,
        ),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              if (isPopular)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('RECOMMENDED', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(price, style: const TextStyle(color: Color(0xFF00E676), fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Expanded(child: Text(duration, style: const TextStyle(color: Colors.white70, fontSize: 13))),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 12),
          for (final f in features) ...[
            Row(
              children: [
                Icon(Icons.check_circle_outline, color: isPopular ? const Color(0xFF00E676) : Colors.blueAccent, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(f, style: const TextStyle(color: Colors.white, fontSize: 13))),
              ],
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Pay with Razorpay', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              style: ElevatedButton.styleFrom(
                backgroundColor: isPopular ? const Color(0xFF00E676) : Colors.blueAccent,
                foregroundColor: isPopular ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                PaymentService().initiateCheckout(
                  context,
                  planId: planId,
                  onResult: (success, message) {
                    if (success) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(message ?? 'Activation successful!'), backgroundColor: const Color(0xFF00E676)),
                      );
                      // Close dialogs and reload
                      Navigator.of(context).popUntil((route) => route.isFirst);
                      LicenseService().pollOnlineSubscriptionStatus(force: true);
                    } else if (message != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
                      );
                    }
                  }
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Show QR Code Payment dialog with developer UPI ID & instructions
  static Future<void> showPaymentQr(BuildContext context, String planName, String amount, {String? deviceId}) async {
    final resolvedDeviceId = deviceId ?? await LicenseService().getDeviceId();
    final upiId = LicenseService().getDeveloperUpiId();

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF161B22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Scan & Pay via UPI', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    IconButton(icon: const Icon(Icons.close, color: Colors.grey), onPressed: () => Navigator.pop(context)),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(planName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                      Text('₹$amount', style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 18)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // QR Code Display Box
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(color: const Color(0xFF00E676).withValues(alpha: 0.2), blurRadius: 16, spreadRadius: 2),
                    ],
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.qr_code_scanner, color: Colors.black, size: 140),
                      const SizedBox(height: 8),
                      Text('UPI ID: $upiId', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 4),
                      Text('Scan with GPay, PhonePe, or Paytm', style: TextStyle(color: Colors.grey.shade700, fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Note: UPI ID is currently set to "$upiId".\n(Developer check reminder before final release)',
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 11, fontStyle: FontStyle.italic),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),

                // Steps to activate
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Activation Instructions:', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      Text(
                        '1. Scan the QR above or transfer ₹$amount via UPI.\n2. Tap below to copy your Device ID ($resolvedDeviceId) and send your payment screenshot to the developer via WhatsApp.',
                        style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Action Button: Copy Device ID & WhatsApp
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.message, color: Colors.white),
                    label: const Text('Send Screenshot via WhatsApp', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366), // WhatsApp Green
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () async {
                      Clipboard.setData(ClipboardData(text: resolvedDeviceId));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Device ID copied to clipboard! Opening WhatsApp...')),
                      );
                      final msg = 'Hello Developer,\nI have paid ₹$amount for $planName.\nMy Device ID is: $resolvedDeviceId\nPlease activate my VendSoft license.';
                      try {
                        await WhatsAppService.sendWhatsAppMessage(
                          mobile: '+919427698665',
                          message: msg,
                          useBusinessApp: false,
                        );
                      } catch (e) {
                        print('Error opening WhatsApp: $e');
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
