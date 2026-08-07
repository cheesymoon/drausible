// Riverpod wiring for the config domain. No codegen — plain providers.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server.dart';
import '../models/site.dart';
import '../repositories/config_repository.dart';

/// Overridden with a fake in tests to avoid hitting the secure storage channel.
final Provider<KeyStore> keyStoreProvider = Provider<KeyStore>((ref) => SecureKeyStore());

final FutureProvider<SharedPreferences> sharedPreferencesProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

final FutureProvider<ConfigRepository> configRepositoryProvider = FutureProvider<ConfigRepository>((
  ref,
) async {
  final SharedPreferences prefs = await ref.watch(sharedPreferencesProvider.future);
  final KeyStore keyStore = ref.watch(keyStoreProvider);
  return ConfigRepository(prefs: prefs, keyStore: keyStore);
});

class ConfigNotifier extends Notifier<ConfigState> {
  @override
  ConfigState build() {
    // Rebuilds automatically once configRepositoryProvider resolves.
    final ConfigRepository? repository = ref.watch(configRepositoryProvider).valueOrNull;
    return repository?.state ?? ConfigState.empty;
  }

  Future<ConfigRepository> get _repository => ref.read(configRepositoryProvider.future);

  Future<void> addServer(Server server, String apiKey) async {
    final ConfigRepository repository = await _repository;
    state = await repository.addServer(server, apiKey);
  }

  Future<void> updateServer(Server server, {String? apiKey}) async {
    final ConfigRepository repository = await _repository;
    state = await repository.updateServer(server, apiKey: apiKey);
  }

  Future<void> deleteServer(String id) async {
    final ConfigRepository repository = await _repository;
    state = await repository.deleteServer(id);
  }

  Future<void> addSite(Site site) async {
    final ConfigRepository repository = await _repository;
    state = await repository.addSite(site);
  }

  Future<void> updateSite(Site site) async {
    final ConfigRepository repository = await _repository;
    state = await repository.updateSite(site);
  }

  Future<void> deleteSite(String id) async {
    final ConfigRepository repository = await _repository;
    state = await repository.deleteSite(id);
  }

  Future<String?> getApiKey(String serverId) async {
    final ConfigRepository repository = await _repository;
    return repository.getApiKey(serverId);
  }
}

final NotifierProvider<ConfigNotifier, ConfigState> configProvider =
    NotifierProvider<ConfigNotifier, ConfigState>(ConfigNotifier.new);
