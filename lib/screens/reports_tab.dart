import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/license_service.dart';
import '../reports/framework/report_config.dart';
import '../reports/framework/report_framework.dart';
import '../reports/cm_pending_report.dart';
import '../reports/monthly_collection_report.dart';

class ReportsTab extends StatefulWidget {
  final ExcelService excelService;

  const ReportsTab({super.key, required this.excelService});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
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

  Future<void> _pickDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF00E676),
              onPrimary: Colors.black,
              surface: Color(0xFF161B22),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

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

    // 3. Build Sections
    List<ReportSection> sections = [];
    final sortedCmKeys = groupedByCm.keys.toList()..sort();

    for (String cm in sortedCmKeys) {
      List<Customer> cmCustomers = groupedByCm[cm]!;
      List<Customer> onlineList = cmCustomers.where((c) => c.paymentMethod.toLowerCase() == 'online').toList();
      List<Customer> cashList = cmCustomers.where((c) => c.paymentMethod.toLowerCase() == 'cash').toList();
      
      double cmOnlineTotal = 0;
      double cmCashTotal = 0;

      // Online Section
      if (onlineList.isNotEmpty) {
        List<List<String>> rows = [];
        for (int i = 0; i < onlineList.length; i++) {
          final c = onlineList[i];
          rows.add([
            (i + 1).toString(),
            c.billNo,
            c.custNo,
            c.custName,
            double.tryParse(c.amountPaid)?.toStringAsFixed(2) ?? '0.00'
          ]);
        }
        cmOnlineTotal = onlineList.fold(0.0, (sum, c) => sum + (double.tryParse(c.amountPaid) ?? 0));
        dayOnlineTotal += cmOnlineTotal;
        
        sections.add(ReportSection(
          title: 'Collection Man: $cm',
          subtitle: '** Payment Mode: ONLINE **',
          rows: rows,
          summaryLines: ['Online Total ($cm): ${cmOnlineTotal.toStringAsFixed(2)}'],
        ));
      }

      // Cash Section
      if (cashList.isNotEmpty) {
        List<List<String>> rows = [];
        for (int i = 0; i < cashList.length; i++) {
          final c = cashList[i];
          rows.add([
            (i + 1).toString(),
            c.billNo,
            c.custNo,
            c.custName,
            double.tryParse(c.amountPaid)?.toStringAsFixed(2) ?? '0.00'
          ]);
        }
        cmCashTotal = cashList.fold(0.0, (sum, c) => sum + (double.tryParse(c.amountPaid) ?? 0));
        dayCashTotal += cmCashTotal;
        
        sections.add(ReportSection(
          title: onlineList.isEmpty ? 'Collection Man: $cm' : '', 
          subtitle: '** Payment Mode: CASH **',
          rows: rows,
          summaryLines: [
            'Cash Total ($cm): ${cmCashTotal.toStringAsFixed(2)}',
            if (onlineList.isNotEmpty) 'Total for $cm: ${(cmOnlineTotal + cmCashTotal).toStringAsFixed(2)}'
          ],
        ));
      } else if (onlineList.isNotEmpty) {
        sections.last.summaryLines.add('Total for $cm: ${cmOnlineTotal.toStringAsFixed(2)}');
      }
    }

    double grandTotal = dayOnlineTotal + dayCashTotal;
    List<String> grandTotals = dayCustomers.isEmpty ? [] : [
      'TOTAL ONLINE COLLECTION: ${dayOnlineTotal.toStringAsFixed(2)}',
      'TOTAL CASH COLLECTION: ${dayCashTotal.toStringAsFixed(2)}',
      'GRAND TOTAL: ${grandTotal.toStringAsFixed(2)}'
    ];

    // 4. Create Config
    final config = ReportConfig(
      reportTitle: 'Recovery Register',
      businessName: businessName,
      filters: ['Collection Date: $formattedDate'],
      pageFormat: format,
      headers: ['Sr.No', 'Bill No', 'Cust.No', 'Name of Customer', 'Amount'],
      columnAlignments: {
        0: pw.Alignment.center,
        1: pw.Alignment.center,
        2: pw.Alignment.center,
        3: pw.Alignment.centerLeft,
        4: pw.Alignment.centerRight,
      },
      columnWidths: {
        0: const pw.FlexColumnWidth(1),
        1: const pw.FlexColumnWidth(1.5),
        2: const pw.FlexColumnWidth(1.5),
        3: const pw.FlexColumnWidth(4.5),
        4: const pw.FlexColumnWidth(1.5),
      },
      sections: sections,
      grandTotals: grandTotals,
    );

    // 5. Generate PDF using Framework
    return ReportFramework.generate(config);
  }

@override
  Widget build(BuildContext context) {
    String formattedDate = DateFormat('dd/MM/yyyy').format(_selectedDate);

    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu, color: Colors.white),
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        backgroundColor: const Color(0xFF161B22),
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _selectedReport,
            dropdownColor: const Color(0xFF161B22),
            icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            items: const [
              DropdownMenuItem(value: 'Recovery Register', child: Text('Recovery Register')),
              DropdownMenuItem(value: 'CM Pending', child: Text('CM Pending')),
              DropdownMenuItem(value: 'Monthly Collection', child: Text('Monthly Collection')),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _selectedReport = val);
            },
          ),
        ),
        actions: [
          if (_selectedReport == 'Recovery Register')
            TextButton.icon(
              onPressed: () => _pickDate(context),
              icon: const Icon(Icons.calendar_month, color: Color(0xFF00E676)),
              label: Text(formattedDate, style: const TextStyle(color: Colors.white)),
            ),
          const SizedBox(width: 8),
        ],
      ),
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
  }
}
