// Fetches stats through a per-server PlausibleApi, with a short in-memory
// cache so switching between tabs/ranges doesn't re-hit the network.

import '../api/api_exception.dart';
import '../api/plausible_api.dart';
import '../models/date_range.dart';
import '../models/server.dart';
import '../models/site.dart';
import '../models/stats.dart';

const Duration _cacheTtl = Duration(seconds: 60);

typedef _CacheKey = ({
  String serverId,
  String siteDomain,
  DateRangeSel range,
  String kind,
  BreakdownDimension? dimension,
  int? limit,
});

class _CacheEntry {
  _CacheEntry(this.value, this.expiresAt);

  final Object value;
  final DateTime expiresAt;
}

class StatsRepository {
  StatsRepository({
    required Future<String?> Function(String serverId) getApiKey,
    required PlausibleApi Function(Server server, String apiKey) apiFactory,
    void Function(Server server)? onFetched,
    void Function(Server server)? onRateLimited,
    DateTime Function() now = DateTime.now,
  }) : _getApiKey = getApiKey,
       _apiFactory = apiFactory,
       _onFetched = onFetched,
       _onRateLimited = onRateLimited,
       _now = now;

  final Future<String?> Function(String serverId) _getApiKey;
  final PlausibleApi Function(Server server, String apiKey) _apiFactory;
  // Called once a server's fetches have gone quiet, if at least one of them
  // reached the network. The API version probe rides on those fetches, so this
  // is where its answer gets stored.
  final void Function(Server server)? _onFetched;
  final void Function(Server server)? _onRateLimited;
  final DateTime Function() _now;

  final Map<_CacheKey, _CacheEntry> _cache = <_CacheKey, _CacheEntry>{};
  // Loads still out per server, and the servers owed a report once theirs
  // reach zero.
  final Map<String, int> _inFlight = <String, int>{};
  final Set<String> _reportWhenQuiet = <String>{};

  Future<AggregateStats> aggregate(
    Server server,
    Site site,
    DateRangeSel range, {
    bool refresh = false,
  }) {
    final _CacheKey key = (
      serverId: server.id,
      siteDomain: site.domain,
      range: range,
      kind: 'aggregate',
      dimension: null,
      limit: null,
    );
    return _cached(server, key, refresh, () async {
      final PlausibleApi api = await _apiFor(server);
      return api.aggregate(site.domain, range);
    });
  }

  Future<List<TimeseriesPoint>> timeseries(
    Server server,
    Site site,
    DateRangeSel range, {
    bool refresh = false,
  }) {
    final _CacheKey key = (
      serverId: server.id,
      siteDomain: site.domain,
      range: range,
      kind: 'timeseries',
      dimension: null,
      limit: null,
    );
    return _cached(server, key, refresh, () async {
      final PlausibleApi api = await _apiFor(server);
      return api.timeseries(site.domain, range);
    });
  }

  Future<List<BreakdownRow>> breakdown(
    Server server,
    Site site,
    DateRangeSel range,
    BreakdownDimension dimension, {
    int limit = 15,
    bool refresh = false,
  }) {
    final _CacheKey key = (
      serverId: server.id,
      siteDomain: site.domain,
      range: range,
      kind: 'breakdown',
      dimension: dimension,
      limit: limit,
    );
    return _cached(server, key, refresh, () async {
      final PlausibleApi api = await _apiFor(server);
      return api.breakdown(site.domain, range, dimension, limit: limit);
    });
  }

  /// Drops every cached entry for one site. Pull-to-refresh calls this so the
  /// re-fetch actually hits the network instead of the 60s cache.
  void evictSite(String serverId, String siteDomain) {
    _cache.removeWhere(
      (_CacheKey key, _) => key.serverId == serverId && key.siteDomain == siteDomain,
    );
  }

  Future<T> _cached<T extends Object>(
    Server server,
    _CacheKey key,
    bool refresh,
    Future<T> Function() load,
  ) async {
    if (!refresh) {
      final _CacheEntry? entry = _cache[key];
      if (entry != null && _now().isBefore(entry.expiresAt)) {
        return entry.value as T;
      }
    }
    _inFlight[server.id] = (_inFlight[server.id] ?? 0) + 1;
    try {
      final T value = await load();
      _cache[key] = _CacheEntry(value, _now().add(_cacheTtl));
      _reportWhenQuiet.add(server.id);
      return value;
    } on RateLimitedException {
      _onRateLimited?.call(server);
      rethrow;
    } finally {
      _settle(server);
    }
  }

  /// Drops one in-flight load and reports the server once its last one lands.
  ///
  /// Waiting for quiet is the point. The report persists a probed API version,
  /// which writes config and re-runs every stats provider; firing it while a
  /// sibling of the same Future.wait is still out would restart that sibling as
  /// a cache miss and double the requests the shared probe exists to save.
  void _settle(Server server) {
    final int left = (_inFlight[server.id] ?? 1) - 1;
    if (left > 0) {
      _inFlight[server.id] = left;
      return;
    }
    _inFlight.remove(server.id);
    if (_reportWhenQuiet.remove(server.id)) _onFetched?.call(server);
  }

  Future<PlausibleApi> _apiFor(Server server) async {
    final String? apiKey = await _getApiKey(server.id);
    if (apiKey == null) throw const UnauthorizedException();
    return _apiFactory(server, apiKey);
  }
}
