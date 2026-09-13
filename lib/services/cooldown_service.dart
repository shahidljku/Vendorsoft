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
/// Batch: 20–40 messages per window (randomized per cycle) → 25–40 min cooldown → repeat.
/// Inter-message: 8–15s delay to simulate human pace.
class CooldownService {
  static const _channel = MethodChannel('com.example.image_sender/cooldown');
  static const _keyCooldownEndTime = 'cooldownEndTime';
  static const _keySentTimestamps = 'sentTimestamps';
  static const _keyCurrentBatchQuota = 'currentBatchQuota';

  /// Min and max messages per batch before cooldown triggers.
  /// Randomized per cycle (20–40) to avoid detectable patterns.
  static const int _minBatchQuota = 20;
  static const int _maxBatchQuota = 40;

  /// Rolling window duration (seconds). Timestamps older than this are pruned.
  /// Set to 40 minutes (2400s) to match the max cooldown duration.
  static const int _windowDurationSeconds = 2400;

  SharedPreferences? _prefs;

  Future<void> _init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Returns the current batch quota for this cycle.
  /// Generates a random value (20–40) if none is set, and persists it.
  Future<int> getCurrentBatchQuota() async {
    await _init();
    int? quota = _prefs!.getInt(_keyCurrentBatchQuota);
    if (quota == null || quota < _minBatchQuota || quota > _maxBatchQuota) {
      quota = _minBatchQuota + Random().nextInt(_maxBatchQuota - _minBatchQuota + 1);
      await _prefs!.setInt(_keyCurrentBatchQuota, quota);
    }
    return quota;
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

  /// Returns the number of messages sent in the current window.
  Future<int> getUsedQuota() async {
    final maxQuota = await getCurrentBatchQuota();
    if (await isCooldownActive()) return maxQuota;
    await _pruneOldTimestamps();
    final timestamps = _getTimestamps();
    return timestamps.length > maxQuota ? maxQuota : timestamps.length;
  }

  /// Returns the remaining available quota in the current window.
  Future<int> getRemainingQuota() async {
    if (await isCooldownActive()) return 0;
    final maxQuota = await getCurrentBatchQuota();
    await _pruneOldTimestamps();
    final timestamps = _getTimestamps();
    final remaining = maxQuota - timestamps.length;
    return remaining < 0 ? 0 : remaining;
  }

  /// Records a successfully sent message timestamp.
  /// If total count in window hits the batch quota, automatically triggers a full cooldown lock.
  Future<void> recordMessageSent() async {
    await _init();
    await _pruneOldTimestamps();
    final timestamps = _getTimestamps();
    timestamps.add(DateTime.now().millisecondsSinceEpoch);
    await _saveTimestamps(timestamps);

    final maxQuota = await getCurrentBatchQuota();
    if (timestamps.length >= maxQuota) {
      await startCooldown();
    }
  }

  /// Returns the configured cooldown duration in minutes.
  Future<int> getCooldownDurationMinutes() async {
    await _init();
    return _prefs!.getInt('cooldownMinutes') ?? 25;
  }

  /// Sets the cooldown duration in minutes.
  Future<void> setCooldownDurationMinutes(int minutes) async {
    await _init();
    final safeMinutes = minutes < 1 ? 1 : minutes;
    await _prefs!.setInt('cooldownMinutes', safeMinutes);
  }

  /// Triggers a full cooldown lock using the user-configured duration (default: 25 minutes).
  Future<void> startCooldown({int? testDurationSeconds}) async {
    await _init();
    final configuredMinutes = await getCooldownDurationMinutes();
    final durationSeconds = testDurationSeconds ?? (configuredMinutes * 60);
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

  /// Clears the cooldown lock and allows immediate sending.
  Future<void> clearCooldown() async {
    await _init();
    await _prefs!.remove(_keyCooldownEndTime);
    await _prefs!.remove(_keySentTimestamps);
    // Generate a new random batch quota for the next cycle
    final newQuota = _minBatchQuota + Random().nextInt(_maxBatchQuota - _minBatchQuota + 1);
    await _prefs!.setInt(_keyCurrentBatchQuota, newQuota);
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
  /// Delay: 8–15 seconds between each message send.
  static int getJitterDelayMilliseconds() {
    final rng = Random();
    return 8000 + rng.nextInt(7001); // 8,000–15,000 ms (8–15 seconds)
  }
}

