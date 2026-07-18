import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'license_service.dart';
import 'dart:io';
import 'push_notification_service.dart';

class TransferRequiredException implements Exception {
  final String message;
  TransferRequiredException(this.message);
  @override
  String toString() => message;
}

class RegistrationService {
  static final RegistrationService _instance = RegistrationService._internal();
  factory RegistrationService() => _instance;
  RegistrationService._internal();

  final String baseUrl = 'https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1';

  Future<Map<String, String>> _buildHeaders() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      try {
        final cred = await FirebaseAuth.instance.signInAnonymously();
        user = cred.user;
      } catch (e) {
        print('Registration anonymous sign-in failed: $e');
      }
    }
    
    final token = user != null ? await user.getIdToken() : '';
    final hardwareId = await LicenseService().getDeviceId();

    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'x-hardware-id': hardwareId,
      'x-installation-uuid': hardwareId, // Fallback to hardwareId for simplicity
      'x-app-version': '1.0.0',
      'x-platform': Platform.operatingSystem,
    };
  }

  Future<bool> registerCustomer({
    String? businessName,
    String? ownerName,
    required String mobileNumber,
    String? city,
  }) async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/customers/register');
      
      final fcmToken = PushNotificationService().fcmToken;

      final body = jsonEncode({
        'businessName': businessName ?? 'Unknown',
        'ownerName': ownerName ?? 'Unknown',
        'mobileNumber': mobileNumber,
        'city': city ?? 'Unknown',
        'deviceModel': Platform.operatingSystem,
        if (fcmToken != null) 'fcmToken': fcmToken,
      });

      final response = await http.post(url, headers: headers, body: body);

      if (response.statusCode == 201 || response.statusCode == 200) {
        final resJson = jsonDecode(response.body);
        if (resJson['success'] == true) {
          final data = resJson['data'];
          if (data['signedLeaseToken'] != null) {
            await LicenseService().verifySignedLeaseToken(data['signedLeaseToken'], saveToStorage: true);
            return true;
          }
        }
        throw Exception('Invalid response format from server.');
      } else {
        try {
          final resJson = jsonDecode(response.body);
          final code = resJson['error']?['code'];
          final message = resJson['error']?['message'] ?? 'Error ${response.statusCode}';
          
          if (code == 'DEVICE_BANNED') {
            LicenseService().triggerDeviceBan();
          } else if (code == 'TRANSFER_REQUIRED') {
            throw TransferRequiredException(message);
          }
          
          throw Exception(message);
        } catch (e) {
          if (e is FormatException) {
            throw Exception('Server returned ${response.statusCode}');
          }
          rethrow;
        }
      }
    } catch (e) {
      print('Registration failed: $e');
      rethrow;
    }
  }
}
