// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'license_service.dart';

class PaymentService {
  static final PaymentService _instance = PaymentService._internal();
  factory PaymentService() => _instance;
  PaymentService._internal();

  String baseUrl = 'https://api.vendsoft.app/api/v1';

  Razorpay? _razorpay;
  Function(bool success, String? message)? _currentCallback;
  String? _currentOrderId;

  void init() {
    if (Platform.isAndroid || Platform.isIOS) {
      _razorpay = Razorpay();
      _razorpay!.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
      _razorpay!.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
      _razorpay!.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
    }
  }

  void dispose() {
    _razorpay?.clear();
  }

  Future<Map<String, String>> _buildHeaders() async {
    final deviceId = await LicenseService().getDeviceId();
    String? idToken;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        idToken = await user.getIdToken();
      }
    } catch (e) {
      print('Failed to get Firebase token for PaymentService: $e');
    }

    return {
      'Content-Type': 'application/json',
      if (idToken != null) 'Authorization': 'Bearer $idToken',
      'x-installation-uuid': deviceId,
      'x-installation-id': deviceId,
      'x-hardware-id': deviceId,
      'x-platform': Platform.operatingSystem,
      'x-app-version': '1.0.0'
    };
  }

  /// Calls Cloudflare Worker `POST /api/v1/orders/create` to generate a Razorpay order.
  Future<Map<String, dynamic>> createOrder({required String planId, String? customerId}) async {
    try {
      final headers = await _buildHeaders();
      if (customerId != null && customerId.isNotEmpty) {
        headers['x-customer-id'] = customerId;
      }

      final url = Uri.parse('$baseUrl/orders/create');
      final body = jsonEncode({'planId': planId});

      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 201 || response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['data'] != null) {
          return {'success': true, 'data': data['data']};
        }
      }

      final err = jsonDecode(response.body);
      return {
        'success': false,
        'message': err['error']?['message'] ?? 'Failed to initiate order (${response.statusCode})'
      };
    } catch (e) {
      print('Exception in createOrder: $e');
      return {'success': false, 'message': 'Network error connection to payment gateway.'};
    }
  }

  /// Calls Cloudflare Worker `POST /api/v1/orders/verify` to verify and settle payment.
  Future<Map<String, dynamic>> verifyOrder({
    required String razorpayOrderId,
    String? razorpayPaymentId,
    String? razorpaySignature,
    String? errorCode
  }) async {
    try {
      final headers = await _buildHeaders();
      final url = Uri.parse('$baseUrl/orders/verify');
      final body = jsonEncode({
        'razorpayOrderId': razorpayOrderId,
        'razorpayPaymentId':? razorpayPaymentId,
        'razorpaySignature':? razorpaySignature,
        'errorCode':? errorCode
      });

      final response = await http.post(url, headers: headers, body: body);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['data'] != null) {
          final leaseToken = data['data']['signedLeaseToken'];
          if (leaseToken != null && leaseToken.toString().isNotEmpty) {
            await LicenseService().verifySignedLeaseToken(leaseToken);
          }
          return {'success': true, 'data': data['data']};
        }
      }

      final err = jsonDecode(response.body);
      return {
        'success': false,
        'message': err['error']?['message'] ?? 'Payment verification failed (${response.statusCode})'
      };
    } catch (e) {
      print('Exception in verifyOrder: $e');
      return {'success': false, 'message': 'Network error verifying payment.'};
    }
  }

  /// Initiates the full checkout pipeline from UI.
  Future<void> initiateCheckout(
    BuildContext context, {
    required String planId,
    String? customerId,
    required Function(bool success, String? message) onResult
  }) async {
    _currentCallback = onResult;

    final orderRes = await createOrder(planId: planId, customerId: customerId);
    if (orderRes['success'] != true) {
      onResult(false, orderRes['message'] ?? 'Could not create order');
      return;
    }

    final orderData = orderRes['data'];
    final razorpayOrderId = orderData['razorpayOrderId'];
    final amountPaise = orderData['amountPaise'];
    final keyId = orderData['keyId'] ?? 'rzp_test_local_mock';

    _currentOrderId = razorpayOrderId;

    // If running on Desktop (Windows/Linux) or when keyId is local mock, simulate capture / verification directly
    if (!Platform.isAndroid && !Platform.isIOS || keyId == 'rzp_test_local_mock') {
      print('Simulating payment capture for local/desktop environment: $razorpayOrderId');
      final verifyRes = await verifyOrder(
        razorpayOrderId: razorpayOrderId,
        razorpayPaymentId: 'pay_simulated_mock_capture',
        razorpaySignature: 'sig_mock_valid'
      );
      if (verifyRes['success'] == true) {
        onResult(true, 'Payment successful and subscription activated!');
      } else {
        onResult(false, verifyRes['message'] ?? 'Verification failed.');
      }
      return;
    }

    if (_razorpay == null) {
      init();
    }

    var options = {
      'key': keyId,
      'amount': amountPaise,
      'name': 'VendSoft',
      'description': orderData['planId'] == 'PRO_YEARLY' ? 'Pro Annual License' : 'Pro Monthly License',
      'order_id': razorpayOrderId,
      'prefill': {
        'contact': '',
        'email': ''
      },
      'theme': {
        'color': '#00D1FF'
      }
    };

    try {
      _razorpay?.open(options);
    } catch (e) {
      print('Razorpay open error: $e');
      onResult(false, 'Unable to launch checkout modal: $e');
    }
  }

  void _handlePaymentSuccess(PaymentSuccessResponse response) async {
    if (_currentOrderId == null || _currentCallback == null) return;
    print('Razorpay Payment Success: ${response.paymentId}');

    final verifyRes = await verifyOrder(
      razorpayOrderId: _currentOrderId!,
      razorpayPaymentId: response.paymentId,
      razorpaySignature: response.signature
    );

    if (verifyRes['success'] == true) {
      _currentCallback?.call(true, 'Payment successful and subscription activated!');
    } else {
      _currentCallback?.call(false, verifyRes['message'] ?? 'Payment captured but server verification failed.');
    }
  }

  void _handlePaymentError(PaymentFailureResponse response) async {
    print('Razorpay Payment Error: ${response.code} - ${response.message}');
    if (_currentOrderId != null) {
      await verifyOrder(
        razorpayOrderId: _currentOrderId!,
        errorCode: 'PAYMENT_CANCELLED'
      );
    }
    _currentCallback?.call(false, response.message ?? 'Payment cancelled or failed.');
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    print('Razorpay External Wallet: ${response.walletName}');
    _currentCallback?.call(false, 'External wallet selected: ${response.walletName}');
  }
}
