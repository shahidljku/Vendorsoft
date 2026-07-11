// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:encrypt/encrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:android_id/android_id.dart';
// ignore: depend_on_referenced_packages
import 'package:pointycastle/asymmetric/api.dart';

class LicenseService {
  static final LicenseService _instance = LicenseService._internal();
  factory LicenseService() => _instance;
  LicenseService._internal();

  static const String _licenseKeyPref = 'offline_license_key';
  final _storage = const FlutterSecureStorage();
  final _androidIdPlugin = const AndroidId();

  // Hardcoded public key corresponding to the developer's private key
  static const String publicKeyString = '''
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAq5K1M4RgVKtFNqVfRQ71
ocBrAfUu9uhK6rR91r07iJstUzygBjpqCbIxAc0BzATIxgQ6yHd3zp5rr4xrKRIh
9Kl7o4A6uRiiaAb61S9Tcf/D6Chq8etZJ4VQc2WBzyi00Kw5lKmZtYFqmgQPuzcy
nykc3e8LoQ8HeMdoUp41nQdlf4ycmqq2fi5TVFFodvE21O+9Q9Kr3OM91QFrxKVd
of9lekmxqtIFjL3ia7w+dkenebHxq/YbCFHHgZvRbnABRRyxToVHFPLS+6ZOnVL3
TMj+g3jEHWMMdOrqXtNXkCcXfe8lFNpIKZx7zBoLp2DGPhneZwPgSvrhYiWirefA
MQIDAQAB
-----END PUBLIC KEY-----
''';

  String? _deviceIdCache;
  Map<String, dynamic>? _currentLicenseInfo;

  /// Generate a stable, short Device ID.
  Future<String> getDeviceId() async {
    if (_deviceIdCache != null) return _deviceIdCache!;

    String? androidId = await _androidIdPlugin.getId();
    if (androidId == null || androidId.isEmpty) {
      androidId = 'UNKNOWN_DEVICE';
    }

    // Hash it and take the first 16 chars to make it nice for sharing
    final bytes = utf8.encode(androidId);
    final digest = sha256.convert(bytes);
    final shortId = digest.toString().substring(0, 16).toUpperCase();

    _deviceIdCache = shortId;
    return shortId;
  }

  /// Verifies a license key (base64 encoded JSON containing payload and signature)
  Future<bool> verifyAndSaveLicense(String licenseKeyBase64) async {
    try {
      final decodedBytes = base64Decode(licenseKeyBase64);
      final jsonStr = utf8.decode(decodedBytes);
      final licenseObj = jsonDecode(jsonStr);

      final payloadStr = licenseObj['payload'];
      final signatureBase64 = licenseObj['signature'];

      // Parse payload
      final payload = jsonDecode(payloadStr);
      final licensedDeviceId = payload['deviceId'];

      // Check device ID match
      final currentDeviceId = await getDeviceId();
      if (licensedDeviceId != currentDeviceId) {
        return false;
      }

      // Verify RSA Signature
      final parser = RSAKeyParser();
      final publicKey = parser.parse(publicKeyString) as RSAPublicKey;
      
      final signer = Signer(RSASigner(RSASignDigest.SHA256, publicKey: publicKey));
      final isValid = signer.verify(payloadStr, Encrypted.fromBase64(signatureBase64));

      if (isValid) {
        await _storage.write(key: _licenseKeyPref, value: licenseKeyBase64);
        _currentLicenseInfo = payload;
        return true;
      }
    } catch (e) {
      // Invalid format or tampering
      print('License verification failed: \$e');
    }
    return false;
  }

  /// Check if the app is currently licensed on this device
  Future<bool> isLicensed() async {
    final savedKey = await _storage.read(key: _licenseKeyPref);
    if (savedKey == null) {
      return false;
    }

    // We verify it again to ensure device ID hasn't changed (e.g. copied APK/data to new phone)
    final isValid = await verifyAndSaveLicense(savedKey);
    if (!isValid) {
      // Remove invalid key
      await removeLicense();
    }
    return isValid;
  }
  
  /// Check if the current license is expired
  bool isLicenseExpired() {
    if (_currentLicenseInfo == null) return true;
    
    final customerType = _currentLicenseInfo!['customerType'] as String?;
    if (customerType == 'Lifetime') {
      return false;
    }
    
    final expiryDateStr = _currentLicenseInfo!['expiryDate'] as String?;
    if (expiryDateStr != null && expiryDateStr.isNotEmpty) {
      final expiryDate = DateTime.tryParse(expiryDateStr);
      if (expiryDate != null) {
        // Only comparing date parts, ignoring time
        final today = DateTime.now();
        final todayDate = DateTime(today.year, today.month, today.day);
        final expDate = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
        
        if (todayDate.isAfter(expDate)) {
          return true; // Expired
        }
      }
    }
    
    return false;
  }

  /// Retrieve license information
  Map<String, dynamic>? getLicenseInfo() {
    return _currentLicenseInfo;
  }

  /// Retrieve the business name (customer name) from the license
  String getBusinessName() {
    if (_currentLicenseInfo == null) return 'Your Business Name';
    return _currentLicenseInfo!['customerName'] as String? ?? 'Your Business Name';
  }

  /// Remove license (deactivate)
  Future<void> removeLicense() async {
    await _storage.delete(key: _licenseKeyPref);
    _currentLicenseInfo = null;
  }

  /// Check if application is currently in Demo Mode (unlicensed or expired)
  Future<bool> isDemoMode() async {
    bool licensed = await isLicensed();
    if (!licensed) return true;
    return isLicenseExpired();
  }

  /// Maximum number of customers allowed when in Demo Mode
  int getDemoCustomerLimit() => 50;

  /// Subscription pricing helpers
  String getMonthlyPlanPrice() => '₹799 / month';
  String getYearlyPlanPrice() => '₹9,499 / year (12 + 1 Month FREE)';
  
  /// IMPORTANT REMINDER: Developer must replace this with active UPI ID before release
  String getDeveloperUpiId() => '9427698665@paytm';
}

