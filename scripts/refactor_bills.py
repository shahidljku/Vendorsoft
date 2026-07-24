import os
import re

file_path = r'e:\image_sender\lib\screens\bills_tab.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Add imports
if "import '../widgets/cooldown_button.dart';" not in content:
    content = content.replace(
        "import '../services/print_service.dart';", 
        "import '../services/print_service.dart';\nimport '../widgets/cooldown_button.dart';"
    )

# Add state variables
state_vars = """
  bool _isAccessibilityEnabled = false;

  Timer? _debounce;
  
  // Caches
  List<Customer> _cachedFilteredCustomers = [];
  int _allCount = 0;
  int _pendingBillsCount = 0;
  int _failedBillsCount = 0;
  int _sentBillsCount = 0;
  List<String> _cmNames = ['All'];
"""
# BillsTab already has _cooldownTimer, _isCooldown, _remainingCooldown. I will keep them but remove the root timer. Wait, the user wants CooldownButton. So I can just delete _cooldownTimer, _isCooldown, _remainingCooldown from BillsTab, as CooldownButton handles it itself!
# But BillsTab uses _isCooldown and _remainingCooldown in _showCooldownDialog. Wait, Dashboard had `_showCooldownDialog` that did it asynchronously! 
# Let's remove the old cooldown vars and add our state vars.
old_vars_pattern = r'  Timer\? _cooldownTimer;\n  bool _isCooldown = false;\n  Duration _remainingCooldown = Duration\.zero;'
content = re.sub(old_vars_pattern, '', content)

content = re.sub(r'bool _isAccessibilityEnabled = false;', state_vars.strip(), content)

# Init and dispose
init_dispose = """
  @override
  void initState() {
    super.initState();
    _statusFilter = widget.initialFilter ?? 'All';
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibility();
    _calculateData();
    widget.excelService.addListener(_calculateData);
  }

  @override
  void dispose() {
    widget.excelService.removeListener(_calculateData);
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }
"""
content = re.sub(r'  void _startCooldownTimer\(\) \{.*?\}\n', '', content, flags=re.DOTALL)
content = re.sub(r'  Future<void> _checkCooldown\(\) async \{.*?\}\n', '', content, flags=re.DOTALL)
content = re.sub(r'@override\s+void initState\(\).*?super\.dispose\(\);\s*\}', init_dispose.strip(), content, flags=re.DOTALL)


# didUpdateWidget
did_update = """
  @override
  void didUpdateWidget(BillsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.navKey != oldWidget.navKey) {
      if (widget.initialFilter != null) {
        _statusFilter = widget.initialFilter!;
        _calculateData();
      }
    }
  }
"""
content = re.sub(r'@override\s+void didUpdateWidget.*?\}', did_update.strip(), content, flags=re.DOTALL)


# Remove filteredCustomers getter and add _calculateData
calculate_data = """
  void _calculateData() {
    List<Customer> allCustomers = widget.excelService.allCustomers;
    
    // Tab Counts
    int pending = 0;
    int failed = 0;
    int sent = 0;
    
    Set<String> cmSet = {'All'};

    for (var c in allCustomers) {
      String st = c.status.trim().toLowerCase();
      
      if (st == 'pending' || st == 'waiting' || st == 'processing') pending++;
      if (st == 'failed') failed++;
      if (st == 'sent' || st == 'message sent') sent++;
      
      if (c.cmName.isNotEmpty) cmSet.add(c.cmName);
    }
    
    // Now filter list
    List<Customer> result = allCustomers;
    if (_statusFilter != 'All') {
      result = result.where((c) {
        String st = c.status.trim().toLowerCase();
        String pst = c.paymentStatus.trim().toLowerCase();
        String rst = c.receiptStatus.trim().toLowerCase();
        if (_statusFilter == 'Pending Bills') return st == 'pending' || st == 'waiting' || st == 'processing';
        if (_statusFilter == 'Sent Bills') return st == 'sent' || st == 'message sent';
        if (_statusFilter == 'Failed Bills') return st == 'failed';
        if (_statusFilter == 'Unpaid Bills') return pst != 'successful' && !pst.contains('success') && pst != 'paid';
        if (_statusFilter == 'Receipts Pending') return (pst == 'successful' || pst.contains('success') || pst == 'paid') && rst != 'sent';
        return true;
      }).toList();
    }
    if (_collectionManFilter != 'All') {
      result = result.where((c) => c.cmName == _collectionManFilter).toList();
    }
    if (_searchQuery.isNotEmpty) {
      String q = _searchQuery.toLowerCase().trim();
      result = result.where((c) => c.billNo.toLowerCase().contains(q)).toList();
    }
    
    if (mounted) {
      setState(() {
        _allCount = allCustomers.length;
        _pendingBillsCount = pending;
        _failedBillsCount = failed;
        _sentBillsCount = sent;
        _cmNames = cmSet.toList();
        
        if (!_cmNames.contains(_collectionManFilter)) {
          _collectionManFilter = 'All';
        }
        
        _cachedFilteredCustomers = result;
      });
    }
  }

  void _onSearchChanged(String val) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    if (val.isEmpty) {
      _searchQuery = '';
      _calculateData();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchQuery = val;
      _calculateData();
    });
  }

  void _onSearchSubmitted(String val) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _searchQuery = val;
    _calculateData();
  }
"""

