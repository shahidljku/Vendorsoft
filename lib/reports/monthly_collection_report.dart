import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../services/excel_service.dart';

class _DailyCollection {
  final String date;
  double cashAmount = 0;
  int cashCount = 0;
  double bankAmount = 0;
  int bankCount = 0;
  double unknownAmount = 0;
  int unknownCount = 0;

  _DailyCollection(this.date);

  double get totalAmount => cashAmount + bankAmount + unknownAmount;
  int get totalCount => cashCount + bankCount + unknownCount;
}

class MonthlyCollectionReport {
  static String _standardizeDate(String dateStr) {
    if (dateStr.isEmpty) return 'Unknown Date';
    
    // Instead of chained .split().replaceAll(), we can optimize for speed
    int spaceIndex = dateStr.indexOf(' ');
    String s = spaceIndex != -1 ? dateStr.substring(0, spaceIndex) : dateStr;
    s = s.replaceAll('-', '/');
    
    List<String> parts = s.split('/');
    if (parts.length == 3) {
      if (parts[0].length == 4) {
        return '${parts[2].padLeft(2, '0')}/${parts[1].padLeft(2, '0')}/${parts[0]}';
      } else {
        return '${parts[0].padLeft(2, '0')}/${parts[1].padLeft(2, '0')}/${parts[2]}';
      }
    }
    return s;
  }

  static String _formatAmount(double a) {
    String s = a.toStringAsFixed(0);
    if (a > 0 && s.length < 4) {
      return s.padLeft(4, '0');
    }
    return s;
  }

  static String _formatCount(int c) {
    if (c == 0) return '00';
    return c.toString().padLeft(2, '0');
  }

  static Future<Uint8List> generate(PdfPageFormat format, ExcelService excelService) async {
    final pdf = pw.Document();

    final paidCustomers = excelService.allCustomers.where((c) => c.isPaid).toList();

    Map<String, _DailyCollection> grouped = {};

    for (var c in paidCustomers) {
      final method = c.paymentMethod.trim().toLowerCase();
      double amt = double.tryParse(c.amountPaid) ?? 0;
      
      String dateStr = c.paymentDate.trim().isNotEmpty ? c.paymentDate.trim() : c.vouchDate.trim();
      String stdDate = _standardizeDate(dateStr);
      
      grouped.putIfAbsent(stdDate, () => _DailyCollection(stdDate));
      final daily = grouped[stdDate]!;
      
      if (method == 'cash') {
        daily.cashAmount += amt;
        daily.cashCount += 1;
      } else if (method == 'online') {
        daily.bankAmount += amt;
        daily.bankCount += 1;
      } else {
        daily.unknownAmount += amt;
        daily.unknownCount += 1;
      }
    }

    final sortedKeys = grouped.keys.toList()..sort((a, b) {
      DateTime parse(String d) {
        if (d == 'Unknown Date') return DateTime(1900);
        List<String> p = d.split('/');
        if (p.length == 3) {
          return DateTime(int.tryParse(p[2]) ?? 1900, int.tryParse(p[1]) ?? 1, int.tryParse(p[0]) ?? 1);
        }
        return DateTime(1900);
      }
      return parse(a).compareTo(parse(b));
    });

    List<pw.TableRow> tableRows = [];
    
    for (int i = 0; i < sortedKeys.length; i += 2) {
      final left = grouped[sortedKeys[i]]!;
      final right = (i + 1 < sortedKeys.length) ? grouped[sortedKeys[i + 1]]! : null;
      
      pw.Widget buildCell(_DailyCollection? daily) {
        if (daily == null) {
          return pw.Container(padding: const pw.EdgeInsets.all(5));
        }

        return pw.Container(
          padding: const pw.EdgeInsets.all(5),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Date :-${daily.date}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
              pw.SizedBox(height: 2),
              pw.Text('Cash Amount : ${_formatAmount(daily.cashAmount)}  Count ${_formatCount(daily.cashCount)}', style: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 2),
              pw.Text('Bank Amount : ${_formatAmount(daily.bankAmount)}  Count ${_formatCount(daily.bankCount)}', style: const pw.TextStyle(fontSize: 10)),
              if (daily.unknownCount > 0) ...[
                pw.SizedBox(height: 2),
                pw.Text('Unknown Amount : ${_formatAmount(daily.unknownAmount)}  Count ${_formatCount(daily.unknownCount)}', style: const pw.TextStyle(fontSize: 10)),
              ],
              pw.SizedBox(height: 2),
              pw.Text('Total Amount : ${_formatAmount(daily.totalAmount)}  Count ${_formatCount(daily.totalCount)}', style: const pw.TextStyle(fontSize: 10)),
            ]
          )
        );
      }

      tableRows.add(
        pw.TableRow(
          children: [
            buildCell(left),
            buildCell(right),
          ]
        )
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(30),
        header: (context) {
          return pw.Container(
            alignment: pw.Alignment.center,
            margin: const pw.EdgeInsets.only(bottom: 20),
            child: pw.Text(
              'Monthly Payment Summary',
              style: pw.TextStyle(
                fontSize: 14,
                fontWeight: pw.FontWeight.bold,
                decoration: pw.TextDecoration.underline,
              ),
            ),
          );
        },
        build: (context) => [
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.black, width: 0.5),
            columnWidths: {
              0: const pw.FlexColumnWidth(1),
              1: const pw.FlexColumnWidth(1),
            },
            children: tableRows,
          ),
        ],
      ),
    );

    return pdf.save();
  }
}
