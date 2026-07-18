// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:encrypt/encrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:android_id/android_id.dart';
// ignore: depend_on_referenced_packages
import 'package:pointycastle/asymmetric/api.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'trial_service.dart';
import 'dart:io';
import 'dart:async';
import 'package:device_info_plus/device_info_plus.dart';
class LicenseService {
  static final LicenseService _instance = LicenseService._internal();
  factory LicenseService() => _instance;
  LicenseService._internal();

  static const String _licenseKeyPref = 'offline_license_key';
  static const String _signedLeaseTokenPref = 'signed_lease_token';
  static const String _lastSyncPref = 'last_successful_sync';
  final _storage = const FlutterSecureStorage();
  final _androidIdPlugin = const AndroidId();

  // Hardcoded public key corresponding to the developer's private key
  static const String publicKeyString = '''
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAj/ogDRDyPvLs3T68lnzV
5dVp/ZCJ05nyBTZZB7xMt60Moa4SkM7ihfyBxJDruIdcLWOabHdimLDRVvmT5pCg
DAskyVEy+ycR2RaPjzVHgHVBNZRh1b/XMUiBWjt5i2nmzfWboA/q5tklAETe9Psi
iIgjBkUGqedpAVLEOS47DtZbGU1WIN0J8g8RFpDvrChSOFzrcR9HR9gxb1hmzeQ+
0hHJjAJHo/8uD68hNpGmO+IZE8k3CJombBhPvQHipKiDBc/aN358DklyWALyMlY5
X/7xBMv2Qqdx5gQgmWNH6JoCvPSQA4cu1RQa//1iG6fT1K4u1TxZ1T2/t/1VwaRo
JQIDAQAB
-----END PUBLIC KEY-----
''';

  String? _deviceIdCache;
  Map<String, dynamic>? _currentLicenseInfo;
  String? _cachedLicenseKey;
  bool? _cachedIsValid;

  final StreamController<String?> _revocationController = StreamController<String?>.broadcast();
  Stream<String?> get onLicenseRevoked => _revocationController.stream;

  void triggerDeviceBan() {
    _revocationController.add('BANNED');
  }

  /// Generate a stable, un-spoofable Cryptographic Hardware Signature.
  Future<String> getDeviceId() async {
    if (_deviceIdCache != null) return _deviceIdCache!;

    String? androidId = await _androidIdPlugin.getId();
    if (androidId == null || androidId.isEmpty) {
      androidId = 'UNKNOWN_DEVICE';
    }

    String hardwareString = androidId;

    if (Platform.isAndroid) {
      try {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        
        // Combine deep physical hardware properties that survive factory resets and dual-app cloning
        hardwareString = '''
          $androidId
          ${androidInfo.board}
          ${androidInfo.brand}
          ${androidInfo.device}
          ${androidInfo.hardware}
          ${androidInfo.id}
          ${androidInfo.manufacturer}
          ${androidInfo.model}
          ${androidInfo.product}
        ''';
      } catch (e) {
        print('Warning: Failed to gather deep hardware fingerprint: $e');
      }
    } else if (Platform.isWindows) {
      try {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        final WindowsDeviceInfo windowsInfo = await deviceInfo.windowsInfo;
        hardwareString = '$androidId-${windowsInfo.deviceId}';
      } catch (e) {}
    }

    // Hash the composite physical hardware string
    final bytes = utf8.encode(hardwareString);
    final digest = sha256.convert(bytes);
    // Keep it short and readable but cryptographically tied to the hardware
    final shortId = digest.toString().substring(0, 16).toUpperCase();

    _deviceIdCache = shortId;
    return shortId;
  }

