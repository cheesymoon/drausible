// Picks the stats client a server needs. A server nobody has probed yet gets
// one minimal POST to /api/v2/query; a 404 there, and only a 404, sends the
// probe on to the v1 route, and the answer is remembered per server.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/date_range.dart';
import '../models/server.dart';
import '../models/stats.dart';
import 'api_exception.dart';
import 'api_http.dart';
import 'plausible_api.dart';
import 'plausible_api_v1.dart';
import 'plausible_api_v2.dart';

/// One per server: holds the detected [ApiVersion] and the single probe that
/// finds it out.
class ApiVersionResolver {
  ApiVersionResolver([this._version = ApiVersion.unknown]);

  ApiVersion _version;
  Future<ApiVersion>? _inFlight;
  // Bumped on every reset, so a probe that finishes after one can tell its
  // slot was taken away from it.
  int _generation = 0;

  ApiVersion get version => _version;

  /// Runs [probe] only while the version is unknown, and only once at a time.
  /// The sharing carries weight: opening the site list asks every visible row
  /// for an aggregate and a timeseries at the same moment, and each of those
  /// would otherwise probe on its own, a dozen wasted 404s against a budget
  /// of 600 requests an hour.
  Future<ApiVersion> resolve(Future<ApiVersion> Function() probe) {
    if (_version != ApiVersion.unknown) return Future<ApiVersion>.value(_version);
    return _inFlight ??= _probeOnce(probe);
  }

  /// Back to undetected, in-flight probe included. Used by "Re-check", and by
  /// a v1 route answering 404: whatever pinned the server to v1 no longer
  /// holds.
  void reset() {
    _version = ApiVersion.unknown;
    _inFlight = null;
    _generation++;
  }

  Future<ApiVersion> _probeOnce(Future<ApiVersion> Function() probe) async {
    final int generation = _generation;
    try {
      final ApiVersion version = await probe();
      _version = version;
      return version;
    } finally {
      // Cleared either way: an inconclusive probe (both routes 404, a dropped
      // connection) leaves the server unknown and probeable again. Only if the
      // slot is still this probe's, though. A reset since then may have let a
      // newer one take it, and clearing that would let a third probe start
      // alongside it.
      if (generation == _generation) _inFlight = null;
    }
  }
}

/// [PlausibleApi] that sends each call to whichever concrete client the server
/// turned out to need, probing first when that isn't known yet.
class PlausibleApiWithFallback implements PlausibleApi {
  PlausibleApiWithFallback(
    http.Client client,
    Uri baseUrl,
    String apiKey, {
    required ApiVersionResolver resolver,
    bool isProxied = false,
  }) : _client = client,
       _apiKey = apiKey,
       _resolver = resolver,
       _isProxied = isProxied,
       _v2ProbeUrl = joinApiPath(baseUrl, '/api/v2/query'),
       _v1ProbeUrl = joinApiPath(baseUrl, '/api/v1/stats/aggregate'),
       _v2 = PlausibleApiV2(client, baseUrl, apiKey, isProxied: isProxied),
       _v1 = PlausibleApiV1(client, baseUrl, apiKey, isProxied: isProxied);

  final http.Client _client;
  final String _apiKey;
  final ApiVersionResolver _resolver;
  final bool _isProxied;
  final Uri _v2ProbeUrl;
  final Uri _v1ProbeUrl;
  final PlausibleApiV2 _v2;
  final PlausibleApiV1 _v1;

  @override
  Future<AggregateStats> aggregate(String siteId, DateRangeSel range) async {
    final ApiVersion version = await _resolver.resolve(() => _probe(siteId));
    if (version == ApiVersion.v1) return _watchForV1Gone(() => _v1.aggregate(siteId, range));
    return _v2.aggregate(siteId, range);
  }

  @override
  Future<List<TimeseriesPoint>> timeseries(String siteId, DateRangeSel range) async {
    final ApiVersion version = await _resolver.resolve(() => _probe(siteId));
    if (version == ApiVersion.v1) return _watchForV1Gone(() => _v1.timeseries(siteId, range));
    return _v2.timeseries(siteId, range);
  }

  @override
  Future<List<BreakdownRow>> breakdown(
    String siteId,
    DateRangeSel range,
    BreakdownDimension dimension, {
    int limit = 15,
  }) async {
    final ApiVersion version = await _resolver.resolve(() => _probe(siteId));
    if (version == ApiVersion.v1) {
      return _watchForV1Gone(() => _v1.breakdown(siteId, range, dimension, limit: limit));
    }
    return _v2.breakdown(siteId, range, dimension, limit: limit);
  }

  /// Asks each route the cheapest question it accepts. This is "is this
  /// endpoint here", not a request for data. The real call follows.
  Future<ApiVersion> _probe(String siteId) async {
    try {
      await _sendProbe(
        _v2ProbeUrl,
        () => _client.post(
          _v2ProbeUrl,
          headers: <String, String>{
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'site_id': siteId,
            'metrics': const <String>['visitors'],
            'date_range': 'day',
          }),
        ),
      );
      return ApiVersion.v2;
    } on NotFoundEndpointException {
      // The one answer that means "no v2 route here". A legacy server returns
      // 404 with an HTML body, so it's the status that's read. Everything else
      // leaves the question open and propagates untouched: a site_id this
      // server doesn't have answers 401, a captive portal answers 200 with
      // HTML, a dropped circuit answers nothing at all.
    }

    final Uri url = _v1ProbeUrl.replace(
      queryParameters: <String, String>{'site_id': siteId, 'period': 'day', 'metrics': 'visitors'},
    );
    // v1 has to answer for real before the server is pinned to it. A 404 on
    // its own is just as easily a wrong base url or a proxy in the way, and
    // pinning on that would keep a healthy server on the legacy API forever.
    await _sendProbe(url, () => _client.get(url, headers: <String, String>{'Authorization': 'Bearer $_apiKey'}));
    return ApiVersion.v1;
  }

  /// A 404 from a v1 route means the pin no longer fits: the server has been
  /// upgraded, or it was never v1 in the first place. Forget it so the next
  /// call probes for v2 again.
  Future<T> _watchForV1Gone<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on NotFoundEndpointException {
      _resolver.reset();
      rethrow;
    }
  }

  /// Sends, and insists on a 2xx carrying a JSON object: a 200 of HTML is a
  /// captive portal, not an endpoint, and says nothing about which API this
  /// server speaks.
  Future<void> _sendProbe(Uri url, Future<http.Response> Function() send) async {
    final http.Response response = await sendRequest(url, isProxied: _isProxied, send: send);
    throwForStatusCode(response.statusCode);
    try {
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) throw const FormatException('response body is not an object');
    } on FormatException {
      throw ServerException(response.statusCode);
    }
  }
}
