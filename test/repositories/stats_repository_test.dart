import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/api/plausible_api.dart';
import 'package:drausible/src/models/date_range.dart';
import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';
import 'package:drausible/src/models/stats.dart';
import 'package:drausible/src/repositories/stats_repository.dart';

class FakePlausibleApi implements PlausibleApi {
  int aggregateCalls = 0;
  int timeseriesCalls = 0;
  int breakdownCalls = 0;

  @override
  Future<AggregateStats> aggregate(String siteId, DateRangeSel range) async {
    aggregateCalls++;
    return AggregateStats(visitors: 0, pageviews: 0, bounceRate: 0, visitDurationSeconds: 0);
  }

  @override
  Future<List<TimeseriesPoint>> timeseries(String siteId, DateRangeSel range) async {
    timeseriesCalls++;
    return <TimeseriesPoint>[];
  }

  @override
  Future<List<BreakdownRow>> breakdown(
    String siteId,
    DateRangeSel range,
    BreakdownDimension dimension, {
    int limit = 15,
  }) async {
    breakdownCalls++;
    return <BreakdownRow>[];
  }
}

/// Holds each call open until its gate is completed, so a batch can be settled
/// one leg at a time.
class GatedPlausibleApi implements PlausibleApi {
  GatedPlausibleApi(this.aggregateGate, this.timeseriesGate);

  final Future<void> aggregateGate;
  final Future<void> timeseriesGate;

  @override
  Future<AggregateStats> aggregate(String siteId, DateRangeSel range) async {
    await aggregateGate;
    return AggregateStats(visitors: 0, pageviews: 0, bounceRate: 0, visitDurationSeconds: 0);
  }

  @override
  Future<List<TimeseriesPoint>> timeseries(String siteId, DateRangeSel range) async {
    await timeseriesGate;
    return <TimeseriesPoint>[];
  }

  @override
  Future<List<BreakdownRow>> breakdown(
    String siteId,
    DateRangeSel range,
    BreakdownDimension dimension, {
    int limit = 15,
  }) async => <BreakdownRow>[];
}

Server _buildServer({String id = 'srv1'}) =>
    Server(id: id, name: 'Test server', baseUrl: Uri.parse('https://plausible.example.org'));

Site _buildSite({String id = 'site1', String serverId = 'srv1', String domain = 'example.com'}) =>
    Site(id: id, serverId: serverId, domain: domain);

void main() {
  test('a cache hit within the 60s TTL does not call the api again', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    DateTime now = DateTime(2024, 1, 1, 12);
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => fakeApi,
      now: () => now,
    );

    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());
    now = now.add(const Duration(seconds: 59));
    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());

    expect(fakeApi.aggregateCalls, 1);
  });

  test('a cache miss past the TTL calls the api again', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    DateTime now = DateTime(2024, 1, 1, 12);
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => fakeApi,
      now: () => now,
    );

    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());
    now = now.add(const Duration(seconds: 61));
    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());

    expect(fakeApi.aggregateCalls, 2);
  });

  test('refresh: true bypasses and repopulates the cache', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => fakeApi,
    );

    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());
    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30(), refresh: true);
    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());

    // The refresh repopulated the cache, so the third call is a hit again.
    expect(fakeApi.aggregateCalls, 2);
  });

  test('aggregate and timeseries are cached separately for the same range', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => fakeApi,
    );

    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());
    await repo.timeseries(_buildServer(), _buildSite(), const DateRangeSel.d30());

    expect(fakeApi.aggregateCalls, 1);
    expect(fakeApi.timeseriesCalls, 1);
  });

  test('different ranges are cached separately', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => fakeApi,
    );

    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());
    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d7());

    expect(fakeApi.aggregateCalls, 2);
  });

  test('breakdown is cached per dimension', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => fakeApi,
    );

    await repo.breakdown(_buildServer(), _buildSite(), const DateRangeSel.d30(), BreakdownDimension.country);
    await repo.breakdown(_buildServer(), _buildSite(), const DateRangeSel.d30(), BreakdownDimension.country);
    await repo.breakdown(_buildServer(), _buildSite(), const DateRangeSel.d30(), BreakdownDimension.page);

    expect(fakeApi.breakdownCalls, 2);
  });

  test('breakdown is cached per limit', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => fakeApi,
    );

    await repo.breakdown(_buildServer(), _buildSite(), const DateRangeSel.d30(), BreakdownDimension.country, limit: 5);
    await repo.breakdown(_buildServer(), _buildSite(), const DateRangeSel.d30(), BreakdownDimension.country, limit: 15);

    expect(fakeApi.breakdownCalls, 2);
  });

  test('evictSite drops cached entries for that site only', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => fakeApi,
    );

    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());
    await repo.aggregate(_buildServer(), _buildSite(id: 'site2', domain: 'other.com'), const DateRangeSel.d30());
    repo.evictSite('srv1', 'example.com');
    await repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());
    await repo.aggregate(_buildServer(), _buildSite(id: 'site2', domain: 'other.com'), const DateRangeSel.d30());

    expect(fakeApi.aggregateCalls, 3); // example.com twice, other.com once
  });

  test('a fetch is reported once, and not until the rest of its batch lands', () async {
    final Completer<void> aggregateGate = Completer<void>();
    final Completer<void> timeseriesGate = Completer<void>();
    final List<String> reported = <String>[];
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => GatedPlausibleApi(aggregateGate.future, timeseriesGate.future),
      onFetched: (Server server) => reported.add(server.id),
    );

    final Future<List<Object>> batch = Future.wait(<Future<Object>>[
      repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30()),
      repo.timeseries(_buildServer(), _buildSite(), const DateRangeSel.d30()),
    ]);

    aggregateGate.complete();
    await pumpEventQueue();
    // Reporting here would write config and re-run the providers, restarting
    // the timeseries call that is still out as a cache miss.
    expect(reported, isEmpty);

    timeseriesGate.complete();
    await batch;

    expect(reported, <String>['srv1']);
  });

  test('a sibling that fails still lets the batch report', () async {
    final Completer<void> aggregateGate = Completer<void>();
    final Completer<void> timeseriesGate = Completer<void>();
    final List<String> reported = <String>[];
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => 'key',
      apiFactory: (Server server, String apiKey) => GatedPlausibleApi(aggregateGate.future, timeseriesGate.future),
      onFetched: (Server server) => reported.add(server.id),
    );

    final Future<AggregateStats> ok = repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30());
    final Future<List<TimeseriesPoint>> boom = repo.timeseries(_buildServer(), _buildSite(), const DateRangeSel.d30());

    aggregateGate.complete();
    await pumpEventQueue();
    expect(reported, isEmpty);

    timeseriesGate.completeError(const ServerException(500));
    await expectLater(boom, throwsA(isA<ServerException>()));
    await ok;

    expect(reported, <String>['srv1']);
  });

  test('a missing api key throws UnauthorizedException', () async {
    final FakePlausibleApi fakeApi = FakePlausibleApi();
    final StatsRepository repo = StatsRepository(
      getApiKey: (String serverId) async => null,
      apiFactory: (Server server, String apiKey) => fakeApi,
    );

    expect(
      () => repo.aggregate(_buildServer(), _buildSite(), const DateRangeSel.d30()),
      throwsA(isA<UnauthorizedException>()),
    );
  });
}
