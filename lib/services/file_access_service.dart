// ignore_for_file: avoid_print
import 'package:flutter/services.dart';

/// Service that communicates with native Android SAF (Storage Access Framework)
/// to pick files with persistent write access and save back to the original location.
class FileAccessService {
  static const _channel = MethodChannel('com.example.image_sender/file_access');

  /// Picks an Excel file using Android SAF with read+write permission.
  /// Returns a map with 'uri' (String), 'bytes' (Uint8List), and 'fileName' (String).
  /// Returns null if the user cancels.
  static Future<Map<String, dynamic>?> pickExcelWithWriteAccess() async {
    try {
      final result = await _channel.invokeMethod('pickExcelWithWriteAccess');
      if (result == null) return null;

      return {
        'uri': result['uri'] as String,
        'bytes': result['bytes'] as Uint8List,
        'fileName': result['fileName'] as String,
      };
    } on PlatformException catch (e) {
      print('FileAccessService pick error: ${e.message}');
      return null;
    }
  }

  /// Saves bytes back to the original document using its content URI.
  /// Returns true on success, false on failure.
  static Future<bool> saveToUri(String uri, Uint8List bytes) async {
    try {
      final result = await _channel.invokeMethod('saveToUri', {
        'uri': uri,
        'bytes': bytes,
      });
      return result == true;
    } on PlatformException catch (e) {
      print('FileAccessService save error: ${e.message}');
      return false;
    }
  }

  /// Re-reads the file content from the original document URI.
  /// Returns the bytes, or null on failure.
  static Future<Uint8List?> readFromUri(String uri) async {
    try {
      final result = await _channel.invokeMethod('readFromUri', {
        'uri': uri,
      });
      return result as Uint8List?;
    } on PlatformException catch (e) {
      print('FileAccessService read error: ${e.message}');
      return null;
    }
  }

  /// Exports log content via Android SAF (CREATE_DOCUMENT)
  static Future<String?> exportLogFile(String content) async {
    try {
      final result = await _channel.invokeMethod('exportLogFile', {
        'content': content,
      });
      return result as String?;
    } on PlatformException catch (e) {
      print('FileAccessService export error: ${e.message}');
      return null;
    }
  }
}
