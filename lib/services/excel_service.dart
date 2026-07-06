// ignore_for_file: avoid_print
import 'dart:typed_data';

import '../models/customer.dart';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';
import 'file_access_service.dart';

class ExcelService extends ChangeNotifier {

  /// The content URI of the original file (from SAF).
  /// This is used to save back to the original location.
  String? _documentUri;

  /// Expose the document URI for persisting in settings
  String? get documentUri => _documentUri;

  /// The display name of the picked file.
  String? fileName;

  /// All customers loaded from the Excel file.
  /// This is the master list that gets saved back to Excel.
  List<Customer> allCustomers = [];

  /// Picks an Excel file using Android SAF with persistent write access.
  /// Returns the file name if successful, null if cancelled.
  Future<String?> pickExcel() async {

    final result = await FileAccessService.pickExcelWithWriteAccess();

    if (result == null) return null;

    _documentUri = result['uri'] as String;
    final bytes = result['bytes'] as Uint8List;
    fileName = result['fileName'] as String;

    // Parse the Excel content
    _parseExcelBytes(bytes);

    return fileName;
  }

  /// Attempts to load the Excel file from a previously saved URI.
  /// Returns true if successful, false otherwise.
  Future<bool> loadFromUri(String uri, String name) async {
    final bytes = await FileAccessService.readFromUri(uri);
    if (bytes == null) return false;

    _documentUri = uri;
    fileName = name;

    try {
      _parseExcelBytes(bytes);
      return true;
    } catch (e) {
      print('ExcelService loadFromUri error: $e');
      return false;
    }
  }

  /// Parses Excel bytes and populates allCustomers.
  void _parseExcelBytes(Uint8List bytes) {
    List<Customer> customers = [];

    var excel = Excel.decodeBytes(bytes);

    String firstSheet = excel.tables.keys.first;

    Sheet sheet = excel.tables[firstSheet]!;

    for (int i = 1; i < sheet.maxRows; i++) {
      var row = sheet.row(i);

      String status = row.length > 3
          ? _cellToString(row[3], 'Pending')
          : 'Pending';

      // If status is empty, default to Pending
      if (status.isEmpty) {
        status = 'Pending';
      }

      customers.add(
        Customer(
          mobile: row.isNotEmpty ? _cellToString(row[0]) : '',
          custName: row.length > 1 ? _cellToString(row[1]) : '',
          yesNo: row.length > 2 ? _cellToString(row[2]) : '',
          status: status,
          imagePath: row.length > 4 ? _cellToString(row[4]) : '',
          message: row.length > 5 ? _cellToString(row[5]) : '',
          vouchDate: row.length > 6 ? _cellToString(row[6], '', true) : '',
          custNo: row.length > 7 ? _cellToString(row[7]) : '',
          billNo: row.length > 8 ? _cellToString(row[8]) : '',
          billAmount: row.length > 9 ? _cellToString(row[9]) : '',
          clBalance: row.length > 10 ? _cellToString(row[10]) : '',
          cmCode: row.length > 11 ? _cellToString(row[11]) : '',
          cmName: row.length > 12 ? _cellToString(row[12]) : '',
          monthNm: row.length > 13 ? _cellToString(row[13]) : '',
          sentTime: row.length > 14 ? _cellToString(row[14]) : '',
          paymentStatus: row.length > 15 ? _cellToString(row[15]) : '',
          amountPaid: row.length > 16 ? _cellToString(row[16]) : '',
          transactionId: row.length > 17 ? _cellToString(row[17]) : '',
          paymentMethod: row.length > 18 ? _cellToString(row[18]) : '',
          receiptStatus: row.length > 19 ? _cellToString(row[19]) : '',
          paymentDate: row.length > 20 ? _cellToString(row[20], '', true) : '',
        ),
      );
    }

    allCustomers = customers;
    notifyListeners();
  }