  /// Verifies a license key (base64 encoded JSON containing payload and signature)
  Future<bool> verifyLicenseKey(String licenseKeyBase64, {bool saveToStorage = true}) async {
    try {
      final decodedBytes = base64Decode(licenseKeyBase64);
      final jsonStr = utf8.decode(decodedBytes);
      final licenseObj = jsonDecode(jsonStr);

      final payloadStr = licenseObj['payload'];
      final signatureBase64 = licenseObj['signature'];

      final payload = jsonDecode(payloadStr);
      final licensedDeviceId = payload['deviceId'];

      final currentDeviceId = await getDeviceId();
      if (licensedDeviceId != currentDeviceId) {
        return false;
      }

      final parser = RSAKeyParser();
      final publicKey = parser.parse(publicKeyString) as RSAPublicKey;
      
      final signer = Signer(RSASigner(RSASignDigest.SHA256, publicKey: publicKey));
      final isValid = signer.verify(payloadStr, Encrypted.fromBase64(signatureBase64));

      if (isValid) {
        if (saveToStorage) {
          try {
            await _storage.write(key: _licenseKeyPref, value: licenseKeyBase64);
          } catch (e) {
            print('Storage write error: $e');
          }
        }
        _cachedLicenseKey = licenseKeyBase64;
        _cachedIsValid = true;
        _currentLicenseInfo = payload;
        return true;
      }
    } catch (e) {
      print('License verification failed: $e');
    }
    return false;
  }

  Future<bool> verifyAndSaveLicense(String licenseKeyBase64) async {
    return verifyLicenseKey(licenseKeyBase64, saveToStorage: true);
  }

  /// Verifies and stores a modern Base64url signedLeaseToken (`Phase 2.1 & 2.2`)
  Future<bool> verifySignedLeaseToken(String leaseTokenBase64, {bool saveToStorage = true}) async {
    try {
      final parts = leaseTokenBase64.split('.');
      if (parts.length < 2) return false;

      // Cryptographically verify the signature first using the authoritative Public Key
      String base64Signature = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (base64Signature.length % 4 != 0) {
        base64Signature += '=';
      }

      final parser = RSAKeyParser();
      final publicKey = parser.parse(publicKeyString) as RSAPublicKey;
      final signer = Signer(RSASigner(RSASignDigest.SHA256, publicKey: publicKey));
      
      // We verify the raw base64url payload string (parts[0]) against the decoded signature
      final isValidSignature = signer.verify(parts[0], Encrypted.fromBase64(base64Signature));

      if (!isValidSignature) {
        print('CRITICAL SECURITY ALERT: signedLeaseToken cryptographic verification failed! Possible forgery attempt.');
        return false;
      }

      // If signature is mathematically proven, decode payload and check expiration
      String base64Payload = parts[0].replaceAll('-', '+').replaceAll('_', '/');
      while (base64Payload.length % 4 != 0) {
        base64Payload += '=';
      }
      final decodedBytes = base64Decode(base64Payload);
      final jsonStr = utf8.decode(decodedBytes);
      final payload = jsonDecode(jsonStr);

      final expiresAtEpochMs = payload['expiresAtEpochMs'] as int?;
      if (expiresAtEpochMs != null && DateTime.now().millisecondsSinceEpoch > expiresAtEpochMs) {
        return false;
      }

      if (saveToStorage) {
        try {
          await _storage.write(key: _signedLeaseTokenPref, value: leaseTokenBase64);
        } catch (e) {
          print('Storage write error for signed lease token: $e');
        }
      }

      _cachedLicenseKey = leaseTokenBase64;
      _cachedIsValid = true;
      _currentLicenseInfo = payload;
      return true;
    } catch (e) {
      print('Signed lease verification failed: $e');
    }
    return false;
  }

  /// Helper to retrieve stored offline RSA license key for migration or inspection
  Future<String?> getSavedLegacyKey() async {
    try {
      return await _storage.read(key: _licenseKeyPref);
    } catch (e) {
      print('SecureStorage read error for legacy key: $e');
      return null;
    }
  }

