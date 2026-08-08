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
      'metrics': const <String>['visitors', 'pageviews', 'bounce_rate', 'visit_duration'],
      'date_range': range.v2DateRange,
    });
    try {
      final List<dynamic> results = response.json['results'] as List<dynamic>;
      final List<dynamic> metrics = (results.first as Map<String, dynamic>)['metrics'] as List<dynamic>;
      return AggregateStats(
        visitors: (metrics[0] as num).toInt(),
        pageviews: (metrics[1] as num).toInt(),
        bounceRate: (metrics[2] as num).toDouble(),
        visitDurationSeconds: (metrics[3] as num).toInt(),
      );
    } catch (_) {
      throw ServerException(response.statusCode);
    }
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
          TimeseriesPoint(
            time: range.parseTimeLabel(label as String),
            visitors: visitorsByLabel[label] ?? 0,
          ),
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
      'order_by': const <List<String>>[<String>['visitors', 'desc']],
      'pagination': <String, dynamic>{'limit': limit},
    });
    try {
      final List<dynamic> results = response.json['results'] as List<dynamic>;
      return <BreakdownRow>[
        for (final dynamic row in results)
          BreakdownRow(
            name: ((row as Map<String, dynamic>)['dimensions'] as List<dynamic>)[0] as String,
            visitors: ((row['metrics'] as List<dynamic>)[0] as num).toInt(),
          ),
      ];
    } catch (_) {
      throw ServerException(response.statusCode);
    }
  }

  Future<_QueryResponse> _query(Map<String, dynamic> body) async {
    final http.Response response = await _send(body);
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
      if (decoded is! Map<String, dynamic>) throw const FormatException('response body is not an object');
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
