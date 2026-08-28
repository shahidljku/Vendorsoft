import 'package:flutter/material.dart';
import '../config/support_config.dart';
import '../services/license_service.dart';
import '../services/settings_service.dart';

class SettingsAuxiliaryModals {
  static void showContactSupport(BuildContext context, SettingsService settingsService) async {
    final deviceId = await LicenseService().getDeviceId();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.support_agent, color: Color(0xFF00E676), size: 24),
                SizedBox(width: 10),
                Text('Contact Support', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            const Text('Need assistance? Reach out via WhatsApp or phone, or copy your Device ID for troubleshooting.', style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.chat, color: Color(0xFF00E676)),
              title: const Text('WhatsApp Support', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: const Text('Chat directly with our support team', style: TextStyle(color: Colors.grey, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                SupportConfig.openWhatsAppSupport(context, deviceId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.phone, color: Colors.blueAccent),
              title: const Text('Phone Support', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: const Text('+91 94276 98665', style: TextStyle(color: Colors.grey, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                SupportConfig.openPhoneSupport(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.email, color: Colors.orange),
              title: const Text('Email Support', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: const Text('vendorproapk@gmail.com', style: TextStyle(color: Colors.grey, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                SupportConfig.openEmailSupport(context, deviceId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.language, color: Colors.cyanAccent),
              title: const Text('Website', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: const Text('https://vendorpro.pages.dev', style: TextStyle(color: Colors.grey, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                SupportConfig.openWebsite(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.location_on, color: Colors.redAccent),
              title: const Text('Business Address', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: const Text('GF Shop 32, Seventh Heaven, 100 Feet Road, Makarba, Ahmedabad 380055, Gujarat, India', style: TextStyle(color: Colors.grey, fontSize: 12)),
              isThreeLine: true,
              onTap: () {
                Navigator.pop(ctx);
                SupportConfig.openAddressMap(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy, color: Colors.orangeAccent),
              title: const Text('Copy Device ID', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: Text(deviceId, style: const TextStyle(color: Colors.grey, fontSize: 12, fontFamily: 'monospace')),
              onTap: () {
                Navigator.pop(ctx);
                SupportConfig.copyDeviceIdToClipboard(context, deviceId);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  static void showPrivacyDialog(BuildContext context) {
    _showScrollableDialog(
      context: context,
      title: 'Privacy & Data Policy',
      icon: Icons.privacy_tip_outlined,
      content: '''
VendorSoft is designed as an offline-first, local-device management tool for newspaper vendors.

1. Local Data Storage
VendorSoft stores customer data locally on your device's internal storage (/storage/emulated/0/VendSoft/) and does not intentionally upload customer data, bill records, or Excel spreadsheets to VendorSoft servers.

2. Excel Database & Backups
All customer lists and automated backup spreadsheets (.xlsx) are maintained strictly within your device's file storage. You maintain full ownership and physical control of your database at all times.

3. External Sharing
When you choose to send bills, receipts, or backup files via WhatsApp or other external messaging apps, those specific data items are transmitted securely through the chosen messaging application according to your explicit action.

4. License & Device Verification
VendorSoft performs local cryptographic verification of your RSA license key against your device's unique identifier without requiring continuous cloud tracking or intrusive data harvesting.
''',
    );
  }

  static void showTermsDialog(BuildContext context) {
    _showScrollableDialog(
      context: context,
      title: 'Terms & Conditions',
      icon: Icons.gavel_outlined,
      content: '''
1. Operational Purpose
VendorSoft is a specialized utility designed to assist newspaper delivery agents with route management, monthly bill calculations, receipt generation, and thermal printing.

2. Vendor Responsibility
While VendorSoft automates bill calculation based on loaded Excel rates and attendance records, vendors remain solely responsible for verifying customer ledger accuracy prior to dispatching payment reminders.

3. Messaging Compliance
Vendors utilizing automated sending features must adhere to local messaging guidelines and ensure messages are sent only to consented subscribers along their delivery routes.

4. Offline Integrity
Because VendorSoft operates as an offline-first system, vendors are responsible for maintaining regular Excel backups using the built-in backup tools to prevent data loss due to device damage or replacement.
''',
    );
  }

  static void showPermissionsDialog(BuildContext context) {
    _showScrollableDialog(
      context: context,
      title: 'Permissions Used by VendorSoft',
      icon: Icons.security_outlined,
      content: '''
VendorSoft requests only the specific Android permissions necessary to operate your newspaper business locally:

1. Storage & Excel Access (READ/WRITE/MANAGE_EXTERNAL_STORAGE)
Required to read your customers.xlsx file from internal storage, automatically save monthly backup copies to /storage/emulated/0/VendSoft/backups, and generate bill receipt images.

2. Accessibility Service (BIND_ACCESSIBILITY_SERVICE)
Required exclusively when you turn on "Auto Send". This service enables VendorSoft to tap "Send" inside WhatsApp automatically during batch bill runs without requiring you to manually tap the screen 50 times.

3. Exact Alarms & Boot Receiver (SCHEDULE_EXACT_ALARM, RECEIVE_BOOT_COMPLETED)
Required to time the 30-message batch cooldown lock safely and ensure that paused batches automatically wake up and resume even if your phone restarts.

4. Notifications (POST_NOTIFICATIONS)
Required to alert you when an automated batch finish sending or when a cooldown pause begins and ends.

5. Ignore Battery Optimizations (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
Required to prevent Android's background battery saver from terminating long bill-sending batches or cooldown timers midway through your delivery route.
''',
    );
  }

  static void showWhySendingPausesDialog(BuildContext context) {
    _showScrollableDialog(
      context: context,
      title: 'Why Sending Pauses',
      icon: Icons.timer_outlined,
      content: '''
To ensure reliable operation and maintain healthy messaging practices when distributing hundreds of monthly bills, VendorSoft incorporates an automated pacing mechanism:

1. 15-Message Batch Sending
When sending bills or payment reminders to your delivery routes, VendorSoft processes messages in steady batches of 15 customers at a time.

2. Automatic Cooldown Timer
After a batch of 15 messages completes, VendorSoft automatically pauses sending and enters a temporary cooldown timer (configured in your sending options).

3. Why This Safety Lock Exists
This pacing protects your WhatsApp account from being flagged for rapid automated activity and ensures that your phone's memory and clipboard remain responsive while processing high-volume billing images.

4. Automatic Background Resume
You do not need to keep the screen on or tap anything during a cooldown pause. Once the cooldown timer expires, VendorSoft automatically wakes up via Android background alarms and resumes sending the next batch seamlessly.
''',
    );
  }

  static void _showScrollableDialog({
    required BuildContext context,
    required String title,
    required IconData icon,
    required String content,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(icon, color: const Color(0xFF00E676)),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              content.trim(),
              style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  static void showOpenSourceLicensesExplanation(BuildContext context, String appName, String appVersion) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
        title: const Row(
          children: [
            Icon(Icons.code_outlined, color: Color(0xFF00E676)),
            SizedBox(width: 10),
            Expanded(child: Text('Open Source Licenses', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
          ],
        ),
        content: const SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              'VendorSoft is developed using professional open-source software packages and frameworks distributed under permissive licenses (MIT, Apache 2.0, BSD).\n\nThese high-performance libraries power local database storage, receipt printing, device diagnostics, and secure offline operations. We gratefully acknowledge the global developer community for their open-source contributions.',
              style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              showLicensePage(
                context: context,
                applicationName: appName.isNotEmpty ? appName : 'VendorSoft',
                applicationVersion: appVersion,
              );
            },
            child: const Text('View Open Source Licenses', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
