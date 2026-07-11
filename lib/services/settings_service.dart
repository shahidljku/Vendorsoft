import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// Service for managing app settings using SharedPreferences.
/// All settings are stored locally on the device.
class SettingsService extends ChangeNotifier {
  static const _keyDefaultSendLimit = 'defaultSendLimit';
  static const _keyDelayBetweenCustomers = 'delayBetweenCustomers';
  static const _keyDelayBeforeNext = 'delayBeforeNext';
  static const _keyThemeMode = 'themeMode';
  static const _keyAutoSendEnabled = 'autoSendEnabled';
  static const _keyIdleTimeout = 'idleTimeout';
  static const _keyPinHash = 'pinHash';
  static const _keyPinSalt = 'pinSalt';
  static const _keyPinEnabled = 'pinEnabled';
  static const _keyUseWhatsAppBusiness = 'useWhatsAppBusiness';
  static const _keySleepStartTime = 'sleepStartTime';
  static const _keySleepEndTime = 'sleepEndTime';
  static const _keyLastExcelUri = 'lastExcelUri';
  static const _keyLastExcelFileName = 'lastExcelFileName';
  static const _keyIsFirstLaunch = 'isFirstLaunch';
  static const _keyDefaultPrinterWidth = 'defaultPrinterWidth';
  static const _keySavedCollectionMen = 'savedCollectionMen';
  static const _keySavedItems = 'savedItems';

  SharedPreferences? _prefs;

  Future<void> _init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ── Send Limit ──

  Future<int> getDefaultSendLimit() async {
    await _init();
    return _prefs!.getInt(_keyDefaultSendLimit) ?? 30;
  }

  Future<void> setDefaultSendLimit(int value) async {
    await _init();
    await _prefs!.setInt(_keyDefaultSendLimit, value);
  }

  // ── Delay Between Customers (milliseconds) ──

  Future<int> getDelayBetweenCustomers() async {
    await _init();
    return _prefs!.getInt(_keyDelayBetweenCustomers) ?? 10000;
  }

  Future<void> setDelayBetweenCustomers(int value) async {
    await _init();
    await _prefs!.setInt(_keyDelayBetweenCustomers, value);
  }

  // ── Delay Before Next Customer (milliseconds) ──

  Future<int> getDelayBeforeNext() async {
    await _init();
    return _prefs!.getInt(_keyDelayBeforeNext) ?? 10000;
  }

  Future<void> setDelayBeforeNext(int value) async {
    await _init();
    await _prefs!.setInt(_keyDelayBeforeNext, value);
  }

  // ── Logging ──

  Future<bool> getEnableLogs() async {
    return true; // Always enabled per user request
  }

  Future<void> setEnableLogs(bool value) async {
    // No-op since it's always enabled
  }

  // ── Theme ──

  Future<String> getThemeMode() async {
    await _init();
    return _prefs!.getString(_keyThemeMode) ?? 'system';
  }

  Future<void> setThemeMode(String value) async {
    await _init();
    await _prefs!.setString(_keyThemeMode, value);
  }

  // ── Auto Send ──

  Future<bool> getAutoSendEnabled() async {
    await _init();
    return _prefs!.getBool(_keyAutoSendEnabled) ?? false;
  }

  Future<void> setAutoSendEnabled(bool value) async {
    await _init();
    await _prefs!.setBool(_keyAutoSendEnabled, value);
  }

  // ── Idle Timeout (minutes) ──

  Future<int> getIdleTimeout() async {
    await _init();
    return _prefs!.getInt(_keyIdleTimeout) ?? 5;
  }

  Future<void> setIdleTimeout(int value) async {
    await _init();
    await _prefs!.setInt(_keyIdleTimeout, value);
  }

  // ── PIN Lock ──

  Future<bool> getPinEnabled() async {
    await _init();
    return _prefs!.getBool(_keyPinEnabled) ?? false;
  }

  Future<void> setPinEnabled(bool value) async {
    await _init();
    await _prefs!.setBool(_keyPinEnabled, value);
  }

  Future<String?> getPinHash() async {
    await _init();
    return _prefs!.getString(_keyPinHash);
  }

  Future<void> setPinHash(String hash) async {
    await _init();
    await _prefs!.setString(_keyPinHash, hash);
  }

  Future<String?> getPinSalt() async {
    await _init();
    return _prefs!.getString(_keyPinSalt);
  }

