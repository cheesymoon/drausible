// PlausibleApi over the legacy v1 stats endpoints (one GET route per report,
// with the window carried by the period/date query parameters).

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/date_range.dart';
import '../models/stats.dart';
import 'api_exception.dart';
import 'api_http.dart';
import 'plausible_api.dart';

class PlausibleApiV1 implements PlausibleApi {
  PlausibleApiV1(this._client, this._baseUrl, this._apiKey, {bool isProxied = false}) : _isProxied = isProxied;

  final http.Client _client;
  final Uri _baseUrl;
  final String _apiKey;
  final bool _isProxied;

  @override
  Future<AggregateStats> aggregate(String siteId, DateRangeSel range) async {
    final _V1Response response = await _get(
      '/api/v1/stats/aggregate',
      siteId,
      range,
      const <String, String>{'metrics': 'visitors,pageviews,bounce_rate,visit_duration'},
    );
    try {
      final Map<String, dynamic> results = response.json['results'] as Map<String, dynamic>;
      return AggregateStats(
        visitors: _metric(results, 'visitors').toInt(),
        pageviews: _metric(results, 'pageviews').toInt(),
        bounceRate: _metric(results, 'bounce_rate').toDouble(),
        visitDurationSeconds: _metric(results, 'visit_duration').toInt(),
      );
    } catch (_) {
      throw ServerException(response.statusCode);
    }
  }

  @override
  Future<List<TimeseriesPoint>> timeseries(String siteId, DateRangeSel range) async {
    // No interval parameter: v1 only accepts day/month there and rejects hour
    // with a 400, so the server's own default per period is the one that works.
    final _V1Response response = await _get(
      '/api/v1/stats/timeseries',
      siteId,
      range,
      const <String, String>{'metrics': 'visitors'},
    );
    try {
      final List<dynamic> results = response.json['results'] as List<dynamic>;
      // No gap-fill here: v1 has no meta.time_labels and fills empty buckets
      // itself.
      final List<TimeseriesPoint> points = <TimeseriesPoint>[];
      for (final dynamic row in results) {
        if (row is! Map<String, dynamic>) continue;
        final DateTime? time = _time(range, row['date']);
        // Nothing to plot a point against, so it goes — the rest of the chart
        // shouldn't fall over one unreadable bucket.
        if (time == null) continue;
        points.add(TimeseriesPoint(time: time, visitors: _count(row['visitors'])));
      }
      return points;
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
    // v1's "property" takes the same identifiers as v2's dimensions, and keys
    // each result row by the segment after the colon ("event:page" -> "page").
    final String property = dimension.v2Dimension;
    final String rowKey = property.split(':').last;
    final _V1Response response = await _get('/api/v1/stats/breakdown', siteId, range, <String, String>{
      'property': property,
      'metrics': 'visitors',
      'limit': '$limit',
    });
    try {
      final List<dynamic> results = response.json['results'] as List<dynamic>;
      final List<BreakdownRow> rows = <BreakdownRow>[];
      for (final dynamic row in results) {
        if (row is! Map<String, dynamic>) continue;
        final dynamic name = row[rowKey];
        // A server with no GeoIP database sends country as null or empty.
        // There is nothing to label such a row with, so drop it and keep the
        // rest of the report.
        if (name is! String || name.isEmpty) continue;
        rows.add(BreakdownRow(name: name, visitors: _count(row['visitors'])));
      }
      return rows;
    } catch (_) {
      throw ServerException(response.statusCode);
    }
  }

  // Aggregate results are keyed by metric name rather than positional as in
  // v2, so they are read by key — the order is not guaranteed. A range with no
  // traffic can report a metric as null or leave it out; both mean 0.
  num _metric(Map<String, dynamic> results, String name) {
    final dynamic metric = results[name];
    if (metric is! Map<String, dynamic>) return 0;
    final dynamic value = metric['value'];
    return value is num ? value : 0;
  }

  // Same story a row at a time: a bucket or a segment with no traffic can come
  // back with visitors null or missing, and both mean 0.
  int _count(dynamic value) => value is num ? value.toInt() : 0;

  // Null, missing, or not a date at all — the caller drops the row instead of
  // losing the whole series to it.
  DateTime? _time(DateRangeSel range, dynamic value) {
    if (value is! String) return null;
    try {
      return range.parseTimeLabel(value);
    } on FormatException {
      return null;
    }
  }

  Future<_V1Response> _get(
    String path,
    String siteId,
    DateRangeSel range,
    Map<String, String> params,
  ) async {
    final String? date = range.v1Date;
    final Uri url = joinApiPath(_baseUrl, path).replace(
      queryParameters: <String, String>{
        'site_id': siteId,
        'period': range.v1Period,
        if (date != null) 'date': date,
        ...params,
      },
    );
    final http.Response response = await _send(url);
    return _V1Response(response.statusCode, _decodeBody(response));
  }

  Future<http.Response> _send(Uri url) {
    return sendRequest(
      url,
      isProxied: _isProxied,
      send: () => _client.get(url, headers: <String, String>{'Authorization': 'Bearer $_apiKey'}),
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

class _V1Response {
  _V1Response(this.statusCode, this.json);

  final int statusCode;
  final Map<String, dynamic> json;
}
