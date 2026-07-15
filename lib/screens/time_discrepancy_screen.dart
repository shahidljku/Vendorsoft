import 'package:flutter/material.dart';

class TimeDiscrepancyScreen extends StatelessWidget {
  final VoidCallback onRetry;
  final bool isRtcReset;
  final bool isForwardJump;
  final bool isRollback;

  const TimeDiscrepancyScreen({
    super.key,
    required this.onRetry,
    this.isRtcReset = false,
    this.isForwardJump = false,
    this.isRollback = false,
  });

  @override
  Widget build(BuildContext context) {
    String title = 'System Clock Discrepancy';
    String description =
        'Your device system clock appears to be out of sync or incorrect. To verify your license and ensure data integrity across your newspaper customer database, please enable Automatic Network Date & Time in Android Settings.';

    if (isRtcReset) {
      title = 'Clock Calibration Needed';
      description =
          'Your device time is reporting a date far in the past (before 2024). This often happens when the phone battery runs down completely. Please connect to the internet or cellular network so your device clock can sync automatically.';
    } else if (isForwardJump) {
      title = 'Future Date Detected';
      description =
          'Your device clock is set years into the future. Vendor Soft temporarily pauses access while the system date is set to the future. Please restore genuine network date/time to resume your valid access.';
    } else if (isRollback) {
      title = 'Clock Discrepancy Detected';
      description =
          'Your device system clock appears to have been rolled backward significantly compared to your previous session. Please restore automatic network date & time to continue securely.';
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.access_time_filled,
                    color: Colors.orangeAccent,
                    size: 64,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 36),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, color: Colors.black),
                    label: const Text(
                      'Check Again / Verify Clock',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
