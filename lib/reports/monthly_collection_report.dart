import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/license_service.dart';
import 'framework/report_config.dart';
import 'framework/report_framework.dart';

class MonthlyCollectionReport {
  static Future<Uint8List> generate(PdfPageFormat format, ExcelService excelService) async {
    // 1. Filter Data
    final paidCustomers = excelService.allCustomers.where((c) => c.isPaid).toList();

    List<Customer> cashList = [];
    List<Customer> onlineList = [];
    List<Customer> unknownList = [];

    double cashTotal = 0;
    double onlineTotal = 0;
    double unknownTotal = 0;

    for (var c in paidCustomers) {
      final method = c.paymentMethod.trim().toLowerCase();
      double amt = double.tryParse(c.amountPaid) ?? 0;

      if (method == 'cash') {
        cashList.add(c);
        cashTotal += amt;
      } else if (method == 'online') {
        onlineList.add(c);
        onlineTotal += amt;
      } else {
        unknownList.add(c);
        unknownTotal += amt;
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

    // 3. Build Sections
    List<ReportSection> sections = [];

    // Helper to map rows
    List<List<String>> mapRows(List<Customer> list) {
      List<List<String>> rows = [];
      for (int i = 0; i < list.length; i++) {
        final c = list[i];
        double amt = double.tryParse(c.amountPaid) ?? 0;
        rows.add([
          (i + 1).toString(),
          c.custNo,
          c.custName,
          c.paymentMethod,
          amt.toStringAsFixed(2),
        ]);
      }
      return rows;
    }

    // Cash Section
    if (cashList.isEmpty) {
      sections.add(ReportSection(
        title: 'CASH COLLECTION',
        subtitle: 'No Cash Collections',
        rows: [],
        summaryLines: [],
      ));
    } else {
      sections.add(ReportSection(
        title: 'CASH COLLECTION',
        subtitle: '',
        rows: mapRows(cashList),
        summaryLines: [
          'Cash Count: ${cashList.length}',
          'Total Cash: ${cashTotal.toStringAsFixed(2)}',
        ],
      ));
    }

    // Online Section
    if (onlineList.isEmpty) {
      sections.add(ReportSection(
        title: 'ONLINE COLLECTION',
        subtitle: 'No Online Collections',
        rows: [],
        summaryLines: [],
      ));
    } else {
      sections.add(ReportSection(
        title: 'ONLINE COLLECTION',
        subtitle: '',
        rows: mapRows(onlineList),
        summaryLines: [
          'Online Count: ${onlineList.length}',
          'Total Online: ${onlineTotal.toStringAsFixed(2)}',
        ],
      ));
    }

    // Unknown Section
    if (unknownList.isNotEmpty) {
      sections.add(ReportSection(
        title: 'UNKNOWN PAYMENT METHOD',
        subtitle: '',
        rows: mapRows(unknownList),
        summaryLines: [
          'Unknown Count: ${unknownList.length}',
          'Total Unknown: ${unknownTotal.toStringAsFixed(2)}',
        ],
      ));
    }

    double grandTotal = cashTotal + onlineTotal + unknownTotal;
    
    List<String> grandTotals = [
      'Cash Collection Total: ${cashTotal.toStringAsFixed(2)}',
      'Online Collection Total: ${onlineTotal.toStringAsFixed(2)}',
    ];
    if (unknownList.isNotEmpty) {
      grandTotals.add('Unknown Collection Total: ${unknownTotal.toStringAsFixed(2)}');
    }
    grandTotals.addAll([
      'Grand Total Collection: ${grandTotal.toStringAsFixed(2)}',
      'Total Paid Customers: ${paidCustomers.length}',
    ]);

    // 4. Build Config
    final config = ReportConfig(
      reportTitle: 'Monthly Collection Report – $monthStr',
      businessName: businessName,
      filters: [],
      pageFormat: format,
      headers: ['S.No', 'Customer No', 'Customer Name', 'Payment Method', 'Amount Paid'],
      columnAlignments: {
        0: pw.Alignment.center,
        1: pw.Alignment.center,
        2: pw.Alignment.centerLeft,
        3: pw.Alignment.center,
        4: pw.Alignment.centerRight,
      },
      columnWidths: {
        0: const pw.FlexColumnWidth(1),
        1: const pw.FlexColumnWidth(2),
        2: const pw.FlexColumnWidth(4),
        3: const pw.FlexColumnWidth(3),
        4: const pw.FlexColumnWidth(2),
      },
      sections: sections,
      grandTotals: grandTotals,
    );

    // 5. Generate PDF
    return ReportFramework.generate(config);
  }
}
