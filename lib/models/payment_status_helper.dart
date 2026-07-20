class PaymentStatusHelper {
  static const String successful = 'Successful';
  static const String pending = 'Pending';

  /// Determines if a customer has paid based on their raw Excel payment status string.
  /// Applies forgiving normalization to account for manual user entry.
  static bool isPaid(String? status) {
    if (status == null || status.isEmpty) return false;
    final pst = status.trim().toLowerCase();
    return pst == 'successful' || pst.contains('success') || pst == 'paid';
  }
}
