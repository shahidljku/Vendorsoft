import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../services/settings_service.dart';

/// Service for PIN lock and security features.
class SecurityService {
  final SettingsService _settingsService;

  SecurityService(this._settingsService);

  /// Generates a random cryptographic salt
  String _generateSalt([int length = 16]) {
    final random = Random.secure();
    final values = List<int>.generate(length, (i) => random.nextInt(256));
    return base64UrlEncode(values);
  }

  /// Hashes a PIN using SHA-256 with key stretching (1000 iterations).
  String _hashPinWithSalt(String pin, String salt) {
    String currentHash = '$salt$pin';
    for (int i = 0; i < 1000; i++) {
      final bytes = utf8.encode(currentHash);
      final digest = sha256.convert(bytes);
      currentHash = digest.toString();
    }
    return currentHash;
  }

  /// Sets a new PIN.
  Future<void> setPin(String pin) async {
    String salt = _generateSalt();
    String hash = _hashPinWithSalt(pin, salt);
    await _settingsService.setPinSalt(salt);
    await _settingsService.setPinHash(hash);
    await _settingsService.setPinEnabled(true);
  }

  /// Verifies a PIN against the stored hash and salt.
  Future<bool> verifyPin(String pin) async {
    String? storedHash = await _settingsService.getPinHash();
    String? storedSalt = await _settingsService.getPinSalt();
    
    if (storedHash == null || storedSalt == null) return false;
    
    return _hashPinWithSalt(pin, storedSalt) == storedHash;
  }

  /// Checks if PIN lock is enabled.
  Future<bool> isPinEnabled() async {
    return await _settingsService.getPinEnabled();
  }

  /// Checks if a PIN has been set.
  Future<bool> hasPinSet() async {
    String? hash = await _settingsService.getPinHash();
    return hash != null && hash.isNotEmpty;
  }

  /// Changes the PIN. Requires old PIN verification.
  Future<bool> changePin(String oldPin, String newPin) async {
    bool verified = await verifyPin(oldPin);
    if (!verified) return false;
    await setPin(newPin);
    return true;
  }

  /// Removes PIN lock.
  Future<void> removePin() async {
    await _settingsService.setPinEnabled(false);
    await _settingsService.setPinHash('');
    await _settingsService.setPinSalt('');
  }
}
