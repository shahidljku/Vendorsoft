import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class SupportConfig {
  // Distributor helpline contact numbers (configure before release)
  static const String supportWhatsAppNumber = '+919427698665';
  static const String supportPhoneNumber = '+919427698665';
  static const String supportEmail = 'vendorproapk@gmail.com';

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

  static Future<void> openEmailSupport(BuildContext context, String deviceId) async {
    if (supportEmail.isEmpty) return;
    final Uri emailLaunchUri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      query: 'subject=VendorSoft Support Request&body=Device ID: $deviceId\n\nHow can we help you?',
    );
    try {
      if (!await launchUrl(emailLaunchUri)) {
        throw Exception('Could not launch email');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open email client. Please email: $supportEmail')),
        );
      }
    }
  }

  static Future<void> openWebsite(BuildContext context) async {
    final Uri url = Uri.parse('https://vendorpro.pages.dev');
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not launch website');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open website: $url')),
        );
      }
    }
  }

  static Future<void> openAddressMap(BuildContext context) async {
    const query = 'GF Shop 32, Seventh Heaven, 100 Feet Road, Makarba, Ahmedabad 380055, Gujarat, India';
    final Uri mapLaunchUri = Uri.parse('geo:0,0?q=${Uri.encodeComponent(query)}');
    try {
      if (!await launchUrl(mapLaunchUri)) {
        // Fallback to google maps url
        final Uri webUrl = Uri.parse('https://maps.google.com/?q=${Uri.encodeComponent(query)}');
        if (!await launchUrl(webUrl, mode: LaunchMode.externalApplication)) {
          throw Exception('Could not launch maps');
        }
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open maps application.')),
        );
      }
    }
  }
}
