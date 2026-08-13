import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/backup/backup_codec.dart';
import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('importBackup replaces provider state and secure keys', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeKeyStore keyStore = FakeKeyStore();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[keyStoreProvider.overrideWithValue(keyStore)],
    );
    addTearDown(container.dispose);
    await container.read(configRepositoryProvider.future);

    final Server oldServer = Server(id: 'srv1', name: 'Old', baseUrl: Uri.parse('https://old.example.org'));
    await container.read(configProvider.notifier).addServer(oldServer, 'old-key');

    final Server newServer = Server(id: 'srv2', name: 'Imported', baseUrl: Uri.parse('https://new.example.org'));
    final Site newSite = Site(id: 'site2', serverId: 'srv2', domain: 'example.com');
    await container
        .read(configProvider.notifier)
        .importBackup(
          BackupPayload(
            servers: <Server>[newServer],
            sites: <Site>[newSite],
            apiKeys: const <String, String>{'srv2': 'new-key'},
          ),
        );

    final ConfigState state = container.read(configProvider);
    expect(state.servers.single.name, 'Imported');
    expect(state.sites.single.domain, 'example.com');
    expect(keyStore.values['apikey_srv1'], isNull);
    expect(keyStore.values['apikey_srv2'], 'new-key');
  });
}
