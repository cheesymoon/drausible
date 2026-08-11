import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/models/date_range.dart';
import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';
import 'package:drausible/src/providers/config_providers.dart';
import 'package:drausible/src/providers/stats_providers.dart';
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

Future<String> _fixture(String name) => File('test/fixtures/$name').readAsString();

final Server _server = Server(id: 'srv1', name: 'My server', baseUrl: Uri.parse('https://plausible.example.org'));
final Site _site = Site(id: 'site1', serverId: 'srv1', domain: 'example.com');
const ({String serverId, String siteId, DateRangeSel range}) _overviewArgs = (
  serverId: 'srv1',
  siteId: 'site1',
  range: DateRangeSel.d30(),
);

/// The probe is the only v2 request that asks for a single metric and no
/// dimension.
bool _isV2Probe(http.Request request) {
  if (request.url.path != '/api/v2/query') return false;
  final Map<String, dynamic> body = jsonDecode(request.body) as Map<String, dynamic>;
  return !body.containsKey('dimensions') && (body['metrics'] as List<dynamic>).length == 1;
}

/// Answers whichever v2 query came in, probe included.
Future<http.Response> _v2Reply(http.Request request) async {
  if (_isV2Probe(request)) return http.Response('{}', 200);
  final Map<String, dynamic> body = jsonDecode(request.body) as Map<String, dynamic>;
  if (body.containsKey('dimensions')) return http.Response(await _fixture('v2_timeseries.json'), 200);
  return http.Response(await _fixture('v2_aggregate.json'), 200);
}

