import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/api/plausible_api_v1.dart';
import 'package:drausible/src/models/date_range.dart';
import 'package:drausible/src/models/stats.dart';

Future<String> _fixture(String name) => File('test/fixtures/$name').readAsString();

void main() {
  group('request shape', () {
    test('aggregate gets the aggregate route with site_id/period/metrics and the auth header', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v1_aggregate.json'), 200);
      });
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final AggregateStats stats = await api.aggregate('example.com', const DateRangeSel.d30());

      expect(captured!.method, 'GET');
      expect(captured!.url.path, '/api/v1/stats/aggregate');
      expect(captured!.headers['Authorization'], 'Bearer secret-key');
      expect(
        captured!.url.queryParameters,
        equals(<String, String>{
          'site_id': 'example.com',
          'period': '30d',
          'metrics': 'visitors,pageviews,bounce_rate,visit_duration',
        }),
      );
      // A preset carries its own window, so no date parameter goes out.
      expect(captured!.url.queryParameters.containsKey('date'), isFalse);
      expect(stats.visitors, 1423);
      expect(stats.pageviews, 3211);
      expect(stats.bounceRate, 47.0);
      expect(stats.visitDurationSeconds, 161);
    });

    test('a trailing slash on the base url does not duplicate', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v1_aggregate.json'), 200);
      });
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org/'), 'secret-key');

      await api.aggregate('example.com', const DateRangeSel.d30());

      expect(captured!.url.path, '/api/v1/stats/aggregate');
      expect(captured!.url.toString(), startsWith('https://plausible.example.org/api/v1/stats/aggregate?'));
    });

    test('aggregate reads metrics by key and treats a null one as 0', () async {
      // Keys deliberately out of order, as a server is free to emit them.
      const String body =
          '{"results": {"visit_duration": {"value": 90}, "bounce_rate": {"value": null}, '
          '"pageviews": {"value": 7}, "visitors": {"value": 4}}}';
      final MockClient client = MockClient((http.Request request) async => http.Response(body, 200));
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final AggregateStats stats = await api.aggregate('example.com', const DateRangeSel.d30());

      expect(stats.visitors, 4);
      expect(stats.pageviews, 7);
      expect(stats.bounceRate, 0);
      expect(stats.visitDurationSeconds, 90);
    });

    test('timeseries asks for visitors without an interval and parses date/visitors rows', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v1_timeseries.json'), 200);
      });
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<TimeseriesPoint> points = await api.timeseries('example.com', const DateRangeSel.d7());

      expect(captured!.url.path, '/api/v1/stats/timeseries');
      expect(
        captured!.url.queryParameters,
        equals(<String, String>{'site_id': 'example.com', 'period': '7d', 'metrics': 'visitors'}),
      );
      expect(points, hasLength(3));
      expect(points[0].time, DateTime(2024, 1, 13));
      expect(points[0].visitors, 10);
      expect(points[1].visitors, 0);
      expect(points[2].visitors, 25);
    });

    test('timeseries parses the space-separated timestamps of an hourly day range', () async {
      // Captured from a v1 server: a day range comes back as hourly buckets the
      // server has already zero-filled, so there is nothing to gap-fill here.
      final MockClient client = MockClient(
        (http.Request request) async => http.Response(await _fixture('v1_timeseries_hourly.json'), 200),
      );
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<TimeseriesPoint> points = await api.timeseries('example.com', const DateRangeSel.day());

      expect(points, hasLength(4));
      expect(points.first.time, DateTime(2026, 8, 8));
      expect(points.first.visitors, 0);
      expect(points.last.time, DateTime(2026, 8, 8, 10));
      expect(points.last.visitors, 13);
    });

    test('timeseries reads a null visitors count as 0 and drops a row with no date', () async {
      const String body =
          '{"results": [{"date": "2024-01-13", "visitors": null}, '
          '{"date": null, "visitors": 5}, {"visitors": 9}, {"date": "2024-01-15", "visitors": 25}]}';
      final MockClient client = MockClient((http.Request request) async => http.Response(body, 200));
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<TimeseriesPoint> points = await api.timeseries('example.com', const DateRangeSel.d7());

      expect(points, hasLength(2));
      expect(points[0].time, DateTime(2024, 1, 13));
      expect(points[0].visitors, 0);
      expect(points[1].time, DateTime(2024, 1, 15));
      expect(points[1].visitors, 25);
    });

    test('breakdown drops rows with a null or missing dimension value and keeps the rest', () async {
      // What a server with no GeoIP database sends back.
      const String body =
          '{"results": [{"country": "US", "visitors": 532}, '
          '{"country": null, "visitors": 42}, {"visitors": 17}, '
          '{"country": "", "visitors": 3}, {"country": "DE", "visitors": null}]}';
      final MockClient client = MockClient((http.Request request) async => http.Response(body, 200));
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<BreakdownRow> rows = await api.breakdown(
        'example.com',
        const DateRangeSel.d30(),
        BreakdownDimension.country,
      );

      expect(rows, hasLength(2));
      expect(rows[0].name, 'US');
      expect(rows[0].visitors, 532);
      expect(rows[1].name, 'DE');
      expect(rows[1].visitors, 0);
    });

    test('a custom range sends period=custom with the inclusive date pair', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v1_timeseries.json'), 200);
      });
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      await api.timeseries('example.com', DateRangeSel.custom(DateTime(2024, 1, 3), DateTime(2024, 2, 7)));

      expect(
        captured!.url.queryParameters,
        equals(<String, String>{
          'site_id': 'example.com',
          'period': 'custom',
          'date': '2024-01-03,2024-02-07',
          'metrics': 'visitors',
        }),
      );
    });

    test('breakdown by country sends the property and limit, and reads the post-colon row key', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v1_breakdown.json'), 200);
      });
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<BreakdownRow> rows = await api.breakdown(
        'example.com',
        const DateRangeSel.d30(),
        BreakdownDimension.country,
        limit: 10,
      );

      expect(captured!.url.path, '/api/v1/stats/breakdown');
      expect(
        captured!.url.queryParameters,
        equals(<String, String>{
          'site_id': 'example.com',
          'period': '30d',
          'property': 'visit:country',
          'metrics': 'visitors',
          'limit': '10',
        }),
      );
      expect(rows, hasLength(3));
      expect(rows[0].name, 'US');
      expect(rows[0].visitors, 532);
    });

    test('breakdown by page reads rows keyed by "page"', () async {
      const String body = '{"results": [{"page": "/blog", "visitors": 12}]}';
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(body, 200);
      });
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<BreakdownRow> rows = await api.breakdown(
        'example.com',
        const DateRangeSel.d30(),
        BreakdownDimension.page,
      );

      expect(captured!.url.queryParameters['property'], 'event:page');
      expect(captured!.url.queryParameters['limit'], '15');
      expect(rows.single.name, '/blog');
      expect(rows.single.visitors, 12);
    });
  });

  group('error mapping', () {
    PlausibleApiV1 apiReturning(int statusCode, String body) {
      final MockClient client = MockClient((http.Request request) async {
        return http.Response(body, statusCode);
      });
      return PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');
    }

    test('401 throws UnauthorizedException', () {
      final PlausibleApiV1 api = apiReturning(401, '{}');
      expect(() => api.aggregate('example.com', const DateRangeSel.d30()), throwsA(isA<UnauthorizedException>()));
    });

    test('404 throws NotFoundEndpointException', () {
      final PlausibleApiV1 api = apiReturning(404, '{}');
      expect(() => api.aggregate('example.com', const DateRangeSel.d30()), throwsA(isA<NotFoundEndpointException>()));
    });

    test('429 throws RateLimitedException', () {
      final PlausibleApiV1 api = apiReturning(429, '{}');
      expect(() => api.aggregate('example.com', const DateRangeSel.d30()), throwsA(isA<RateLimitedException>()));
    });

    test('500 throws ServerException with the status code', () {
      final PlausibleApiV1 api = apiReturning(500, '{}');
      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('a 200 with a garbage body throws ServerException', () {
      final PlausibleApiV1 api = apiReturning(200, 'not json');
      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 200)),
      );
    });

    test('a 200 whose results are the wrong shape throws ServerException', () {
      final PlausibleApiV1 api = apiReturning(200, '{"results": []}');
      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 200)),
      );
    });

    test('a thrown SocketException surfaces as a non-proxied NetworkException', () {
      final MockClient client = MockClient((http.Request request) async {
        throw const SocketException('connection refused');
      });
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<NetworkException>().having((NetworkException e) => e.isProxied, 'isProxied', false)),
      );
    });

    test('a thrown ClientException surfaces as a NetworkException', () {
      final MockClient client = MockClient((http.Request request) async {
        throw http.ClientException('Connection closed before full header was received');
      });
      final PlausibleApiV1 api = PlausibleApiV1(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<NetworkException>().having((NetworkException e) => e.host, 'host', 'plausible.example.org')),
      );
    });

    test('a proxied client flags the bare socks5_proxy Exception as proxied', () {
      final MockClient client = MockClient((http.Request request) async {
        throw Exception('Command handling failed. With error: hostUnreachable');
      });
      final PlausibleApiV1 api = PlausibleApiV1(
        client,
        Uri.parse('https://plausible.example.org'),
        'secret-key',
        isProxied: true,
      );

      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<NetworkException>().having((NetworkException e) => e.isProxied, 'isProxied', true)),
      );
    });
  });
}
