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

  bool get enforceStrictAppVersion {
    if (_systemConfig == null) return false;
    return _systemConfig!['enforceStrictAppVersion'] == true;
  }

  String get minimumSupportedVersion {
    return _systemConfig?['minimumSupportedVersion'] ?? '1.0.0+1';
  }

  String get latestVersion {
    return _systemConfig?['latestVersion'] ?? '1.0.0+1';
  }

  String get apkDownloadUrl {
    return _systemConfig?['apkDownloadUrl'] ?? '';
  }

  bool isUpdateRequired(String currentAppVersion) {
    if (!enforceStrictAppVersion) return false;
    
    // Simple semver comparison (assuming format like "1.0.0+1" or "1.0.0")
    // If the string exactly matches the minimum or latest, we can consider it.
    // To make it robust: compare the versions.
    List<int> parseVersion(String v) {
      final parts = v.split('+');
      final numbers = parts[0].split('.').map((e) => int.tryParse(e) ?? 0).toList();
      if (parts.length > 1) {
        numbers.add(int.tryParse(parts[1]) ?? 0);
      } else {
        numbers.add(0);
      }
      return numbers;
    }

    final current = parseVersion(currentAppVersion);
    final minimum = parseVersion(minimumSupportedVersion);
    final latest = parseVersion(latestVersion);

    // If current is less than minimum, definitely require update
    for (int i = 0; i < minimum.length; i++) {
      if (i >= current.length) return true; // Current is shorter, e.g. 1.0 vs 1.0.1
      if (current[i] < minimum[i]) return true;
      if (current[i] > minimum[i]) return false; // Current is strictly greater
    }
    
    // If we reach here, current >= minimum. 
    // Wait, the prompt says "enforceStrictAppVersion" forces users to update to latest if they are outdated.
    // If enforceStrictAppVersion is true, they MUST be on the latest version.
    for (int i = 0; i < latest.length; i++) {
      if (i >= current.length) return true;
      if (current[i] < latest[i]) return true;
      if (current[i] > latest[i]) return false;
    }

    return false;
  }

  String get monthlyPlanPrice {
    return _systemConfig?['pricing']?['monthly'] ?? '₹799';
  }

  String get yearlyPlanPrice {
    return _systemConfig?['pricing']?['yearly'] ?? '₹9,499 (12 + 1 Month FREE)';
  }
}
