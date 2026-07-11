import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_sender_license_manager/services/license_generator_service.dart';

void main() {
  group('LicenseGeneratorService Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('generateLicense produces verifiable base64 payload and increments counter', () async {
      final generator = LicenseGeneratorService();

      final license1 = await generator.generateLicense(
        deviceId: 'TESTDEVICE123456',
        customerName: 'Test Business',
        customerType: 'Yearly',
        expiryDate: DateTime(2027, 7, 11),
      );

      expect(license1, isNotEmpty);

      // Decode Base64 -> JSON string
      final decodedJson = utf8.decode(base64Decode(license1));
      final licenseObj = jsonDecode(decodedJson);
      expect(licenseObj['payload'], isNotNull);
      expect(licenseObj['signature'], isNotNull);

      final payloadMap = jsonDecode(licenseObj['payload']);
      expect(payloadMap['deviceId'], 'TESTDEVICE123456');
      expect(payloadMap['customerName'], 'Test Business');
      expect(payloadMap['customerType'], 'Yearly');
      expect(payloadMap['licenseNumber'], contains('LIC-'));

      // Check history
      final history = await generator.getHistory();
      expect(history.length, 1);
      expect(history[0]['customerName'], 'Test Business');

      // Generate second license and check incremental number
      await generator.generateLicense(
        deviceId: 'ANOTHERDEVICE123',
        customerName: 'Second Business',
        customerType: 'Lifetime',
      );
      final history2 = await generator.getHistory();
      expect(history2.length, 2);
    });

    test('clearHistory clears saved license entries', () async {
      final generator = LicenseGeneratorService();
      await generator.generateLicense(
        deviceId: 'DEV1',
        customerName: 'Biz 1',
        customerType: 'Yearly',
      );
      expect((await generator.getHistory()).length, 1);

      await generator.clearHistory();
      expect((await generator.getHistory()).isEmpty, true);
    });
  });
}
