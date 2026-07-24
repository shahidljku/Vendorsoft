import os
import re

file_path = r'e:\image_sender\lib\screens\reports_tab.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Add Caching Variables and ListenableBuilder scoping
state_vars = """
  DateTime _selectedDate = DateTime.now();
  String _selectedReport = 'Recovery Register';
  String _selectedCmName = 'All';

  // Caches for Recovery Register
  DateTime? _cachedDate;
  List<Customer>? _cachedDateCustomers;
  Map<String, List<Customer>>? _cachedGroupedByCm;
  
  // Caches for CMS
  List<String> _cms = ['All'];

  @override
  void initState() {
    super.initState();
    _calculateCms();
    widget.excelService.addListener(_onExcelDataChanged);
  }

  @override
  void dispose() {
    widget.excelService.removeListener(_onExcelDataChanged);
    super.dispose();
  }

  void _onExcelDataChanged() {
    _calculateCms();
    // Invalidate caches
    _cachedDate = null;
    _cachedDateCustomers = null;
    _cachedGroupedByCm = null;
    if (mounted) setState(() {});
  }

  void _calculateCms() {
    Set<String> cms = {'All'};
    for (var c in widget.excelService.allCustomers) {
      if (c.cmName.isNotEmpty) cms.add(c.cmName.toUpperCase());
    }
    _cms = cms.toList();
    if (!_cms.contains(_selectedCmName.toUpperCase()) && _selectedCmName != 'All') {
      _selectedCmName = 'All';
    }
  }

  void _prepareRecoveryRegisterCache() {
    if (_cachedDate == _selectedDate && _cachedGroupedByCm != null) return;
    
    String d1 = DateFormat('dd/MM/yyyy').format(_selectedDate);
    String d2 = DateFormat('d/M/yyyy').format(_selectedDate);
    String d3 = DateFormat('yyyy-MM-dd').format(_selectedDate);

    // Cache A: Date-Filtered Customers (References only)
    _cachedDateCustomers = widget.excelService.allCustomers.where((c) {
      if (!c.isPaid) return false;
      String pDate = c.paymentDate;
      String vDate = c.vouchDate;
      String dateToCheck = pDate.isNotEmpty ? pDate : vDate;
      if (dateToCheck.contains(d1) || dateToCheck.contains(d2) || dateToCheck.contains(d3)) return true;
      String normalizedDate = dateToCheck.replaceAll('-', '/');
      return normalizedDate.contains(d1) || normalizedDate.contains(d2);
    }).toList();

    // Cache B: Grouped By CM (References only)
    Map<String, List<Customer>> groupedByCm = {};
    for (var c in _cachedDateCustomers!) {
      String cm = c.cmName.isNotEmpty ? c.cmName.toUpperCase() : 'UNKNOWN';
      groupedByCm.putIfAbsent(cm, () => []).add(c);
    }
    _cachedGroupedByCm = groupedByCm;
    _cachedDate = _selectedDate;
  }
"""

content = re.sub(r'  DateTime _selectedDate = DateTime.now\(\);\n  String _selectedReport = \'Recovery Register\';\n  String _selectedCmName = \'All\';', state_vars.strip(), content)

# Change _generatePdf
generate_pdf_repl = """
  Future<Uint8List> _generatePdf(PdfPageFormat format) async {
    if (_selectedReport == 'Monthly Collection') {
      return MonthlyCollectionReport.generate(format, widget.excelService);
    }
    if (_selectedReport == 'CM Pending') {
      return CmPendingReport.generate(format, widget.excelService, _selectedCmName == 'All' ? '' : _selectedCmName);
    }

    _prepareRecoveryRegisterCache();
    
    String formattedDate = DateFormat('dd/MM/yyyy').format(_selectedDate);
    Map<String, List<Customer>> groupedByCm = _cachedGroupedByCm!;
    List<Customer> dayCustomers = _cachedDateCustomers!;

    final String businessName = LicenseService().getBusinessName();
    
    double dayOnlineTotal = 0;
    double dayCashTotal = 0;
"""
content = re.sub(r'  Future<Uint8List> _generatePdf\(PdfPageFormat format\) async \{.*?double dayCashTotal = 0;', generate_pdf_repl.strip(), content, flags=re.DOTALL)


# Remove ListenableBuilder from build
build_start = """
  @override
  Widget build(BuildContext context) {
    String formattedDate = DateFormat('dd/MM/yyyy').format(_selectedDate);

    return Scaffold(
"""
content = re.sub(r'  @override\n  Widget build\(BuildContext context\) \{.*?\n    return Scaffold\(', build_start.strip(), content, flags=re.DOTALL)

# Refactor the body to remove ListenableBuilder
# Find:
# body: ListenableBuilder(
#   listenable: widget.excelService,
#   builder: (context, child) {
#     ...
#     return Column(...)

body_repl = """
      body: Column(
            children: [
              if (_selectedReport == 'CM Pending')
                Container(
                  color: const Color(0xFF0B1014),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Text('Collection Man: ', style: TextStyle(color: Colors.grey)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButton<String>(
                          value: _selectedCmName,
                          isExpanded: true,
                          dropdownColor: const Color(0xFF161B22),
                          style: const TextStyle(color: Colors.white),
                          items: _cms.map((cm) {
                            return DropdownMenuItem(
                              value: cm,
                              child: Text(cm, maxLines: 1, overflow: TextOverflow.ellipsis),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedCmName = val);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: PdfPreview(
                  build: (format) => _generatePdf(format),
                  allowSharing: true,
                  allowPrinting: true,
                  canChangeOrientation: false,
                  canChangePageFormat: false,
                  canDebug: false,
                  pdfFileName: '${_selectedReport.replaceAll(' ', '_')}_$formattedDate.pdf'.replaceAll('/', '-'),
                ),
              ),
            ],
          ),
    );
"""
# Need to carefully replace the whole body
content = re.sub(r'      body: ListenableBuilder\(\s+listenable: widget.excelService,\s+builder: \(context, child\) \{.*?\}\,\n      \),', body_repl.strip(), content, flags=re.DOTALL)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