Future<ProviderContainer> _container({
  List<Override> overrides = const <Override>[],
  ApiVersion apiVersion = ApiVersion.unknown,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'config_v1': jsonEncode(<String, dynamic>{
      'schemaVersion': 1,
      'servers': <dynamic>[_server.copyWith(apiVersion: apiVersion).toJson()],
      'sites': <dynamic>[_site.toJson()],
    }),
  });
  final FakeKeyStore keyStore = FakeKeyStore()..values['apikey_srv1'] = 'secret-key';
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[keyStoreProvider.overrideWithValue(keyStore), ...overrides],
  );
  addTearDown(container.dispose);
  // configProvider reads the repository through valueOrNull. Until this
  // resolves the config is still empty.
  await container.read(configRepositoryProvider.future);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('RateLimitGate suspends a tripped server until its cooldown lapses', () {
    DateTime now = DateTime(2026);
    final RateLimitGate gate = RateLimitGate(now: () => now);

    expect(gate.isSuspended('srv1'), isFalse);

    gate.trip('srv1');

    expect(gate.isSuspended('srv1'), isTrue);
    expect(gate.isSuspended('srv2'), isFalse);

    now = now.add(RateLimitGate.cooldown);

    expect(gate.isSuspended('srv1'), isFalse);
  });

  test('a stats fetch that is rate limited trips the gate and still throws', () async {
    final MockClient client = MockClient((http.Request request) async => http.Response('{}', 429));
    final ProviderContainer container = await _container(
      overrides: <Override>[httpClientProvider('srv1').overrideWithValue(client)],
      apiVersion: ApiVersion.v2,
    );

    await expectLater(
      container.read(statsRepositoryProvider).aggregate(_server, _site, const DateRangeSel.day()),
      throwsA(isA<RateLimitedException>()),
    );

    expect(container.read(rateLimitGateProvider).isSuspended('srv1'), isTrue);
  });

  test('realtimeProvider skips the first poll while the server is suspended', () async {
    final RateLimitGate gate = RateLimitGate()..trip('srv1');
    final List<http.Request> requests = <http.Request>[];
    final MockClient client = MockClient((http.Request request) async {
      requests.add(request);
      return http.Response('0', 200);
    });
    final ProviderContainer container = await _container(
      overrides: <Override>[
        rateLimitGateProvider.overrideWithValue(gate),
        httpClientProvider('srv1').overrideWithValue(client),
      ],
    );

    final ProviderSubscription<AsyncValue<int>> subscription = container.listen(
      realtimeProvider((serverId: 'srv1', siteId: 'site1')),
      (AsyncValue<int>? previous, AsyncValue<int> next) {},
    );
    addTearDown(subscription.close);
    await pumpEventQueue();

    expect(requests, isEmpty);
    // Skipped quietly, the badge would keep whatever it last showed.
    expect(container.read(realtimeProvider((serverId: 'srv1', siteId: 'site1'))).hasError, isTrue);
  });

  // Fake time, so the 30s tick can be reached without waiting for it.
  testWidgets('a rate limited tick reaches the stream, unlike other late failures', (WidgetTester tester) async {
    int calls = 0;
    final MockClient client = MockClient((http.Request request) async {
      calls++;
      if (calls == 1) return http.Response('7', 200);
      return http.Response('{}', 429);
    });
    final ProviderContainer container = await _container(
      overrides: <Override>[httpClientProvider('srv1').overrideWithValue(client)],
    );
    const ({String serverId, String siteId}) args = (serverId: 'srv1', siteId: 'site1');
    final ProviderSubscription<AsyncValue<int>> subscription = container.listen(
      realtimeProvider(args),
      (AsyncValue<int>? previous, AsyncValue<int> next) {},
    );

    await tester.pump();
    expect(container.read(realtimeProvider(args)).valueOrNull, 7);

    await tester.pump(const Duration(seconds: 30));
    await tester.pump();

    expect(container.read(realtimeProvider(args)).hasError, isTrue);
    expect(container.read(rateLimitGateProvider).isSuspended('srv1'), isTrue);

    // Dropping the last listener is what cancels the polling timer, and that
    // has to happen inside the test: the container's teardown runs after the
    // binding has already checked for stray timers.
    subscription.close();
    await tester.idle();
  });

  test('a probed v2 is persisted once, and the re-run rides the cache', () async {
    final List<http.Request> requests = <http.Request>[];
    final MockClient client = MockClient((http.Request request) async {
      requests.add(request);
      return _v2Reply(request);
    });
    final ProviderContainer container = await _container(
      overrides: <Override>[httpClientProvider('srv1').overrideWithValue(client)],
    );
    int configWrites = 0;
    container.listen(configProvider, (ConfigState? previous, ConfigState next) => configWrites++);
    // Keep the provider alive past the fetch so the config write re-runs it.
    container.listen(
      overviewProvider(_overviewArgs),
      (AsyncValue<OverviewData>? previous, AsyncValue<OverviewData> next) {},
    );

    await container.read(overviewProvider(_overviewArgs).future);
    await pumpEventQueue();

    expect(container.read(configProvider).servers.single.apiVersion, ApiVersion.v2);
    // Aggregate and timeseries both settle on the same probe; only one writes.
    expect(configWrites, 1);
    // Probe, aggregate, timeseries, and nothing more, because the re-run the
    // write set off is served by the 60s cache.
    expect(requests, hasLength(3));
  });

  test('a probed v1 is persisted only once the v1 route has answered', () async {
    final List<http.Request> requests = <http.Request>[];
    final MockClient client = MockClient((http.Request request) async {
      requests.add(request);
      if (request.url.path == '/api/v2/query') {
        return http.Response('<html><body>404 not found</body></html>', 404);
      }
      if (request.url.path == '/api/v1/stats/timeseries') {
        return http.Response(await _fixture('v1_timeseries.json'), 200);
      }
      return http.Response(await _fixture('v1_aggregate.json'), 200);
    });
    final ProviderContainer container = await _container(
      overrides: <Override>[httpClientProvider('srv1').overrideWithValue(client)],
    );
    int requestsWhenWritten = 0;
    container.listen(
      configProvider,
      (ConfigState? previous, ConfigState next) => requestsWhenWritten = requests.length,
    );

    await container.read(overviewProvider(_overviewArgs).future);
    await pumpEventQueue();

    expect(container.read(configProvider).servers.single.apiVersion, ApiVersion.v1);
    // v2 probe, v1 probe, then the aggregate and timeseries the screen asked
    // for: the version is written after the request that carried the probe,
    // never on the 404 alone.
    expect(requestsWhenWritten, 4);
  });

  test('a version forgotten by a re-check is detected and persisted again', () async {
    final List<http.Request> requests = <http.Request>[];
    final MockClient client = MockClient((http.Request request) async {
      requests.add(request);
      return _v2Reply(request);
    });
    final ProviderContainer container = await _container(
      overrides: <Override>[httpClientProvider('srv1').overrideWithValue(client)],
    );

    await container.read(overviewProvider(_overviewArgs).future);
    await pumpEventQueue();
    expect(container.read(configProvider).servers.single.apiVersion, ApiVersion.v2);

    // What "Re-check" does: forget the version, drop the resolver holding it,
    // and clear the stats that were fetched with it.
    await container.read(configProvider.notifier).updateServer(_server.copyWith(apiVersion: ApiVersion.unknown));
    container.invalidate(apiVersionResolverProvider('srv1'));
    container.read(statsRepositoryProvider).evictSite('srv1', 'example.com');

    await container.read(overviewProvider(_overviewArgs).future);
    await pumpEventQueue();

    expect(requests.where(_isV2Probe), hasLength(2));
    expect(container.read(configProvider).servers.single.apiVersion, ApiVersion.v2);
  });

  test('a server that 404s on both routes keeps its unknown version', () async {
    final MockClient client = MockClient((http.Request request) async => http.Response('{}', 404));
    final ProviderContainer container = await _container(
      overrides: <Override>[httpClientProvider('srv1').overrideWithValue(client)],
    );
    int configWrites = 0;
    container.listen(configProvider, (ConfigState? previous, ConfigState next) => configWrites++);

    await expectLater(
      container.read(overviewProvider(_overviewArgs).future),
      throwsA(isA<NotFoundEndpointException>()),
    );
    await pumpEventQueue();

    expect(container.read(configProvider).servers.single.apiVersion, ApiVersion.unknown);
    expect(configWrites, 0);
  });

  test('a server persisted as v1 is not probed again', () async {
    final List<http.Request> requests = <http.Request>[];
    final MockClient client = MockClient((http.Request request) async {
      requests.add(request);
      if (request.url.path == '/api/v1/stats/timeseries') {
        return http.Response(await _fixture('v1_timeseries.json'), 200);
      }
      return http.Response(await _fixture('v1_aggregate.json'), 200);
    });
    final ProviderContainer container = await _container(
      overrides: <Override>[httpClientProvider('srv1').overrideWithValue(client)],
      apiVersion: ApiVersion.v1,
    );

    await container.read(overviewProvider(_overviewArgs).future);

    expect(requests, hasLength(2));
    expect(requests.every((http.Request r) => r.url.path.startsWith('/api/v1/')), isTrue);
  });

  test('renaming a server keeps its http client', () async {
    final ProviderContainer container = await _container();
    container.listen(httpClientProvider('srv1'), (http.Client? previous, http.Client next) {});
    final http.Client before = container.read(httpClientProvider('srv1'));

    await container.read(configProvider.notifier).updateServer(_server.copyWith(name: 'Renamed'));

    expect(container.read(configProvider).servers.single.name, 'Renamed');
    // Closing the client would abort whatever it has in flight, and a probe
    // result lands on the server record the same way a rename does.
    expect(container.read(httpClientProvider('srv1')), same(before));
  });

  test('changing the proxy does rebuild its http client', () async {
    final ProviderContainer container = await _container();
    container.listen(httpClientProvider('srv1'), (http.Client? previous, http.Client next) {});
    final http.Client before = container.read(httpClientProvider('srv1'));

    await container
        .read(configProvider.notifier)
        .updateServer(_server.copyWith(proxy: ProxyConfig(host: '127.0.0.1', port: 9050)));

    expect(container.read(httpClientProvider('srv1')), isNot(same(before)));
  });
}
