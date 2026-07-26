import 'package:flutter/material.dart';

class FaqTopic {
  final String category;
  final String title;
  final String answer;
  final IconData icon;

  const FaqTopic({
    required this.category,
    required this.title,
    required this.answer,
    required this.icon,
  });
}

class HelpAndFaqScreen extends StatefulWidget {
  const HelpAndFaqScreen({super.key});

  @override
  State<HelpAndFaqScreen> createState() => _HelpAndFaqScreenState();
}

class _HelpAndFaqScreenState extends State<HelpAndFaqScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedCategory = 'All';

  static const List<String> _categories = [
    'All',
    'Installation & Trial',
    'Licensing & Keys',
    'Backup & Excel',
    'Printer & WhatsApp',
    'Troubleshooting',
  ];

  static const List<FaqTopic> _topics = [
    // ── Installation & Trial ──
    FaqTopic(
      category: 'Installation & Trial',
      title: 'First Installation',
      icon: Icons.install_mobile_outlined,
      answer: '''
Upon first launch, VendorSoft automatically begins your 30-day trial and asks for file storage permission.

• Tap "Grant Permissions" on the guidance screen.
• VendorSoft automatically creates your primary database file at: /storage/emulated/0/VendSoft/customers.xlsx.
• You can immediately start adding your newspaper subscribers using the "Add Customer" button. No internet connection or login is required.
''',
    ),
    FaqTopic(
      category: 'Installation & Trial',
      title: '30-Day Trial',
      icon: Icons.access_time,
      answer: '''
Your first-install trial gives you 30 full days of access to test VendorSoft's core capabilities:

• Manage unlimited customer records across your delivery routes.
• Test automated WhatsApp bill sending, monthly rate calculations, and Collection Man routing.
• Test Bluetooth thermal receipt printing.
• No credit card, phone number registration, or internet connection is needed during your trial.
''',
    ),
    FaqTopic(
      category: 'Installation & Trial',
      title: 'Trial Expiry',
      icon: Icons.hourglass_disabled_outlined,
      answer: '''
Once the 30-day trial period completes, VendorSoft will prompt you for an Activation Key when opened.

• Your customer records, delivery routes, and Excel spreadsheet are never deleted or locked inside any cloud.
• Your database remains completely safe inside your internal storage at /storage/emulated/0/VendSoft/customers.xlsx.
• To remove the 50-customer trial limit and unlock continuous commercial operation, simply enter a valid commercial activation key.
''',
    ),

    // ── Licensing & Keys ──
    FaqTopic(
      category: 'Licensing & Keys',
      title: 'Commercial License Activation',
      icon: Icons.vpn_key_outlined,
      answer: '''
Activating your commercial license is instant and operates 100% offline:

1. Open VendorSoft and go to Settings -> Deactivate / Activate License (or tap "Activation" when prompted).
2. Note your 16-character Device ID displayed on the screen.
3. Send your Device ID to your distributor via WhatsApp.
4. Paste the RSA Activation Key provided by your distributor into the activation box and tap Activate.
''',
    ),
    FaqTopic(
      category: 'Licensing & Keys',
      title: 'Lifetime License',
      icon: Icons.workspace_premium_outlined,
      answer: '''
VendorSoft supports both subscription packages and permanent Lifetime commercial licenses:

• A Lifetime license is permanently paired with your mobile device's unique hardware ID.
• It never requires monthly renewals, annual re-activation, or internet server check-ins.
• Once activated, your newspaper delivery database operates indefinitely on that mobile device.
''',
    ),
    FaqTopic(
      category: 'Licensing & Keys',
      title: 'Lost License Key',
      icon: Icons.find_in_page_outlined,
      answer: '''
If you accidentally uninstall VendorSoft or reset app data on your exact same mobile phone, you do not need to purchase a new key:

• Because your license key is mathematically generated for your exact device ID, simply paste your original key when you reinstall the app.
• If you misplaced your key text, contact your distributor with your Device ID to request your existing key copy.
''',
    ),
    FaqTopic(
      category: 'Licensing & Keys',
      title: 'Changed Phone',
      icon: Icons.phone_android_outlined,
      answer: '''
Commercial licenses are cryptographically locked to the unique hardware Device ID of each phone to prevent unauthorized copying:

• A license key from an old phone will not activate on a new mobile device.
• When upgrading to a new phone, take a fresh backup of your customers.xlsx file and copy it to the new phone.
• Contact your distributor with your new phone's Device ID to request a replacement license key for your new device.
''',
    ),

    // ── Backup & Excel ──
    FaqTopic(
      category: 'Backup & Excel',
      title: 'Backup',
      icon: Icons.backup_outlined,
      answer: '''
VendorSoft protects your billing history by taking automatic safety copies before major actions. To create a manual backup anytime:

1. Go to Settings -> Database & Backup (Excel).
2. Tap "Create Backup Snapshot".
3. VendorSoft immediately creates a timestamped copy of your active database directly into your phone's internal storage folder.
''',
    ),
    FaqTopic(
      category: 'Backup & Excel',
      title: 'Restore',
      icon: Icons.restore_outlined,
      answer: '''
To recover your customer records from a previous backup snapshot or external Excel sheet:

1. Go to Settings -> Database & Backup (Excel).
2. Tap "Restore from Backup".
3. Select any timestamped backup file from your backups list or phone storage. VendorSoft instantly reloads your complete customer list, pending balances, and Collection Man assignments.
''',
    ),
    FaqTopic(
      category: 'Backup & Excel',
      title: 'Backup Folder Location',
      icon: Icons.folder_open_outlined,
      answer: '''
All database files and safety snapshots reside locally inside your phone's internal memory:

• Active Database: /storage/emulated/0/VendSoft/customers.xlsx
• Backup Snapshots Folder: /storage/emulated/0/VendSoft/backups/

You can view, copy, or share these files anytime using your phone's built-in "My Files" or "File Manager" app.
''',
    ),
    FaqTopic(
      category: 'Backup & Excel',
      title: 'Excel Format',
      icon: Icons.table_chart_outlined,
      answer: '''
If you choose to edit your spreadsheet on a PC, VendorSoft requires a clean 13-column layout:

Col 1: Name | Col 2: Mobile | Col 3: Paper Name | Col 4: Rate | Col 5: Bill Amount | Col 6: Status | Col 7: Image Path | Col 8: Bill Date | Col 9: Paid Amount | Col 10: Attendance | Col 11: CM Code | Col 12: CM Name.

Tip: For guaranteed layout accuracy, we recommend adding and editing customer records directly inside the VendorSoft app.
''',
    ),
    FaqTopic(
      category: 'Backup & Excel',
      title: 'Customer Import',
      icon: Icons.file_upload_outlined,
      answer: '''
You can easily adopt an existing customer sheet created on a PC or shared from another delivery agent:

1. Copy your .xlsx spreadsheet onto your phone storage.
2. Open VendorSoft -> Settings -> Database & Backup (Excel).
3. Tap "Load Custom Excel Spreadsheet". Select your spreadsheet to instantly adopt it as your primary delivery database.
''',
    ),
    FaqTopic(
      category: 'Backup & Excel',
      title: 'Collection Man',
      icon: Icons.directions_walk_outlined,
      answer: '''
Collection Man assignment allows you to track analytics across multiple delivery routes and collectors:

• Assign each customer a Collection Man Code (cmCode) and Name (cmName, e.g., "Ramesh - Route 1").
• On the Dashboard tab, VendorSoft automatically summarizes total assigned bills, collected money, and recovery percentage separately for each Collection Man.
''',
    ),

    // ── Printer & WhatsApp ──
    FaqTopic(
      category: 'Printer & WhatsApp',
      title: 'Thermal Printer Setup',
      icon: Icons.print_outlined,
      answer: '''
Connecting a 58mm or 80mm Bluetooth ESC/POS receipt printer takes less than a minute:

1. Turn on your thermal printer and pair it inside Android Bluetooth settings (common PINs are 0000 or 1234).
2. Open VendorSoft -> Settings -> Printer & Receipts.
3. Tap "Select Bluetooth Printer" and choose your paired printer from the list.
4. Select your paper width (58mm or 80mm) to ensure receipts align perfectly.
''',
    ),
    FaqTopic(
      category: 'Printer & WhatsApp',
      title: 'Printer Not Printing',
      icon: Icons.print_disabled_outlined,
      answer: '''
If your printer feeds paper but prints blank sheets, or fails to connect:

• Paper Upside Down: Thermal receipt paper only prints on one side. Open the printer lid, flip the paper roll around, and close the lid.
• Bluetooth Disconnected: Ensure the printer is powered on and paired in Android Bluetooth settings before tapping print inside VendorSoft.
• Paper Width Mismatch: Check that your setting (58mm vs 80mm) matches your physical paper roll width.
''',
    ),
    FaqTopic(
      category: 'Printer & WhatsApp',
      title: 'WhatsApp',
      icon: Icons.chat_bubble_outline,
      answer: '''
By default, VendorSoft generates monthly billing images and payment reminders and dispatches them directly through your personal WhatsApp application (com.whatsapp). Ensure your personal WhatsApp is installed and logged in before launching batch sending.
''',
    ),
    FaqTopic(
      category: 'Printer & WhatsApp',
      title: 'WhatsApp Business',
      icon: Icons.business_center_outlined,
      answer: '''
If you use a dedicated WhatsApp Business account for your newspaper distribution:

1. Go to Settings -> Sending Options.
2. Turn ON the switch for "Use WhatsApp Business".
3. VendorSoft will immediately route all automated batch sending and billing messages through your WhatsApp Business application (com.whatsapp.w4b).
''',
    ),
    FaqTopic(
      category: 'Printer & WhatsApp',
      title: 'Why Sending Pauses',
      icon: Icons.timer_outlined,
      answer: '''
When sending hundreds of monthly bills along your delivery route, sending too quickly can cause WhatsApp to flag your account or freeze your phone clipboard:

• VendorSoft automatically sends messages in steady batches of 30 customers at a time.
• After a 30-message batch completes, sending pauses automatically for a brief cooldown safety timer.
• Once the cooldown timer finishes, VendorSoft wakes up in the background and sends the next batch without you needing to tap the screen.
''',
    ),

    // ── Troubleshooting ──
    FaqTopic(
      category: 'Troubleshooting',
      title: 'Accessibility Permission',
      icon: Icons.touch_app_outlined,
      answer: '''
Android security rules prevent background apps from tapping buttons inside other apps.

• When you turn ON "Auto Send", VendorSoft asks you to enable the "VendorSoft Accessibility Service".
• This permission allows VendorSoft to automatically tap the "Send" arrow inside WhatsApp during your 30-customer bill run so you don't have to manually tap the screen 50 times.
''',
    ),
    FaqTopic(
      category: 'Troubleshooting',
      title: 'Accessibility Keeps Turning Off',
      icon: Icons.power_settings_new_outlined,
      answer: '''
If Android disables your VendorSoft Accessibility Service every few days, it is caused by your phone's aggressive Battery Saver or Battery Optimization:

1. Go to Settings -> System Diagnostics and verify if "Battery Optimization" shows as Unrestricted.
2. If restricted, open your phone's Android App Info for VendorSoft -> Battery -> select "Unrestricted" (or "No restrictions"). This prevents Android from putting VendorSoft to sleep.
''',
    ),
    FaqTopic(
      category: 'Troubleshooting',
      title: 'Date & Time Error',
      icon: Icons.access_alarms_outlined,
      answer: '''
If your device displays a "Suspicious Time Tampering / Clock Discrepancy" screen, VendorSoft's built-in ClockGuard has detected that your phone clock was shifted backward or jumped abnormally while offline:

• Your license or trial is not permanently cancelled or lost.
• To resolve this right now, open your phone's Android Date & Time settings and turn ON "Automatic Date & Time (Network provided time)".
• Return to VendorSoft and normal operation will resume automatically.
''',
    ),
    FaqTopic(
      category: 'Troubleshooting',
      title: 'Common Troubleshooting',
      icon: Icons.build_circle_outlined,
      answer: '''
If you encounter any unexpected UI sluggishness or file access warnings while on your delivery route:

1. Check Diagnostics: Open Settings -> System Diagnostics for an instant live status of Storage permissions, Battery optimization, and Printer connectivity.
2. Refresh App: Close VendorSoft from your phone's recent apps screen and reopen it.
3. Helpline Support: Go to Settings -> Contact Support, tap "Copy Device ID", and send your Device ID to your distributor via WhatsApp for quick troubleshooting.
''',
    ),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<FaqTopic> get _filteredTopics {
    return _topics.where((topic) {
      final matchesCategory = _selectedCategory == 'All' || topic.category == _selectedCategory;
      final query = _searchQuery.toLowerCase().trim();
      final matchesSearch = query.isEmpty ||
          topic.title.toLowerCase().contains(query) ||
          topic.answer.toLowerCase().contains(query) ||
          topic.category.toLowerCase().contains(query);
      return matchesCategory && matchesSearch;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredTopics;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Row(
          children: [
            Icon(Icons.menu_book, color: Color(0xFF00E676), size: 22),
            SizedBox(width: 10),
            Text('User Guide & FAQs', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      body: Column(
        children: [
          // Search Bar & Categories Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            decoration: const BoxDecoration(
              color: Color(0xFF161B22),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search topics, keywords, or error messages...',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                    prefixIcon: const Icon(Icons.search, color: Color(0xFF00E676)),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, color: Colors.white54, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: const Color(0xFF0B1014),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                  onChanged: (val) {
                    setState(() => _searchQuery = val);
                  },
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _categories.map((cat) {
                      final isSelected = _selectedCategory == cat;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(cat, style: TextStyle(
                            color: isSelected ? const Color(0xFF0B1014) : Colors.white70,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            fontSize: 12,
                          )),
                          selected: isSelected,
                          selectedColor: const Color(0xFF00E676),
                          backgroundColor: Colors.white.withValues(alpha: 0.05),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide.none),
                          onSelected: (selected) {
                            if (selected) {
                              setState(() => _selectedCategory = cat);
                            }
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),

          // FAQ List
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.help_outline, color: Colors.white24, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            'No FAQs found matching "$_searchQuery"',
                            style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Try selecting "All" or searching for broader terms like "Printer" or "Trial".',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF161B22),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                        ),
                        child: Theme(
                          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00E676).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(item.icon, color: const Color(0xFF00E676), size: 20),
                            ),
                            title: Text(
                              item.title,
                              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                              item.category,
                              style: const TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                            iconColor: const Color(0xFF00E676),
                            collapsedIconColor: Colors.white54,
                            children: [
                              Container(
                                width: double.maxFinite,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0B1014),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  item.answer.trim(),
                                  style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
