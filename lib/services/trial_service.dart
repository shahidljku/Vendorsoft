// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'clock_guard_service.dart';
import 'license_service.dart';

class TrialService {
  static final TrialService _instance = TrialService._internal();
  factory TrialService() => _instance;
  TrialService._internal();

  static const String _storageKey = 'trial_first_boot_millis';
  static const String _prefsKey = 'trial_first_boot_millis_prefs';
  static const String _salt = 'vend_soft_offline_trial_anchor_v4';
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final ClockGuardService _clockGuard = ClockGuardService();

  int? _firstBootMillis;
  bool _isTrialActive = false;
  int _daysRemaining = 0;
  bool _isClockDiscrepancy = false;

  bool get isTrialActive => _isTrialActive;
  int get daysRemaining => _daysRemaining;
  bool get isClockDiscrepancy => _isClockDiscrepancy;
  int? get firstBootMillis => _firstBootMillis;

  /// Check and initialize offline first-install trial status.
  /// Never checks or validates paid RSA licenses.
  Future<bool> checkTrialState() async {
    _isClockDiscrepancy = false;
    _isTrialActive = false;
    _daysRemaining = 0;

    // 1. Verify system clock integrity using independent ClockGuardService
    final bool clockOk = await _clockGuard.checkClockIntegrity();
    if (!clockOk) {
      _isClockDiscrepancy = true;
      _isTrialActive = false;
      return false;
    }

    final int nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;

    // 2. Load stored trial start timestamp
    int? startMillis = await _loadFirstBootMillis();

    // 3. If no timestamp found anywhere, initialize new first-install trial anchor
    if (startMillis == null || startMillis <= 0) {
      startMillis = nowUtc;
      await _saveFirstBootMillis(startMillis);
    }

    _firstBootMillis = startMillis;

    // 4. Calculate elapsed duration in UTC epoch milliseconds
    final int elapsedMillis = nowUtc - startMillis;

    if (elapsedMillis < -300000) {
      // Clock is set earlier than first boot date
      _isClockDiscrepancy = true;
      _isTrialActive = false;
      return false;
    }

    const int thirtyDaysMillis = 30 * 24 * 60 * 60 * 1000; // (2,592,000,000 ms)
    if (elapsedMillis <= thirtyDaysMillis) {
      _isTrialActive = true;
      final int elapsedDays = (elapsedMillis / (24 * 60 * 60 * 1000)).floor();
      _daysRemaining = (30 - elapsedDays).clamp(0, 30);
      return true;
    } else {
      _isTrialActive = false;
      _daysRemaining = 0;
      return false;
    }
  }

  Future<int?> _loadFirstBootMillis() async {
    int? earliestTimestamp;

    // A. Read Secure Storage
    try {
      final String? secValStr = await _secureStorage.read(key: _storageKey);
      if (secValStr != null) {
        final int? secVal = int.tryParse(secValStr);
        if (secVal != null && secVal > 0) {
          earliestTimestamp = secVal;
        }
      }
    } catch (e) {
      print('TrialService: SecureStorage read warning: $e');
    }

    // B. Read SharedPreferences
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int? prefsVal = prefs.getInt(_prefsKey);
      if (prefsVal != null && prefsVal > 0) {
        if (earliestTimestamp == null || prefsVal < earliestTimestamp) {
          earliestTimestamp = prefsVal;
        }
      }
    } catch (e) {
      print('TrialService: SharedPreferences read warning: $e');
    }

    // C. Read External File Anchor (/storage/emulated/0/VendSoft/.sys_meta/.app_t)
    try {
      final File externalFile = File('/storage/emulated/0/VendSoft/.sys_meta/.app_t');
      if (externalFile.existsSync()) {
        final List<String> lines = externalFile.readAsLinesSync();
        if (lines.length >= 2) {
          final int? fileVal = int.tryParse(lines[0].trim());
          final String signature = lines[1].trim();

          if (fileVal != null && fileVal > 0) {
            final String deviceId = await LicenseService().getDeviceId();
            final String expectedSig = _generateSignature(fileVal, deviceId);

            if (signature == expectedSig) {
              if (earliestTimestamp == null || fileVal < earliestTimestamp) {
                earliestTimestamp = fileVal;
              }
            } else {
              print('TrialService: External file signature mismatch (likely device copy)');
            }
          }
        }
      }
    } catch (e) {
      // External storage might not be accessible yet
    }

    return earliestTimestamp;
  }

  Future<void> _saveFirstBootMillis(int startMillis) async {
    // A. Write Secure Storage
    try {
      await _secureStorage.write(key: _storageKey, value: startMillis.toString());
    } catch (e) {
      print('TrialService: SecureStorage write warning: $e');
    }

    // B. Write SharedPreferences
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKey, startMillis);
    } catch (e) {
      print('TrialService: SharedPreferences write warning: $e');
    }

    // C. Write External File Anchor
    try {
      final Directory metaDir = Directory('/storage/emulated/0/VendSoft/.sys_meta');
      if (!metaDir.existsSync()) {
        metaDir.createSync(recursive: true);
      }
      final File externalFile = File('${metaDir.path}/.app_t');
      final String deviceId = await LicenseService().getDeviceId();
      final String signature = _generateSignature(startMillis, deviceId);
      externalFile.writeAsStringSync('$startMillis\n$signature');
    } catch (e) {
      // Ignore external write failure if permission not granted yet
    }
  }

  String _generateSignature(int timestampMillis, String deviceId) {
    final bytes = utf8.encode('$timestampMillis:$deviceId:$_salt');
    return sha256.convert(bytes).toString();
  }
}
