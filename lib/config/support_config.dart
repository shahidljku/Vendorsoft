import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SupportConfig {
  // Distributor helpline contact numbers (configure before release)
  static const String supportWhatsAppNumber = '';
  static const String supportPhoneNumber = '';
  static const String supportEmail = 'support@vendorsoft.com';

  static Future<void> openWhatsAppSupport(BuildContext context, String deviceId, {String? customSubject, bool useBusinessApp = false}) async {
    if (supportWhatsAppNumber.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Support contact has not been configured.')),
        );
      }
      return;
    }

    final String subject = customSubject ?? 'Hello VendorSoft Support,\n\nI need assistance with my newspaper vendor setup.\nDevice ID: $deviceId';
    try {
      await const MethodChannel('com.example.image_sender/whatsapp').invokeMethod('sendMessage', {
        'mobile': supportWhatsAppNumber,
        'message': subject,
        'useBusinessApp': useBusinessApp,
      });
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open WhatsApp. Please contact: $supportWhatsAppNumber')),
        );
      }
    }
  }

  static Future<void> openPhoneSupport(BuildContext context) async {
    if (supportPhoneNumber.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Support contact has not been configured.')),
        );
      }
      return;
    }

    try {
      await const MethodChannel('com.example.image_sender/file_access').invokeMethod('openDialer', {
        'phone': supportPhoneNumber,
      });
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open Phone Dialer. Please call: $supportPhoneNumber')),
        );
      }
    }
  }

  static void copyDeviceIdToClipboard(BuildContext context, String deviceId) {
    Clipboard.setData(ClipboardData(text: deviceId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Device ID copied to clipboard: $deviceId')),
    );
  }
}
