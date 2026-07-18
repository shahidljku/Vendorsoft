import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  final String baseUrl = 'https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1';

  Map<String, dynamic>? _systemConfig;
  Map<String, dynamic>? get systemConfig => _systemConfig;

  final StreamController<void> _configUpdatedController = StreamController<void>.broadcast();
  Stream<void> get onConfigUpdated => _configUpdatedController.stream;

  Timer? _pollingTimer;

  void startBackgroundPolling() {
    _pollingTimer?.cancel();
    fetchSystemConfig(); // Fire immediately on boot
    _pollingTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      fetchSystemConfig();
    });
  }

  void stopBackgroundPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  Future<void> fetchSystemConfig() async {
    try {
      final url = Uri.parse('$baseUrl/config/system');
      final response = await http.get(url);
      
      if (response.statusCode == 200) {
        final resJson = jsonDecode(response.body);
        if (resJson['success'] == true) {
          final newConfig = resJson['data'];
          if (jsonEncode(_systemConfig) != jsonEncode(newConfig)) {
            _systemConfig = newConfig;
            _configUpdatedController.add(null);
          }
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
