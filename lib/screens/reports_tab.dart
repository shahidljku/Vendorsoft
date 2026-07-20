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

    String formattedDate = DateFormat('dd/MM/yyyy').format(_selectedDate);
    
    // 1. Filter Data
    List<Customer> dayCustomers = widget.excelService.allCustomers.where((c) {
      bool isSuccessful = c.isPaid;
      
      String d1 = DateFormat('dd/MM/yyyy').format(_selectedDate); // 02/07/2026
      String d2 = DateFormat('d/M/yyyy').format(_selectedDate);   // 2/7/2026
      String d3 = DateFormat('yyyy-MM-dd').format(_selectedDate); // 2026-07-02
      
      String pDate = c.paymentDate.trim();
      String vDate = c.vouchDate.trim();
      
      String dateToCheck = pDate.isNotEmpty ? pDate : vDate;

      bool isCorrectDate = dateToCheck.contains(d1) || 
                           dateToCheck.contains(d2) || 
                           dateToCheck.contains(d3) ||
                           dateToCheck.replaceAll('-', '/').contains(d1);
                           
      return isCorrectDate && isSuccessful;
    }).toList();

    // 2. Group by Collection Man
    Map<String, List<Customer>> groupedByCm = {};
    for (var c in dayCustomers) {
      String cm = c.cmName.isNotEmpty ? c.cmName.toUpperCase() : 'UNKNOWN';
      groupedByCm.putIfAbsent(cm, () => []).add(c);
    }

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
      body: ListenableBuilder(
        listenable: widget.excelService,
        builder: (context, child) {
          Set<String> cms = {'All'};
          for (var c in widget.excelService.allCustomers) {
            if (c.cmName.isNotEmpty) cms.add(c.cmName.toUpperCase());
          }
          if (!cms.contains(_selectedCmName.toUpperCase()) && _selectedCmName != 'All') {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _selectedCmName = 'All');
            });
          }

          return Column(
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
                          items: cms.map((cm) {
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
          );
        },
      ),
    );
  }
}
