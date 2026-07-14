import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing WhatsApp anti-bot rolling quota (max 30 sends in 1h10m)
/// and full cooldown locks (1h to 1h10m) across Bills and Receipts.
class CooldownService {
  static const _channel = MethodChannel('com.example.image_sender/cooldown');
  static const _keyCooldownEndTime = 'cooldownEndTime';
  static const _keySentTimestamps = 'sentTimestamps';
  static const int _maxQuota = 30;
  static const int _windowDurationSeconds = 4200; // 1 hour 10 minutes

  SharedPreferences? _prefs;

  Future<void> _init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Returns true if a full cooldown lock is currently active.
  Future<bool> isCooldownActive() async {
    await _init();
    final endTimeMillis = _prefs!.getInt(_keyCooldownEndTime);
    if (endTimeMillis == null) return false;
    final endTime = DateTime.fromMillisecondsSinceEpoch(endTimeMillis);
    if (DateTime.now().isBefore(endTime)) {
      return true;
    } else {
      // Cooldown expired! Clear it.
      await clearCooldown();
      return false;
    }
  }

  /// Returns remaining time until the active cooldown lock expires.
  Future<Duration> getRemainingCooldown() async {
    await _init();
    final endTimeMillis = _prefs!.getInt(_keyCooldownEndTime);
    if (endTimeMillis == null) return Duration.zero;
    final endTime = DateTime.fromMillisecondsSinceEpoch(endTimeMillis);
    final diff = endTime.difference(DateTime.now());
    if (diff.isNegative) {
      await clearCooldown();
      return Duration.zero;
    }
    return diff;
  }

  /// Returns the number of messages sent (out of 30) in the current 1h10m window.
  Future<int> getUsedQuota() async {
    if (await isCooldownActive()) return _maxQuota;
    await _pruneOldTimestamps();
    final timestamps = _getTimestamps();
    return timestamps.length > _maxQuota ? _maxQuota : timestamps.length;
  }

  /// Returns the remaining available quota (out of 30) in the current 1h10m window.
  Future<int> getRemainingQuota() async {
    if (await isCooldownActive()) return 0;
    await _pruneOldTimestamps();
    final timestamps = _getTimestamps();
    final remaining = _maxQuota - timestamps.length;
    return remaining < 0 ? 0 : remaining;
  }

  /// Records a successfully sent message timestamp.
  /// If total count in window hits 30, automatically triggers a full cooldown lock.
  Future<void> recordMessageSent() async {
    await _init();
    await _pruneOldTimestamps();
    final timestamps = _getTimestamps();
    timestamps.add(DateTime.now().millisecondsSinceEpoch);
    await _saveTimestamps(timestamps);

    if (timestamps.length >= _maxQuota) {
      await startCooldown();
    }
  }

  /// Triggers a full cooldown lock for a randomized jitter of 1h to 1h10m (3600 to 4200s).
  /// Also schedules an Android system notification for when the cooldown expires.
  Future<void> startCooldown({int? testDurationSeconds}) async {
    await _init();
    // Jitter: 3600 to 4200 seconds (1 hour to 1 hour 10 minutes)
    final durationSeconds = testDurationSeconds ?? (3600 + Random().nextInt(601));
    final endTime = DateTime.now().add(Duration(seconds: durationSeconds));
    await _prefs!.setInt(_keyCooldownEndTime, endTime.millisecondsSinceEpoch);

    // Schedule Android background notification
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      await _channel.invokeMethod('scheduleNotification', {
        'seconds': durationSeconds,
      });
    } on PlatformException catch (e) {
      // Ignore if platform channel fails or on non-Android
      // ignore: avoid_print
      print('Failed to schedule cooldown notification: $e');
    }
  }

  /// Clears the cooldown lock.
  Future<void> clearCooldown() async {
    await _init();
    await _prefs!.remove(_keyCooldownEndTime);
    try {
      await _channel.invokeMethod('cancelNotification');
    } on PlatformException {
      // Ignore
    }
  }

  /// Removes any sent timestamp older than 1 hour 10 minutes (4200 seconds).
  Future<void> _pruneOldTimestamps() async {
    await _init();
    final timestamps = _getTimestamps();
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final cutoffMillis = nowMillis - (_windowDurationSeconds * 1000);
    timestamps.removeWhere((ts) => ts < cutoffMillis);
    await _saveTimestamps(timestamps);
  }

  List<int> _getTimestamps() {
    final list = _prefs!.getStringList(_keySentTimestamps) ?? [];
    return list.map((s) => int.tryParse(s) ?? 0).where((ts) => ts > 0).toList();
  }

  Future<void> _saveTimestamps(List<int> timestamps) async {
    await _prefs!.setStringList(
      _keySentTimestamps,
      timestamps.map((ts) => ts.toString()).toList(),
    );
  }

  /// Formats a Duration into a human-readable string (e.g. "1h 05m 12s" or "45m 10s" or "12s").
  static String formatDuration(Duration duration) {
    if (duration.isNegative || duration == Duration.zero) return '0s';
    int hours = duration.inHours;
    int minutes = duration.inMinutes.remainder(60);
    int seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Generates a randomized inter-message jitter delay between 5 and 10 seconds (in milliseconds).
  static int getJitterDelayMilliseconds() {
    return 5000 + Random().nextInt(5001); // 5000 to 10000 ms
  }
}
