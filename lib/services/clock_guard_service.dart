// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ClockGuardService {
  static final ClockGuardService _instance = ClockGuardService._internal();
  factory ClockGuardService() => _instance;
  ClockGuardService._internal();

  static const String _storageKey = 'clock_guard_last_verified';
  static const String _prefsKey = 'clock_guard_last_verified_prefs';
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  int? _lastVerifiedTimestampMillis;
  bool _isClockTrustworthy = true;
  bool _isRollbackDetected = false;
  bool _isForwardJumpDetected = false;
  bool _isRtcResetDetected = false;

  bool get isClockTrustworthy => _isClockTrustworthy;
  bool get isRollbackDetected => _isRollbackDetected;
  bool get isForwardJumpDetected => _isForwardJumpDetected;
  bool get isRtcResetDetected => _isRtcResetDetected;
  int? get lastVerifiedTimestamp => _lastVerifiedTimestampMillis;

  /// Check clock integrity across secure storage, shared preferences, and external directory anchor.
  Future<bool> checkClockIntegrity() async {
    _isRollbackDetected = false;
    _isForwardJumpDetected = false;
    _isRtcResetDetected = false;
    _isClockTrustworthy = true;

    final int nowUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    final int nowYear = DateTime.now().toUtc().year;

    // 1. Check RTC Reset (battery died, clock reset to 1970 or early epoch < 2024)
    if (nowYear < 2024 || nowUtc < 1704067200000) {
      _isRtcResetDetected = true;
      _isClockTrustworthy = false;
      return false;
    }

    // 2. Check Suspicious Forward Jump (clock set to far future > 2035)
    if (nowYear > 2035) {
      _isForwardJumpDetected = true;
      _isClockTrustworthy = false;
      return false;
    }

    // 3. Load max last_verified from all available storage layers
    int maxKnownMillis = await _loadMaxKnownTimestamp();

    if (maxKnownMillis > 0) {
      // Check Clock Rollback (allowing 5 minutes / 300,000 ms tolerance for minor NTP drift)
      if (nowUtc < (maxKnownMillis - 300000)) {
        _isRollbackDetected = true;
        _isClockTrustworthy = false;
        return false;
      }
    }

    // If all checks pass, time is trustworthy. Update monotonic high-water mark.
    _isClockTrustworthy = true;
    _lastVerifiedTimestampMillis = max(maxKnownMillis, nowUtc);
    await _saveVerifiedTimestamp(_lastVerifiedTimestampMillis!);

    return true;
  }

  Future<int> _loadMaxKnownTimestamp() async {
    int maxVal = _lastVerifiedTimestampMillis ?? 0;

    // A. Read Secure Storage
    try {
      final String? secValStr = await _secureStorage.read(key: _storageKey);
      if (secValStr != null) {
        final int? secVal = int.tryParse(secValStr);
        if (secVal != null && secVal > maxVal) {
          maxVal = secVal;
        }
      }
    } catch (e) {
      print('ClockGuardService: SecureStorage read warning: $e');
    }

    // B. Read SharedPreferences
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int? prefsVal = prefs.getInt(_prefsKey);
      if (prefsVal != null && prefsVal > maxVal) {
        maxVal = prefsVal;
      }
    } catch (e) {
      print('ClockGuardService: SharedPreferences read warning: $e');
    }

    // C. Read External File Anchor (/storage/emulated/0/VendSoft/.sys_meta/.cg_t)
    try {
      final File externalFile = File('/storage/emulated/0/VendSoft/.sys_meta/.cg_t');
      if (externalFile.existsSync()) {
        final String fileContent = externalFile.readAsStringSync().trim();
        final int? fileVal = int.tryParse(fileContent);
        if (fileVal != null && fileVal > maxVal) {
          maxVal = fileVal;
        }
        // Also check file modification time as an extra timestamp anchor
        final int modTime = externalFile.lastModifiedSync().toUtc().millisecondsSinceEpoch;
        if (modTime > maxVal) {
          maxVal = modTime;
        }
      }
    } catch (e) {
      // External storage might not be permitted yet or missing directory
    }

    return maxVal;
  }

  Future<void> _saveVerifiedTimestamp(int timestampMillis) async {
    // A. Write Secure Storage
    try {
      await _secureStorage.write(key: _storageKey, value: timestampMillis.toString());
    } catch (e) {
      print('ClockGuardService: SecureStorage write warning: $e');
    }

    // B. Write SharedPreferences
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKey, timestampMillis);
    } catch (e) {
      print('ClockGuardService: SharedPreferences write warning: $e');
    }

    // C. Write External File Anchor
    try {
      final Directory metaDir = Directory('/storage/emulated/0/VendSoft/.sys_meta');
      if (!metaDir.existsSync()) {
        metaDir.createSync(recursive: true);
      }
      final File externalFile = File('${metaDir.path}/.cg_t');
      externalFile.writeAsStringSync(timestampMillis.toString());
    } catch (e) {
      // Ignore external write failures (e.g. if storage permission not granted yet)
    }
  }
}
