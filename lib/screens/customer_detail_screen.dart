import 'dart:io';
import 'package:flutter/material.dart';
import '../models/customer.dart';

/// Screen showing detailed information about a single customer.
class CustomerDetailScreen extends StatelessWidget {
  final Customer customer;

  const CustomerDetailScreen({super.key, required this.customer});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Details'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Mobile Number
            _buildDetailRow(
              context,
              icon: Icons.phone,
              label: 'Mobile Number',
              value: customer.mobile,
            ),
            const SizedBox(height: 16),

            // Customer Name
            if (customer.custName.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.person,
                label: 'Customer Name',
                value: customer.custName,
              ),
              const SizedBox(height: 16),
            ],

            // Status
            _buildDetailRow(
              context,
              icon: Icons.info_outline,
              label: 'Status',
              value: customer.status,
              valueColor: _getStatusColor(customer.status),
            ),
            const SizedBox(height: 16),

            // Sent Time
            if (customer.sentTime.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.access_time,
                label: 'Sent Time',
                value: customer.sentTime,
              ),
              const SizedBox(height: 16),
            ],

            // Last Error
            if (customer.lastError.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.error_outline,
                label: 'Last Error',
                value: customer.lastError,
                valueColor: Colors.red,
              ),
              const SizedBox(height: 16),
            ],

            // Bill Number
            if (customer.billNo.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.receipt,
                label: 'Bill Number',
                value: customer.billNo,
              ),
              const SizedBox(height: 16),
            ],

            // Bill Amount
            if (customer.billAmount.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.attach_money,
                label: 'Bill Amount',
                value: customer.billAmount,
              ),
              const SizedBox(height: 16),
            ],

            // Closing Balance
            if (customer.clBalance.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.account_balance_wallet,
                label: 'Closing Balance',
                value: customer.clBalance,
              ),
              const SizedBox(height: 16),
            ],

            // Vouch Date
            if (customer.vouchDate.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.date_range,
                label: 'Vouch Date',
                value: customer.vouchDate,
              ),
              const SizedBox(height: 16),
            ],

            // Month Name
            if (customer.monthNm.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.calendar_month,
                label: 'Month',
                value: customer.monthNm,
              ),
              const SizedBox(height: 16),
            ],

            // Customer Number (custNo)
            if (customer.custNo.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.numbers,
                label: 'Customer No',
                value: customer.custNo,
              ),
              const SizedBox(height: 16),
            ],

            // Collection Man Details
            if (customer.cmCode.isNotEmpty || customer.cmName.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.badge,
                label: 'Collection Man',
                value: '${customer.cmCode} - ${customer.cmName}'.trim(),
              ),
              const SizedBox(height: 16),
            ],

            // YesNo (Future Purpose)
            if (customer.yesNo.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.rule,
                label: 'Yes/No',
                value: customer.yesNo,
              ),
              const SizedBox(height: 16),
            ],

            // Message (Future Purpose)
            if (customer.message.isNotEmpty) ...[
              _buildDetailRow(
                context,
                icon: Icons.message,
                label: 'Message',
                value: customer.message,
              ),
              const SizedBox(height: 16),
            ],

            // Image Path
            _buildDetailRow(
              context,
              icon: Icons.folder,
              label: 'Image Path',
              value: customer.resolvedImagePath,
            ),
            const SizedBox(height: 24),

            // Image Preview
            const Text(
              'Image Preview',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            Center(
              child: _buildImagePreview(),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.grey),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value.isEmpty ? '—' : value,
                style: TextStyle(
                  fontSize: 16,
                  color: valueColor,
                  fontWeight: valueColor != null
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImagePreview() {
    File file = File(customer.resolvedImagePath);

    if (!file.existsSync()) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_not_supported, size: 80, color: Colors.grey),
          SizedBox(height: 8),
          Text('Image not found', style: TextStyle(color: Colors.grey)),
        ],
      );
    }

    try {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          file,
          fit: BoxFit.contain,
        ),
      );
    } catch (e) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image, size: 80, color: Colors.grey),
          SizedBox(height: 8),
          Text('Cannot load image', style: TextStyle(color: Colors.grey)),
        ],
      );
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case "Sent":
        return Colors.green;
      case "Processing":
        return Colors.orange;
      case "Waiting":
        return Colors.blue;
      case "Failed":
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}
