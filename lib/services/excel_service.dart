// ignore_for_file: avoid_print
import 'dart:async';
import '../models/customer.dart';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';
import 'file_access_service.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
// ignore: unused_import
import 'license_service.dart';

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
    await _parseExcelBytes(bytes);

    return fileName;
  }

  bool _isCorrupted = false;
  bool get isCorrupted => _isCorrupted;

  /// Attempts to load the Excel file from a previously saved URI.
  /// Returns true if successful, false otherwise.
  Future<bool> loadFromUri(String uri, String name) async {
    while (_activeSaveFuture != null) {
      try {
        await _activeSaveFuture;
      } catch (_) {}
    }
    
    _isCorrupted = false;
    final bytes = await FileAccessService.readFromUri(uri);
    if (bytes == null || bytes.isEmpty) {
      _isCorrupted = true;
      return false;
    }

    _documentUri = uri;
    fileName = name;

    try {
      await _parseExcelBytes(bytes);
      return true;
    } catch (e) {
      print('ExcelService loadFromUri error: $e');
      _isCorrupted = true;
      return false;
    }
  }

  Future<bool> hasRecoverableBackup(String uri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final backupUri = prefs.getString('backup_uri_key');
      if (backupUri != uri) return false;

      final dir = await getApplicationDocumentsDirectory();
      final validFile = File('${dir.path}/VendSoft_Backup/valid_backup.xlsx');
      return await validFile.exists();
    } catch (_) {
      return false;
    }
  }

  Future<bool> restoreFromBackup(String uri) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final validFile = File('${dir.path}/VendSoft_Backup/valid_backup.xlsx');
      if (!await validFile.exists()) return false;

      final bytes = await validFile.readAsBytes();
      bool saved = await FileAccessService.saveToUri(uri, bytes);
      if (saved) {
        return await loadFromUri(uri, fileName ?? 'Restored_File');
      }
      return false;
    } catch (e) {
      print('Restore error: $e');
      return false;
    }
  }

  /// Parses Excel bytes and populates allCustomers.
  Future<void> _parseExcelBytes(Uint8List bytes) async {
    List<Customer> customers = [];

    var excel = Excel.decodeBytes(bytes);

    for (var table in excel.tables.keys) {
      var rows = excel.tables[table]?.rows;
      if (rows == null || rows.isEmpty) continue;

      // Skip header row
      for (int i = 1; i < rows.length; i++) {
        var row = rows[i];
        if (row.isEmpty) continue;

        String mobile = _cellToString(row[0]);
        if (mobile == 'mobile_no') continue;

        String status = row.length > 3 ? _cellToString(row[3]) : 'Pending';

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
            receiptNo: row.length > 21 ? _cellToString(row[21]) : '',
          ),
        );
      }
    }

    // DEMO LIMIT DISABLED — uncomment to restore 50-customer cap
    // if (await LicenseService().isDemoMode()) {
    //   int limit = LicenseService().getDemoCustomerLimit();
    //   if (customers.length > limit) {
    //     print('Demo Mode: Truncating loaded customers to $limit');
    //     customers = customers.sublist(0, limit);
    //   }
    // }

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

  Future<bool>? _activeSaveFuture;

  /// Saves all customers back to the ORIGINAL Excel file via SAF.
  /// Uses a mutex lock to serialize concurrent save requests to prevent file corruption.
  /// Returns true on success, false on failure.
  Future<bool> saveCustomers({List<Customer>? customers, bool notify = true}) async {
    while (_activeSaveFuture != null) {
      try {
        await _activeSaveFuture;
      } catch (_) {}
    }

    final completer = Completer<bool>();
    _activeSaveFuture = completer.future;

    try {
      final targetCustomers = customers ?? allCustomers;
      final result = await _executeSave(targetCustomers, notify);
      completer.complete(result);
      return result;
    } catch (e) {
      print('ExcelService save error: $e');
      if (!completer.isCompleted) completer.complete(false);
      return false;
    } finally {
      if (_activeSaveFuture == completer.future) {
        _activeSaveFuture = null;
      }
    }
  }

  Future<bool> _executeSave(List<Customer> customers, bool notify) async {
    if (_documentUri == null) {
      print('ExcelService save error: no document URI');
      return false;
    }

    try {
      final serializedCustomers = customers.map((c) => c.toJson()).toList();
      final Uint8List? bytes = await compute(_buildExcelBytesInBackground, serializedCustomers);

      if (bytes == null) {
        print('ExcelService save error: encode() returned null');
        return false;
      }

      // -- QA-001 Transactional Backup --
      try {
        final dir = await getApplicationDocumentsDirectory();
        final backupDir = Directory('${dir.path}/VendSoft_Backup');
        if (!await backupDir.exists()) {
          await backupDir.create(recursive: true);
        }
        final tempFile = File('${backupDir.path}/temp_backup.xlsx');
        final validFile = File('${backupDir.path}/valid_backup.xlsx');

        await tempFile.writeAsBytes(bytes, flush: true);
        if (await tempFile.length() > 0) {
          if (await validFile.exists()) {
            await validFile.delete();
          }
          await tempFile.rename(validFile.path);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('backup_uri_key', _documentUri!);
        }
      } catch (e) {
        print('ExcelService backup error: $e');
      }
      // ---------------------------------

      // Write back to the ORIGINAL file via SAF content URI
      bool saved = await FileAccessService.saveToUri(
        _documentUri!,
        bytes,
      );

      if (saved) {
        print('ExcelService: Saved ${customers.length} customers to original file');
        if (notify) {
          notifyListeners();
        }
      } else {
        print('ExcelService save error: SAF write failed');
      }

      return saved;
    } catch (e) {
      print('ExcelService save error: $e');
      return false;
    }
  }

  /// Flushes all cached Excel data from memory and UI state.
  /// Used during logout to prevent account data merging (Issue 10).
  Future<void> clearData() async {
    allCustomers.clear();
    _documentUri = null;
    fileName = null;
    notifyListeners();
  }
  
  void triggerNotify() {
    notifyListeners();
  }
}

