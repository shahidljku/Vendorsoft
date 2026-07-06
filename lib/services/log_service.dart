// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'settings_service.dart';

class LogService extends ChangeNotifier {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  Future<void> writeLog(
      String mobile,
      String status,
      ) async {
    try {
      if (!(await SettingsService().getEnableLogs())) {
        return;
      }

      final directory = await getApplicationDocumentsDirectory();
      final logDir = Directory('${directory.path}/VendSoft');

      if (!logDir.existsSync()) {
        logDir.createSync(recursive: true);
      }

      File file = File('${logDir.path}/logs.txt');

      await file.writeAsString(
        '${DateTime.now()} | $mobile | $status\n',
        mode: FileMode.append,
      );
      
      notifyListeners();
    } catch (e) {
      // Log write failure should not crash the app
      print('LogService error: $e');
    }
  }
}