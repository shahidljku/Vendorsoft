// ignore_for_file: avoid_print
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
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

  /// Connect to / select a specific system/network printer in settings
  Future<void> connectPrinter(Printer printer, SettingsService settingsService) async {
    await settingsService.setPrinterConnectionType('system');
    await settingsService.setSelectedPrinterUrl(printer.url);
    await settingsService.setSelectedPrinterName(printer.name);
    await settingsService.setDirectPrintEnabled(true);
  }

  /// Get list of available native Bluetooth ESC/POS printers on the device
  Future<List<BluetoothInfo>> getAvailableBluetoothPrinters() async {
    try {
      final permitted = await PrintBluetoothThermal.isPermissionBluetoothGranted;
      if (!permitted) return [];
      return await PrintBluetoothThermal.pairedBluetooths;
    } catch (e) {
      print('Error listing Bluetooth printers: $e');
      return [];
    }
  }

  /// Connect to a native Bluetooth ESC/POS printer
  Future<bool> connectBluetoothPrinter(BluetoothInfo info, SettingsService settingsService) async {
    try {
      final connected = await PrintBluetoothThermal.connect(macPrinterAddress: info.macAdress);
      if (connected) {
        await settingsService.setPrinterConnectionType('bluetooth');
        await settingsService.setSelectedBluetoothMac(info.macAdress);
        await settingsService.setSelectedPrinterName(info.name);
        await settingsService.setDirectPrintEnabled(true);
        return true;
      }
    } catch (e) {
      print('Error connecting Bluetooth thermal printer: $e');
    }
    return false;
  }

  /// Send PDF layout directly to Bluetooth ESC/POS Thermal Printer
  Future<bool> _sendPdfToBluetoothThermal(Uint8List pdfBytes, SettingsService settingsService) async {
    try {
      final mac = await settingsService.getSelectedBluetoothMac();
      if (mac == null || mac.isEmpty) return false;

      bool isConnected = await PrintBluetoothThermal.connectionStatus;
      if (!isConnected) {
        isConnected = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      }
      if (!isConnected) return false;

      final widthStr = await settingsService.getDefaultPrinterWidth();
      final is80mm = widthStr == '80mm';
      final profile = await CapabilityProfile.load();
      final generator = Generator(is80mm ? PaperSize.mm80 : PaperSize.mm58, profile);

      List<int> bytes = [];
      bytes.addAll(generator.reset());

      await for (final page in Printing.raster(pdfBytes, dpi: 200)) {
        final imgBytes = await page.toPng();
        final decodedImg = img.decodePng(imgBytes);
        if (decodedImg != null) {
          bytes.addAll(generator.imageRaster(decodedImg, align: PosAlign.center));
        }
      }

      bytes.addAll(generator.feed(2));
      bytes.addAll(generator.cut());

      await PrintBluetoothThermal.writeBytes(bytes);
      return true;
    } catch (e) {
      print('Error sending bytes to Bluetooth printer: $e');
      return false;
    }
  }

  /// Disconnect / clear saved thermal printer
  Future<void> disconnectPrinter(SettingsService settingsService) async {
    try {
      await PrintBluetoothThermal.disconnect;
    } catch (_) {}
    await settingsService.setSelectedPrinterUrl(null);
    await settingsService.setSelectedPrinterName(null);
    await settingsService.setSelectedBluetoothMac(null);
    await settingsService.setPrinterConnectionType('system');
    await settingsService.setDirectPrintEnabled(false);
  }

  /// Get list of available printers on the device
  Future<List<Printer>> getAvailablePrinters() async {
    try {
      return await Printing.listPrinters();
    } catch (e) {
      print('Error listing printers: $e');
      return [];
    }
  }

  /// Helper to get the currently connected printer (if any)
  Future<Printer?> getConnectedPrinter(SettingsService settingsService) async {
    final url = await settingsService.getSelectedPrinterUrl();
    final name = await settingsService.getSelectedPrinterName();
    if (url != null && url.isNotEmpty) {
      try {
        final printers = await Printing.listPrinters();
        for (var p in printers) {
          if (p.url == url || (name != null && p.name == name)) {
            return p;
          }
        }
      } catch (_) {}
      return Printer(url: url, name: name ?? 'Thermal Printer');
    }
    return null;
  }

  /// Runs a test print on the thermal printer
  Future<bool> testPrint({required SettingsService settingsService}) async {
    try {
      final pageFormat = await _getPageFormat(settingsService);
      final businessName = LicenseService().getBusinessName();

      Future<Uint8List> buildTestLayout(PdfPageFormat format) async {
        final doc = pw.Document();
        doc.addPage(
          pw.Page(
            pageFormat: pageFormat,
            build: (pw.Context context) {
              return pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  pw.Text(
                    businessName.isEmpty ? 'VENDSOFT BILLING' : businessName.toUpperCase(),
                    style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
                    textAlign: pw.TextAlign.center,
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text('THERMAL PRINTER TEST', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                  pw.Divider(thickness: 1, height: 8),
                  pw.Text('Status: Connected & Working!', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.Text('Width: ${pageFormat.width / PdfPageFormat.mm} mm', style: const pw.TextStyle(fontSize: 8)),
                  pw.Text('Date: ${DateTime.now().toString().substring(0, 16)}', style: const pw.TextStyle(fontSize: 8)),
                  pw.Divider(thickness: 1, height: 8),
                  pw.Text('Thank you for choosing VendSoft!', style: const pw.TextStyle(fontSize: 8), textAlign: pw.TextAlign.center),
                  pw.SizedBox(height: 4),
                ],
              );
            },
          ),
        );
        return doc.save();
      }

      final directPrint = await settingsService.getDirectPrintEnabled();
      final connectionType = await settingsService.getPrinterConnectionType();

      if (directPrint && connectionType == 'bluetooth') {
        final pdfBytes = await buildTestLayout(pageFormat);
        final btSuccess = await _sendPdfToBluetoothThermal(pdfBytes, settingsService);
        if (btSuccess) return true;
      }

      final printer = await getConnectedPrinter(settingsService);

      if (directPrint && printer != null) {
        final success = await Printing.directPrintPdf(
          printer: printer,
          onLayout: buildTestLayout,
          name: 'VendSoft_Test_Print',
        );
        if (success) return true;
      }

      await Printing.layoutPdf(
        onLayout: buildTestLayout,
        name: 'VendSoft_Test_Print',
      );
      return true;
    } catch (e) {
      print('PrintService testPrint error: $e');
      return false;
    }
  }

  /// Automatically cleans numeric paper codes (e.g. "101 - TOI", "TOI [Code 101]", "TOI | 150") from raw paper names
  static String _cleanPaperName(String raw) {
    String cleaned = raw.trim();
    if (cleaned.isEmpty || cleaned == 'null' || cleaned == '-') return '';
    if (cleaned.contains('|')) {
      cleaned = cleaned.split('|')[0].trim();
    }
    String stripped = cleaned.replaceAll(RegExp(r'^(?:[cC]ode[\s#:-]*)?#?\d+[\.\s-:]+'), '');
    stripped = stripped.replaceAll(RegExp(r'^(?:[cC]ode[\s#:-]*)?#?\d+\s+'), '');
    stripped = stripped.replaceAll(RegExp(r'[\s-:]+(?:[cC]ode[\s#:-]*)?#?\d+$'), '');
    stripped = stripped.replaceAll(RegExp(r'\s*[\(\[](?:[cC]ode[\s#:-]*)?#?\d+[\)\]]\s*$'), '');
    stripped = stripped.trim();
    if (stripped.isEmpty) return cleaned;
    return stripped;
  }

  /// Returns a safe fallback display string for Paper Name when cleanPapers list is empty.
  /// Skips Yes/No subscription flags and route codes.
  static String _getFallbackPaperDisplay(Customer customer) {
    // Try message first
    if (customer.message.isNotEmpty && customer.message != 'null' && customer.message != '-') {
      return customer.message;
    }
    // Try yesNo, but skip if it's just a subscription flag
    if (customer.yesNo.isNotEmpty && customer.yesNo != 'null' && customer.yesNo != '-') {
      String yesNoLower = customer.yesNo.trim().toLowerCase();
      bool isJustFlag = const {'yes', 'no', 'y', 'n', 'haa', 'ha', 'na', 'nahi', 'naa', 'true', 'false', '1', '0'}.contains(yesNoLower);
      if (!isJustFlag) {
        return customer.yesNo;
      }
    }
    return '-';
  }

  /// Prints a Bill document for the customer
  Future<bool> printBill({
    required Customer customer,
    required SettingsService settingsService,
  }) async {
    try {
      final pageFormat = await _getPageFormat(settingsService);
      final businessName = LicenseService().getBusinessName();

      Future<Uint8List> buildBillPdf(PdfPageFormat format) async {
        final doc = pw.Document();

        doc.addPage(
            pw.Page(
              pageFormat: pageFormat,
              build: (pw.Context context) {
                double clBal = double.tryParse(customer.clBalance.replaceAll(',', '').trim()) ?? 0.0;
                double billAmt = double.tryParse(customer.billAmount.replaceAll(',', '').trim()) ?? 0.0;
                double prevBal = clBal - billAmt;
                String prevBalStr = prevBal.toStringAsFixed(prevBal.truncateToDouble() == prevBal ? 0 : 2);

                List<String> cleanPapers = customer.message
          .split(RegExp(r'[,;\n+&/]'))
          .map((p) => _cleanPaperName(p))
          .where((p) => p.isNotEmpty)
          .toList();

      // Fallback to yesNo ONLY if it contains actual paper names (not just Yes/No flags)
      if (cleanPapers.isEmpty && customer.yesNo.isNotEmpty && customer.yesNo != '-' && customer.yesNo != 'null') {
        // Skip if yesNo is just a subscription flag (Yes/No/Y/N/Haa/Na etc.)
        String yesNoLower = customer.yesNo.trim().toLowerCase();
        bool isJustFlag = const {'yes', 'no', 'y', 'n', 'haa', 'ha', 'na', 'nahi', 'naa', 'true', 'false', '1', '0'}.contains(yesNoLower);
        if (!isJustFlag) {
          cleanPapers = customer.yesNo
              .split(RegExp(r'[,;\n+&/]'))
              .map((p) => _cleanPaperName(p))
              .where((p) => p.isNotEmpty)
              .toList();
        }
      }

      if (cleanPapers.isEmpty) {
        final match = RegExp(r'\(\s*([^\)]+)\s*\)').firstMatch(customer.custName);
        if (match != null && match.group(1) != null && match.group(1)!.trim().isNotEmpty) {
          String extracted = match.group(1)!.trim();
          // Skip if parenthesized value is just a route/area code like "A:12", "26", "B-5"
          bool isRouteCode = RegExp(r'^[A-Za-z]?\s*[:\-]?\s*\d+$').hasMatch(extracted);
          if (!isRouteCode) {
            cleanPapers = [_cleanPaperName(extracted)].where((p) => p.isNotEmpty).toList();
          }
        }
      }

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
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Customer: ', style: const pw.TextStyle(fontSize: 8)),
                        pw.Expanded(
                          child: pw.Text(
                            customer.custName.isNotEmpty ? customer.custName : customer.mobile,
                            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
                            textAlign: pw.TextAlign.right,
                            maxLines: 3,
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
                    if (customer.monthNm.isNotEmpty)
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Month / Period:', style: const pw.TextStyle(fontSize: 8)),
                          pw.Text(customer.monthNm, style: const pw.TextStyle(fontSize: 8)),
                        ],
                      ),
                    pw.SizedBox(height: 2),
                    if (cleanPapers.isNotEmpty) ...[
                      pw.Row(
                        children: [
                          pw.Text('Paper Name:', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                        ],
                      ),
                      ...cleanPapers
                          .asMap()
                          .entries
                          .map((entry) => pw.Padding(
                                padding: const pw.EdgeInsets.only(left: 4, top: 1),
                                child: pw.Row(
                                  children: [
                                    pw.Text('${entry.key + 1}. ', style: const pw.TextStyle(fontSize: 8)),
                                    pw.Expanded(
                                      child: pw.Text(
                                        entry.value,
                                        style: const pw.TextStyle(fontSize: 8),
                                      ),
                                    ),
                                  ],
                                ),
                              )),
                    ] else ...[
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Paper Name:', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                          pw.Expanded(
                            child: pw.Text(
                              _getFallbackPaperDisplay(customer),
                              style: const pw.TextStyle(fontSize: 8),
                              textAlign: pw.TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ],
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
                          pw.Text('Rs. $prevBalStr', style: const pw.TextStyle(fontSize: 8)),
                        ],
                      ),
                      pw.SizedBox(height: 2),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('Total Payable:', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                          pw.Text('Rs. ${customer.clBalance}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                        ],
                      ),
                    ],
                    if (customer.cmName.isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Row(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('Agent: ', style: const pw.TextStyle(fontSize: 8)),
                          pw.Expanded(
                            child: pw.Text(
                              customer.cmName,
                              style: const pw.TextStyle(fontSize: 8),
                              textAlign: pw.TextAlign.right,
                              maxLines: 2,
                            ),
                          ),
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
      }

      final directPrint = await settingsService.getDirectPrintEnabled();
      final connectionType = await settingsService.getPrinterConnectionType();

      if (directPrint && connectionType == 'bluetooth') {
        final pdfBytes = await buildBillPdf(pageFormat);
        final btSuccess = await _sendPdfToBluetoothThermal(pdfBytes, settingsService);
        if (btSuccess) return true;
      }

      final printer = await getConnectedPrinter(settingsService);

      if (directPrint && printer != null) {
        final success = await Printing.directPrintPdf(
          printer: printer,
          onLayout: buildBillPdf,
          name: 'Bill_${customer.custName.replaceAll(' ', '_')}_${customer.billNo}',
        );
        if (success) return true;
      }

      await Printing.layoutPdf(
        onLayout: buildBillPdf,
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

      Future<Uint8List> buildReceiptPdf(PdfPageFormat format) async {
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
                        pw.Text('Receipt No:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.receiptNo.isNotEmpty ? customer.receiptNo : (customer.billNo.isNotEmpty ? 'REC-${customer.billNo}' : 'N/A'), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                      ],
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Bill No:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.billNo.isNotEmpty ? customer.billNo : 'N/A', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
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
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Received From: ', style: const pw.TextStyle(fontSize: 8)),
                        pw.Expanded(
                          child: pw.Text(
                            customer.custName.isNotEmpty ? customer.custName : (customer.mobile.isNotEmpty ? customer.mobile : 'Cash Customer'),
                            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
                            textAlign: pw.TextAlign.right,
                            maxLines: 3,
                          ),
                        ),
                      ],
                    ),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Mobile:', style: const pw.TextStyle(fontSize: 8)),
                        pw.Text(customer.mobile.isNotEmpty ? customer.mobile : 'N/A', style: const pw.TextStyle(fontSize: 8)),
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
      }

      final directPrint = await settingsService.getDirectPrintEnabled();
      final connectionType = await settingsService.getPrinterConnectionType();

      if (directPrint && connectionType == 'bluetooth') {
        final pdfBytes = await buildReceiptPdf(pageFormat);
        final btSuccess = await _sendPdfToBluetoothThermal(pdfBytes, settingsService);
        if (btSuccess) return true;
      }

      final printer = await getConnectedPrinter(settingsService);

      if (directPrint && printer != null) {
        final success = await Printing.directPrintPdf(
          printer: printer,
          onLayout: buildReceiptPdf,
          name: 'Receipt_${customer.custName.replaceAll(' ', '_')}_${customer.billNo}',
        );
        if (success) return true;
      }

      await Printing.layoutPdf(
        onLayout: buildReceiptPdf,
        name: 'Receipt_${customer.custName.replaceAll(' ', '_')}_${customer.billNo}',
      );
      return true;
    } catch (e) {
      print('PrintService printReceipt error: $e');
      return false;
    }
  }
}
