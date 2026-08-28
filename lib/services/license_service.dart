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
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:image_sender/services/transfer_service.dart';
import 'clock_guard_service.dart';
import 'hardware_fingerprint_service.dart';
import 'config_service.dart';

enum TokenValidationResult {
  valid,
  offlineExpired,
  clockRollback,
  invalidSignature,
  serverRevoked,
  expired
}

class LicenseService {
  static final LicenseService _instance = LicenseService._internal();
  factory LicenseService() => _instance;
  LicenseService._internal();

  static const String _licenseKeyPref = 'offline_license_key';
  static const String _signedLeaseTokenPref = 'signed_lease_token';
  static const String _lastSyncPref = 'last_successful_sync';
  static const String _customBusinessNamePref = 'custom_business_name';
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
  String? _customBusinessName;
  bool _skipReminderThisSession = false;

  final StreamController<String?> _revocationController = StreamController<String?>.broadcast();
  Stream<String?> get onLicenseRevoked => _revocationController.stream;

  void triggerDeviceBan() {
    _revocationController.add('BANNED');
  }

  void triggerLoginReset() {
    _revocationController.add('REVOKED');
  }

  void triggerDeviceSuperseded() {
    _revocationController.add('SUPERSEDED');
  }

  /// Generate a stable, un-spoofable Cryptographic Hardware Signature.
  Future<String> getDeviceId() async {
    if (_deviceIdCache != null) return _deviceIdCache!;
    _deviceIdCache = await HardwareFingerprintService().getFingerprint();
    return _deviceIdCache!;
  }

