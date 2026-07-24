import os
import re

file_path = r'e:\image_sender\lib\screens\receipts_tab.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Add CooldownFab import
if "import '../widgets/cooldown_fab.dart';" not in content:
    content = content.replace(
        "import '../services/print_service.dart';", 
        "import '../services/print_service.dart';\nimport '../widgets/cooldown_fab.dart';"
    )

# Remove the root timer and variables
old_vars_pattern = r'  Timer\? _cooldownTimer;\n  bool _isCooldown = false;\n  Duration _remainingCooldown = Duration\.zero;'
content = re.sub(old_vars_pattern, '', content)

# Remove _startCooldownTimer and _checkCooldown
content = re.sub(r'  void _startCooldownTimer\(\) \{.*?\}\n', '', content, flags=re.DOTALL)
content = re.sub(r'  Future<void> _checkCooldown\(\) async \{.*?\}\n', '', content, flags=re.DOTALL)

# Remove from initState
content = content.replace('    _startCooldownTimer();\n', '')

# Ensure we don't have _cooldownTimer in dispose
content = content.replace('    _cooldownTimer?.cancel();\n', '')

# Replace _showCooldownDialog
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
          '''To prevent WhatsApp from flagging your account as a bot, a cooldown lock is active between batches of 30 messages.

Time remaining: ${CooldownService.formatDuration(remaining)}''',
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
content = re.sub(r'void _showCooldownDialog\(BuildContext context\) \{.*?\n  \}\n', dialog_repl.strip() + '\n\n', content, flags=re.DOTALL)


# Replace floating action button
fab_repl = """
      floatingActionButton: _pendingReceipts.isNotEmpty && !_isSending
          ? CooldownFab(
              label: 'Send Receipts',
              iconData: Icons.send,
              baseColor: _isAccessibilityEnabled ? const Color(0xFF00E676) : Colors.grey,
              onCooldownAction: () => _showCooldownDialog(context),
              onNormalAction: _isAccessibilityEnabled ? () {
                _runPreflightChecks(context);
              } : () async {
                await AccessibilityService.showGuidanceDialog(context);
                bool check = await AccessibilityService.isEnabled();
                if (mounted) setState(() { _isAccessibilityEnabled = check; });
              },
            )
          : null,
"""
content = re.sub(r'floatingActionButton: _pendingReceipts\.isNotEmpty && !_isSending.*?,\n            \)\n          : null,', fab_repl.strip(), content, flags=re.DOTALL)


with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
