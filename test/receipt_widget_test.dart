import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_sender/models/customer.dart';
import 'package:image_sender/services/receipt_service.dart';

void main() {
  group('ReceiptCardWidget Tests', () {
    testWidgets('Renders Due correctly with Gujarati label "બાકી" and Red color', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final customer = Customer(
        mobile: '9876543210',
        custName: 'AASIFBHAI ROSANPARK',
        status: 'Sent',
        imagePath: '',
        billNo: '1641',
        billAmount: '164',
        amountPaid: '100',
        paymentMethod: 'Online',
        transactionId: 'TXN12345',
        receiptNo: '2026-09-007',
        paymentDate: '03/09/2026',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReceiptCardWidget(
                customer: customer,
                businessName: 'ShahidAgency',
              ),
            ),
          ),
        ),
      );

      // Verify Header
      expect(find.text('PAYMENT RECEIPT'), findsOneWidget);
      expect(find.text('Party Name'), findsOneWidget);
      expect(find.text('AASIFBHAI ROSANPARK'), findsOneWidget);
      expect(find.text('Date'), findsOneWidget);
      expect(find.text('03/09/2026'), findsOneWidget);
      expect(find.text('Receipt No.'), findsOneWidget);
      expect(find.text('2026-09-007'), findsOneWidget);

      // Verify Box details
      expect(find.text('Bill No.'), findsOneWidget);
      expect(find.text('1641'), findsOneWidget);
      expect(find.text('Bill Amount'), findsOneWidget);
      expect(find.text('₹164'), findsOneWidget);
      expect(find.text('Payment'), findsOneWidget);
      expect(find.text('₹100'), findsOneWidget);

      // Verify Due: 'બાકી' and '₹64.00' in Red
      final bakiTextFinder = find.text('બાકી');
      expect(bakiTextFinder, findsOneWidget);
      final Text bakiWidget = tester.widget<Text>(bakiTextFinder);
      expect(bakiWidget.style?.color, const Color(0xFFDC2626));

      final dueValueFinder = find.text('₹64.00');
      expect(dueValueFinder, findsOneWidget);
      final Text dueValueWidget = tester.widget<Text>(dueValueFinder);
      expect(dueValueWidget.style?.color, const Color(0xFFDC2626));

      // Verify Mode & Transaction
      expect(find.text('Mode'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Transaction'), findsOneWidget);
      expect(find.text('TXN12345'), findsOneWidget);

      // Verify Status & Footer
      expect(find.text('PAYMENT STATUS'), findsOneWidget);
      expect(find.text('SUCCESSFUL'), findsOneWidget);
      expect(find.text('ShahidAgency'), findsOneWidget);
      expect(find.text('Developed by Imtiyaz Khanusia'), findsOneWidget);
    });

    testWidgets('Renders Surplus correctly with Gujarati label "જમા" and Green color', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final customer = Customer(
        mobile: '9876543210',
        custName: 'AASIFBHAI',
        status: 'Sent',
        imagePath: '',
        billNo: '1641',
        billAmount: '100',
        amountPaid: '150',
        paymentMethod: 'Cash',
        receiptNo: '2026-09-008',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReceiptCardWidget(
                customer: customer,
                businessName: 'ShahidAgency',
              ),
            ),
          ),
        ),
      );

      // Verify Surplus: 'જમા' and '₹50.00' in Green
      final jamaTextFinder = find.text('જમા');
      expect(jamaTextFinder, findsOneWidget);
      final Text jamaWidget = tester.widget<Text>(jamaTextFinder);
      expect(jamaWidget.style?.color, const Color(0xFF16A34A));

      final surplusValueFinder = find.text('₹50.00');
      expect(surplusValueFinder, findsOneWidget);
      final Text surplusValueWidget = tester.widget<Text>(surplusValueFinder);
      expect(surplusValueWidget.style?.color, const Color(0xFF16A34A));
    });
  });
}