Future<Uint8List?> _buildExcelBytesInBackground(List<Map<String, dynamic>> serializedCustomers) async {
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
      TextCellValue('ReceiptNo'),
    ]);

    // Write all customer data
    for (var c in serializedCustomers) {
      sheet.appendRow([
        TextCellValue(c['mobile'] ?? ''),
        TextCellValue(c['custName'] ?? ''),
        TextCellValue(c['yesNo'] ?? ''),
        TextCellValue(c['status'] ?? ''),
        TextCellValue(c['imagePath'] ?? ''),
        TextCellValue(c['message'] ?? ''),
        TextCellValue(c['vouchDate'] ?? ''),
        TextCellValue(c['custNo'] ?? ''),
        TextCellValue(c['billNo'] ?? ''),
        TextCellValue(c['billAmount'] ?? ''),
        TextCellValue(c['clBalance'] ?? ''),
        TextCellValue(c['cmCode'] ?? ''),
        TextCellValue(c['cmName'] ?? ''),
        TextCellValue(c['monthNm'] ?? ''),
        TextCellValue(c['sentTime'] ?? ''),
        TextCellValue(c['paymentStatus'] ?? ''),
        TextCellValue(c['amountPaid'] ?? ''),
        TextCellValue(c['transactionId'] ?? ''),
        TextCellValue(c['paymentMethod'] ?? ''),
        TextCellValue(c['receiptStatus'] ?? ''),
        TextCellValue(c['paymentDate'] ?? ''),
        TextCellValue(c['receiptNo'] ?? ''),
      ]);
    }

    // Remove any extra default sheets
    for (String sheetName in excel.tables.keys.toList()) {
      if (sheetName != 'Sheet1') {
        excel.delete(sheetName);
      }
    }

    List<int>? bytes = excel.encode();
    if (bytes == null) return null;
    return Uint8List.fromList(bytes);
  } catch (e) {
    print('Excel encoding error in isolate: $e');
    return null;
  }
}