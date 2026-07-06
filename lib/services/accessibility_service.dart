import 'dart:async';
import 'package:flutter/services.dart';

/// Service for managing the Android Accessibility Service
/// that auto-presses Send in WhatsApp.
class AccessibilityService {
  static const _channel = MethodChannel('com.example.image_sender/accessibility');

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
}
