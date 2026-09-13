import 'dart:io';
import 'package:crypto/crypto.dart';

enum BillTransactionStatus {
  pending,
  staged,
  inFlight,
  confirmed,
  failed,
  uncertain,
}

extension BillTransactionStatusExtension on BillTransactionStatus {
  String get name {
    switch (this) {
      case BillTransactionStatus.pending:
        return 'PENDING';
      case BillTransactionStatus.staged:
        return 'STAGED';
      case BillTransactionStatus.inFlight:
        return 'IN_FLIGHT';
      case BillTransactionStatus.confirmed:
        return 'CONFIRMED';
      case BillTransactionStatus.failed:
        return 'FAILED';
      case BillTransactionStatus.uncertain:
        return 'UNCERTAIN';
    }
  }

  static BillTransactionStatus fromString(String val) {
    switch (val.toUpperCase().trim()) {
      case 'PENDING':
        return BillTransactionStatus.pending;
      case 'STAGED':
        return BillTransactionStatus.staged;
      case 'IN_FLIGHT':
      case 'INFLIGHT':
        return BillTransactionStatus.inFlight;
      case 'CONFIRMED':
      case 'SENT':
        return BillTransactionStatus.confirmed;
      case 'FAILED':
        return BillTransactionStatus.failed;
      case 'UNCERTAIN':
      case 'NEEDS_REVIEW':
        return BillTransactionStatus.uncertain;
      default:
        return BillTransactionStatus.pending;
    }
  }
}

/// Immutable transactional record binding:
/// Customer + Phone + Bill ID + Billing Period + Image File + Verification Status
class BillTransaction {
  final String transactionId;
  final String customerId;
  final String customerName;
  final String phoneNumber;
  final String billId;
  final String billingPeriod;
  final String imagePath;
  final int fileSizeBytes;
  final String sha256Hash;
  final BillTransactionStatus status;
  final int attemptCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastError;
  final String? diagnosticNote;

  const BillTransaction({
    required this.transactionId,
    required this.customerId,
    required this.customerName,
    required this.phoneNumber,
    required this.billId,
    required this.billingPeriod,
    required this.imagePath,
    required this.fileSizeBytes,
    required this.sha256Hash,
    required this.status,
    this.attemptCount = 1,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
    this.diagnosticNote,
  });

  /// Invariant check: Returns true if the transaction is in a final, irreversible state.
  bool get isTerminal =>
      status == BillTransactionStatus.confirmed ||
      status == BillTransactionStatus.uncertain;

  /// Invariant check: Returns true if this bill may be safely re-attempted.
  /// Strictly prohibited for confirmed or uncertain transactions.
  bool get canRetry => status == BillTransactionStatus.failed;

  /// Creates a copy with specified fields updated.
  BillTransaction copyWith({
    BillTransactionStatus? status,
    int? attemptCount,
    DateTime? updatedAt,
    String? lastError,
    String? diagnosticNote,
  }) {
    return BillTransaction(
      transactionId: transactionId,
      customerId: customerId,
      customerName: customerName,
      phoneNumber: phoneNumber,
      billId: billId,
      billingPeriod: billingPeriod,
      imagePath: imagePath,
      fileSizeBytes: fileSizeBytes,
      sha256Hash: sha256Hash,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      lastError: lastError ?? this.lastError,
      diagnosticNote: diagnosticNote ?? this.diagnosticNote,
    );
  }

  /// Factory helper that computes file size and SHA-256 hash synchronously or safely.
  static Future<BillTransaction> create({
    required String transactionId,
    required String customerId,
    required String customerName,
    required String phoneNumber,
    required String billId,
    required String billingPeriod,
    required String imagePath,
  }) async {
    final file = File(imagePath);
    int size = 0;
    String hash = '';

    if (await file.exists()) {
      size = await file.length();
      final bytes = await file.readAsBytes();
      hash = sha256.convert(bytes).toString();
    }

    final now = DateTime.now();
    return BillTransaction(
      transactionId: transactionId,
      customerId: customerId,
      customerName: customerName,
      phoneNumber: phoneNumber.replaceAll(RegExp(r'[^0-9]'), ''),
      billId: billId,
      billingPeriod: billingPeriod,
      imagePath: imagePath,
      fileSizeBytes: size,
      sha256Hash: hash,
      status: BillTransactionStatus.staged,
      attemptCount: 1,
      createdAt: now,
      updatedAt: now,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'transactionId': transactionId,
      'customerId': customerId,
      'customerName': customerName,
      'phoneNumber': phoneNumber,
      'billId': billId,
      'billingPeriod': billingPeriod,
      'imagePath': imagePath,
      'fileSizeBytes': fileSizeBytes,
      'sha256Hash': sha256Hash,
      'status': status.name,
      'attemptCount': attemptCount,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (lastError != null) 'lastError': lastError,
      if (diagnosticNote != null) 'diagnosticNote': diagnosticNote,
    };
  }

  factory BillTransaction.fromJson(Map<String, dynamic> json) {
    return BillTransaction(
      transactionId: json['transactionId'] as String? ?? '',
      customerId: json['customerId'] as String? ?? '',
      customerName: json['customerName'] as String? ?? '',
      phoneNumber: json['phoneNumber'] as String? ?? '',
      billId: json['billId'] as String? ?? '',
      billingPeriod: json['billingPeriod'] as String? ?? '',
      imagePath: json['imagePath'] as String? ?? '',
      fileSizeBytes: json['fileSizeBytes'] as int? ?? 0,
      sha256Hash: json['sha256Hash'] as String? ?? '',
      status: BillTransactionStatusExtension.fromString(
        json['status'] as String? ?? 'PENDING',
      ),
      attemptCount: json['attemptCount'] as int? ?? 1,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastError: json['lastError'] as String?,
      diagnosticNote: json['diagnosticNote'] as String?,
    );
  }

  @override
  String toString() {
    return 'BillTransaction($transactionId, $customerName, $phoneNumber, status=${status.name})';
  }
}
