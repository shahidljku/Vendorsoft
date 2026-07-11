// ignore_for_file: avoid_print
import 'dart:typed_data';
import 'package:flutter/material.dart' hide TextStyle, EdgeInsets, Divider, Column, Row, MainAxisAlignment, CrossAxisAlignment, Container, Border, BorderSide, SizedBox;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/customer.dart';
import 'license_service.dart';
import 'settings_service.dart';

class PrintService {
  static final PrintService _instance = PrintService._internal();
  factory PrintService() => _instance;
  PrintService._internal();

  /// Resolves the PdfPageFormat based on SettingsService (58mm default, auto height roll)
  Future<PdfPageFormat> _getPageFormat(SettingsService settingsService) async {
    final widthStr = await settingsService.getDefaultPrinterWidth();
    if (widthStr == '80mm') {
      // 80mm roll width with auto height and 6pt margins
      return const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 6 * PdfPageFormat.point);
    } else if (widthStr == 'a4') {
      return PdfPageFormat.a4;
    }
    // Default: 58mm roll width with auto height and 5pt margins (never cut text off)
    return const PdfPageFormat(58 * PdfPageFormat.mm, double.infinity, marginAll: 5 * PdfPageFormat.point);
  }

  /// Prints a Bill document for the customer
  Future<bool> printBill({
    required Customer customer,
    required SettingsService settingsService,
  }) async {
    try {
      final pageFormat = await _getPageFormat(settingsService);
      final businessName = LicenseService().getBusinessName();

      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async {
          final doc = pw.Document();

          doc.addPage(
            pw.Page(
              pageFormat: pageFormat,
              build: (pw.Context context) {
                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  mainAxisSize: pw.MainAxisSize.min,
                  children: [
                    // Business Header
                    pw.Text(
                      businessName.isEmpty ? 'VENDSOFT BILLING' : businessName.toUpperCase(),
                      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
                      textAlign: pw.TextAlign.center,
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text('INVOICE / BILL', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    pw.Divider(thickness: 1, height: 8),

                    // Customer Details
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Bill No:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.billNo.isNotEmpty ? customer.billNo : '-', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                      ],
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Date:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.vouchDate.isNotEmpty ? customer.vouchDate : DateTime.now().toString().substring(0, 10), style: const pw.TextStyle(fontSize: 8)),
                      ],
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Customer:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Expanded(
                          child: pw.Text(
                            customer.custName.isNotEmpty ? customer.custName : customer.mobile,
                            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
                            textAlign: pw.TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                    if (customer.custNo.isNotEmpty)
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Cust No:', style: const pw.TextStyle(fontSize: 8)),
                          pw.Text(customer.custNo, style: const pw.TextStyle(fontSize: 8)),
                        ],
                      ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Mobile:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.mobile, style: const pw.TextStyle(fontSize: 8)),
                      ],
                    ),
                    pw.Divider(thickness: 1, height: 8),

                    // Amounts Breakdown
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Bill Amount:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                        pw.Text('Rs. ${customer.billAmount.isNotEmpty ? customer.billAmount : '0'}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                      ],
                    ),
                    if (customer.clBalance.isNotEmpty && customer.clBalance != '0') ...[
                      pw.SizedBox(height: 2),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Previous Balance:', style: const pw.TextStyle(fontSize: 8)),
                          pw.Text('Rs. ${customer.clBalance}', style: const pw.TextStyle(fontSize: 8)),
                        ],
                      ),
                    ],
                    if (customer.cmName.isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Agent:', style: const pw.TextStyle(fontSize: 8)),
                          pw.Text(customer.cmName, style: const pw.TextStyle(fontSize: 8)),
                        ],
                      ),
                    ],
                    pw.Divider(thickness: 1, height: 8),

                    // Footer
                    pw.Text('Thank you for your business!', style: const pw.TextStyle(fontSize: 8), textAlign: pw.TextAlign.center),
                    pw.SizedBox(height: 4),
                  ],
                );
              },
            ),
          );

          return doc.save();
        },
        name: 'Bill_${customer.custName.replaceAll(' ', '_')}_${customer.billNo}',
      );
      return true;
    } catch (e) {
      print('PrintService printBill error: $e');
      return false;
    }
  }

  /// Prints a Payment Receipt document for the customer
  Future<bool> printReceipt({
    required Customer customer,
    required SettingsService settingsService,
  }) async {
    try {
      final pageFormat = await _getPageFormat(settingsService);
      final businessName = LicenseService().getBusinessName();

      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async {
          final doc = pw.Document();

          doc.addPage(
            pw.Page(
              pageFormat: pageFormat,
              build: (pw.Context context) {
                return pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  mainAxisSize: pw.MainAxisSize.min,
                  children: [
                    // Business Header
                    pw.Text(
                      businessName.isEmpty ? 'VENDSOFT BILLING' : businessName.toUpperCase(),
                      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
                      textAlign: pw.TextAlign.center,
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text('PAYMENT RECEIPT', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    pw.Divider(thickness: 1, height: 8),

                    // Receipt Details
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Receipt For:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.billNo.isNotEmpty ? 'Bill #${customer.billNo}' : 'Payment', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                      ],
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Date:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.paymentDate.isNotEmpty ? customer.paymentDate : DateTime.now().toString().substring(0, 10), style: const pw.TextStyle(fontSize: 8)),
                      ],
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Received From:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Expanded(
                          child: pw.Text(
                            customer.custName.isNotEmpty ? customer.custName : customer.mobile,
                            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
                            textAlign: pw.TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Mobile:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.mobile, style: const pw.TextStyle(fontSize: 8)),
                      ],
                    ),
                    if (customer.paymentMethod.isNotEmpty)
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Method:', style: const pw.TextStyle(fontSize: 8)),
                          pw.Text(customer.paymentMethod, style: const pw.TextStyle(fontSize: 8)),
                        ],
                      ),
                    if (customer.transactionId.isNotEmpty)
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Tx ID / Ref:', style: const pw.TextStyle(fontSize: 8)),
                          pw.Expanded(
                            child: pw.Text(
                              customer.transactionId,
                              style: const pw.TextStyle(fontSize: 8),
                              textAlign: pw.TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    pw.Divider(thickness: 1, height: 8),

                    // Amount Paid
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(width: 1),
                        borderRadius: pw.BorderRadius.circular(4),
                      ),
                      child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('AMOUNT PAID:', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                          pw.Text('Rs. ${customer.amountPaid.isNotEmpty ? customer.amountPaid : customer.billAmount}', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                        ],
                      ),
                    ),
                    pw.SizedBox(height: 6),
                    pw.Text('Payment Verified & Successful', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                    pw.Divider(thickness: 1, height: 8),

                    // Footer
                    pw.Text('Thank you for your payment!', style: const pw.TextStyle(fontSize: 8), textAlign: pw.TextAlign.center),
                    pw.SizedBox(height: 4),
                  ],
                );
              },
            ),
          );

          return doc.save();
        },
        name: 'Receipt_${customer.custName.replaceAll(' ', '_')}_${customer.billNo}',
      );
      return true;
    } catch (e) {
      print('PrintService printReceipt error: $e');
      return false;
    }
  }
}
