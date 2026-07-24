import os
import re

file_path = r'e:\image_sender\lib\screens\dashboard_tab.dart'

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Fix duplicated padding
content = content.replace(
    'return SingleChildScrollView(\n      padding: const EdgeInsets.all(16),\n      padding: const EdgeInsets.all(16),',
    'return SingleChildScrollView(\n      padding: const EdgeInsets.all(16),'
)

# Manually replace the Quick Actions section
pattern = r"const Text\(' Quick Actions',.*?const SizedBox\(height: 24\),"
replacement = """const Text(' Quick Actions', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: CooldownButton(
                  label: 'Send Bills',
                  iconData: Icons.send_rounded,
                  baseColor: const Color(0xFF00E676),
                  onCooldownAction: () => _showCooldownDialog(context),
                  onNormalAction: () => widget.onNavigateToQueue('Pending Bills'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CooldownButton(
                  label: 'Send Receipts',
                  iconData: Icons.receipt_long,
                  baseColor: Colors.blue,
                  onCooldownAction: () => _showCooldownDialog(context),
                  onNormalAction: () => widget.onNavigateToReceipts('Pending'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: CooldownButton(
                  label: 'Payment Reminders (યાદી)',
                  iconData: Icons.notifications_active,
                  baseColor: const Color(0xFF00E676),
                  onCooldownAction: () => _showCooldownDialog(context),
                  onNormalAction: () => RemindersModal.show(context, widget.excelService, widget.settingsService),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),"""

content = re.sub(pattern, replacement, content, flags=re.DOTALL)


# Fix _showCooldownDialog
dialog_repl = """
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
          'To prevent WhatsApp from flagging your account as a bot, a cooldown lock is active between batches of 30 messages.\\n\\nTime remaining: ${CooldownService.formatDuration(remaining)}',
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
"""

content = re.sub(
    r'void _showCooldownDialog\(BuildContext context\) \{.*?\n  \}\n',
    dialog_repl.strip() + '\n\n',
    content,
    flags=re.DOTALL
)

# Remove _buildQuickAction
content = re.sub(
    r'Widget _buildQuickAction\(String title, IconData icon, Color color, VoidCallback onTap\) \{.*?\n  \}\n',
    '',
    content,
    flags=re.DOTALL
)


with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