  /// Helper to safely read a cell value as a non-null string.
  /// Handles null cells, null values, and the literal string "null".
  String _cellToString(dynamic cell, [String defaultValue = '', bool isDate = false]) {
    if (cell == null) return defaultValue;
    final value = cell.value;
    if (value == null) return defaultValue;
    String str = value.toString();
    if (str == 'null') return defaultValue;
    
    if (isDate) {
      if (str.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(str)) {
        DateTime? dt = DateTime.tryParse(str);
        if (dt != null) {
          return "${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}";
        }
      }
    }

    if (str.endsWith('.0')) {
      str = str.substring(0, str.length - 2);
    }
    return str.trim();
  }

  /// Returns the loaded customer list.
  /// Call pickExcel() first to load.
  List<Customer> getCustomers() {
    return allCustomers;
  }

  List<Customer> getPendingCustomers(
      List<Customer> customers,
      int limit
      ) {

    List<Customer> pending = customers
        .where((c) =>
    c.status.toLowerCase() == 'pending')
        .toList();

    if (pending.length <= limit) {
      return pending;
    }

    return pending.sublist(0, limit);
  }

  /// Saves all customers back to the ORIGINAL Excel file via SAF.
  /// Returns true on success, false on failure.
  Future<bool> saveCustomers(
      List<Customer> customers,
      ) async {

    if (_documentUri == null) {
      print('ExcelService save error: no document URI');
      return false;
    }

    try {
      var excel = Excel.createExcel();

      // Get the default sheet name created by createExcel()
      String defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';

      // Rename default sheet to 'Sheet1' if it has a different name
      if (defaultSheet != 'Sheet1') {
        excel.rename(defaultSheet, 'Sheet1');
      }

      Sheet sheet = excel['Sheet1'];

      // Write header row
      sheet.appendRow([
        TextCellValue('mobile_no'),
        TextCellValue('custname'),
        TextCellValue('YesNo'),
        TextCellValue('Status'),
        TextCellValue('jpg_Path'),
        TextCellValue('message'),
        TextCellValue('vouch_date'),
        TextCellValue('cust_no'),
        TextCellValue('bill_no'),
        TextCellValue('bill_amount'),
        TextCellValue('cl_balance'),
        TextCellValue('cm_code'),
        TextCellValue('cm_name'),
        TextCellValue('Month_nm'),
        TextCellValue('SentTime'),
        TextCellValue('PaymentStatus'),
        TextCellValue('AmountPaid'),
        TextCellValue('TransactionId'),
        TextCellValue('PaymentMethod'),
        TextCellValue('ReceiptStatus'),
        TextCellValue('PaymentDate'),
      ]);

      // Write all customer data
      for (Customer c in customers) {
        sheet.appendRow([
          TextCellValue(c.mobile),
          TextCellValue(c.custName),
          TextCellValue(c.yesNo),
          TextCellValue(c.status),
          TextCellValue(c.imagePath),
          TextCellValue(c.message),
          TextCellValue(c.vouchDate),
          TextCellValue(c.custNo),
          TextCellValue(c.billNo),
          TextCellValue(c.billAmount),
          TextCellValue(c.clBalance),
          TextCellValue(c.cmCode),
          TextCellValue(c.cmName),
          TextCellValue(c.monthNm),
          TextCellValue(c.sentTime),
          TextCellValue(c.paymentStatus),
          TextCellValue(c.amountPaid),
          TextCellValue(c.transactionId),
          TextCellValue(c.paymentMethod),
          TextCellValue(c.receiptStatus),
          TextCellValue(c.paymentDate),
        ]);
      }

      // Remove any extra default sheets
      for (String sheetName in excel.tables.keys.toList()) {
        if (sheetName != 'Sheet1') {
          excel.delete(sheetName);
        }
      }

      List<int>? bytes = excel.encode();

      if (bytes == null) {
        print('ExcelService save error: encode() returned null');
        return false;
      }

      // Write back to the ORIGINAL file via SAF content URI
      bool saved = await FileAccessService.saveToUri(
        _documentUri!,
        Uint8List.fromList(bytes),
      );

      if (saved) {
        print('ExcelService: Saved ${customers.length} customers to original file');
        notifyListeners();
      } else {
        print('ExcelService save error: SAF write failed');
      }

      return saved;
    } catch (e) {
      print('ExcelService save error: $e');
      return false;
    }
  }
}