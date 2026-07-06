import 'package:flutter/services.dart';

/// Service for sending images to WhatsApp via native Android intents.
/// Opens WhatsApp directly in the correct chat with the image pre-attached.
class WhatsAppService {
  static const _channel = MethodChannel('com.example.image_sender/whatsapp');

  /// Sends an image to a WhatsApp contact.
  /// Opens WhatsApp with the image attached in the correct chat.
  /// The user only needs to press Send.
  ///
  /// [mobile] — phone number with country code (e.g., "919876543210")
  /// [imagePath] — absolute path to the image file
  /// [useBusinessApp] — if true, opens WhatsApp Business instead
  ///
  /// Returns true if WhatsApp was opened successfully.
  /// Throws if WhatsApp is not installed or image not found.
  static Future<bool> sendImage({
    required String mobile,
    required String imagePath,
    bool useBusinessApp = false,
  }) async {
    try {
      final result = await _channel.invokeMethod('sendImage', {
        'mobile': mobile,
        'imagePath': imagePath,
        'useBusinessApp': useBusinessApp,
      });
      return result == true;
    } on PlatformException catch (e) {
      throw WhatsAppException(e.code, e.message ?? 'Unknown error');
    }
  }

  /// Checks if WhatsApp and/or WhatsApp Business are installed.
  /// Returns a map: {'whatsapp': bool, 'whatsappBusiness': bool}
  static Future<Map<String, bool>> isInstalled() async {
    try {
      final result = await _channel.invokeMethod('isInstalled');
      return {
        'whatsapp': result['whatsapp'] as bool? ?? false,
        'whatsappBusiness': result['whatsappBusiness'] as bool? ?? false,
      };
    } on PlatformException {
      return {'whatsapp': false, 'whatsappBusiness': false};
    }
  }
}

/// Exception thrown when WhatsApp operations fail.
class WhatsAppException implements Exception {
  final String code;
  final String message;

  WhatsAppException(this.code, this.message);

  @override
  String toString() => 'WhatsAppException($code): $message';
}
