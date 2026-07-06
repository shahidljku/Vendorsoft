import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/customer.dart';
import '../services/excel_service.dart';
import '../services/license_service.dart';

class ReportsTab extends StatefulWidget {
  final ExcelService excelService;

  const ReportsTab({super.key, required this.excelService});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  DateTime _selectedDate = DateTime.now();

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
    final pdf = pw.Document();

    String formattedDate = DateFormat('dd/MM/yyyy').format(_selectedDate);
    
    // Make filtering highly forgiving to account for Excel formatting variations
    List<Customer> dayCustomers = widget.excelService.allCustomers.where((c) {
      bool isSuccessful = c.paymentStatus.trim().toLowerCase().contains('success') || 
                          c.paymentStatus.trim().toLowerCase() == 'paid';
      
      String d1 = DateFormat('dd/MM/yyyy').format(_selectedDate); // 02/07/2026
      String d2 = DateFormat('d/M/yyyy').format(_selectedDate);   // 2/7/2026
      String d3 = DateFormat('yyyy-MM-dd').format(_selectedDate); // 2026-07-02
      
      String pDate = c.paymentDate.trim();
      String vDate = c.vouchDate.trim();
      
      // If paymentDate is empty, we fallback to the vouchDate
      String dateToCheck = pDate.isNotEmpty ? pDate : vDate;

      bool isCorrectDate = dateToCheck.contains(d1) || 
                           dateToCheck.contains(d2) || 
                           dateToCheck.contains(d3) ||
                           dateToCheck.replaceAll('-', '/').contains(d1);
                           
      return isCorrectDate && isSuccessful;
    }).toList();

    // Group by Collection Man
    Map<String, List<Customer>> groupedByCm = {};
    for (var c in dayCustomers) {
      String cm = c.cmName.isNotEmpty ? c.cmName.toUpperCase() : 'UNKNOWN';
      groupedByCm.putIfAbsent(cm, () => []).add(c);
    }

    final String businessName = LicenseService().getBusinessName();
    
    double dayOnlineTotal = 0;
    double dayCashTotal = 0;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(32),
        header: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text(businessName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              pw.Text('Recovery Register', style: pw.TextStyle(fontSize: 14)),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Collection Date: $formattedDate', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text('Page : ${context.pageNumber}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ]
              ),
              pw.SizedBox(height: 10),
            ],
          );
        },
        build: (context) {
          List<pw.Widget> widgets = [];
          
          if (dayCustomers.isEmpty) {
            widgets.add(pw.Center(child: pw.Text('No successful payments recorded for $formattedDate')));
            return widgets;
          }

          final sortedCmKeys = groupedByCm.keys.toList()..sort();

          for (String cm in sortedCmKeys) {
            List<Customer> cmCustomers = groupedByCm[cm]!;
            
            List<Customer> onlineList = cmCustomers.where((c) => c.paymentMethod.toLowerCase() == 'online').toList();
            List<Customer> cashList = cmCustomers.where((c) => c.paymentMethod.toLowerCase() == 'cash').toList();
            
            double cmOnlineTotal = 0;
            double cmCashTotal = 0;

            widgets.add(pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 8),
              color: PdfColors.grey200,
              width: double.infinity,
              child: pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8),
                child: pw.Text('Collection Man: $cm', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
              ),
            ));
            
            widgets.add(pw.SizedBox(height: 8));

            // Online Section
            if (onlineList.isNotEmpty) {
              widgets.add(pw.Text('** Payment Mode: ONLINE **', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14)));
              widgets.add(pw.SizedBox(height: 4));
              
              widgets.add(_buildTable(onlineList));
              
              cmOnlineTotal = onlineList.fold(0.0, (sum, c) => sum + (double.tryParse(c.amountPaid) ?? 0));
              dayOnlineTotal += cmOnlineTotal;
              
              widgets.add(pw.SizedBox(height: 4));
              widgets.add(pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text('Online Total ($cm): ${cmOnlineTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14)),
              ));
              widgets.add(pw.SizedBox(height: 12));
            }

            // Cash Section
            if (cashList.isNotEmpty) {
              widgets.add(pw.Text('** Payment Mode: CASH **', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14)));
              widgets.add(pw.SizedBox(height: 4));
              
              widgets.add(_buildTable(cashList));
              
              cmCashTotal = cashList.fold(0.0, (sum, c) => sum + (double.tryParse(c.amountPaid) ?? 0));
              dayCashTotal += cmCashTotal;
              
              widgets.add(pw.SizedBox(height: 4));
              widgets.add(pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text('Cash Total ($cm): ${cmCashTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14)),
              ));
              widgets.add(pw.SizedBox(height: 12));
            }
            
            double cmGrandTotal = cmOnlineTotal + cmCashTotal;
            widgets.add(pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Text('Total for $cm: ${cmGrandTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 15, color: PdfColors.blue800)),
            ));
            
            widgets.add(pw.Divider(thickness: 1.5));
            widgets.add(pw.SizedBox(height: 16));
          }

          // Grand Totals at end of report
          double grandTotal = dayOnlineTotal + dayCashTotal;
          widgets.add(pw.SizedBox(height: 20));
          widgets.add(pw.Divider(thickness: 2));
          widgets.add(pw.SizedBox(height: 4));
          widgets.add(pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text('TOTAL ONLINE COLLECTION: ${dayOnlineTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 15)),
                pw.Text('TOTAL CASH COLLECTION: ${dayCashTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 15)),
                pw.SizedBox(height: 4),
                pw.Text('GRAND TOTAL: ${grandTotal.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18)),
              ]
            )
          ));
          widgets.add(pw.Divider(thickness: 2));

          return widgets;
        }
      )
    );

    return pdf.save();
  }

  pw.Widget _buildTable(List<Customer> list) {
    return pw.TableHelper.fromTextArray(
      headers: ['Sr.No', 'Bill No', 'Cust.No', 'Name of Customer', 'Amount'],
      headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14),
      cellStyle: const pw.TextStyle(fontSize: 12),
      cellAlignment: pw.Alignment.centerLeft,
      headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
      data: list.asMap().entries.map((e) {
        return [
          (e.key + 1).toString(),
          e.value.billNo,
          e.value.custNo,
          e.value.custName,
          double.tryParse(e.value.amountPaid)?.toStringAsFixed(2) ?? '0.00'
        ];
      }).toList(),
      columnWidths: {
        0: const pw.FlexColumnWidth(1),
        1: const pw.FlexColumnWidth(2),
        2: const pw.FlexColumnWidth(2),
        3: const pw.FlexColumnWidth(4),
        4: const pw.FlexColumnWidth(2),
      },
    );
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
        title: const Text('Recovery Register', style: TextStyle(color: Colors.white)),
        actions: [
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
          return PdfPreview(
            build: (format) => _generatePdf(format),
            allowSharing: true,
            allowPrinting: true,
            canChangeOrientation: false,
            canChangePageFormat: false,
            canDebug: false,
            pdfFileName: 'Recovery_Register_$formattedDate.pdf'.replaceAll('/', '-'),
          );
        },
      ),
    );
  }
}
