import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/license_service.dart';
import 'framework/report_config.dart';
import 'framework/report_framework.dart';

class CmPendingReport {
  static Future<Uint8List> generate(PdfPageFormat format, ExcelService excelService, String cmName) async {
    // 1. Filter Data
    // Current Month Only (implied by loaded Excel), cmName match, !isPaid, billAmount > 0
    List<Customer> pendingCustomers = [];
    for (var c in excelService.allCustomers) {
      if (c.cmName.trim().toUpperCase() == cmName.trim().toUpperCase() && !c.isPaid) {
        double amt = double.tryParse(c.billAmount) ?? 0;
        if (amt > 0) {
          pendingCustomers.add(c);
        }
      }
    }

    // 2. Identify Month from the first valid record
    String monthStr = 'Current Month';
    if (excelService.allCustomers.isNotEmpty) {
      final sample = excelService.allCustomers.firstWhere((c) => c.monthNm.isNotEmpty, orElse: () => excelService.allCustomers.first);
      if (sample.monthNm.isNotEmpty) {
        monthStr = sample.monthNm;
      }
    }

    final String businessName = LicenseService().getBusinessName();

    // 3. Handle Empty Report
    if (pendingCustomers.isEmpty) {
      final emptyConfig = ReportConfig(
        reportTitle: 'Pending Collection Report – $monthStr',
        businessName: businessName,
        filters: ['Collection Man: $cmName', 'No pending customers found.'],
        pageFormat: format,
        headers: [],
        columnAlignments: {},
        columnWidths: {},
        sections: [],
        grandTotals: [],
      );
      return ReportFramework.generate(emptyConfig);
    }

    // 4. Build Table Rows
    // Preserve Excel order (no sorting)
    List<List<String>> rows = [];
    double totalExpected = 0;
    
    for (int i = 0; i < pendingCustomers.length; i++) {
      final c = pendingCustomers[i];
      double amt = double.tryParse(c.billAmount) ?? 0;
      totalExpected += amt;
      
      rows.add([
        (i + 1).toString(),
        c.custNo,
        c.custName,
        c.mobile,
        amt.toStringAsFixed(2),
        '', // Collected (Blank)
        '', // Remarks (Blank)
      ]);
    }

    // 5. Build Config
    final config = ReportConfig(
      reportTitle: 'Pending Collection Report – $monthStr',
      businessName: businessName,
      filters: ['Collection Man: $cmName'],
      pageFormat: format,
      headers: ['S.No', 'Customer No', 'Customer Name', 'Mobile', 'Bill Amount', 'Collected', 'Remarks'],
      columnAlignments: {
        0: pw.Alignment.center,
        1: pw.Alignment.center,
        2: pw.Alignment.centerLeft,
        3: pw.Alignment.center,
        4: pw.Alignment.centerRight,
        5: pw.Alignment.center,
        6: pw.Alignment.centerLeft,
      },
      columnWidths: {
        0: const pw.FlexColumnWidth(1),
        1: const pw.FlexColumnWidth(1.5),
        2: const pw.FlexColumnWidth(3),
        3: const pw.FlexColumnWidth(2),
        4: const pw.FlexColumnWidth(1.5),
        5: const pw.FlexColumnWidth(2),
        6: const pw.FlexColumnWidth(3),
      },
      sections: [
        ReportSection(
          title: '',
          subtitle: '',
          rows: rows,
          summaryLines: [],
        )
      ],
      grandTotals: [
        'Total Customers: ${pendingCustomers.length}',
        'Total Expected Collection: ${totalExpected.toStringAsFixed(2)}',
      ],
    );

    // 6. Generate PDF
    return ReportFramework.generate(config);
  }
}