  Future<void> setPinSalt(String salt) async {
    await _init();
    await _prefs!.setString(_keyPinSalt, salt);
  }

  // ── Screenshot Protection ──

  Future<bool> getScreenshotProtection() async {
    return false; // Disabled per user request
  }

  Future<void> setScreenshotProtection(bool value) async {
    // No-op
  }

  // ── WhatsApp Version ──

  Future<bool> getUseWhatsAppBusiness() async {
    await _init();
    return _prefs!.getBool(_keyUseWhatsAppBusiness) ?? false;
  }

  Future<void> setUseWhatsAppBusiness(bool value) async {
    await _init();
    await _prefs!.setBool(_keyUseWhatsAppBusiness, value);
  }

  // ── Sleep Schedule ──

  Future<bool> getSleepScheduleEnabled() async {
    return false; // Disabled per user request
  }

  Future<void> setSleepScheduleEnabled(bool value) async {
    // No-op
  }

  Future<String> getSleepStartTime() async {
    await _init();
    return _prefs!.getString(_keySleepStartTime) ?? '22:00';
  }

  Future<void> setSleepStartTime(String value) async {
    await _init();
    await _prefs!.setString(_keySleepStartTime, value);
  }

  Future<String> getSleepEndTime() async {
    await _init();
    return _prefs!.getString(_keySleepEndTime) ?? '08:00';
  }

  Future<void> setSleepEndTime(String value) async {
    await _init();
    await _prefs!.setString(_keySleepEndTime, value);
  }

  // ── Last Excel File ──

  Future<String?> getLastExcelUri() async {
    await _init();
    return _prefs!.getString(_keyLastExcelUri);
  }

  Future<void> setLastExcelUri(String value) async {
    await _init();
    await _prefs!.setString(_keyLastExcelUri, value);
  }

  Future<String?> getLastExcelFileName() async {
    await _init();
    return _prefs!.getString(_keyLastExcelFileName);
  }

  Future<void> setLastExcelFileName(String value) async {
    await _init();
    await _prefs!.setString(_keyLastExcelFileName, value);
  }

  // ── First Launch ──

  Future<bool> getIsFirstLaunch() async {
    await _init();
    return _prefs!.getBool(_keyIsFirstLaunch) ?? true;
  }

  Future<void> setIsFirstLaunch(bool value) async {
    await _init();
    await _prefs!.setBool(_keyIsFirstLaunch, value);
  }

  // ── Printer Settings ──

  Future<String> getDefaultPrinterWidth() async {
    await _init();
    return _prefs!.getString(_keyDefaultPrinterWidth) ?? '58mm';
  }

  Future<void> setDefaultPrinterWidth(String value) async {
    await _init();
    await _prefs!.setString(_keyDefaultPrinterWidth, value);
    notifyListeners();
  }

  // ── Saved Collection Men (Agents) ──

  Future<List<String>> getSavedCollectionMen() async {
    await _init();
    return _prefs!.getStringList(_keySavedCollectionMen) ?? [];
  }

  Future<void> addSavedCollectionMan(String agentCodeName) async {
    await _init();
    List<String> list = _prefs!.getStringList(_keySavedCollectionMen) ?? [];
    if (!list.contains(agentCodeName)) {
      list.add(agentCodeName);
      await _prefs!.setStringList(_keySavedCollectionMen, list);
      notifyListeners();
    }
  }

  Future<void> removeSavedCollectionMan(String agentCodeName) async {
    await _init();
    List<String> list = _prefs!.getStringList(_keySavedCollectionMen) ?? [];
    list.remove(agentCodeName);
    await _prefs!.setStringList(_keySavedCollectionMen, list);
    notifyListeners();
  }

  // ── Saved Items (Products) ──

  Future<List<String>> getSavedItems() async {
    await _init();
    return _prefs!.getStringList(_keySavedItems) ?? [];
  }

  Future<void> addSavedItem(String itemStr) async {
    await _init();
    List<String> list = _prefs!.getStringList(_keySavedItems) ?? [];
    if (!list.contains(itemStr)) {
      list.add(itemStr);
      await _prefs!.setStringList(_keySavedItems, list);
      notifyListeners();
    }
  }

  Future<void> removeSavedItem(String itemStr) async {
    await _init();
    List<String> list = _prefs!.getStringList(_keySavedItems) ?? [];
    list.remove(itemStr);
    await _prefs!.setStringList(_keySavedItems, list);
    notifyListeners();
  }
}

