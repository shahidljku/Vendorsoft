// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'license_service.dart';

class TransferService {
  static final TransferService _instance = TransferService._internal();
  factory TransferService() => _instance;
  TransferService._internal();

  String baseUrl = 'https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1';

  Future<Map<String, String>> _buildHeaders() async {
    final deviceId = await LicenseService().getDeviceId();
    String? idToken;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        idToken = await user.getIdToken();
      }
    } catch (e) {
      print('Failed to get Firebase token for TransferService: $e');
    }

    final Map<String, String> headers = {
      'Content-Type': 'application/json',
      'x-installation-uuid': deviceId,
      'x-hardware-id': deviceId,
      'x-platform': Platform.operatingSystem,
      'x-app-version': '1.0.0'
    };
    
    if (idToken != null) {
      headers['Authorization'] = 'Bearer $idToken';
    }
    
    return headers;
  }

  /// Requests a peer-to-peer transfer to claim an active subscription (`Phase 2.2`).
  Future<Map<String, dynamic>> requestTransfer({String? customerId, String? subscriptionId, String? mobileNumber}) async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/transfers/request');
      
      final Map<String, dynamic> bodyMap = {
        'deviceModel': Platform.operatingSystem
      };
      if (customerId != null) bodyMap['customerId'] = customerId;
      if (subscriptionId != null) bodyMap['subscriptionId'] = subscriptionId;
      if (mobileNumber != null) bodyMap['mobileNumber'] = mobileNumber;

      final body = jsonEncode(bodyMap);

      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 200 || response.statusCode == 202) {
        final data = jsonDecode(response.body);
        return data['data'] as Map<String, dynamic>;
      } else {
        throw Exception('Transfer request failed (${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      print('Error in requestTransfer: $e');
      rethrow;
    }
  }

  /// Polls pending transfer requests targeting this old device (`Mandatory Synchronization Path`).
  Future<List<Map<String, dynamic>>> pollPendingTransfers() async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/transfers/pending');

      final response = await http.get(url, headers: headers);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final list = (data['data']['pendingTransfers'] as List?) ?? [];
        return list.map((item) => item as Map<String, dynamic>).toList();
      } else {
        print('Poll pending transfers failed (${response.statusCode}): ${response.body}');
        return [];
      }
    } catch (e) {
      print('Error in pollPendingTransfers: $e');
      return [];
    }
  }

  /// Approves an incoming transfer request and deactivates this old device locally (`Phase 2.2`).
  Future<bool> approveTransfer(String transferId) async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/transfers/approve');
      final body = jsonEncode({'transferId': transferId});

      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 200) {
        // Remove local active license right after successful approval
        await LicenseService().removeLicense();
        return true;
      } else {
        print('Approve transfer failed (${response.statusCode}): ${response.body}');
        return false;
      }
    } catch (e) {
      print('Error in approveTransfer: $e');
      return false;
    }
  }

  /// Cancels a pending transfer request from the new device (`Phase 2.2`).
  Future<bool> cancelTransfer(String transferId) async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/transfers/cancel');
      final body = jsonEncode({'transferId': transferId});

      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 200) {
        return true;
      } else {
        print('Cancel transfer failed (${response.statusCode}): ${response.body}');
        return false;
      }
    } catch (e) {
      print('Error in cancelTransfer: $e');
      return false;
    }
  }

  /// Rejects an incoming transfer request (`Phase 2.2`).
  Future<bool> rejectTransfer(String transferId) async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/transfers/reject');
      final body = jsonEncode({'transferId': transferId});

      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 200) {
        return true;
      } else {
        print('Reject transfer failed (${response.statusCode}): ${response.body}');
        return false;
      }
    } catch (e) {
      print('Error in rejectTransfer: $e');
      return false;
    }
  }

  /// Polls the status of a specific transfer request.
  Future<Map<String, dynamic>?> pollTransferStatus(String transferId) async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/transfers/$transferId/status');

      final response = await http.get(url, headers: headers);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['data'] as Map<String, dynamic>?;
      } else {
        print('Poll transfer status failed (${response.statusCode}): ${response.body}');
        return null;
      }
    } catch (e) {
      print('Error in pollTransferStatus: $e');
      return null;
    }
  }
}
