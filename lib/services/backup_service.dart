// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../models/customer.dart';
import 'excel_service.dart';
import 'settings_service.dart';
import 'license_service.dart';

class BackupService {
  static final BackupService _instance = BackupService._internal();
  factory BackupService() => _instance;
  BackupService._internal();

  static const int currentSchemaVersion = 1;

  /// Helper to compute SHA-256 checksum of data string
  String _computeChecksum(String rawData) {
    final bytes = utf8.encode(rawData);
    return sha256.convert(bytes).toString();
  }

  /// Exports full A to Z database and configurations to a verified JSON package
  Future<File?> createBackupFile(ExcelService excelService, SettingsService settingsService) async {
    try {
      final deviceId = await LicenseService().getDeviceId();
      final timestamp = DateTime.now().toIso8601String();

      // Collect all settings
      final settingsMap = {
        'defaultSendLimit': await settingsService.getDefaultSendLimit(),
        'delayBetweenCustomers': await settingsService.getDelayBetweenCustomers(),
        'delayBeforeNext': await settingsService.getDelayBeforeNext(),
        'themeMode': await settingsService.getThemeMode(),
        'autoSendEnabled': await settingsService.getAutoSendEnabled(),
        'idleTimeout': await settingsService.getIdleTimeout(),
        'pinEnabled': await settingsService.getPinEnabled(),
        'useWhatsAppBusiness': await settingsService.getUseWhatsAppBusiness(),
        'defaultPrinterWidth': await settingsService.getDefaultPrinterWidth(),
        'savedCollectionMen': await settingsService.getSavedCollectionMen(),
        'savedItems': await settingsService.getSavedItems(),
      };

      // Collect all customers
      final customersList = excelService.allCustomers.map((c) => c.toJson()).toList();

      // Collect logs if existing
      String logsContent = '';
      try {
        final directory = await getApplicationDocumentsDirectory();
        final logFile = File('${directory.path}/VendSoft/logs.txt');
        if (await logFile.exists()) {
          logsContent = await logFile.readAsString();
        }
      } catch (_) {}

      // Build payload without checksum first
      final dataPayload = {
        'settings': settingsMap,
        'customers': customersList,
        'logs': logsContent,
      };

      final dataJsonStr = jsonEncode(dataPayload);
      final checksum = _computeChecksum(dataJsonStr);

      final fullPackage = {
        'vendsoft_backup_metadata': {
          'version': currentSchemaVersion,
          'timestamp': timestamp,
          'deviceId': deviceId,
          'customer_count': customersList.length,
          'checksum': checksum,
        },
        'data': dataPayload,
      };

      // Ensure backups directory exists
      final backupDir = Directory('/storage/emulated/0/VendSoft/backups');
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      final fileName = 'VendSoft_Backup_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.json';
      final file = File('${backupDir.path}/$fileName');
      await file.writeAsString(jsonEncode(fullPackage));
      print('Backup written successfully to: ${file.path}');
      return file;
    } catch (e) {
      print('Failed to create backup file: $e');
      return null;
    }
  }

  /// Inspects a backup JSON file or string, validating checksum and version
  Future<Map<String, dynamic>> inspectBackup(String jsonContent) async {
    try {
      final decoded = jsonDecode(jsonContent);
      final metadata = decoded['vendsoft_backup_metadata'];
      final data = decoded['data'];

      if (metadata == null || data == null) {
        return {'isValid': false, 'error': 'Invalid backup format: Missing metadata or data section.'};
      }

      final int version = metadata['version'] ?? 0;
      if (version > currentSchemaVersion) {
        return {'isValid': false, 'error': 'Unsupported backup version ($version). Please update the app.'};
      }

      final String expectedChecksum = metadata['checksum'] ?? '';
      final String actualChecksum = _computeChecksum(jsonEncode(data));

      if (expectedChecksum.isNotEmpty && expectedChecksum != actualChecksum) {
        return {'isValid': false, 'error': 'Corrupted backup: Checksum verification failed.'};
      }

      final List<dynamic> customers = data['customers'] ?? [];
      final Map<String, dynamic> settings = data['settings'] ?? {};

      return {
        'isValid': true,
        'version': version,
        'timestamp': metadata['timestamp'],
        'deviceId': metadata['deviceId'],
        'customerCount': customers.length,
        'settingsCount': settings.length,
        'data': data,
      };
    } catch (e) {
      return {'isValid': false, 'error': 'JSON parse failure: $e'};
    }
  }

