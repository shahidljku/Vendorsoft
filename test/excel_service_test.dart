import 'package:flutter_test/flutter_test.dart';
import 'package:image_sender/services/excel_service.dart';
import 'package:image_sender/models/customer.dart';

void main() {
  group('ExcelService Tests', () {
    late ExcelService excelService;

    setUp(() {
      excelService = ExcelService();
    });

    test('getPendingCustomers returns only pending status up to limit', () {
      final customers = <Customer>[
        Customer(mobile: '111', status: 'Pending', imagePath: 'a.jpg'),
        Customer(mobile: '222', status: 'Sent', imagePath: 'b.jpg'),
        Customer(mobile: '333', status: 'pending', imagePath: 'c.jpg'),
        Customer(mobile: '444', status: 'Pending', imagePath: 'd.jpg'),
      ];

      final pending2 = excelService.getPendingCustomers(customers, 2);
      expect(pending2.length, 2);
      expect(pending2[0].mobile, '111');
      expect(pending2[1].mobile, '333');

      final pendingAll = excelService.getPendingCustomers(customers, 10);
      expect(pendingAll.length, 3);
    });

    test('saveCustomers without documentUri returns false safely without throwing', () async {
      final result = await excelService.saveCustomers();
      expect(result, false);
    });
  });
}
