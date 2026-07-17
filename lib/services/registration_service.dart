import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'license_service.dart';
import 'dart:io';

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
    required String businessName,
    required String ownerName,
    required String mobileNumber,
    String? city,
  }) async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/customers/register');
      
      final body = jsonEncode({
        'businessName': businessName,
        'ownerName': ownerName,
        'mobileNumber': mobileNumber,
        'city': city,
        'deviceModel': Platform.operatingSystem,
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
          throw Exception(resJson['error']?['message'] ?? 'Error ${response.statusCode}');
        } catch (_) {
          throw Exception('Server returned ${response.statusCode}');
        }
      }
    } catch (e) {
      print('Registration failed: $e');
      rethrow;
    }
  }
}