  /// Restores A to Z database and configurations from validated backup payload
  Future<bool> restoreFullBackup({
    required Map<String, dynamic> backupData,
    required ExcelService excelService,
    required SettingsService settingsService,
  }) async {
    // 1. Create Pre-Restore Snapshot for safety
    File? snapshotFile;
    try {
      snapshotFile = await createBackupFile(excelService, settingsService);
      if (snapshotFile != null) {
        final snapshotDest = File('/storage/emulated/0/VendSoft/backups/.snapshot_pre_restore.json');
        if (await snapshotDest.exists()) await snapshotDest.delete();
        await snapshotFile.copy(snapshotDest.path);
      }
    } catch (e) {
      print('Warning: Failed to create pre-restore snapshot: $e');
    }

    try {
      final Map<String, dynamic> settingsMap = backupData['settings'] ?? {};
      final List<dynamic> customersList = backupData['customers'] ?? [];
      final String logsContent = backupData['logs'] ?? '';

      // 2. Restore Settings
      if (settingsMap.containsKey('defaultSendLimit')) {
        await settingsService.setDefaultSendLimit(settingsMap['defaultSendLimit'] ?? 30);
      }
      if (settingsMap.containsKey('delayBetweenCustomers')) {
        await settingsService.setDelayBetweenCustomers(settingsMap['delayBetweenCustomers'] ?? 10000);
      }
      if (settingsMap.containsKey('delayBeforeNext')) {
        await settingsService.setDelayBeforeNext(settingsMap['delayBeforeNext'] ?? 10000);
      }
      if (settingsMap.containsKey('themeMode')) {
        await settingsService.setThemeMode(settingsMap['themeMode'] ?? 'system');
      }
      if (settingsMap.containsKey('autoSendEnabled')) {
        await settingsService.setAutoSendEnabled(settingsMap['autoSendEnabled'] ?? false);
      }
      if (settingsMap.containsKey('idleTimeout')) {
        await settingsService.setIdleTimeout(settingsMap['idleTimeout'] ?? 5);
      }
      if (settingsMap.containsKey('pinEnabled')) {
        await settingsService.setPinEnabled(settingsMap['pinEnabled'] ?? false);
      }
      if (settingsMap.containsKey('useWhatsAppBusiness')) {
        await settingsService.setUseWhatsAppBusiness(settingsMap['useWhatsAppBusiness'] ?? false);
      }
      if (settingsMap.containsKey('defaultPrinterWidth')) {
        await settingsService.setDefaultPrinterWidth(settingsMap['defaultPrinterWidth'] ?? '58mm');
      }
      if (settingsMap.containsKey('savedCollectionMen')) {
        final List<dynamic> list = settingsMap['savedCollectionMen'];
        for (var item in list) {
          await settingsService.addSavedCollectionMan(item.toString());
        }
      }
      if (settingsMap.containsKey('savedItems')) {
        final List<dynamic> list = settingsMap['savedItems'];
        for (var item in list) {
          await settingsService.addSavedItem(item.toString());
        }
      }

      // 3. Restore Customers
      List<Customer> restoredCustomers = [];
      for (var item in customersList) {
        if (item is Map<String, dynamic>) {
          restoredCustomers.add(Customer.fromJson(item));
        }
      }
      excelService.allCustomers = restoredCustomers;
      await excelService.saveCustomers();

      // 4. Restore Logs
      if (logsContent.isNotEmpty) {
        try {
          final directory = await getApplicationDocumentsDirectory();
          final logFile = File('${directory.path}/VendSoft/logs.txt');
          await logFile.writeAsString(logsContent);
        } catch (_) {}
      }

      print('Restore completed successfully. Restored ${restoredCustomers.length} customers.');
      return true;
    } catch (e) {
      print('Restore error encountered: $e. Attempting rollback from snapshot...');
      // Rollback from snapshot if restoration crashed midway
      try {
        final snapshotDest = File('/storage/emulated/0/VendSoft/backups/.snapshot_pre_restore.json');
        if (await snapshotDest.exists()) {
          final content = await snapshotDest.readAsString();
          final inspection = await inspectBackup(content);
          if (inspection['isValid'] == true) {
            final data = inspection['data'];
            List<Customer> rollbackCustomers = (data['customers'] as List<dynamic>)
                .map((c) => Customer.fromJson(c as Map<String, dynamic>))
                .toList();
            excelService.allCustomers = rollbackCustomers;
            await excelService.saveCustomers();
            print('Rollback successful.');
          }
        }
      } catch (rollbackErr) {
        print('Rollback failed: $rollbackErr');
      }
      return false;
    }
  }
}
