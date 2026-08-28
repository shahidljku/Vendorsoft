// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/license_service.dart';
import '../services/whatsapp_service.dart';
import '../services/payment_service.dart';
import '../services/config_service.dart';

import 'dart:convert';
import 'package:http/http.dart' as http;

class SubscriptionDialog {
  /// Show modal dialog displaying subscription plans dynamically from the server
  static Future<void> showPlans(BuildContext context, {String? deviceId}) async {
    final resolvedDeviceId = deviceId ?? await LicenseService().getDeviceId();

    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (context) {
        // Initialize with cached plans if already loaded in ConfigService
        List<Map<String, dynamic>> plans = List<Map<String, dynamic>>.from(ConfigService().plans);
        bool isLoading = plans.isEmpty;
        String? errorMessage;
        String? checkingOutPlanId;

        return StatefulBuilder(
          builder: (context, setState) {
            void loadPlansFromServer() {
              final url = Uri.parse('${ConfigService().baseUrl}/plans');
              http.get(url).timeout(const Duration(seconds: 10)).then((response) {
                if (response.statusCode == 200) {
                  final data = jsonDecode(response.body);
                  if (data['success'] == true && data['data'] is List) {
                    final List<dynamic> rawList = data['data'];
                    final fetchedPlans = rawList
                        .where((p) => p is Map && p['isActive'] != false)
                        .map((p) => Map<String, dynamic>.from(p as Map))
                        .toList();

                    if (context.mounted) {
                      setState(() {
                        if (fetchedPlans.isNotEmpty) {
                          plans = fetchedPlans;
                        }
                        isLoading = false;
                        errorMessage = null;
                      });
                    }
                  } else {
                    if (context.mounted) {
                      setState(() {
                        if (plans.isEmpty) {
                          plans = _getFallbackPlans();
                        }
                        isLoading = false;
                      });
                    }
                  }
                } else {
                  if (context.mounted) {
                    setState(() {
                      if (plans.isEmpty) {
                        plans = _getFallbackPlans();
                      }
                      isLoading = false;
                    });
                  }
                }
              }).catchError((e) {
                if (context.mounted) {
                  setState(() {
                    if (plans.isEmpty) {
                      plans = _getFallbackPlans();
                    }
                    isLoading = false;
                  });
                }
              });
            }

            if (isLoading && plans.isEmpty) {
              loadPlansFromServer();
            }

            if (isLoading) {
              return Dialog(
                backgroundColor: const Color(0xFF161B22),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: const Padding(
                  padding: EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFF00E676)),
                      SizedBox(height: 16),
                      Text('Loading Plans...', style: TextStyle(color: Colors.white, fontSize: 15)),
                    ],
                  ),
                ),
              );
            }

