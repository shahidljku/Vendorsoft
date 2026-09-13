import 'package:flutter_test/flutter_test.dart';
import 'package:image_sender/models/bill_transaction.dart';

void main() {
  group('BillTransaction Model & Invariant Tests', () {
    test('BillTransaction JSON serialization and deserialization roundtrip', () {
      final now = DateTime.now();
      final original = BillTransaction(
        transactionId: 'TX_12345',
        customerId: 'CUST_001',
        customerName: 'Shahid Supermarket',
        phoneNumber: '9876543210',
        billId: 'INV-2026-001',
        billingPeriod: '2026-09',
        imagePath: '/storage/emulated/0/Download/bill_001.png',
        fileSizeBytes: 204850,
        sha256Hash: 'abcdef1234567890abcdef1234567890',
        status: BillTransactionStatus.inFlight,
        createdAt: now,
        updatedAt: now,
        diagnosticNote: 'Initiating send via MediaComposerActivity',
      );

      final jsonMap = original.toJson();
      final restored = BillTransaction.fromJson(jsonMap);

      expect(restored.transactionId, original.transactionId);
      expect(restored.customerId, original.customerId);
      expect(restored.customerName, original.customerName);
      expect(restored.phoneNumber, original.phoneNumber);
      expect(restored.billId, original.billId);
      expect(restored.billingPeriod, original.billingPeriod);
      expect(restored.imagePath, original.imagePath);
      expect(restored.fileSizeBytes, original.fileSizeBytes);
      expect(restored.sha256Hash, original.sha256Hash);
      expect(restored.status, BillTransactionStatus.inFlight);
      expect(restored.diagnosticNote, original.diagnosticNote);
    });

    test('copyWith properly updates status and diagnosticNote', () {
      final now = DateTime.now();
      final initial = BillTransaction(
        transactionId: 'TX_12345',
        customerId: 'CUST_001',
        customerName: 'Shahid Supermarket',
        phoneNumber: '9876543210',
        billId: 'INV-2026-001',
        billingPeriod: '2026-09',
        imagePath: '/storage/emulated/0/Download/bill_001.png',
        fileSizeBytes: 1024,
        sha256Hash: 'hash123',
        status: BillTransactionStatus.pending,
        createdAt: now,
        updatedAt: now,
      );

      final updated = initial.copyWith(
        status: BillTransactionStatus.confirmed,
        diagnosticNote: 'Delivered and verified in Conversation',
      );

      expect(updated.status, BillTransactionStatus.confirmed);
      expect(updated.diagnosticNote, 'Delivered and verified in Conversation');
      expect(updated.transactionId, initial.transactionId);
      expect(updated.customerId, initial.customerId);
    });

    test('isTerminal and canRetry state invariants are strictly obeyed', () {
      final now = DateTime.now();
      BillTransaction createWithStatus(BillTransactionStatus s) => BillTransaction(
            transactionId: 'TX_TEST',
            customerId: 'CUST_TEST',
            customerName: 'Customer Test',
            phoneNumber: '9999999999',
            billId: 'BILL_01',
            billingPeriod: '2026-09',
            imagePath: '/dummy/path.png',
            fileSizeBytes: 500,
            sha256Hash: 'hash',
            status: s,
            createdAt: now,
            updatedAt: now,
          );

      expect(createWithStatus(BillTransactionStatus.pending).isTerminal, false);
      expect(createWithStatus(BillTransactionStatus.staged).isTerminal, false);
      expect(createWithStatus(BillTransactionStatus.inFlight).isTerminal, false);
      expect(createWithStatus(BillTransactionStatus.failed).isTerminal, false);

      // Irreversible terminal states:
      expect(createWithStatus(BillTransactionStatus.confirmed).isTerminal, true);
      expect(createWithStatus(BillTransactionStatus.uncertain).isTerminal, true);

      // Retry rules:
      expect(createWithStatus(BillTransactionStatus.confirmed).canRetry, false);
      expect(createWithStatus(BillTransactionStatus.uncertain).canRetry, false);
      expect(createWithStatus(BillTransactionStatus.inFlight).canRetry, false);
      expect(createWithStatus(BillTransactionStatus.failed).canRetry, true);
    });
  });
}
