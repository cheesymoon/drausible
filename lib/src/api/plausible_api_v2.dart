// PlausibleApi over the v2 /api/v2/query endpoint (single query shape for
// aggregate/timeseries/breakdown, distinguished by metrics/dimensions).

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/date_range.dart';
import '../models/stats.dart';
import 'api_exception.dart';
import 'api_http.dart';
import 'plausible_api.dart';

class PlausibleApiV2 implements PlausibleApi {
  PlausibleApiV2(this._client, Uri baseUrl, this._apiKey, {bool isProxied = false})
    : _queryUrl = joinApiPath(baseUrl, '/api/v2/query'),
      _isProxied = isProxied;

  final http.Client _client;
  final String _apiKey;
  final Uri _queryUrl;
  final bool _isProxied;

  @override
  Future<AggregateStats> aggregate(String siteId, DateRangeSel range) async {
    final _QueryResponse response = await _query(<String, dynamic>{
      'site_id': siteId,
      'metrics': const <String>['visitors', 'visits', 'pageviews', 'views_per_visit', 'bounce_rate', 'visit_duration'],
      'date_range': range.v2DateRange,
    });
    try {
      final List<dynamic> results = response.json['results'] as List<dynamic>;
      final List<dynamic> metrics = (results.first as Map<String, dynamic>)['metrics'] as List<dynamic>;
      // Positional, in the order the metrics were requested. A range with no
      // traffic can report one as null, views/visit especially since it is a
      // ratio, and that is a zero rather than a broken response.
      return AggregateStats(
        visitors: _at(metrics, 0)?.toInt() ?? 0,
        visits: _at(metrics, 1)?.toInt() ?? 0,
        pageviews: _at(metrics, 2)?.toInt() ?? 0,
        viewsPerVisit: _at(metrics, 3)?.toDouble() ?? 0,
        bounceRate: _at(metrics, 4)?.toDouble() ?? 0,
        visitDurationSeconds: _at(metrics, 5)?.toInt() ?? 0,
      );
    } catch (_) {
      throw ServerException(response.statusCode);
    }
  }

  // Null for a short row or a null entry; the caller decides what that means.
  num? _at(List<dynamic> metrics, int index) {
    if (index >= metrics.length) return null;
    final dynamic value = metrics[index];
    return value is num ? value : null;
  }

  @override
  Future<List<TimeseriesPoint>> timeseries(String siteId, DateRangeSel range) async {
    final _QueryResponse response = await _query(<String, dynamic>{
      'site_id': siteId,
      'metrics': const <String>['visitors'],
      'date_range': range.v2DateRange,
      'dimensions': <String>[range.timeDimension],
      'include': const <String, dynamic>{'time_labels': true},
    });
    try {
      final Map<String, dynamic> meta = response.json['meta'] as Map<String, dynamic>;
      final List<dynamic> timeLabels = meta['time_labels'] as List<dynamic>;
      final List<dynamic> results = response.json['results'] as List<dynamic>;
      // Gap-fill: a label with no matching results row means 0 visitors.
      final Map<String, int> visitorsByLabel = <String, int>{
        for (final dynamic row in results)
          ((row as Map<String, dynamic>)['dimensions'] as List<dynamic>)[0] as String:
              ((row['metrics'] as List<dynamic>)[0] as num).toInt(),
      };
      return <TimeseriesPoint>[
        for (final dynamic label in timeLabels)
          TimeseriesPoint(time: range.parseTimeLabel(label as String), visitors: visitorsByLabel[label] ?? 0),
      ];
    } catch (_) {
      throw ServerException(response.statusCode);
    }
  }

  @override
  Future<List<BreakdownRow>> breakdown(
    String siteId,
    DateRangeSel range,
    BreakdownDimension dimension, {
    int limit = 15,
  }) async {
    final _QueryResponse response = await _query(<String, dynamic>{
      'site_id': siteId,
      'metrics': const <String>['visitors'],
      'date_range': range.v2DateRange,
      'dimensions': <String>[dimension.v2Dimension],
      'order_by': const <List<String>>[
        <String>['visitors', 'desc'],
      ],
      // One extra for UTM, so the list is still full after the placeholder
      // row goes.
      'pagination': <String, dynamic>{'limit': dimension.isUtm ? limit + 1 : limit},
    });
    try {
      final List<dynamic> results = response.json['results'] as List<dynamic>;
      final List<BreakdownRow> rows = <BreakdownRow>[];
      for (final dynamic row in results) {
        final dynamic name = ((row as Map<String, dynamic>)['dimensions'] as List<dynamic>)[0];
        // Visits without a UTM tag come back as one "(not set)" row, usually
        // the biggest by far. The web dashboard leaves it out, and so does v1
        // on current servers. Browser and OS keep theirs, since the web shows
        // those.
        // A server with no GeoIP database sends country as an empty string.
        // Nothing to label those with, so they go and the rest of the report
        // stays.
        if (name is! String || name.isEmpty) continue;
        if (name == '(not set)' && dimension.isUtm) continue;
        rows.add(BreakdownRow(name: name, visitors: ((row['metrics'] as List<dynamic>)[0] as num).toInt()));
      }
      return rows.take(limit).toList();
    } catch (_) {
      throw ServerException(response.statusCode);
    }
  }

  // Imported data (from Google Analytics or a CSV) only counts when a query
  // asks for it, so every query does. Otherwise the numbers start at the day
  // the site moved to Plausible.
  Future<_QueryResponse> _query(Map<String, dynamic> body) async {
    final http.Response response = await _send(<String, dynamic>{
      ...body,
      'include': <String, dynamic>{...?body['include'] as Map<String, dynamic>?, 'imports': true},
    });
    return _QueryResponse(response.statusCode, _decodeBody(response));
  }

  Future<http.Response> _send(Map<String, dynamic> body) {
    return sendRequest(
      _queryUrl,
      isProxied: _isProxied,
      send: () => _client.post(
        _queryUrl,
        headers: <String, String>{'Authorization': 'Bearer $_apiKey', 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
  }

  Map<String, dynamic> _decodeBody(http.Response response) {
    throwForStatusCode(response.statusCode);
    try {
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('response body is not an object');
      }
      return decoded;
    } on FormatException {
      throw ServerException(response.statusCode);
    }
  }
}

class _QueryResponse {
  _QueryResponse(this.statusCode, this.json);

  final int statusCode;
  final Map<String, dynamic> json;
}
