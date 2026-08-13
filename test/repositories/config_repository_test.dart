import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/backup/backup_codec.dart';
import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';
import 'package:drausible/src/repositories/config_repository.dart';

class FakeKeyStore implements KeyStore {
  final Map<String, String> values = <String, String>{};
  final Set<String> writeFailures = <String>{};
  final Set<String> deleteFailures = <String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (writeFailures.remove(key)) {
      throw StateError('write failed for $key');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (deleteFailures.remove(key)) {
      throw StateError('delete failed for $key');
    }
    values.remove(key);
  }
}

Server buildServer({String id = 'srv1'}) =>
    Server(id: id, name: 'Test server', baseUrl: Uri.parse('https://plausible.example.org'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('addServer stores the server and its key', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);

    final ConfigState state = await repo.addServer(buildServer(), 'secret-key');

    expect(state.servers, hasLength(1));
    expect(state.servers.single.name, 'Test server');
    expect(await repo.getApiKey('srv1'), 'secret-key');
  });

  test('updateServer replaces the server and optionally its key', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo.addServer(buildServer(), 'old-key');

    final Server renamed = buildServer().copyWith(name: 'Renamed');
    final ConfigState state = await repo.updateServer(renamed);

    expect(state.servers.single.name, 'Renamed');
    expect(await repo.getApiKey('srv1'), 'old-key');

    await repo.updateServer(renamed, apiKey: 'new-key');
    expect(await repo.getApiKey('srv1'), 'new-key');
  });

  test('deleteServer cascades to its sites and key', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo.addServer(buildServer(), 'key');
    await repo.addSite(Site(id: 'site1', serverId: 'srv1', domain: 'example.com'));

    final ConfigState state = await repo.deleteServer('srv1');

    expect(state.servers, isEmpty);
    expect(state.sites, isEmpty);
    expect(await repo.getApiKey('srv1'), isNull);
  });

  test('addSite and deleteSite update state', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo.addServer(buildServer(), 'key');

    final ConfigState added = await repo.addSite(Site(id: 'site1', serverId: 'srv1', domain: 'example.com'));
    expect(added.sites, hasLength(1));

    final ConfigState deleted = await repo.deleteSite('site1');
    expect(deleted.sites, isEmpty);
  });

  test('persists across a second repository instance reading the same prefs store', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo1 = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo1.addServer(buildServer(), 'key');
    await repo1.addSite(Site(id: 'site1', serverId: 'srv1', domain: 'example.com'));

    final ConfigRepository repo2 = ConfigRepository(prefs: prefs, keyStore: keyStore);

    expect(repo2.state.servers, hasLength(1));
    expect(repo2.state.servers.single.name, 'Test server');
    expect(repo2.state.sites, hasLength(1));
    expect(repo2.state.sites.single.domain, 'example.com');
  });

  test('exportAll includes current config and secure api keys', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo.addServer(buildServer(), 'secret-key');
    await repo.addSite(Site(id: 'site1', serverId: 'srv1', domain: 'example.com'));

    final BackupPayload payload = await repo.exportAll();

    expect(payload.servers.single.id, 'srv1');
    expect(payload.sites.single.domain, 'example.com');
    expect(payload.apiKeys, <String, String>{'srv1': 'secret-key'});
  });

  test('replaceAll clears old keys, writes incoming keys, and persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo.addServer(buildServer(), 'old-key');
    await repo.addSite(Site(id: 'old-site', serverId: 'srv1', domain: 'old.example.com'));

    final Server incomingServer = buildServer(id: 'srv2').copyWith(name: 'Imported');
    final Site incomingSite = Site(id: 'site2', serverId: 'srv2', domain: 'new.example.com');
    final ConfigState state = await repo.replaceAll(
      BackupPayload(
        servers: <Server>[incomingServer],
        sites: <Site>[incomingSite],
        apiKeys: const <String, String>{'srv2': 'new-key', 'orphan': 'ignored'},
      ),
    );

    expect(state.servers.single.id, 'srv2');
    expect(state.sites.single.domain, 'new.example.com');
    expect(await repo.getApiKey('srv1'), isNull);
    expect(await repo.getApiKey('srv2'), 'new-key');
    expect(keyStore.values.containsKey('apikey_orphan'), isFalse);

    final ConfigRepository reloaded = ConfigRepository(prefs: prefs, keyStore: keyStore);
    expect(reloaded.state.servers.single.name, 'Imported');
    expect(reloaded.state.sites.single.domain, 'new.example.com');
  });

  test('replaceAll clears an existing key omitted by an incoming same-id server', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo.addServer(buildServer(), 'old-key');

    await repo.replaceAll(
      BackupPayload(
        servers: <Server>[buildServer().copyWith(name: 'Imported without key')],
        sites: const <Site>[],
        apiKeys: const <String, String>{},
      ),
    );

    expect(repo.state.servers.single.name, 'Imported without key');
    expect(await repo.getApiKey('srv1'), isNull);
    expect((await repo.exportAll()).apiKeys, isEmpty);
  });

  test('replaceAll restores existing keys when an incoming key write fails', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo.addServer(buildServer(), 'old-key');
    await repo.addSite(Site(id: 'old-site', serverId: 'srv1', domain: 'old.example.com'));
    keyStore.writeFailures.add('apikey_srv2');

    await expectLater(
      repo.replaceAll(
        BackupPayload(
          servers: <Server>[
            buildServer(),
            buildServer(id: 'srv2'),
          ],
          sites: const <Site>[],
          apiKeys: const <String, String>{'srv1': 'replacement-key', 'srv2': 'new-key'},
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(repo.state.servers.single.id, 'srv1');
    expect(repo.state.sites.single.domain, 'old.example.com');
    expect(await repo.getApiKey('srv1'), 'old-key');
    expect(await repo.getApiKey('srv2'), isNull);

    final ConfigRepository reloaded = ConfigRepository(prefs: prefs, keyStore: keyStore);
    expect(reloaded.state.servers.single.id, 'srv1');
    expect(reloaded.state.sites.single.domain, 'old.example.com');
  });

  test('replaceAll restores existing keys when outgoing key cleanup fails', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final FakeKeyStore keyStore = FakeKeyStore();
    final ConfigRepository repo = ConfigRepository(prefs: prefs, keyStore: keyStore);
    await repo.addServer(buildServer(), 'old-key');
    await repo.addServer(buildServer(id: 'srv2'), 'removed-key');
    keyStore.deleteFailures.add('apikey_srv2');

    await expectLater(
      repo.replaceAll(
        BackupPayload(
          servers: <Server>[buildServer()],
          sites: const <Site>[],
          apiKeys: const <String, String>{'srv1': 'replacement-key'},
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(repo.state.servers.map((Server server) => server.id), <String>['srv1', 'srv2']);
    expect(await repo.getApiKey('srv1'), 'old-key');
    expect(await repo.getApiKey('srv2'), 'removed-key');

    final ConfigRepository reloaded = ConfigRepository(prefs: prefs, keyStore: keyStore);
    expect(reloaded.state.servers.map((Server server) => server.id), <String>['srv1', 'srv2']);
  });
}
