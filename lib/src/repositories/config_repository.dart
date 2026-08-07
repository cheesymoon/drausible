// Sole owner of persisted config: servers + sites go in one shared_preferences
// document, API keys go in secure storage keyed per server.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server.dart';
import '../models/site.dart';

const int _schemaVersion = 1;
const String _configKey = 'config_v1';

/// Immutable snapshot of the loaded config.
class ConfigState {
  const ConfigState({this.servers = const <Server>[], this.sites = const <Site>[]});

  static const ConfigState empty = ConfigState();

  final List<Server> servers;
  final List<Site> sites;
}

/// Minimal secure key/value interface so tests can fake it — flutter_secure_storage
/// has no official mock and hits a platform channel.
abstract class KeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureKeyStore implements KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

String _apiKeyKey(String serverId) => 'apikey_$serverId';

class ConfigRepository {
  ConfigRepository({required SharedPreferences prefs, required KeyStore keyStore})
    : _prefs = prefs,
      _keyStore = keyStore,
      _state = _readState(prefs);

  final SharedPreferences _prefs;
  final KeyStore _keyStore;
  ConfigState _state;

  ConfigState get state => _state;

  static ConfigState _readState(SharedPreferences prefs) {
    final String? raw = prefs.getString(_configKey);
    if (raw == null) return ConfigState.empty;
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
    final List<dynamic> serversJson = json['servers'] as List<dynamic>? ?? <dynamic>[];
    final List<dynamic> sitesJson = json['sites'] as List<dynamic>? ?? <dynamic>[];
    return ConfigState(
      servers: <Server>[
        for (final dynamic s in serversJson) Server.fromJson(s as Map<String, dynamic>),
      ],
      sites: <Site>[for (final dynamic s in sitesJson) Site.fromJson(s as Map<String, dynamic>)],
    );
  }

  Future<void> _persist() async {
    final Map<String, dynamic> json = <String, dynamic>{
      'schemaVersion': _schemaVersion,
      'servers': <dynamic>[for (final Server s in _state.servers) s.toJson()],
      'sites': <dynamic>[for (final Site s in _state.sites) s.toJson()],
    };
    await _prefs.setString(_configKey, jsonEncode(json));
  }

  Future<ConfigState> addServer(Server server, String apiKey) async {
    await _keyStore.write(_apiKeyKey(server.id), apiKey);
    _state = ConfigState(servers: <Server>[..._state.servers, server], sites: _state.sites);
    await _persist();
    return _state;
  }

  /// apiKey left null keeps the server's existing key.
  Future<ConfigState> updateServer(Server server, {String? apiKey}) async {
    if (apiKey != null) {
      await _keyStore.write(_apiKeyKey(server.id), apiKey);
    }
    _state = ConfigState(
      servers: <Server>[for (final Server s in _state.servers) s.id == server.id ? server : s],
      sites: _state.sites,
    );
    await _persist();
    return _state;
  }

  Future<ConfigState> deleteServer(String id) async {
    await _keyStore.delete(_apiKeyKey(id));
    _state = ConfigState(
      servers: <Server>[for (final Server s in _state.servers) if (s.id != id) s],
      sites: <Site>[for (final Site s in _state.sites) if (s.serverId != id) s],
    );
    await _persist();
    return _state;
  }

  Future<ConfigState> addSite(Site site) async {
    _state = ConfigState(servers: _state.servers, sites: <Site>[..._state.sites, site]);
    await _persist();
    return _state;
  }

  Future<ConfigState> updateSite(Site site) async {
    _state = ConfigState(
      servers: _state.servers,
      sites: <Site>[for (final Site s in _state.sites) s.id == site.id ? site : s],
    );
    await _persist();
    return _state;
  }

  Future<ConfigState> deleteSite(String id) async {
    _state = ConfigState(
      servers: _state.servers,
      sites: <Site>[for (final Site s in _state.sites) if (s.id != id) s],
    );
    await _persist();
    return _state;
  }

  Future<String?> getApiKey(String serverId) => _keyStore.read(_apiKeyKey(serverId));
}
