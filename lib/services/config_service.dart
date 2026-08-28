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

  List<Map<String, dynamic>> _plans = [];
  List<Map<String, dynamic>> get plans => _plans;

  final StreamController<void> _configUpdatedController = StreamController<void>.broadcast();
  Stream<void> get onConfigUpdated => _configUpdatedController.stream;

  Timer? _pollingTimer;

  void startBackgroundPolling() {
    _pollingTimer?.cancel();
    fetchSystemConfig(); // Fire immediately on boot
    fetchPlans();
    _pollingTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      fetchSystemConfig();
      fetchPlans();
    });
  }

  void stopBackgroundPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  Future<void> fetchSystemConfig() async {
    try {
      final url = Uri.parse('$baseUrl/config/system');
      final response = await http.get(url).timeout(const Duration(seconds: 8));
      
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
      // Background poll failure is normal during offline states
    }
  }

  Future<List<Map<String, dynamic>>> fetchPlans() async {
    try {
      final url = Uri.parse('$baseUrl/plans');
      final response = await http.get(url).timeout(const Duration(seconds: 8));
      
      if (response.statusCode == 200) {
        final resJson = jsonDecode(response.body);
        if (resJson['success'] == true && resJson['data'] is List) {
          final List<dynamic> rawList = resJson['data'];
          final List<Map<String, dynamic>> newPlans = rawList
              .where((item) => item is Map && item['isActive'] != false)
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList();
          
          if (newPlans.isNotEmpty && jsonEncode(_plans) != jsonEncode(newPlans)) {
            _plans = newPlans;
            _configUpdatedController.add(null);
          }
        }
      }
    } catch (e) {
      // Fallback handled gracefully
    }
    return _plans;
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
    
    // Simple semver comparison
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

    for (int i = 0; i < minimum.length; i++) {
      if (i >= current.length) return true;
      if (current[i] < minimum[i]) return true;
      if (current[i] > minimum[i]) return false;
    }
    
    for (int i = 0; i < latest.length; i++) {
      if (i >= current.length) return true;
      if (current[i] < latest[i]) return true;
      if (current[i] > latest[i]) return false;
    }

    return false;
  }

  String get monthlyPlanPrice {
    final monthlyPlan = _plans.firstWhere(
      (p) => p['planId'] == 'PRO_MONTHLY' || p['planId'] == 'PRO_MONTHLY_SOFT',
      orElse: () => <String, dynamic>{},
    );
    if (monthlyPlan.isNotEmpty && monthlyPlan['amountPaise'] != null) {
      final inr = (monthlyPlan['amountPaise'] / 100).toInt();
      return '₹$inr';
    }
    return _systemConfig?['pricing']?['monthly'] ?? '₹999';
  }

  String get yearlyPlanPrice {
    final yearlyPlan = _plans.firstWhere(
      (p) => p['planId'] == 'PRO_YEARLY' || p['planId'] == 'PRO_YEARLY_SOFT',
      orElse: () => <String, dynamic>{},
    );
    if (yearlyPlan.isNotEmpty && yearlyPlan['amountPaise'] != null) {
      final inr = (yearlyPlan['amountPaise'] / 100).toInt();
      return '₹$inr (12 + 1 Month FREE)';
    }
    return _systemConfig?['pricing']?['yearly'] ?? '₹11,999 (12 + 1 Month FREE)';
  }
}
