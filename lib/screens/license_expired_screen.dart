import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/subscription_dialog.dart';
import '../services/config_service.dart';
import '../services/payment_service.dart';
import '../services/license_service.dart';

class LicenseExpiredScreen extends StatefulWidget {
  final String deviceId;
  final String customerName;
  final String licenseNumber;
  final String expiryDate;
  final VoidCallback onActivateLicense;

  const LicenseExpiredScreen({
    super.key,
    required this.deviceId,
    required this.customerName,
    required this.licenseNumber,
    required this.expiryDate,
    required this.onActivateLicense,
  });

  @override
  State<LicenseExpiredScreen> createState() => _LicenseExpiredScreenState();
}

class _LicenseExpiredScreenState extends State<LicenseExpiredScreen> {
  String? _checkingOutPlanId;

  @override
  void initState() {
    super.initState();
    // Ensure latest dynamic plans are fetched
    ConfigService().fetchPlans().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final plans = ConfigService().plans.isNotEmpty
        ? ConfigService().plans
        : [
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

    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      appBar: AppBar(
        title: const Text('License Expired', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Warning Box
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B22),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.redAccent.withValues(alpha: 0.15),
                      ),
                      child: const Icon(
                        Icons.timer_off_outlined,
                        size: 48,
                        color: Colors.redAccent,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Demo Period / License Expired',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your 50-customer trial or previous license has expired. Choose a subscription below or enter your renewal key.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    // Device Info box
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Your Device ID:', style: TextStyle(color: Colors.grey, fontSize: 11)),
                                const SizedBox(height: 2),
                                Text(
                                  widget.deviceId,
                                  style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 14, fontFamily: 'monospace'),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, color: Color(0xFF00E676)),
                            tooltip: 'Copy Device ID',
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: widget.deviceId));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Device ID copied to clipboard')),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              const Text(
                'Select Your Plan to Unlock:',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),

              // Dynamic Plan Cards
              for (final plan in plans) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: _buildDynamicPlanCard(plan),
                ),
              ],

              const SizedBox(height: 12),

              // Activation Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: widget.onActivateLicense,
                  icon: const Icon(Icons.key, color: Colors.black),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  label: const Text(
                    'Enter Renewal / Activation Key',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => SystemNavigator.pop(),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    foregroundColor: Colors.grey,
                  ),
                  child: const Text('Exit App', style: TextStyle(fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDynamicPlanCard(Map<String, dynamic> plan) {
    final planId = plan['planId']?.toString() ?? 'PRO_MONTHLY';
    final isPopular = planId == 'PRO_YEARLY' || planId == 'PRO_YEARLY_SOFT';
    final title = plan['planName'] ?? (isPopular ? 'Pro Annual License' : 'Pro Monthly License');
    
    int amountInr = 0;
    if (plan['amountPaise'] != null && plan['amountPaise'] is num) {
      amountInr = (plan['amountPaise'] / 100).toInt();
    } else if (plan['priceINR'] != null && plan['priceINR'] is num) {
      amountInr = (plan['priceINR'] as num).toInt();
    } else {
      amountInr = isPopular ? 11999 : 999;
    }

    final duration = plan['description'] ?? (isPopular ? '12 + 1 Month FREE (395 Days)' : 'Per Month (30 Days)');
    final isCheckingOut = _checkingOutPlanId == planId;

    final features = isPopular
        ? const [
            '13 Months Total Access (1 Month Free)',
            'Unlimited Customers & Batch Bills',
            'Thermal Roll Printing (58mm/80mm)',
            'Direct WhatsApp Message Automation',
            'Full Offline Billing & Excel Sync',
          ]
        : const [
            '30 Days Full Access',
            'Unlimited Customers & Batch Bills',
            'Thermal Roll Printing (58mm/80mm)',
            'Direct WhatsApp Message Automation',
            'Full Offline Billing & Excel Sync',
          ];

    return Container(
      decoration: BoxDecoration(
        color: isPopular ? const Color(0xFF00E676).withValues(alpha: 0.08) : const Color(0xFF161B22),
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
              Expanded(
                child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              if (isPopular)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('1 MONTH FREE', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('₹$amountInr', style: const TextStyle(color: Color(0xFF00E676), fontSize: 28, fontWeight: FontWeight.bold)),
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
              icon: isCheckingOut
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.payment),
              label: Text(
                isCheckingOut ? 'Opening Gateway...' : 'Pay with Razorpay (₹$amountInr)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isPopular ? const Color(0xFF00E676) : Colors.blueAccent,
                foregroundColor: isPopular ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: isCheckingOut
                  ? null
                  : () {
                      setState(() => _checkingOutPlanId = planId);
                      PaymentService().initiateCheckout(
                        context,
                        planId: planId,
                        onResult: (success, message) {
                          if (mounted) {
                            setState(() => _checkingOutPlanId = null);
                          }
                          if (success) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(message ?? 'Activation successful!'),
                                backgroundColor: const Color(0xFF00E676),
                              ),
                            );
                            LicenseService().pollOnlineSubscriptionStatus(force: true);
                            widget.onActivateLicense();
                          } else if (message != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
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
