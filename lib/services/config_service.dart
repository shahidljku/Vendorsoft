import 'dart:convert';
import 'package:http/http.dart' as http;

class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  final String baseUrl = 'https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1';

  Map<String, dynamic>? _systemConfig;
  Map<String, dynamic>? get systemConfig => _systemConfig;

  Future<void> fetchSystemConfig() async {
    try {
      final url = Uri.parse('$baseUrl/config/system');
      final response = await http.get(url);
      
      if (response.statusCode == 200) {
        final resJson = jsonDecode(response.body);
        if (resJson['success'] == true) {
          _systemConfig = resJson['data'];
        }
      }
    } catch (e) {
      print('Failed to fetch system config: $e');
    }
  }

  bool get isMaintenanceMode {
    if (_systemConfig == null) return false;
    return _systemConfig!['maintenanceMode'] == true;
  }

  String get maintenanceMessage {
    if (_systemConfig == null) return 'System is under maintenance. Offline billing continues normally.';
    return _systemConfig!['maintenanceMessage'] ?? 'System is under maintenance. Offline billing continues normally.';
  }

  bool get allowRegistrations {
    if (_systemConfig == null) return true;
    return _systemConfig!['allowRegistrations'] != false;
  }
}
