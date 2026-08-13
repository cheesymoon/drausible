import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/backup/backup_codec.dart';
import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';
import 'package:drausible/src/providers/config_providers.dart';
import 'package:drausible/src/providers/settings_providers.dart';
import 'package:drausible/src/providers/stats_providers.dart';
import 'package:drausible/src/repositories/config_repository.dart';
import 'package:drausible/src/repositories/stats_repository.dart';
import 'package:drausible/src/ui/screens/settings_screen.dart';

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

final Server _oldServer = Server(id: 'srv1', name: 'Old server', baseUrl: Uri.parse('https://old.example.org'));
final Site _oldSite = Site(id: 'site1', serverId: 'srv1', domain: 'old.example.com');

void _mockPlatformState({Map<String, Object> prefs = const <String, Object>{}}) {
  SharedPreferences.setMockInitialValues(prefs);
  PackageInfo.setMockInitialValues(
    appName: 'Drausible',
    packageName: 'io.github.cheesymoon.drausible',
    version: '0.1.0',
    buildNumber: '1',
    buildSignature: '',
  );
}

void _mockClipboard(String? Function() read, void Function(String text) write) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
    MethodCall call,
  ) async {
    switch (call.method) {
      case 'Clipboard.setData':
        final Map<dynamic, dynamic> args = call.arguments as Map<dynamic, dynamic>;
        write(args['text'] as String);
        return null;
      case 'Clipboard.getData':
        return <String, dynamic>{'text': read()};
    }
    return null;
  });
}

void _mockClipboardReadFailure() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
    MethodCall call,
  ) async {
    if (call.method == 'Clipboard.getData') {
      throw PlatformException(code: 'unreadable', message: 'clipboard read failed');
    }
    return null;
  });
}

void _mockFileSave(String? Function(MethodCall call) onSave) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('miguelruivo.flutter.plugins.filepicker'),
    (MethodCall call) async => call.method == 'save' ? onSave(call) : null,
  );
}

