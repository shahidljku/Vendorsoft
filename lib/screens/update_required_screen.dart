import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

class UpdateRequiredScreen extends StatefulWidget {
  final String apkDownloadUrl;
  final String latestVersion;

  const UpdateRequiredScreen({
    Key? key,
    required this.apkDownloadUrl,
    required this.latestVersion,
  }) : super(key: key);

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusMessage = 'A new version is required to continue.';

  Future<void> _startDownload() async {
    if (widget.apkDownloadUrl.isEmpty) {
      setState(() => _statusMessage = 'Update URL is missing. Contact Admin.');
      return;
    }

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _statusMessage = 'Downloading update...';
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final savePath = '${tempDir.path}/app_update_${widget.latestVersion}.apk';

      final dio = Dio();
      await dio.download(
        widget.apkDownloadUrl,
        savePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setState(() {
              _progress = received / total;
              _statusMessage = 'Downloading: ${(received / 1024 / 1024).toStringAsFixed(1)} MB / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
            });
          }
        },
      );

      setState(() {
        _statusMessage = 'Download complete! Starting installation...';
        _isDownloading = false;
      });

      // Launch APK installation intent
      final result = await OpenFilex.open(savePath);
      if (result.type != ResultType.done) {
        setState(() {
          _statusMessage = 'Error opening APK: ${result.message}\nPlease try again.';
        });
      }
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _statusMessage = 'Failed to download update.\nMake sure you have internet access and try again.';
      });
      print('Download error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.system_update_alt,
                size: 80,
                color: Color(0xFF00E676),
              ),
              const SizedBox(height: 32),
              const Text(
                'Update Required',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              if (_isDownloading)
                Column(
                  children: [
                    LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E676)),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${(_progress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ],
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _startDownload,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Download & Install Update',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
