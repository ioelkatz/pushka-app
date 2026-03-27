import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Dialog stability tests', () {
    testWidgets('Holiday donation dialog - type numbers without crash',
        (tester) async {
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final holidayBanner = find.textContaining('Maos');
      if (holidayBanner.evaluate().isNotEmpty) {
        await tester.tap(holidayBanner);
        await tester.pumpAndSettle();

        final textFields = find.byType(TextField);
        if (textFields.evaluate().isNotEmpty) {
          await tester.enterText(textFields.first, '25');
          await tester.pumpAndSettle();
          await tester.enterText(textFields.first, '250');
          await tester.pumpAndSettle();
          await tester.enterText(textFields.first, '');
          await tester.pumpAndSettle();
          await tester.enterText(textFields.first, '99.99');
          await tester.pumpAndSettle();
        }

        final closeBtn = find.byIcon(Icons.close);
        if (closeBtn.evaluate().isNotEmpty) {
          await tester.tap(closeBtn.first);
          await tester.pumpAndSettle();
        }
      }
    });

    testWidgets('Donate now dialog', (tester) async {
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final donateBtn = find.text('DONAR AHORA');
      if (donateBtn.evaluate().isNotEmpty) {
        await tester.tap(donateBtn);
        await tester.pumpAndSettle();

        final textFields = find.byType(TextField);
        if (textFields.evaluate().isNotEmpty) {
          await tester.enterText(textFields.first, '100');
          await tester.pumpAndSettle();
        }

        final closeBtn = find.byIcon(Icons.close);
        if (closeBtn.evaluate().isNotEmpty) {
          await tester.tap(closeBtn.first);
          await tester.pumpAndSettle();
        }
      }
    });
  });
}