Map<String, Object> _storedConfig(Server server, Site site) {
  return <String, Object>{
    'config_v1': jsonEncode(<String, dynamic>{
      'schemaVersion': 1,
      'servers': <dynamic>[server.toJson()],
      'sites': <dynamic>[site.toJson()],
    }),
  };
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

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

  testWidgets('the create-passphrase dialog fits a phone with the keyboard up', (WidgetTester tester) async {
    _mockPlatformState();
    // Roughly what is left of a portrait phone once the software keyboard is
    // up, which is the whole time someone is typing a passphrase.
    tester.view.physicalSize = const Size(360, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: SettingsScreen())));
    await tester.pumpAndSettle();

    final Finder exportTile = find.widgetWithText(ListTile, 'Export backup');
    await tester.scrollUntilVisible(exportTile, 120);
    await tester.tap(exportTile);
    await tester.pumpAndSettle();

    // An overflowing Column fails the test through FlutterError before this.
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
  });

  testWidgets('export backup copies an encrypted envelope to the clipboard', (WidgetTester tester) async {
    _mockPlatformState(prefs: _storedConfig(_oldServer, _oldSite));
    String? clipboard;
    _mockClipboard(() => clipboard, (String text) {
      clipboard = text;
    });
    final FakeKeyStore keyStore = FakeKeyStore()..values['apikey_srv1'] = 'old-key';

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          keyStoreProvider.overrideWithValue(keyStore),
          backupCodecProvider.overrideWithValue(BackupCodec(random: Random(1), defaultIterations: 2)),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Export backup'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextFormField).at(1), 'correct horse');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pumpAndSettle();

    expect(clipboard, isNotNull);
    expect(clipboard, isNot(contains('old-key')));
    final BackupPayload decoded = await BackupCodec(defaultIterations: 2).decode(clipboard!, 'correct horse');
    expect(decoded.servers.single.name, 'Old server');
    expect(decoded.sites.single.domain, 'old.example.com');
    expect(decoded.apiKeys, <String, String>{'srv1': 'old-key'});
  });

  testWidgets('export backup writes an encrypted envelope to the chosen file', (WidgetTester tester) async {
    _mockPlatformState(prefs: _storedConfig(_oldServer, _oldSite));
    MethodCall? saveCall;
    _mockFileSave((MethodCall call) {
      saveCall = call;
      return '/storage/emulated/0/Download/drausible-backup.json';
    });
    final FakeKeyStore keyStore = FakeKeyStore()..values['apikey_srv1'] = 'old-key';

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          keyStoreProvider.overrideWithValue(keyStore),
          backupCodecProvider.overrideWithValue(BackupCodec(random: Random(1), defaultIterations: 2)),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Export backup'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextFormField).at(1), 'correct horse');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to file'));
    await tester.pumpAndSettle();

    final Map<dynamic, dynamic> arguments = saveCall!.arguments as Map<dynamic, dynamic>;
    expect(arguments['fileName'] as String, matches(RegExp(r'^drausible-backup-\d{8}-\d{6}\.json$')));
    final String envelope = utf8.decode(arguments['bytes'] as List<int>);
    expect(envelope, isNot(contains('old-key')));
    final BackupPayload decoded = await BackupCodec(defaultIterations: 2).decode(envelope, 'correct horse');
    expect(decoded.servers.single.name, 'Old server');
    expect(decoded.apiKeys, <String, String>{'srv1': 'old-key'});
    expect(find.text('Backup saved'), findsOneWidget);
  });

  testWidgets('dismissing the save sheet reports nothing', (WidgetTester tester) async {
    _mockPlatformState(prefs: _storedConfig(_oldServer, _oldSite));
    _mockFileSave((MethodCall call) => null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          keyStoreProvider.overrideWithValue(FakeKeyStore()),
          backupCodecProvider.overrideWithValue(BackupCodec(random: Random(1), defaultIterations: 2)),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Export backup'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextFormField).at(1), 'correct horse');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to file'));
    await tester.pumpAndSettle();

    expect(find.text('Backup saved'), findsNothing);
    expect(find.text('Backup export failed'), findsNothing);
  });

  testWidgets('import backup from clipboard replaces config', (WidgetTester tester) async {
    final Server newServer = Server(id: 'srv2', name: 'Imported server', baseUrl: Uri.parse('https://new.example.org'));
    final Site newSite = Site(id: 'site2', serverId: 'srv2', domain: 'new.example.com');
    final BackupCodec codec = BackupCodec(random: Random(2), defaultIterations: 2);
    String? clipboard = await codec.encode(
      BackupPayload(
        servers: <Server>[newServer],
        sites: <Site>[newSite],
        apiKeys: const <String, String>{'srv2': 'new-key'},
      ),
      'correct horse',
    );
    _mockPlatformState(prefs: _storedConfig(_oldServer, _oldSite));
    _mockClipboard(() => clipboard, (String text) {
      clipboard = text;
    });
    final FakeKeyStore keyStore = FakeKeyStore()..values['apikey_srv1'] = 'old-key';
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[keyStoreProvider.overrideWithValue(keyStore), backupCodecProvider.overrideWithValue(codec)],
    );
    addTearDown(container.dispose);
    await container.read(configRepositoryProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Import backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste from clipboard'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'correct horse');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Replace 1 server / 1 site with 1 server / 1 site?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();

    final ConfigState state = container.read(configProvider);
    expect(state.servers.single.name, 'Imported server');
    expect(state.sites.single.domain, 'new.example.com');
    expect(keyStore.values['apikey_srv1'], isNull);
    expect(keyStore.values['apikey_srv2'], 'new-key');
  });

  testWidgets('import backup invalidates stats cache and api-version resolver', (WidgetTester tester) async {
    final Server oldServer = _oldServer.copyWith(apiVersion: ApiVersion.v1);
    final Server newServer = _oldServer.copyWith(
      baseUrl: Uri.parse('https://new.example.org'),
      apiVersion: ApiVersion.v2,
    );
    final BackupCodec codec = BackupCodec(random: Random(4), defaultIterations: 2);
    String? clipboard = await codec.encode(
      BackupPayload(
        servers: <Server>[newServer],
        sites: <Site>[_oldSite],
        apiKeys: const <String, String>{'srv1': 'new-key'},
      ),
      'correct horse',
    );
    _mockPlatformState(prefs: _storedConfig(oldServer, _oldSite));
    _mockClipboard(() => clipboard, (String text) {
      clipboard = text;
    });
    final FakeKeyStore keyStore = FakeKeyStore()..values['apikey_srv1'] = 'old-key';
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[keyStoreProvider.overrideWithValue(keyStore), backupCodecProvider.overrideWithValue(codec)],
    );
    addTearDown(container.dispose);
    await container.read(configRepositoryProvider.future);
    final oldResolver = container.read(apiVersionResolverProvider('srv1'));
    final StatsRepository oldRepository = container.read(statsRepositoryProvider);
    expect(oldResolver.version, ApiVersion.v1);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Import backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste from clipboard'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'correct horse');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();

    expect(container.read(configProvider).servers.single.baseUrl, Uri.parse('https://new.example.org'));
    expect(container.read(apiVersionResolverProvider('srv1')), isNot(same(oldResolver)));
    expect(container.read(apiVersionResolverProvider('srv1')).version, ApiVersion.v2);
    expect(container.read(statsRepositoryProvider), isNot(same(oldRepository)));
  });

  testWidgets('wrong import passphrase shows an error and changes nothing', (WidgetTester tester) async {
    final Server newServer = Server(id: 'srv2', name: 'Imported server', baseUrl: Uri.parse('https://new.example.org'));
    final BackupCodec codec = BackupCodec(random: Random(3), defaultIterations: 2);
    String? clipboard = await codec.encode(
      BackupPayload(
        servers: <Server>[newServer],
        sites: const <Site>[],
        apiKeys: const <String, String>{'srv2': 'new-key'},
      ),
      'correct horse',
    );
    _mockPlatformState(prefs: _storedConfig(_oldServer, _oldSite));
    _mockClipboard(() => clipboard, (String text) {
      clipboard = text;
    });
    final FakeKeyStore keyStore = FakeKeyStore()..values['apikey_srv1'] = 'old-key';
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[keyStoreProvider.overrideWithValue(keyStore), backupCodecProvider.overrideWithValue(codec)],
    );
    addTearDown(container.dispose);
    await container.read(configRepositoryProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Import backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste from clipboard'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'wrong passphrase');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Wrong passphrase or damaged backup'), findsOneWidget);
    expect(container.read(configProvider).servers.single.name, 'Old server');
    expect(keyStore.values['apikey_srv1'], 'old-key');
    expect(keyStore.values['apikey_srv2'], isNull);
  });

  testWidgets('import read failure shows an error and changes nothing', (WidgetTester tester) async {
    _mockPlatformState(prefs: _storedConfig(_oldServer, _oldSite));
    _mockClipboardReadFailure();
    final FakeKeyStore keyStore = FakeKeyStore()..values['apikey_srv1'] = 'old-key';
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[keyStoreProvider.overrideWithValue(keyStore)],
    );
    addTearDown(container.dispose);
    await container.read(configRepositoryProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'Import backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste from clipboard'));
    await tester.pumpAndSettle();

    expect(find.text('Backup import failed'), findsOneWidget);
    expect(container.read(configProvider).servers.single.name, 'Old server');
    expect(keyStore.values['apikey_srv1'], 'old-key');
  });
}
