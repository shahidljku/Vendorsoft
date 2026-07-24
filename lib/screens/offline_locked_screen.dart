import 'package:flutter/material.dart';

class OfflineLockedScreen extends StatelessWidget {
  final VoidCallback onRetry;
  final bool isRetrying;

  const OfflineLockedScreen({
    super.key,
    required this.onRetry,
    this.isRetrying = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.wifi_off_rounded,
                size: 80,
                color: Colors.orangeAccent,
              ),
              const SizedBox(height: 24),
              const Text(
                'Offline Grace Period Expired',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                '• Your subscription is still recognised.\n• Verification is temporarily required.\n• No customer data has been lost.\n• Reconnect to the internet and tap Retry.\n• Access will automatically resume after successful verification.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.6,
                ),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: isRetrying ? null : onRetry,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: isRetrying
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black54,
                          ),
                        )
                      : const Icon(Icons.refresh_rounded),
                  label: Text(
                    isRetrying ? 'Checking connection...' : 'Retry Connection',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
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
