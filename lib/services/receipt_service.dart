import 'dart:io';
import 'package:flutter/material.dart';
import 'package:screenshot/screenshot.dart';
import '../models/customer.dart';

/// Reusable Widget for rendering the official payment receipt card.
class ReceiptCardWidget extends StatelessWidget {
  final Customer customer;
  final String businessName;

  const ReceiptCardWidget({
    super.key,
    required this.customer,
    required this.businessName,
  });

  static String _getCurrentDateFormatted() {
    final now = DateTime.now();
    final day = now.day.toString().padLeft(2, '0');
    final month = now.month.toString().padLeft(2, '0');
    final year = now.year.toString();
    return '$day/$month/$year';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 450,
          color: Colors.white,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top dark blue bar
              Container(height: 16, color: const Color(0xFF02295B)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    _buildDashedLine(),
                    const SizedBox(height: 16),
                    const Text(
                      'PAYMENT RECEIPT',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF02295B),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildDashedLine(),
                    const SizedBox(height: 16),

                    // Rows
                    _buildReceiptRow(Icons.business, Colors.blue, 'Party Name', customer.custName.isNotEmpty ? customer.custName : customer.mobile),
                    const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                    _buildReceiptRow(Icons.calendar_month, Colors.green, 'Date', customer.paymentDate.isNotEmpty ? customer.paymentDate : _getCurrentDateFormatted()),
                    const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                    _buildReceiptRow(Icons.receipt, Colors.teal, 'Receipt No.', customer.receiptNo.isNotEmpty ? customer.receiptNo : 'N/A'),
                    const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                    _buildReceiptRow(Icons.receipt_long, Colors.orange, 'Bill No.', customer.billNo.isNotEmpty ? customer.billNo : 'N/A'),
                    const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                    _buildReceiptRow(Icons.currency_rupee, Colors.blueAccent, 'Payment', '₹${customer.amountPaid}'),
                    const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                    _buildReceiptRow(Icons.account_balance_wallet, Colors.purpleAccent, 'Mode', customer.paymentMethod.isNotEmpty ? customer.paymentMethod : 'Online'),
                    const Divider(height: 16, thickness: 1, color: Color(0xFFEEEEEE)),
                    _buildReceiptRow(Icons.assignment_ind, Colors.pinkAccent, 'Transaction', customer.transactionId.isNotEmpty ? customer.transactionId : 'N/A'),

                    const SizedBox(height: 20),

                    // Payment Status Box
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE9F5EB),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.verified_user, color: Color(0xFF1B9347), size: 40),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text('PAYMENT STATUS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1B9347))),
                              Text('SUCCESSFUL', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1B9347))),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),
                    const Text(
                      'Thank you for your payment.',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(child: Divider(color: Colors.green.shade300, thickness: 1.5)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(Icons.spa, color: Colors.green.shade700, size: 24),
                        ),
                        Expanded(child: Divider(color: Colors.green.shade300, thickness: 1.5)),
                      ],
                    ),

                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.receipt, color: Color(0xFF02295B), size: 36),
                        const SizedBox(width: 12),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              businessName.isNotEmpty ? businessName : 'Vendor Software',
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),
                    _buildDashedLine(),
                    const SizedBox(height: 12),
                    const Text(
                      'Developed by Imtiyaz Khanusia',
                      style: TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              // Bottom dark blue bar
              Container(height: 16, color: const Color(0xFF02295B)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptRow(IconData icon, Color iconColor, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 28),
        const SizedBox(width: 16),
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
          ),
        ),
        const Text(
          ':',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF02295B)),
          ),
        ),
      ],
    );
  }

  Widget _buildDashedLine() {
    return Row(
      children: List.generate(
        40,
        (index) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: const Color(0xFF02295B),
            height: 2,
          ),
        ),
      ),
    );
  }
}

/// Service for generating receipt numbers and saving receipt PNG images to disk.
class ReceiptService {
  /// Generates a professional sequential receipt number in YYYY-MM-NNN format.
  static String generateReceiptNo(List<Customer> allCustomers) {
    final now = DateTime.now();
    final prefix = '${now.year}-${now.month.toString().padLeft(2, '0')}';

    int maxSeq = 0;
    for (final c in allCustomers) {
      final rn = c.receiptNo;
      if (rn.startsWith(prefix) && rn.length > prefix.length + 1) {
        final seqPart = rn.substring(prefix.length + 1); // after "YYYY-MM-"
        final parsed = int.tryParse(seqPart);
        if (parsed != null && parsed > maxSeq) {
          maxSeq = parsed;
        }
      }
    }

    final nextSeq = (maxSeq + 1).toString().padLeft(3, '0');
    return '$prefix-$nextSeq';
  }

  /// Captures the receipt widget to an image file and saves it in the receipts directory.
  static Future<String> generateReceiptImageFile(Customer customer, String businessName) async {
    final dir = Directory('/storage/emulated/0/VendSoft/receipts');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final screenshotController = ScreenshotController();
    final imageBytes = await screenshotController.captureFromWidget(
      ReceiptCardWidget(
        customer: customer,
        businessName: businessName,
      ),
      delay: const Duration(milliseconds: 100),
    );

    final now = DateTime.now();
    String ddmmyy = "${now.day.toString().padLeft(2, '0')}${now.month.toString().padLeft(2, '0')}${now.year.toString().substring(2)}";
    String identifier = customer.billNo.isNotEmpty ? customer.billNo : customer.mobile;
    identifier = identifier.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    String receiptPath = '${dir.path}/receipt_${identifier}_$ddmmyy.png';
    File receiptFile = File(receiptPath);
    await receiptFile.writeAsBytes(imageBytes);

    return receiptPath;
  }
}