  /// Get the human-readable device model (e.g. "SM-G998B")
  Future<String> getDeviceModel() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (kIsWeb) {
        return 'Web Browser';
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return androidInfo.model;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.utsname.machine;
      } else if (Platform.isWindows) {
        return 'Windows PC';
      }
    } catch (e) {
      debugPrint('Error getting device model: $e');
    }
    return 'Unknown Device';
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
        _customBusinessName ??= await _storage.read(key: _customBusinessNamePref);
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
  Future<TokenValidationResult> verifySignedLeaseToken(String leaseTokenBase64, {bool saveToStorage = true}) async {
    try {
      final parts = leaseTokenBase64.split('.');
      if (parts.length < 2) return TokenValidationResult.invalidSignature;

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
        return TokenValidationResult.invalidSignature;
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
      final now = DateTime.now().millisecondsSinceEpoch;

      if (expiresAtEpochMs != null && now > expiresAtEpochMs) {
        return TokenValidationResult.expired;
      }

      // Check offline grace period explicitly from the server-signed token (V1 Protocol)
      if (payload['version'] == 1) {
        final offlineValidUntilEpochMs = payload['offlineValidUntilEpochMs'] as int?;
        if (offlineValidUntilEpochMs != null && now > offlineValidUntilEpochMs) {
          // Send explicit event for UI to handle this gracefully
          _revocationController.add('OFFLINE_EXPIRED');
          return TokenValidationResult.offlineExpired;
        }
        
        // Use ClockGuardService merely to detect malicious rollback that bypasses the above check
        final clockTrustworthy = await ClockGuardService().checkClockIntegrity();
        if (!clockTrustworthy) {
           _revocationController.add('OFFLINE_EXPIRED');
           return TokenValidationResult.clockRollback;
        }
      }

      if (saveToStorage) {
        try {
          // Iteration 2.2: explicit reminder reset on renewal & skip on fresh activation
          if (_currentLicenseInfo != null && _currentLicenseInfo!['expiresAtEpochMs'] != null && expiresAtEpochMs != null) {
            final oldExp = _currentLicenseInfo!['expiresAtEpochMs'] as int;
            if (expiresAtEpochMs > oldExp) {
              await _storage.delete(key: 'last_reminder_date');
              _skipReminderThisSession = true;
            }
          } else if (_currentLicenseInfo == null) {
            _skipReminderThisSession = true;
          }

          await _storage.write(key: _signedLeaseTokenPref, value: leaseTokenBase64);
        } catch (e) {
          print('Storage write error for signed lease token: $e');
        }
      }

      _cachedLicenseKey = leaseTokenBase64;
      _cachedIsValid = true;
      _currentLicenseInfo = payload;
      _customBusinessName ??= await _storage.read(key: _customBusinessNamePref);
      return TokenValidationResult.valid;
    } catch (e) {
      print('Signed lease verification failed: $e');
    }
    return TokenValidationResult.invalidSignature;
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
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final resJson = jsonDecode(response.body);
        if (resJson['success'] == true && resJson['data']?['signedLeaseToken'] != null) {
          final newLease = resJson['data']['signedLeaseToken'] as String;
          await verifySignedLeaseToken(newLease, saveToStorage: true);
          return true; // Migration successful if server issued it
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
        final validationResult = await verifySignedLeaseToken(savedLeaseToken, saveToStorage: false);
        
        if (validationResult == TokenValidationResult.valid) {
          // Asynchronously poll the backend to ensure device hasn't been remotely superseded
          pollOnlineSubscriptionStatus();
          return true;
        } else if (validationResult == TokenValidationResult.offlineExpired || validationResult == TokenValidationResult.clockRollback) {
          // Cryptographically valid, but locked due to offline constraints.
          // Keep the token. Return true so the app recognizes the subscription and shows the Offline UI.
          return true;
        } else if (validationResult == TokenValidationResult.expired) {
          // Subscription naturally expired. Keep it so the UI can show the "Expired" screen.
          return true;
        }
        
        // Only delete on Invalid Signature or Server Revoked
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
    
    // Modern signedLeaseToken check (`expiresAtEpochMs` & `offlineValidUntilEpochMs`)
    if (_currentLicenseInfo!.containsKey('expiresAtEpochMs')) {
      final expEpoch = _currentLicenseInfo!['expiresAtEpochMs'] as int?;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (expEpoch != null && now > expEpoch) {
        return true;
      }
      
      // Enforce V1 offline token limits locally
      if (_currentLicenseInfo!['version'] == 1) {
        final offlineValidUntilEpochMs = _currentLicenseInfo!['offlineValidUntilEpochMs'] as int?;
        if (offlineValidUntilEpochMs != null && now > offlineValidUntilEpochMs) {
          return true; // Lock out until they sync
        }
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

  /// Get days remaining on the active subscription
  int getDaysRemaining() {
    if (_currentLicenseInfo == null) return 0;
    
    // Modern signedLeaseToken check (`expiresAtEpochMs`)
    if (_currentLicenseInfo!.containsKey('expiresAtEpochMs')) {
      final expEpoch = _currentLicenseInfo!['expiresAtEpochMs'] as int?;
      if (expEpoch != null) {
        final today = DateTime.now();
        final todayDate = DateTime(today.year, today.month, today.day);
        final expiryDate = DateTime.fromMillisecondsSinceEpoch(expEpoch);
        final expiryDay = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
        final diff = expiryDay.difference(todayDate).inDays;
        return diff > 0 ? diff : 0;
      }
    }

    final customerType = _currentLicenseInfo!['customerType'] as String?;
    if (customerType == 'Lifetime') {
      return 9999;
    }
    
    final expiryDateStr = _currentLicenseInfo!['expiryDate'] as String?;
    if (expiryDateStr != null && expiryDateStr.isNotEmpty) {
      final expiryDate = DateTime.tryParse(expiryDateStr);
      if (expiryDate != null) {
        final today = DateTime.now();
        final todayDate = DateTime(today.year, today.month, today.day);
        final expiryDay = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
        final diff = expiryDay.difference(todayDate).inDays;
        return diff > 0 ? diff : 0;
      }
    }
    
    return 0;
  }

  /// Iteration 2.2: Check if we should show a subscription expiry reminder today
  Future<bool> shouldShowExpiryReminder() async {
    if (_skipReminderThisSession) {
      return false; // Activated or renewed during this session
    }

    final days = getDaysRemaining();
    if (![7, 5, 3, 1, 0].contains(days)) {
      return false; // Only show on these specific thresholds
    }

    try {
      final lastShownStr = await _storage.read(key: 'last_reminder_date');
      final todayStr = DateTime.now().toIso8601String().substring(0, 10); // YYYY-MM-DD
      
      if (lastShownStr == todayStr) {
        return false; // Already shown today
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Iteration 2.2: Mark the reminder as shown for today
  Future<void> markExpiryReminderShown() async {
    try {
      final todayStr = DateTime.now().toIso8601String().substring(0, 10); // YYYY-MM-DD
      await _storage.write(key: 'last_reminder_date', value: todayStr);
    } catch (_) {}
  }

  /// Retrieve the business name (customer name) from the license
  String getBusinessName() {
    if (_customBusinessName != null && _customBusinessName!.trim().isNotEmpty) {
      return _customBusinessName!;
    }
    if (_currentLicenseInfo == null) return 'Your Business Name';
    return _currentLicenseInfo!['customerName'] as String? ?? 'Your Business Name';
  }

  /// Override the business name locally
  Future<void> setCustomBusinessName(String name) async {
    _customBusinessName = name.trim().isEmpty ? null : name.trim();
    if (_customBusinessName == null) {
      await _storage.delete(key: _customBusinessNamePref);
    } else {
      await _storage.write(key: _customBusinessNamePref, value: _customBusinessName);
    }
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

  /// Subscription pricing helpers
  String getMonthlyPlanPrice() => ConfigService().monthlyPlanPrice;
  String getYearlyPlanPrice() => ConfigService().yearlyPlanPrice;
  
  /// IMPORTANT REMINDER: Developer must replace this with active UPI ID before release
  String getDeveloperUpiId() => '9427698665@paytm';

  Timer? _pollingTimer;

  void startBackgroundPolling() {
    _pollingTimer?.cancel();
    pollOnlineSubscriptionStatus(force: false); // Fire immediately on boot
    
    // Check every 5 minutes to ensure instant revocation if the admin forces a transfer
    _pollingTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      pollOnlineSubscriptionStatus(force: false);
    });
  }

  void stopBackgroundPolling() {
    _pollingTimer?.cancel();
  }

  int _lastPollAttemptMs = 0;

  /// Periodically checks the backend to enforce the "One Active Device" rule.
  /// If the server returns 403 INSTALLATION_SUPERSEDED, this device was revoked.
  Future<void> pollOnlineSubscriptionStatus({bool force = false}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Rate limit polls to once every 6 hours unless forced
    if (!force && (nowMs - _lastPollAttemptMs) < 6 * 60 * 60 * 1000) {
      return; 
    }
    _lastPollAttemptMs = nowMs;

    try {
      final hasLic = await isLicensed();
      final hasTrial = await TrialService().checkTrialState();
      if (!hasLic && !hasTrial && !force) {
        return; // Skip polling if no active license or trial locally to avoid 404 infinite loops on fresh installs
      }

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
        'x-platform': kIsWeb ? 'web' : Platform.operatingSystem,
      }).timeout(const Duration(seconds: 5));

      if (response.statusCode == 403) {
        final data = jsonDecode(response.body);
        final errorCode = data['error']?['code'];
        if (errorCode == 'DEVICE_BANNED') {
          print('CRITICAL: Device is banned. Removing license.');
          await removeLicense();
          await FirebaseAuth.instance.signOut();
          _revocationController.add('BANNED');
        } else if (errorCode == 'INSTALLATION_SUPERSEDED' || errorCode == 'CUSTOMER_DEACTIVATED' || errorCode == 'TRIAL_EXPIRED' || errorCode == 'SUBSCRIPTION_EXPIRED' || errorCode == 'SUBSCRIPTION_CANCELLED') {
          try {
            // Check if there is a pending transfer request targeted at this device
            // If so, we delay the forced logout so the user can actually see and approve/reject the transfer.
            final pending = await TransferService().pollPendingTransfers();
            if (pending.isNotEmpty) {
              print('CRITICAL ALERT ($errorCode), but skipping forced logout because a transfer request is pending approval.');
              return;
            }
          } catch (e) {
            print('Error checking pending transfers before logout: $e');
          }

          print('CRITICAL: License invalid ($errorCode). Removing license.');
          await TrialService().killTrial();
          if (errorCode == 'SUBSCRIPTION_EXPIRED' || errorCode == 'SUBSCRIPTION_CANCELLED' || errorCode == 'TRIAL_EXPIRED') {
            await _storage.write(key: 'was_cancelled_on_device', value: 'true');
          }
          await removeLicense();
          
          if (errorCode == 'INSTALLATION_SUPERSEDED') {
            _revocationController.add('SUPERSEDED');
          } else if (errorCode == 'CUSTOMER_DEACTIVATED') {
            _revocationController.add('DEACTIVATED');
          } else {
            _revocationController.add('TRIAL_EXPIRED');
          }
        }
      } else if (response.statusCode == 404 || response.statusCode == 400) {
        print('WARNING: 400/404 from server. This could be a transient network/identity error on resume. Falling back to offline grace period.');
        await _checkOfflineGracePeriod();
      } else if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['data']?['signedLeaseToken'] != null) {
          // Update the locally cached lease token if the backend has a fresher one
          await verifySignedLeaseToken(data['data']['signedLeaseToken'], saveToStorage: true);
          await _storage.write(key: _lastSyncPref, value: DateTime.now().millisecondsSinceEpoch.toString());
          _revocationController.add('RESTORED');
        }
      } else if (response.statusCode >= 500) {
        print('Temporary Server Error (500/503). Retaining cached token.');
        await _checkOfflineGracePeriodFallback();
      } else {
        // Unhandled client error (400, 404), treat as soft failure
        await _checkOfflineGracePeriodFallback();
      }
    } on SocketException catch (e) {
      print('Network offline (SocketException): $e');
      await _checkOfflineGracePeriodFallback();
    } on TimeoutException catch (e) {
      print('Network timeout (TimeoutException): $e');
      await _checkOfflineGracePeriodFallback();
    } catch (e) {
      print('Online subscription status polling failed (unknown): $e');
      await _checkOfflineGracePeriodFallback();
    }
  }

  Future<void> _checkOfflineGracePeriodFallback() async {
    // If using V1, the token itself enforces offline expiry via verifySignedLeaseToken
    // If using Legacy, fallback to the old method
    if (_currentLicenseInfo?['version'] != 1) {
      await _checkOfflineGracePeriod();
    } else {
      // Re-evaluate the token against the current time to trigger OFFLINE_EXPIRED if needed
      final savedLeaseToken = await _storage.read(key: _signedLeaseTokenPref);
      if (savedLeaseToken != null) {
        await verifySignedLeaseToken(savedLeaseToken, saveToStorage: false);
      }
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

