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

final Server _server = Server(id: 'srv1', name: 'My server', baseUrl: Uri.parse('https://plausible.example.org'));
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

Finder _field(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextFormField));

/// The warning card pushes Save past the bottom of the default 800x600 test
/// surface. Taller beats scrolling before every tap.
void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
    final ProviderContainer container = await _pump(tester, server: _server.copyWith(apiVersion: ApiVersion.v2));

    await tester.tap(find.widgetWithText(TextButton, 'Re-check'));
    await tester.pumpAndSettle();

    expect(container.read(configProvider).servers.single.apiVersion, ApiVersion.unknown);
    // The row watches the config, so it follows the write without a reopen.
    expect(find.text('Not detected yet'), findsOneWidget);
    expect(find.text('Cleared. The next stats load detects it again.'), findsOneWidget);
  });

  testWidgets('saving a different base url forgets the detected version', (WidgetTester tester) async {
    final ProviderContainer container = await _pump(tester, server: _server.copyWith(apiVersion: ApiVersion.v2));

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

  testWidgets('an https server draws no warning', (WidgetTester tester) async {
    await _pump(tester, server: _server);

    expect(find.text('Unencrypted connection'), findsNothing);
  });

  testWidgets('an http base url warns and holds Save back until acknowledged', (WidgetTester tester) async {
    _tallSurface(tester);
    final ProviderContainer container = await _pump(tester);

    // A pump between these matters: back to back, the text lands in whichever
    // field the keyboard is still attached to.
    await tester.enterText(_field('Server name'), 'LAN box');
    await tester.pumpAndSettle();
    await tester.enterText(_field('Base URL'), 'http://192.168.1.10:8000');
    await tester.pumpAndSettle();
    await tester.enterText(_field('API key'), 'secret');
    await tester.pumpAndSettle();

    // The warning follows the text field, no save round trip needed.
    expect(find.text('Unencrypted connection'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Tick the box to connect over http'), findsOneWidget);
    expect(container.read(configProvider).servers, hasLength(1));

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(find.text('Tick the box to connect over http'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(container.read(configProvider).servers, hasLength(2));
  });

  testWidgets('switching the url back to https drops the warning', (WidgetTester tester) async {
    await _pump(tester);

    await tester.enterText(_field('Base URL'), 'http://192.168.1.10:8000');
    await tester.pumpAndSettle();
    expect(find.text('Unencrypted connection'), findsOneWidget);

    await tester.enterText(_field('Base URL'), 'https://plausible.example.org');
    await tester.pumpAndSettle();
    expect(find.text('Unencrypted connection'), findsNothing);
  });

  testWidgets('a .onion host carries its own encryption, so no warning', (WidgetTester tester) async {
    await _pump(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.enterText(_field('Base URL'), 'http://abcdefgh.onion');
    await tester.pumpAndSettle();

    expect(find.text('Unencrypted connection'), findsNothing);
  });

  testWidgets('a server already stored on http opens acknowledged', (WidgetTester tester) async {
    _tallSurface(tester);
    final Server lan = Server(id: 'srv1', name: 'LAN box', baseUrl: Uri.parse('http://192.168.1.10:8000'));
    final ProviderContainer container = await _pump(tester, server: lan);

    expect(find.text('Unencrypted connection'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);

    // Renaming it goes through without re-ticking.
    await tester.enterText(_field('Server name'), 'Home box');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(container.read(configProvider).servers.single.name, 'Home box');
  });
}
