import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:android_id/android_id.dart';

/// Service responsible for generating a deterministic, cryptographically hashed
/// hardware fingerprint that survives app reinstalls and data clears.
class HardwareFingerprintService {
  static final HardwareFingerprintService _instance = HardwareFingerprintService._internal();
  factory HardwareFingerprintService() => _instance;
  HardwareFingerprintService._internal();

  final _androidIdPlugin = const AndroidId();
  final _storage = const FlutterSecureStorage();
  String? _fingerprintCache;

  /// Computes and returns the SHA-256 hardware fingerprint.
  Future<String> getFingerprint() async {
    if (_fingerprintCache != null) return _fingerprintCache!;

    String? androidId;
    try {
      androidId = await _androidIdPlugin.getId();
    } catch (e) {
      debugPrint('Warning: Failed to get Android ID: $e');
    }

    if (androidId == null || androidId.isEmpty) {
      androidId = await _storage.read(key: 'fallback_device_id');
      if (androidId == null || androidId.isEmpty) {
        androidId = 'FB_${DateTime.now().millisecondsSinceEpoch}';
        await _storage.write(key: 'fallback_device_id', value: androidId);
      }
    }

    String rawHardwareString = androidId;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        
        // Deep hardware properties that survive resets and cloners
        rawHardwareString = '''
          ${androidId}
          ${androidInfo.board}
          ${androidInfo.brand}
          ${androidInfo.device}
          ${androidInfo.hardware}
          ${androidInfo.manufacturer}
          ${androidInfo.model}
          ${androidInfo.product}
          ${androidInfo.supportedAbis.join(',')}
        ''';
      } catch (e) {
        debugPrint('Warning: Failed to gather deep hardware fingerprint: $e');
      }
    } else if (!kIsWeb && Platform.isIOS) {
      try {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        final IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        rawHardwareString = '''
          ${androidId}
          ${iosInfo.identifierForVendor}
          ${iosInfo.model}
          ${iosInfo.systemName}
          ${iosInfo.systemVersion}
          ${iosInfo.utsname.machine}
        ''';
      } catch (e) {
        debugPrint('Warning: Failed to gather iOS fingerprint: $e');
      }
    } else if (!kIsWeb && Platform.isWindows) {
      try {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        final WindowsDeviceInfo windowsInfo = await deviceInfo.windowsInfo;
        rawHardwareString = '$androidId-${windowsInfo.deviceId}';
      } catch (e) {}
    }

    // Normalize: trim, lowercase, remove all whitespace characters
    final normalizedString = rawHardwareString.toLowerCase().replaceAll(RegExp(r'\s+'), '');

    // Compute SHA-256 Hash
    final bytes = utf8.encode(normalizedString);
    final digest = sha256.convert(bytes);
    
    // Convert to uppercase hex string
    final fingerprint = digest.toString().toUpperCase();

    _fingerprintCache = fingerprint;
    return fingerprint;
  }
}
