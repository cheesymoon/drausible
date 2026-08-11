import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/app.dart';
import 'package:drausible/src/providers/config_providers.dart';
import 'package:drausible/src/repositories/config_repository.dart';

class FakeKeyStore implements KeyStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Future<void> pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[keyStoreProvider.overrideWithValue(FakeKeyStore())],
      child: const DrausibleApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the empty state on a fresh start', (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('Add your first Plausible server'), findsOneWidget);
  });

  testWidgets('add a server, then add and view a site', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Server name'), 'My server');
    await tester.enterText(find.widgetWithText(TextFormField, 'Base URL'), 'https://plausible.example.org');
    await tester.enterText(find.widgetWithText(TextFormField, 'API key'), 'secret-key');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('My server'), findsOneWidget);

    await tester.tap(find.text('My server'));
    await tester.pumpAndSettle();

    expect(find.text('Add your first site'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Domain'), 'example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('example.com'), findsOneWidget);
  });
}
