import 'dart:io';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onCompleted;
  final SettingsService settingsService;

  const OnboardingScreen({
    super.key,
    required this.onCompleted,
    required this.settingsService,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _termsAccepted = false;

  void _nextPage() {
    if (_currentPage < 2) {
      _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    } else {
      _finishOnboarding();
    }
  }

  Future<void> _finishOnboarding() async {
    // Step 5: Automatically create VendorSoft folders if missing without requesting permissions
    try {
      final baseDir = Directory('/storage/emulated/0/VendSoft');
      final backupDir = Directory('/storage/emulated/0/VendSoft/backups');
      if (!baseDir.existsSync()) {
        baseDir.createSync(recursive: true);
      }
      if (!backupDir.existsSync()) {
        backupDir.createSync(recursive: true);
      }
    } catch (e) {
      // If storage permission is not yet granted, folders will be created automatically later when permission is requested on first save/read.
    }

    // Step 6: Save acceptance and continue into app
    await widget.settingsService.setHasAcceptedTerms(true);
    widget.onCompleted();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      body: SafeArea(
        child: Column(
          children: [
            // Top Progress Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: List.generate(3, (index) {
                  final isActive = index == _currentPage;
                  final isPassed = index < _currentPage;
                  return Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      height: 4,
                      decoration: BoxDecoration(
                        color: isActive || isPassed ? const Color(0xFF00E676) : Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
            ),

            // Page Content
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(), // Prevent skipping terms via swipe
                onPageChanged: (idx) {
                  setState(() => _currentPage = idx);
                },
                children: [
                  _buildWelcomeSlide(),
                  _buildTermsSlide(),
                  _buildPrivacySlide(),
                ],
              ),
            ),

            // Bottom Navigation & Actions
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  if (_currentPage > 0)
                    TextButton(
                      onPressed: () {
                        _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                      },
                      child: const Text('Back', style: TextStyle(color: Colors.white54, fontSize: 15)),
                    )
                  else
                    const SizedBox.shrink(),
                  const Spacer(),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: (_currentPage == 1 && !_termsAccepted)
                          ? Colors.grey.shade800
                          : const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: (_currentPage == 1 && !_termsAccepted) ? null : _nextPage,
                    child: Text(
                      _currentPage == 2 ? 'Get Started & Enter App' : (_currentPage == 1 ? 'Accept & Continue' : 'Next'),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomeSlide() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF00E676).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.newspaper, size: 72, color: Color(0xFF00E676)),
          ),
          const SizedBox(height: 32),
          const Text(
            'Welcome to VendorSoft',
            style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Text(
            'The complete offline billing, route management, and automated WhatsApp dispatch solution specifically built for newspaper vendors and distribution agents.',
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _buildHighlightRow(Icons.offline_bolt_outlined, '100% Offline Capability', 'Your database lives on your device. No cloud logins or external internet required.'),
          _buildHighlightRow(Icons.chat_bubble_outline, 'Automated Bill Dispatch', 'Send monthly bills directly through WhatsApp or WhatsApp Business in safety batches.'),
          _buildHighlightRow(Icons.print_outlined, 'Instant Thermal Receipts', 'Print professional 58mm/80mm Bluetooth receipts along your morning routes.'),
        ],
      ),
    );
  }

  Widget _buildTermsSlide() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Terms & Conditions',
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Please read and accept the operational terms for using VendorSoft.',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: const SingleChildScrollView(
                child: Text(
                  '''1. Operational License
VendorSoft is licensed to newspaper vendors for tracking deliveries, rates, and customer billing. Commercial licenses are hardware-locked to the device's unique ID.

2. WhatsApp & Messaging Responsibilities
VendorSoft automates message dispatching via your installed WhatsApp application. You agree to use steady batch cooldown intervals to maintain compliance with third-party messaging terms.

3. Data Management Guarantee
All customer records, balances, and Excel spreadsheets are maintained locally on your mobile device. You are responsible for creating periodic backup snapshots using the built-in backup tools.

4. Limitation of Liability
VendorSoft provides automated calculation and printing utilities. The software developer and distributor are not responsible for accidental data loss resulting from hardware failure or un-backed-up uninstallation.''',
                  style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.6),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: () {
              setState(() => _termsAccepted = !_termsAccepted);
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: _termsAccepted ? const Color(0xFF00E676).withValues(alpha: 0.15) : const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _termsAccepted ? const Color(0xFF00E676) : Colors.white24),
              ),
              child: Row(
                children: [
                  Checkbox(
                    value: _termsAccepted,
                    onChanged: (val) {
                      setState(() => _termsAccepted = val ?? false);
                    },
                    activeColor: const Color(0xFF00E676),
                    checkColor: Colors.black,
                  ),
                  const Expanded(
                    child: Text(
                      'I accept the Terms & Conditions of Operation',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacySlide() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF00E676).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.privacy_tip_outlined, size: 64, color: Color(0xFF00E676)),
          ),
          const SizedBox(height: 32),
          const Text(
            'Privacy & Local Storage',
            style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Text(
            'VendorSoft is built on an offline-first architecture. Your business data belongs strictly to you.',
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _buildHighlightRow(
            Icons.folder_shared_outlined,
            'Dedicated Storage Directory',
            'Your primary data will be saved inside /storage/emulated/0/VendSoft/ and protected against accidental overwrites.',
          ),
          _buildHighlightRow(
            Icons.security,
            'Zero Cloud Scraping',
            'No subscriber numbers, collection routes, or financial transactions are ever transmitted to external servers.',
          ),
          _buildHighlightRow(
            Icons.touch_app_outlined,
            'On-Demand Permissions Only',
            'We will never request storage or accessibility permissions right now. We only ask when you tap "Send Bills" or "Print Receipt".',
          ),
        ],
      ),
    );
  }

  Widget _buildHighlightRow(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF00E676), size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