            if (errorMessage != null && plans.isEmpty) {
              return Dialog(
                backgroundColor: const Color(0xFF161B22),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                      const SizedBox(height: 16),
                      Text(errorMessage!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676), foregroundColor: Colors.black),
                            onPressed: () {
                              setState(() {
                                isLoading = true;
                                errorMessage = null;
                              });
                              loadPlansFromServer();
                            },
                            child: const Text('Retry'),
                          ),
                        ],
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
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
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
                              const Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Upgrade Plan',
                                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    'Instant online activation',
                                    style: TextStyle(color: Color(0xFF00E676), fontSize: 11, fontWeight: FontWeight.w500),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.grey),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Unlock unlimited customers, premium thermal receipt printing, and WhatsApp automation without limits.',
                        style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
                      ),
                      const SizedBox(height: 16),

                      // Plan Cards
                      for (final plan in plans) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14.0),
                          child: _buildPlanCard(
                            context: context,
                            plan: plan,
                            resolvedDeviceId: resolvedDeviceId,
                            isCheckingOut: checkingOutPlanId == plan['planId'],
                            onStartCheckout: (planId) {
                              setState(() => checkingOutPlanId = planId);
                            },
                            onFinishCheckout: () {
                              if (context.mounted) {
                                setState(() => checkingOutPlanId = null);
                              }
                            },
                          ),
                        ),
                      ],

                      const SizedBox(height: 4),

                      // Device ID info block
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.phone_android, color: Colors.grey, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Your Device ID', style: TextStyle(color: Colors.white54, fontSize: 10)),
                                  const SizedBox(height: 1),
                                  Text(
                                    resolvedDeviceId,
                                    style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.w600),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, color: Color(0xFF00E676), size: 18),
                              tooltip: 'Copy Device ID',
                              constraints: const BoxConstraints(),
                              padding: EdgeInsets.zero,
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: resolvedDeviceId));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Device ID copied to clipboard'),
                                    backgroundColor: Color(0xFF161B22),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
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
        );
      },
    );
  }

  static List<Map<String, dynamic>> _getFallbackPlans() {
    return [
      {
        'planId': 'PRO_YEARLY',
        'planName': 'Pro Annual License',
        'amountPaise': 1199900,
        'durationDays': 395,
        'description': '12 + 1 Month FREE (395 Days)',
        'isActive': true,
      },
      {
        'planId': 'PRO_MONTHLY',
        'planName': 'Pro Monthly License',
        'amountPaise': 99900,
        'durationDays': 30,
        'description': 'Full feature access for 30 days.',
        'isActive': true,
      },
    ];
  }

  static List<String> _getDefaultFeaturesForPlan(String planId) {
    final isYearly = planId == 'PRO_YEARLY' || planId == 'PRO_YEARLY_SOFT';
    if (isYearly) {
      return [
        '13 Months Total Access (1 Month Free)',
        'Unlimited Customers & Batch Bills',
        'Thermal Roll Printing (58mm/80mm)',
        'Direct WhatsApp Message Automation',
        'Full Offline Billing & Excel Sync',
        'Priority Updates & Customer Support',
      ];
    } else {
      return [
        '30 Days Full Access',
        'Unlimited Customers & Batch Bills',
        'Thermal Roll Printing (58mm/80mm)',
        'Direct WhatsApp Message Automation',
        'Full Offline Billing & Excel Sync',
      ];
    }
  }

  static Widget _buildPlanCard({
    required BuildContext context,
    required Map<String, dynamic> plan,
    required String resolvedDeviceId,
    required bool isCheckingOut,
    required Function(String planId) onStartCheckout,
    required VoidCallback onFinishCheckout,
  }) {
    final planId = plan['planId']?.toString() ?? 'PRO_MONTHLY';
    final title = plan['planName'] ?? plan['name'] ?? (planId.contains('YEARLY') ? 'Pro Annual License' : 'Pro Monthly License');
    
    int amountInr = 0;
    if (plan['amountPaise'] != null && plan['amountPaise'] is num) {
      amountInr = (plan['amountPaise'] / 100).toInt();
    } else if (plan['priceINR'] != null && plan['priceINR'] is num) {
      amountInr = (plan['priceINR'] as num).toInt();
    } else if (plan['priceInr'] != null && plan['priceInr'] is num) {
      amountInr = (plan['priceInr'] as num).toInt();
    } else {
      amountInr = planId.contains('YEARLY') ? 11999 : 999;
    }

    final priceFormatted = '₹$amountInr';
    final duration = plan['description'] ?? (planId.contains('YEARLY') ? '12 + 1 Month FREE (395 Days)' : 'Per Month (30 Days)');
    
    List<String> features = [];
    if (plan['features'] != null && plan['features'] is List && (plan['features'] as List).isNotEmpty) {
      features = List<String>.from(plan['features']);
    } else {
      features = _getDefaultFeaturesForPlan(planId);
    }

    final isPopular = planId == 'PRO_YEARLY' || planId == 'PRO_YEARLY_SOFT';

    return Container(
      decoration: BoxDecoration(
        color: isPopular ? const Color(0xFF00E676).withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isPopular ? const Color(0xFF00E676) : Colors.white12,
          width: isPopular ? 2 : 1,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
              if (isPopular)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text('RECOMMENDED', style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(priceFormatted, style: const TextStyle(color: Color(0xFF00E676), fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  duration,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 10),

          // Features
          for (final f in features) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 5.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle, color: isPopular ? const Color(0xFF00E676) : Colors.blueAccent, size: 15),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f, style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.3))),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Action Button: Pay with Razorpay
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: isCheckingOut
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.payment, size: 18),
              label: Text(
                isCheckingOut ? 'Opening Gateway...' : 'Pay with Razorpay ($priceFormatted)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isPopular ? const Color(0xFF00E676) : Colors.blueAccent,
                foregroundColor: isPopular ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: isCheckingOut
                  ? null
                  : () {
                      onStartCheckout(planId);
                      PaymentService().initiateCheckout(
                        context,
                        planId: planId,
                        onResult: (success, message) {
                          onFinishCheckout();
                          if (success) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(message ?? 'Activation successful!'),
                                backgroundColor: const Color(0xFF00E676),
                                duration: const Duration(seconds: 4),
                              ),
                            );
                            if (Navigator.of(context, rootNavigator: true).canPop()) {
                              Navigator.of(context, rootNavigator: true).pop();
                            }
                            LicenseService().pollOnlineSubscriptionStatus(force: true);
                          } else if (message != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(message),
                                backgroundColor: Colors.redAccent,
                                duration: const Duration(seconds: 4),
                              ),
                            );
                          }
                        },
                      );
                    },
            ),
          ),
        ],
      ),
    );
  }
}
