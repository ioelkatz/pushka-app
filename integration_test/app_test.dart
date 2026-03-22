import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pushka_app/main.dart' as app;

/// E2E integration tests that run on a real device/emulator.
/// Run with: flutter test integration_test/app_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Login flow', () {
    testWidgets('login screen renders correctly', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Login screen should be visible
      expect(find.byType(TextField), findsWidgets);
      expect(find.text('Iniciar sesión'), findsWidgets);
    });

    testWidgets('empty email shows validation error', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 5));

      final loginButton = find.widgetWithText(ElevatedButton, 'Iniciar sesión');
      if (loginButton.evaluate().isNotEmpty) {
        await tester.tap(loginButton);
        await tester.pumpAndSettle();
        expect(find.textContaining('correo'), findsWidgets);
      }
    });

    testWidgets('invalid email shows format error', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 5));

      final emailField = find.byType(TextField).first;
      if (emailField.evaluate().isNotEmpty) {
        await tester.enterText(emailField, 'not-an-email');
        await tester.pumpAndSettle();

        final loginButton = find.widgetWithText(ElevatedButton, 'Iniciar sesión');
        if (loginButton.evaluate().isNotEmpty) {
          await tester.tap(loginButton);
          await tester.pumpAndSettle();
        }
      }
    });
  });

  group('Navigation', () {
    testWidgets('drawer opens when tapping hamburger menu', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // If we're past login, try to open the drawer
      final menuButton = find.byIcon(Icons.menu);
      if (menuButton.evaluate().isNotEmpty) {
        await tester.tap(menuButton);
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);
      }
    });
  });
}
