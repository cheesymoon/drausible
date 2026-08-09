import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';
import 'package:drausible/src/providers/config_providers.dart';
import 'package:drausible/src/repositories/config_repository.dart';
import 'package:drausible/src/ui/screens/server_edit_screen.dart';

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

final Server _server = Server(
  id: 'srv1',
  name: 'My server',
  baseUrl: Uri.parse('https://plausible.example.org'),
);
final Site _site = Site(id: 'site1', serverId: 'srv1', domain: 'example.com');

/// Pass a server for edit mode, nothing for create mode. The stored config
/// holds that server either way, so create mode is the only difference.
Future<ProviderContainer> _pump(WidgetTester tester, {Server? server}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'config_v1': jsonEncode(<String, dynamic>{
      'schemaVersion': 1,
      'servers': <dynamic>[(server ?? _server).toJson()],
      'sites': <dynamic>[_site.toJson()],
    }),
  });
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[keyStoreProvider.overrideWithValue(FakeKeyStore())],
  );
  addTearDown(container.dispose);
  // configProvider reads the repository through valueOrNull. Until this
  // resolves the config is still empty.
  await container.read(configRepositoryProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ServerEditScreen(server: server)),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('edit mode names the detected stats API', (WidgetTester tester) async {
    await _pump(tester, server: _server.copyWith(apiVersion: ApiVersion.v2));

    expect(find.text('Stats API'), findsOneWidget);
    expect(find.text('Version 2'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Re-check'), findsOneWidget);
  });

  testWidgets('an undetected server says so instead of hiding the row', (WidgetTester tester) async {
    await _pump(tester, server: _server);

    expect(find.text('Stats API'), findsOneWidget);
    expect(find.text('Not detected yet'), findsOneWidget);
  });

  testWidgets('create mode has no version row at all', (WidgetTester tester) async {
    await _pump(tester);

    expect(find.text('Stats API'), findsNothing);
    expect(find.text('Re-check'), findsNothing);
  });

  testWidgets('Re-check forgets the stored version', (WidgetTester tester) async {
    final ProviderContainer container = await _pump(
      tester,
      server: _server.copyWith(apiVersion: ApiVersion.v2),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Re-check'));
    await tester.pumpAndSettle();

    expect(container.read(configProvider).servers.single.apiVersion, ApiVersion.unknown);
    // The row watches the config, so it follows the write without a reopen.
    expect(find.text('Not detected yet'), findsOneWidget);
    expect(
      find.text('Cleared. The next stats load detects it again.'),
      findsOneWidget,
    );
  });

  testWidgets('saving a different base url forgets the detected version', (WidgetTester tester) async {
    final ProviderContainer container = await _pump(
      tester,
      server: _server.copyWith(apiVersion: ApiVersion.v2),
    );

    await tester.enterText(
      find.ancestor(of: find.text('Base URL'), matching: find.byType(TextFormField)),
      'https://stats.example.net',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final Server saved = container.read(configProvider).servers.single;
    expect(saved.baseUrl, Uri.parse('https://stats.example.net'));
    expect(saved.apiVersion, ApiVersion.unknown);
  });
}
