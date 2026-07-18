import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'license_service.dart';

class PushNotificationService {
  static final PushNotificationService _instance = PushNotificationService._internal();

  factory PushNotificationService() {
    return _instance;
  }

  PushNotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  String? _fcmToken;
  
  final StreamController<RemoteMessage> _onMessageController = StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get onMessageStream => _onMessageController.stream;

  Future<void> initialize() async {
    // Permissions are handled elsewhere in the app as per user comment
    try {
      _fcmToken = await _fcm.getToken();
      debugPrint('FCM Token generated.');
      if (_fcmToken != null) {
        _updateTokenOnBackend(_fcmToken!);
      }
      
      _fcm.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        _updateTokenOnBackend(newToken);
      });
      
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('Got a message whilst in the foreground!');
        if (message.notification != null) {
          _onMessageController.add(message);
        }
      });
    } catch (e) {
      debugPrint('Failed to get FCM token: $e');
    }
  }

  Future<void> _updateTokenOnBackend(String token) async {
    try {
      User? user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final idToken = await user.getIdToken();
      if (idToken == null) return;

      final deviceId = await LicenseService().getDeviceId();
      final url = Uri.parse('https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1/installations/update-fcm');
      
      await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
          'x-installation-uuid': deviceId,
          'x-hardware-id': deviceId,
        },
        body: jsonEncode({'fcmToken': token}),
      );
    } catch (e) {
      debugPrint('Failed to update FCM token on backend: $e');
    }
  }

  String? get fcmToken => _fcmToken;
}