  /// Phase 5 Grace Support: Automatically migrates a valid historical RSA offline_license_key
  /// into a modern Cloudflare composite device lease (`POST /v1/migrate/legacy-key`).
  Future<bool> migrateLegacyLicenseToServer(String idToken, {String baseUrl = 'https://vendsoft-api-worker.vendorproapk.workers.dev/v1'}) async {
    try {
      final savedKey = await getSavedLegacyKey();
      if (savedKey == null || savedKey.isEmpty) return false;

      // Ensure key is locally valid before querying server
      final isLocallyValid = await verifyLicenseKey(savedKey, saveToStorage: false);
      if (!isLocallyValid) return false;

      final deviceId = await getDeviceId();
      final url = Uri.parse('$baseUrl/migrate/legacy-key');
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
          'x-hardware-id': deviceId,
          'x-installation-uuid': deviceId,
          'x-platform': 'android',
          'x-app-version': '1.0.0',
        },
        body: jsonEncode({'legacyLicenseKey': savedKey}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final resJson = jsonDecode(response.body);
        if (resJson['success'] == true && resJson['data']?['signedLeaseToken'] != null) {
          final newLease = resJson['data']['signedLeaseToken'] as String;
          await verifySignedLeaseToken(newLease, saveToStorage: true);
          return true;
        }
      }
    } catch (e) {
      print('Legacy license server migration attempt failed (offline or network issue): $e');
    }
    return false;
  }

  /// Check if the app is currently licensed on this device
  Future<bool> isLicensed() async {
    if (_cachedIsValid != null && _cachedIsValid == true && _cachedLicenseKey != null) {
      return true;
    }

    // 1. First check modern signedLeaseToken (`Phase 2.1 & 2.2`)
    try {
      final savedLeaseToken = await _storage.read(key: _signedLeaseTokenPref);
      if (savedLeaseToken != null && savedLeaseToken.isNotEmpty) {
        final isValidLease = await verifySignedLeaseToken(savedLeaseToken, saveToStorage: false);
        if (isValidLease) {
          // Asynchronously poll the backend to ensure device hasn't been remotely superseded
          pollOnlineSubscriptionStatus();
          return true;
        }
        await _storage.delete(key: _signedLeaseTokenPref);
      }
    } catch (e) {
      print('SecureStorage read error for signed_lease_token: $e');
    }

    // 2. Fall back to checking legacy RSA offline_license_key (`Backward Compatibility`)
    String? savedKey;
    try {
      savedKey = await _storage.read(key: _licenseKeyPref);
    } catch (e) {
      print('SecureStorage read error (BAD_DECRYPT handled): $e');
      try {
        await _storage.deleteAll();
      } catch (_) {}
      _cachedIsValid = false;
      _cachedLicenseKey = null;
      _currentLicenseInfo = null;
      return false;
    }

    if (savedKey == null) {
      _cachedIsValid = false;
      return false;
    }

    final isValid = await verifyLicenseKey(savedKey, saveToStorage: false);
    if (!isValid) {
      await removeLicense();
    }
    return isValid;
  }
  
  /// Check if the current license is expired
  bool isLicenseExpired() {
    if (_currentLicenseInfo == null) return true;
    
    // Modern signedLeaseToken check (`expiresAtEpochMs`)
    if (_currentLicenseInfo!.containsKey('expiresAtEpochMs')) {
      final expEpoch = _currentLicenseInfo!['expiresAtEpochMs'] as int?;
      if (expEpoch != null) {
        return DateTime.now().millisecondsSinceEpoch > expEpoch;
      }
    }

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
        final expiryDay = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
        return todayDate.isAfter(expiryDay);
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
    try {
      await _storage.delete(key: _licenseKeyPref);
      await _storage.delete(key: _signedLeaseTokenPref);
    } catch (_) {
      try {
        await _storage.deleteAll();
      } catch (_) {}
    }
    _currentLicenseInfo = null;
    _cachedLicenseKey = null;
    _cachedIsValid = false;
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

  Timer? _pollingTimer;

  void startBackgroundPolling() {
    _pollingTimer?.cancel();
    pollOnlineSubscriptionStatus(); // Fire immediately on boot
    _pollingTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      pollOnlineSubscriptionStatus();
    });
  }

  void stopBackgroundPolling() {
    _pollingTimer?.cancel();
  }

  /// Periodically checks the backend to enforce the "One Active Device" rule.
  /// If the server returns 403 INSTALLATION_SUPERSEDED, this device was revoked.
  Future<void> pollOnlineSubscriptionStatus() async {
    try {
      User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        try {
          final userCred = await FirebaseAuth.instance.signInAnonymously();
          user = userCred.user;
        } catch (e) {
          print('Failed to sign in anonymously for polling: $e');
        }
      }
      
      final token = user != null ? await user.getIdToken() : '';
      if (token == null || token.isEmpty) {
        print('Skipping polling: no firebase auth token available.');
        return;
      }

      final deviceId = await getDeviceId();
      final url = Uri.parse('https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1/subscriptions/status');
      
      final response = await http.get(url, headers: {
        'Authorization': 'Bearer $token',
        'x-installation-uuid': deviceId,
        'x-installation-id': deviceId,
        'x-hardware-id': deviceId,
        'x-app-version': '1.0.0',
        'x-platform': Platform.operatingSystem,
      });

      if (response.statusCode == 403) {
        final data = jsonDecode(response.body);
        final errorCode = data['error']?['code'];
        if (errorCode == 'DEVICE_BANNED') {
          print('CRITICAL: Device is banned. Removing license.');
          await removeLicense();
          await FirebaseAuth.instance.signOut();
          _revocationController.add('BANNED');
        } else if (errorCode == 'INSTALLATION_SUPERSEDED') {
          print('CRITICAL: This installation was superseded. Removing license.');
          await TrialService().killTrial();
          await removeLicense();
          _revocationController.add('SUPERSEDED');
        } else if (errorCode == 'CUSTOMER_DEACTIVATED') {
          print('CRITICAL: Customer deactivated by admin. Signing out.');
          await TrialService().killTrial();
          await removeLicense();
          await FirebaseAuth.instance.signOut();
          _revocationController.add('DEACTIVATED');
        }
      } else if (response.statusCode == 404 || response.statusCode == 400) {
        print('CRITICAL: Account or subscription not found on server. Removing license.');
        await TrialService().killTrial();
        await removeLicense();
        await FirebaseAuth.instance.signOut();
        _revocationController.add('REVOKED');
      } else if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['data']?['signedLeaseToken'] != null) {
          // Update the locally cached lease token if the backend has a fresher one
          await verifySignedLeaseToken(data['data']['signedLeaseToken'], saveToStorage: true);
          await _storage.write(key: _lastSyncPref, value: DateTime.now().millisecondsSinceEpoch.toString());
          _revocationController.add('RESTORED');
        }
      } else {
        // Unhandled server error (500, etc), treat as network issue and use grace period
        await _checkOfflineGracePeriod();
      }
    } catch (e) {
      print('Online subscription status polling failed (offline?): $e');
      await _checkOfflineGracePeriod();
    }
  }

  Future<void> _checkOfflineGracePeriod() async {
    try {
      final syncStr = await _storage.read(key: _lastSyncPref);
      if (syncStr != null && syncStr.isNotEmpty) {
        final lastSync = int.tryParse(syncStr);
        if (lastSync != null) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final elapsed = now - lastSync;
          final gracePeriod = 24 * 60 * 60 * 1000; // 24 hours
          if (elapsed > gracePeriod) {
            print('CRITICAL: Offline grace period exceeded.');
            _revocationController.add('OFFLINE_LOCKED');
          }
        }
      } else if (_cachedIsValid == true) {
        // If we've never synced but we have a license, start the timer now
        await _storage.write(key: _lastSyncPref, value: DateTime.now().millisecondsSinceEpoch.toString());
      }
    } catch (_) {}
  }
}

