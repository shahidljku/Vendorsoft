import 'package:flutter_test/flutter_test.dart';
import 'package:image_sender/models/customer.dart';

void main() {
  group('Customer Model Tests', () {
    test('resolvedImagePath handles empty, absolute, and relative paths correctly', () {
      final customerEmpty = Customer(mobile: '919876543210', status: 'Pending', imagePath: '');
      expect(customerEmpty.resolvedImagePath, '');

      final customerAbsolute = Customer(mobile: '919876543210', status: 'Pending', imagePath: '/storage/emulated/0/my_image.jpg');
      expect(customerAbsolute.resolvedImagePath, '/storage/emulated/0/my_image.jpg');

      final customerVendSoftPrefix = Customer(mobile: '919876543210', status: 'Pending', imagePath: 'VendSoft/images/photo.jpg');
      expect(customerVendSoftPrefix.resolvedImagePath, '/storage/emulated/0/VendSoft/images/photo.jpg');

      final customerRelative = Customer(mobile: '919876543210', status: 'Pending', imagePath: 'bill_001.jpg');
      expect(customerRelative.resolvedImagePath, '/storage/emulated/0/VendSoft/bill_001.jpg');
    });

    test('fromRow extracts strings safely across primitives and null cells without NoSuchMethodError', () {
      final rawRow = [
        '9876543210',
        'John Doe',
        'Yes',
        'Pending',
        'photo.jpg',
        'Hello World',
        '2026-07-11',
        '101',
        'INV-500',
        '1500',
        '200',
        'CM01',
        'Agent Smith',
        'July',
        '12:00',
        'Successful',
        '1500',
        'TXN12345',
        'Online',
        'Pending',
        '2026-07-11'
      ];

      final customer = Customer.fromRow(rawRow);
      expect(customer.mobile, '9876543210');
      expect(customer.custName, 'John Doe');
      expect(customer.status, 'Pending');
      expect(customer.paymentStatus, 'Successful');
      expect(customer.amountPaid, '1500');
      expect(customer.transactionId, 'TXN12345');
      expect(customer.paymentMethod, 'Online');
      expect(customer.receiptStatus, 'Pending');
    });

    test('fromRow handles sparse / missing row data cleanly without range or null errors', () {
      final sparseRow = ['9876543210', null, 'No'];
      final customer = Customer.fromRow(sparseRow);
      expect(customer.mobile, '9876543210');
      expect(customer.custName, '');
      expect(customer.yesNo, 'No');
      expect(customer.status, '');
      expect(customer.paymentStatus, '');
    });

    test('toJson and fromJson symmetry', () {
      final original = Customer(
        mobile: '919876543210',
        custName: 'Alice',
        yesNo: 'Yes',
        status: 'Sent',
        imagePath: '/storage/emulated/0/VendSoft/alice.jpg',
        message: 'Your bill is ready',
        vouchDate: '2026-07-10',
        custNo: 'C001',
        billNo: 'B001',
        billAmount: '2500',
        clBalance: '0',
        cmCode: 'CM02',
        cmName: 'Bob',
        monthNm: 'July',
        sentTime: '10:30 AM',
      );
      original.paymentStatus = 'Successful';
      original.amountPaid = '2500';
      original.transactionId = 'UPI8899';
      original.paymentMethod = 'UPI';
      original.receiptStatus = 'Sent';
      original.paymentDate = '2026-07-10';

      final jsonMap = original.toJson();
      final restored = Customer.fromJson(jsonMap);

      expect(restored.mobile, original.mobile);
      expect(restored.custName, original.custName);
      expect(restored.status, original.status);
      expect(restored.paymentStatus, original.paymentStatus);
      expect(restored.transactionId, original.transactionId);
      expect(restored.receiptStatus, original.receiptStatus);
    });
  });
}
