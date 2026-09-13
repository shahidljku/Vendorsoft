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

  static String _formatWholeOrDecimal(String amt) {
    String cleaned = amt.replaceAll('₹', '').replaceAll(',', '').trim();
    if (cleaned.isEmpty) return '0';
    final val = double.tryParse(cleaned);
    if (val == null) return cleaned;
    if (val == val.roundToDouble()) {
      return val.toInt().toString();
    }
    return val.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final double billAmt = double.tryParse(
      customer.billAmount.replaceAll(',', '').replaceAll('₹', '').trim()) ?? 0.0;
    final double paidAmt = double.tryParse(
      customer.amountPaid.replaceAll(',', '').replaceAll('₹', '').trim()) ?? 0.0;
    final double clBal = double.tryParse(
      customer.clBalance.replaceAll(',', '').replaceAll('₹', '').trim()) ?? 0.0;

    String balanceLabel = 'બાકી';
    String balanceValue = '₹0.00';
    Color balanceColor = const Color(0xFF16A34A); // Green if clear
    IconData balanceIcon = Icons.arrow_downward;

    if (billAmt > 0) {
      if (paidAmt > billAmt) {
        // Surplus (જમા) - Green
        balanceLabel = 'જમા';
        balanceValue = '₹${(paidAmt - billAmt).toStringAsFixed(2)}';
        balanceColor = const Color(0xFF16A34A);
        balanceIcon = Icons.arrow_upward;
      } else if (paidAmt < billAmt) {
        // Due (બાકી) - Red
        balanceLabel = 'બાકી';
        balanceValue = '₹${(billAmt - paidAmt).toStringAsFixed(2)}';
        balanceColor = const Color(0xFFDC2626);
        balanceIcon = Icons.arrow_downward;
      } else {
        // Fully paid
        balanceLabel = 'બાકી';
        balanceValue = '₹0.00';
        balanceColor = const Color(0xFF16A34A);
        balanceIcon = Icons.arrow_downward;
      }
    } else if (clBal != 0.0) {
      if (clBal > 0) {
        // Due (બાકી) - Red
        balanceLabel = 'બાકી';
        balanceValue = '₹${clBal.toStringAsFixed(2)}';
        balanceColor = const Color(0xFFDC2626);
        balanceIcon = Icons.arrow_downward;
      } else {
        // Surplus (જમા) - Green
        balanceLabel = 'જમા';
        balanceValue = '₹${clBal.abs().toStringAsFixed(2)}';
        balanceColor = const Color(0xFF16A34A);
        balanceIcon = Icons.arrow_upward;
      }
    } else if (paidAmt > 0) {
      balanceLabel = 'જમા';
      balanceValue = '₹${paidAmt.toStringAsFixed(2)}';
      balanceColor = const Color(0xFF16A34A);
      balanceIcon = Icons.arrow_upward;
    }

    final String displayBillAmount = customer.billAmount.isNotEmpty
        ? _formatWholeOrDecimal(customer.billAmount)
        : (customer.amountPaid.isNotEmpty ? _formatWholeOrDecimal(customer.amountPaid) : '0');
    final String displayPaidAmount = customer.amountPaid.isNotEmpty
        ? _formatWholeOrDecimal(customer.amountPaid)
        : '0';

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 450,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDashedLine(),
                const SizedBox(height: 16),
                const Text(
                  'PAYMENT RECEIPT',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF02295B),
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 16),
                _buildDashedLine(),
                const SizedBox(height: 16),

                // Top Rows (Party Name, Date, Receipt No.)
                _buildReceiptRow(
                  Icons.apartment,
                  const Color(0xFF0091EA),
                  'Party Name',
                  customer.custName.isNotEmpty ? customer.custName : customer.mobile,
                ),
                const Divider(height: 16, thickness: 0.8, color: Color(0xFFEEEEEE)),
                _buildReceiptRow(
                  Icons.calendar_month,
                  const Color(0xFF4CAF50),
                  'Date',
                  customer.paymentDate.isNotEmpty ? customer.paymentDate : _getCurrentDateFormatted(),
                ),
                const Divider(height: 16, thickness: 0.8, color: Color(0xFFEEEEEE)),
                _buildReceiptRow(
                  Icons.receipt,
                  const Color(0xFF009688),
                  'Receipt No.',
                  customer.receiptNo.isNotEmpty ? customer.receiptNo : 'N/A',
                ),
                const SizedBox(height: 12),

                // Highlighted Golden/Cream Box for Financial Details
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFDF2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFF6C944),
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildReceiptRow(
                        Icons.receipt_long,
                        const Color(0xFFF59E0B),
                        'Bill No.',
                        customer.billNo.isNotEmpty ? customer.billNo : 'N/A',
                      ),
                      const Divider(height: 16, thickness: 0.8, color: Color(0xFFF3E8C8)),
                      _buildReceiptRow(
                        Icons.monetization_on,
                        const Color(0xFFF97316),
                        'Bill Amount',
                        '₹$displayBillAmount',
                      ),
                      const Divider(height: 16, thickness: 0.8, color: Color(0xFFF3E8C8)),
                      _buildReceiptRow(
                        Icons.currency_rupee,
                        const Color(0xFF0EA5E9),
                        'Payment',
                        '₹$displayPaidAmount',
                      ),
                      const Divider(height: 16, thickness: 0.8, color: Color(0xFFF3E8C8)),
                      _buildReceiptRow(
                        balanceIcon,
                        balanceColor,
                        balanceLabel,
                        balanceValue,
                        labelColor: balanceColor,
                        valueColor: balanceColor,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Bottom Rows (Mode, Transaction)
                _buildReceiptRow(
                  Icons.account_balance_wallet,
                  const Color(0xFFA855F7),
                  'Mode',
                  customer.paymentMethod.isNotEmpty ? customer.paymentMethod : 'Online',
                ),
                const Divider(height: 16, thickness: 0.8, color: Color(0xFFEEEEEE)),
                _buildReceiptRow(
                  Icons.assignment_ind,
                  const Color(0xFFEC4899),
                  'Transaction',
                  customer.transactionId.isNotEmpty ? customer.transactionId : 'N/A',
                ),
                const SizedBox(height: 20),

                // Payment Status Box
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9F5EB),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.verified_user, color: Color(0xFF1B9347), size: 40),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text(
                            'PAYMENT STATUS',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1B9347),
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            'SUCCESSFUL',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1B9347),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // Thank you message
                const Text(
                  'Thank you for your payment.',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF02295B),
                  ),
                ),
                const SizedBox(height: 10),

                // Leaf divider
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
                const SizedBox(height: 22),

                // Business Name
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.receipt, color: Color(0xFF02295B), size: 36),
                    const SizedBox(width: 12),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          businessName.isNotEmpty ? businessName : 'ShahidAgency',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF02295B),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildDashedLine(),
                const SizedBox(height: 12),
                const Text(
                  'Developed by Imtiyaz Khanusia',
                  style: TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptRow(
    IconData icon,
    Color iconColor,
    String label,
    String value, {
    Color? labelColor,
    Color? valueColor,
  }) {
    final Color defaultColor = const Color(0xFF02295B);
    final Color effectiveLabelColor = labelColor ?? defaultColor;
    final Color effectiveValueColor = valueColor ?? defaultColor;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: iconColor, size: 28),
        const SizedBox(width: 16),
        SizedBox(
          width: 125,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: effectiveLabelColor,
                fontFamilyFallback: const ['Noto Sans Gujarati', 'sans-serif'],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            ':',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: effectiveLabelColor,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: effectiveValueColor,
                fontFamilyFallback: const ['Noto Sans Gujarati', 'sans-serif'],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDashedLine() {
    return Row(
      children: List.generate(
        42,
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
