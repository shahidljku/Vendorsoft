import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Service for managing the Android Accessibility Service
/// that auto-presses Send in WhatsApp.
class AccessibilityService {
  static const _channel = MethodChannel('com.example.image_sender/accessibility');

  /// Tracks active sending mode across the app: 'bill', 'receipt', or 'none'.
  /// Ensures Bill sending and Receipt sending never cross-talk.
  static String activeSendingMode = 'none';

  static final _messageSentController = StreamController<bool>.broadcast();
  static Stream<bool> get onMessageSent => _messageSentController.stream;

  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'messageSent') {
        _messageSentController.add(true);
      }
    });
  }

  /// Checks if the Image Sender accessibility service is enabled.
  static Future<bool> isEnabled() async {
    try {
      final result = await _channel.invokeMethod('isEnabled');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Android's Accessibility Settings page so the user can enable the service.
  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod('openSettings');
    } on PlatformException {
      // Silently fail
    }
  }

  /// Opens Android's App Info page so the user can Allow Restricted Settings on Android 13+.
  static Future<void> openAppInfo() async {
    try {
      await _channel.invokeMethod('openAppInfo');
    } on PlatformException {
      // Silently fail
    }
  }

  /// Enables or disables auto-send mode.
  /// When enabled, the accessibility service will auto-press Send in WhatsApp.
  static Future<void> setAutoSendMode(bool enabled) async {
    try {
      await _channel.invokeMethod('setAutoSendMode', {
        'enabled': enabled,
      });
    } on PlatformException {
      // Silently fail
    }
  }

  /// Shows a guidance dialog explaining how to enable Accessibility,
  /// including instructions for Android 13+ Restricted Settings.
  static Future<void> showGuidanceDialog(BuildContext context) async {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.accessibility_new, color: Colors.indigo),
            SizedBox(width: 8),
            Expanded(child: Text('Enable Auto-Send', style: TextStyle(fontWeight: FontWeight.bold))),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'To automatically send messages without clicking Send every time, enable Accessibility Service:',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              const Text('1. Tap "Open Accessibility" below.', style: TextStyle(fontWeight: FontWeight.w600)),
              const Text('2. Find "Vendor Soft" and turn it ON.', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('⚠️ Android 13+ / Samsung One UI Notice', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF664D03))),
                    SizedBox(height: 6),
                    Text(
                      'If Vendor Soft says "Restricted setting" when toggled ON:\n\n'
                      '1. Tap OK on the "Restricted setting" popup first (mandatory to unlock hidden menu).\n'
                      '2. Tap "Open App Info" below (or go to Settings -> Apps -> Vendor Soft).\n'
                      '3. Tap the 3 dots (⋮) at the top right of App Info and select "Allow restricted settings".\n'
                      '   *(Note: On some Samsung devices, tap "Permissions" inside App Info first, then tap the 3 dots at top right!)*\n'
                      '4. Come back and Open Accessibility again—it will now turn ON easily!',
                      style: TextStyle(fontSize: 12.5, color: Color(0xFF664D03), height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          OutlinedButton.icon(
            onPressed: () {
              openAppInfo();
            },
            icon: const Icon(Icons.info_outline, size: 18),
            label: const Text('Open App Info'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              openSettings();
              Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.settings_accessibility, size: 18),
            label: const Text('Open Accessibility'),
          ),
        ],
      ),
    );
  }
}
