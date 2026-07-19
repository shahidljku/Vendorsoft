import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'license_service.dart';

class FirebaseInstallationService {
  static final FirebaseInstallationService _instance = FirebaseInstallationService._internal();
  factory FirebaseInstallationService() => _instance;
  FirebaseInstallationService._internal();

  static const String _keyFirebaseRegistered = 'firebase_installation_registered';

  /// Performs anonymous authentication if needed and registers this installation in Firestore.
  Future<void> registerInstallationIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bool alreadyRegistered = prefs.getBool(_keyFirebaseRegistered) ?? false;
      if (alreadyRegistered) {
        return;
      }

      final FirebaseAuth auth = FirebaseAuth.instance;
      User? user = auth.currentUser;
      if (user == null) {
        final UserCredential credential = await auth.signInAnonymously();
        user = credential.user;
      }

      if (user != null) {
        final String deviceId = await LicenseService().getDeviceId();
        final FirebaseFirestore firestore = FirebaseFirestore.instance;
        final DocumentReference docRef = firestore.collection('installations').doc(deviceId);

        final DocumentSnapshot docSnap = await docRef.get();
        if (!docSnap.exists) {
          await docRef.set({
            'deviceId': deviceId,
            'uid': user.uid,
            'createdAt': FieldValue.serverTimestamp(),
          'platform': kIsWeb ? 'web' : Platform.operatingSystem,
          });
        }

        // Mark as registered so we don't repeat this check on every startup
        await prefs.setBool(_keyFirebaseRegistered, true);
      }
    } catch (e) {
      debugPrint('Firebase installation registration warning: $e');
    }
  }
}
