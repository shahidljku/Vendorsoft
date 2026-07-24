import 'package:flutter/material.dart';

class SubscriptionReminderDialog extends StatelessWidget {
  final int daysRemaining;
  final VoidCallback onRenew;

  const SubscriptionReminderDialog({
    super.key,
    required this.daysRemaining,
    required this.onRenew,
  });

  String _getMessage() {
    if (daysRemaining == 7) {
      return 'Your subscription will expire in 7 days.';
    } else if (daysRemaining == 5) {
      return 'Your subscription will expire in 5 days.';
    } else if (daysRemaining == 3) {
      return 'Your subscription expires in only 3 days.';
    } else if (daysRemaining == 1) {
      return 'Your subscription expires tomorrow.';
    } else if (daysRemaining == 0) {
      return 'Your subscription expires today.\nRenew now to avoid interruption.';
    }
    return 'Your subscription is expiring soon.';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.orangeAccent,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'Subscription Expiring Soon',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              _getMessage(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Later',
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 16,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    onRenew();
                    Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Renew Now',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