content = re.sub(r'List<Customer> get filteredCustomers \{.*?return result;\n  \}', calculate_data.strip(), content, flags=re.DOTALL)

# AppBar Actions
actions_repl = """
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              if (_debounce?.isActive ?? false) _debounce!.cancel();
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchCtrl.clear();
                  _searchQuery = '';
                  _calculateData();
                }
              });
            },
          ),
"""
content = re.sub(r'IconButton\(\s+icon: Icon\(_isSearching \? Icons\.close : Icons\.search\),.*?onPressed: \(\) \{.*?\n\s+\},\n\s+\),', actions_repl.strip(), content, flags=re.DOTALL)

# TextField Search
textfield_repl = """
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Search Bill No...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                onChanged: _onSearchChanged,
                onSubmitted: _onSearchSubmitted,
              )
"""
content = re.sub(r'\? TextField\(.*?\n\s+onChanged: \(val\) => setState\(\(\) => _searchQuery = val\),\n\s+\)', textfield_repl.strip(), content, flags=re.DOTALL)


# Body changes
# Replace ListenableBuilder
body_pattern = r'body: ListenableBuilder\(\s+listenable: widget.excelService,\s+builder: \(context, _\) \{.*?return Column\('
body_repl = """
      body: Column(
"""
content = re.sub(body_pattern, body_repl.strip(), content, flags=re.DOTALL)

content = content.replace('_buildFilterTab(\'All\', allCount,', '_buildFilterTab(\'All\', _allCount,')
content = content.replace('_buildFilterTab(\'Pending Bills\', pendingBillsCount,', '_buildFilterTab(\'Pending Bills\', _pendingBillsCount,')
content = content.replace('_buildFilterTab(\'Failed Bills\', failedBillsCount,', '_buildFilterTab(\'Failed Bills\', _failedBillsCount,')
content = content.replace('_buildFilterTab(\'Sent Bills\', sentBillsCount,', '_buildFilterTab(\'Sent Bills\', _sentBillsCount,')
content = content.replace('cmNames.length', '_cmNames.length')
content = content.replace('cmNames.map', '_cmNames.map')
content = content.replace('List<Customer> customers = filteredCustomers;', '')

# List changes
content = content.replace('customers.length', '_cachedFilteredCustomers.length')
content = content.replace('customers.isEmpty', '_cachedFilteredCustomers.isEmpty')
content = content.replace('customers[index]', '_cachedFilteredCustomers[index]')
content = content.replace('Customer c = customers[index];', 'Customer c = _cachedFilteredCustomers[index];')

# The end brace of builder
content = re.sub(r'\)\;\n        \},\n      \),', ');\n', content)
content = content.replace('body: ListenableBuilder(', '') # if missed

# Dropdown onChanged (status filter and collection man filter)
content = content.replace(
    'setState(() => _statusFilter = title);',
    'setState(() { _statusFilter = title; _calculateData(); });'
)
content = content.replace(
    'setState(() => _collectionManFilter = val!);',
    'setState(() { _collectionManFilter = val!; _calculateData(); });'
)

# Now CooldownButton
# Let's find _buildQuickAction and _showCooldownDialog
# Remove _buildQuickAction
content = re.sub(r'Widget _buildQuickAction\(String title, IconData icon, Color color, VoidCallback onTap\) \{.*?\n  \}\n', '', content, flags=re.DOTALL)

# Refactor _showCooldownDialog
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

# Replace Quick Actions usage
# Find "Expanded(child: _buildQuickAction('Send Selected Bills',"
quick_actions_repl = """
          Row(
            children: [
              Expanded(
                child: CooldownButton(
                  label: 'Send Selected Bills',
                  iconData: Icons.send,
                  baseColor: const Color(0xFF00E676),
                  onCooldownAction: () => _showCooldownDialog(context),
                  onNormalAction: () => _startSendingProcess(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CooldownButton(
                  label: 'Retry Failed Bills',
                  iconData: Icons.refresh,
                  baseColor: Colors.orange,
                  onCooldownAction: () => _showCooldownDialog(context),
                  onNormalAction: () => _retryFailed(context),
                ),
              ),
            ],
          ),
"""
content = re.sub(r'Row\(\s+children: \[\s+Expanded\(\s+child: _buildQuickAction\(.*?\)\s+\]\s+\),', quick_actions_repl.strip(), content, flags=re.DOTALL)


with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
