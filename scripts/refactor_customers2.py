import os
import re

file_path = r'e:\image_sender\lib\screens\customers_tab.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

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
  int _unpaidCount = 0;
  int _receiptPendingCount = 0;
  List<String> _cmNames = ['All'];
"""
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
content = re.sub(r'@override\s+void initState\(\).*?super\.dispose\(\);\s*\}', init_dispose.strip(), content, flags=re.DOTALL)

# didUpdateWidget
did_update = """
  @override
  void didUpdateWidget(CustomersTab oldWidget) {
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
    int unpaid = 0;
    int receiptPending = 0;
    
    Set<String> cmSet = {'All'};

    for (var c in allCustomers) {
      String st = c.status.trim().toLowerCase();
      String pst = c.paymentStatus.trim().toLowerCase();
      String rst = c.receiptStatus.trim().toLowerCase();
      
      if (st == 'pending' || st == 'waiting' || st == 'processing') pending++;
      if (st == 'failed') failed++;
      if (st == 'sent' || st == 'message sent') sent++;
      if (pst != 'successful' && !pst.contains('success') && pst != 'paid') unpaid++;
      if ((pst == 'successful' || pst.contains('success') || pst == 'paid') && rst != 'sent') receiptPending++;
      
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
      result = result.where((c) => c.billNo.toLowerCase().contains(q) || c.custName.toLowerCase().contains(q) || c.mobile.contains(q)).toList();
    }
    
    if (mounted) {
      setState(() {
        _allCount = allCustomers.length;
        _pendingBillsCount = pending;
        _failedBillsCount = failed;
        _sentBillsCount = sent;
        _unpaidCount = unpaid;
        _receiptPendingCount = receiptPending;
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
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Search Name, Bill No, Mobile...',
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
content = content.replace('_buildFilterTab(\'Unpaid Bills\', unpaidCount,', '_buildFilterTab(\'Unpaid Bills\', _unpaidCount,')
content = content.replace('_buildFilterTab(\'Receipts Pending\', receiptPendingCount,', '_buildFilterTab(\'Receipts Pending\', _receiptPendingCount,')

content = content.replace('cmNames.length', '_cmNames.length')
content = content.replace('cmNames.map', '_cmNames.map')
content = content.replace('List<Customer> customers = filteredCustomers;', '')

# List changes
content = content.replace('customers.length', '_cachedFilteredCustomers.length')
content = content.replace('customers.isEmpty', '_cachedFilteredCustomers.isEmpty')
content = content.replace('customers[index]', '_cachedFilteredCustomers[index]')
content = content.replace('Customer c = customers[index];', 'Customer c = _cachedFilteredCustomers[index];')

# Dropdown onChanged (status filter and collection man filter)
content = content.replace(
    'setState(() => _statusFilter = title);',
    'setState(() { _statusFilter = title; _calculateData(); });'
)
content = content.replace(
    'setState(() => _collectionManFilter = val!);',
    'setState(() { _collectionManFilter = val!; _calculateData(); });'
)
content = content.replace(
    'setState(() { _statusFilter = label; });',
    'setState(() { _statusFilter = label; _calculateData(); });'
)
content = content.replace(
    'setState(() {\n          _statusFilter = label;\n        });',
    'setState(() {\n          _statusFilter = label;\n          _calculateData();\n        });'
)

# Replace the ListenableBuilder closing brace
content = content.replace(
    '});\n    );\n  }',
    ');\n  }'
)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
