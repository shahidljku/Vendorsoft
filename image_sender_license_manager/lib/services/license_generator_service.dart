import 'dart:convert';
import 'package:encrypt/encrypt.dart';
// ignore: depend_on_referenced_packages
import 'package:pointycastle/asymmetric/api.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LicenseGeneratorService {
  static final LicenseGeneratorService _instance = LicenseGeneratorService._internal();
  factory LicenseGeneratorService() => _instance;
  LicenseGeneratorService._internal();

  static const String privateKeyString = '''
[REDACTED_RSA_PRIVATE_KEY]
''';

  static const String _historyKey = 'license_history';

  Future<String> getNextLicenseNumber() async {
    final prefs = await SharedPreferences.getInstance();
    final year = DateTime.now().year;
    final counterKey = 'license_counter_$year';
    int counter = prefs.getInt(counterKey) ?? 1;
    prefs.setInt(counterKey, counter + 1);
    final numberStr = counter.toString().padLeft(6, '0');
    return 'LIC-$year-$numberStr';
  }

  Future<String> generateLicense({
    required String deviceId,
    required String customerName,
    required String customerType,
    DateTime? expiryDate,
  }) async {
    final licenseNumber = await getNextLicenseNumber();
    final issueDate = DateTime.now();

    final payload = {
      'deviceId': deviceId.trim(),
      'customerName': customerName.trim(),
      'customerType': customerType,
      'licenseNumber': licenseNumber,
      'issueDate': issueDate.toIso8601String(),
      'expiryDate': expiryDate?.toIso8601String() ?? '',
      'appVersion': '1.0',
    };

    final payloadStr = jsonEncode(payload);

    final parser = RSAKeyParser();
    final privateKey = parser.parse(privateKeyString) as RSAPrivateKey;
    
    final signer = Signer(RSASigner(RSASignDigest.SHA256, privateKey: privateKey));
    final signature = signer.sign(payloadStr);

    final licenseObj = {
      'payload': payloadStr,
      'signature': signature.base64,
    };

    final finalLicense = base64Encode(utf8.encode(jsonEncode(licenseObj)));

    await _saveToHistory({
      ...payload,
      'fullLicense': finalLicense,
    });

    return finalLicense;
  }

  Future<void> _saveToHistory(Map<String, dynamic> licenseData) async {
    final prefs = await SharedPreferences.getInstance();
    final historyStr = prefs.getString(_historyKey);
    List<dynamic> history = [];
    if (historyStr != null) {
      history = jsonDecode(historyStr);
    }
    history.insert(0, licenseData);
    await prefs.setString(_historyKey, jsonEncode(history));
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final historyStr = prefs.getString(_historyKey);
    if (historyStr == null) return [];
    
    final List<dynamic> list = jsonDecode(historyStr);
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }
}
