import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_sender/services/cooldown_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CooldownService Rolling Quota & Aging Window Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.example.image_sender/cooldown'),
        (MethodCall methodCall) async {
          return true;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (MethodCall methodCall) async {
          return 3; // PermissionStatus.granted
        },
      );
    });

    test('Initial quota is 30 and no cooldown is active', () async {
      final service = CooldownService();
      final quota = await service.getRemainingQuota();
      final active = await service.isCooldownActive();

      expect(quota, 30);
      expect(active, false);
    });

    test('Sending 10 messages reduces quota to 20 without triggering cooldown', () async {
      final service = CooldownService();
      for (int i = 0; i < 10; i++) {
        await service.recordMessageSent();
      }

      final quota = await service.getRemainingQuota();
      final active = await service.isCooldownActive();

      expect(quota, 20);
      expect(active, false);
    });

    test('Messages sent over 1 hour and 10 minutes (4200s) ago are pruned from rolling quota', () async {
      // 10 messages sent 80 minutes ago (4800s ago) - should be pruned!
      // 5 messages sent 10 minutes ago (600s ago) - should be counted!
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final oldTimestamps = List.generate(10, (index) => (nowMillis - 4800 * 1000).toString());
      final recentTimestamps = List.generate(5, (index) => (nowMillis - 600 * 1000).toString());

      SharedPreferences.setMockInitialValues({
        'sentTimestamps': [...oldTimestamps, ...recentTimestamps],
      });

      final service = CooldownService();
      final quota = await service.getRemainingQuota();

      // Only the 5 recent messages should be counted (30 - 5 = 25 quota remaining)
      expect(quota, 25);
    });

    test('Reaching 30 messages in rolling window triggers cooldown lock', () async {
      final service = CooldownService();
      for (int i = 0; i < 30; i++) {
        await service.recordMessageSent();
      }

      final quota = await service.getRemainingQuota();
      final active = await service.isCooldownActive();
      final remainingDuration = await service.getRemainingCooldown();

      expect(quota, 0);
      expect(active, true);
      // Cooldown jitter is between 1 hour (3600s) and 1 hour 10 min (4200s)
      expect(remainingDuration.inSeconds, greaterThanOrEqualTo(3599));
      expect(remainingDuration.inSeconds, lessThanOrEqualTo(4200));
    });

    test('clearCooldown() clears lock without wiping sent timestamps', () async {
      final service = CooldownService();
      for (int i = 0; i < 30; i++) {
        await service.recordMessageSent();
      }
      expect(await service.isCooldownActive(), true);

      await service.clearCooldown();
      expect(await service.isCooldownActive(), false);
      // Quota should still be 0 because the 30 sent messages are preserved in the rolling window!
      expect(await service.getRemainingQuota(), 0);
    });
  });
}
