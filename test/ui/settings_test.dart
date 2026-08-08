import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/providers/settings_providers.dart';
import 'package:drausible/src/ui/screens/settings_screen.dart';

void _mockPlatformState() {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  PackageInfo.setMockInitialValues(
    appName: 'Drausible',
    packageName: 'io.github.cheesymoon.drausible',
    version: '0.1.0',
    buildNumber: '1',
    buildSignature: '',
  );
}

void main() {
  testWidgets('renders the three theme options and the app version', (WidgetTester tester) async {
    _mockPlatformState();
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: SettingsScreen())));
    await tester.pumpAndSettle();

    expect(find.text('System default'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('0.1.0'), findsOneWidget);
  });

  testWidgets('tapping Dark updates themeModeProvider state', (WidgetTester tester) async {
    _mockPlatformState();
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(container.read(themeModeProvider), ThemeMode.dark);
  });
}
