import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';
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
}
