import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing WhatsApp anti-bot rolling quota and cooldown locks.
///
/// Designed to make sending patterns indistinguishable from a human vendor
/// manually sending bills to customers one at a time.
///
/// Batch: 15 messages per window → 25–40 min cooldown → repeat.
/// Inter-message: 18–35s (with occasional extra pauses) to simulate human pace.
/// Daily throughput: ~200–280 messages/day (enough for 500–700 over 2–3 days).
class CooldownService {
  static const _channel = MethodChannel('com.example.image_sender/cooldown');
  static const _keyCooldownEndTime = 'cooldownEndTime';
  static const _keySentTimestamps = 'sentTimestamps';

  /// Max messages per batch before cooldown triggers.
  /// 15 is conservative enough to avoid WhatsApp's burst detection,
  /// while still being practical for month-end billing.
  static const int _maxQuota = 15;

  /// Rolling window duration (seconds). Timestamps older than this are pruned.
  /// Set to 40 minutes (2400s) to match the max cooldown duration.
  static const int _windowDurationSeconds = 2400;

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

  /// Returns the number of messages sent (out of 15) in the current window.
  Future<int> getUsedQuota() async {
    if (await isCooldownActive()) return _maxQuota;
    await _pruneOldTimestamps();
    final timestamps = _getTimestamps();
    return timestamps.length > _maxQuota ? _maxQuota : timestamps.length;
  }

  /// Returns the remaining available quota (out of 15) in the current window.
  Future<int> getRemainingQuota() async {
    if (await isCooldownActive()) return 0;
    await _pruneOldTimestamps();
    final timestamps = _getTimestamps();
    final remaining = _maxQuota - timestamps.length;
    return remaining < 0 ? 0 : remaining;
  }

  /// Records a successfully sent message timestamp.
  /// If total count in window hits 15, automatically triggers a full cooldown lock.
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

  /// Triggers a full cooldown lock for a randomized duration of 25–40 minutes.
  /// Shorter cooldowns (vs old 1h+) compensate for the smaller batch size,
  /// maintaining similar throughput while spreading messages more evenly over time.
  Future<void> startCooldown({int? testDurationSeconds}) async {
    await _init();
    // Jitter: 1500 to 2400 seconds (25 to 40 minutes)
    final durationSeconds = testDurationSeconds ?? (1500 + Random().nextInt(901));
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

  /// Removes any sent timestamp older than the rolling window.
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

  /// Generates a humanized inter-message delay (in milliseconds).
  ///
  /// Base delay: 18–33 seconds (simulates human opening WhatsApp, previewing, sending, switching back).
  /// Spike delay: 15% chance of an additional 5–15 second pause (simulates human briefly
  /// checking a notification, scrolling back, or adjusting something between sends).
  ///
  /// Average: ~25 seconds. Range: 18–48 seconds.
  /// This pacing makes 15 messages take ~6–8 minutes, which matches a real person's speed.
  static int getJitterDelayMilliseconds() {
    final rng = Random();
    int base = 18000 + rng.nextInt(15001); // 18,000–33,000 ms (18–33 seconds)
    // 15% chance of an additional "human distraction" pause
    int spike = rng.nextDouble() < 0.15 ? (5000 + rng.nextInt(10001)) : 0; // 0 or 5,000–15,000 ms
    return base + spike;
  }
}

