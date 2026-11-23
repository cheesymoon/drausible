import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/api/plausible_api_v2.dart';
import 'package:drausible/src/models/date_range.dart';
import 'package:drausible/src/models/stats.dart';

Future<String> _fixture(String name) => File('test/fixtures/$name').readAsString();

void main() {
  group('request shape', () {
    test('aggregate posts site_id/metrics/date_range with the auth header', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v2_aggregate.json'), 200);
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final AggregateStats stats = await api.aggregate('example.com', const DateRangeSel.d30());

      expect(captured!.method, 'POST');
      expect(captured!.url.toString(), 'https://plausible.example.org/api/v2/query');
      expect(captured!.headers['Authorization'], 'Bearer secret-key');
      expect(captured!.headers['Content-Type'], contains('application/json'));
      expect(
        jsonDecode(captured!.body),
        equals(<String, dynamic>{
          'site_id': 'example.com',
          'metrics': <String>['visitors', 'visits', 'pageviews', 'views_per_visit', 'bounce_rate', 'visit_duration'],
          'date_range': '30d',
          'include': <String, dynamic>{'imports': true},
        }),
      );
      expect(stats.visitors, 1423);
      expect(stats.visits, 1398);
      expect(stats.pageviews, 3211);
      expect(stats.viewsPerVisit, 2.3);
      expect(stats.bounceRate, 47.3);
      expect(stats.visitDurationSeconds, 161);
    });

    test('a trailing slash on the base url does not duplicate', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v2_aggregate.json'), 200);
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org/'), 'secret-key');

      await api.aggregate('example.com', const DateRangeSel.d30());

      expect(captured!.url.toString(), 'https://plausible.example.org/api/v2/query');
    });

    test('timeseries for a day range requests time:hour and gap-fills the missing hour', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v2_timeseries.json'), 200);
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<TimeseriesPoint> points = await api.timeseries('example.com', const DateRangeSel.day());

      expect(
        jsonDecode(captured!.body),
        equals(<String, dynamic>{
          'site_id': 'example.com',
          'metrics': <String>['visitors'],
          'date_range': 'day',
          'dimensions': <String>['time:hour'],
          'include': <String, dynamic>{'time_labels': true, 'imports': true},
        }),
      );
      expect(points, hasLength(3));
      expect(points[0].visitors, 10);
      expect(points[1].visitors, 0); // gap-filled: no results row for this label
      expect(points[2].visitors, 25);
    });

    test('timeseries for a custom range sends the from/to pair and the plain time dimension', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v2_timeseries.json'), 200);
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      await api.timeseries('example.com', DateRangeSel.custom(DateTime(2024, 1, 3), DateTime(2024, 2, 7)));

      expect(
        jsonDecode(captured!.body),
        equals(<String, dynamic>{
          'site_id': 'example.com',
          'metrics': <String>['visitors'],
          'date_range': <String>['2024-01-03', '2024-02-07'],
          'dimensions': <String>['time'],
          'include': <String, dynamic>{'time_labels': true, 'imports': true},
        }),
      );
    });

    test('breakdown by country requests the limit and dimension', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(await _fixture('v2_breakdown.json'), 200);
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<BreakdownRow> rows = await api.breakdown(
        'example.com',
        const DateRangeSel.d30(),
        BreakdownDimension.country,
        limit: 10,
      );

      expect(
        jsonDecode(captured!.body),
        equals(<String, dynamic>{
          'site_id': 'example.com',
          'metrics': <String>['visitors'],
          'date_range': '30d',
          'dimensions': <String>['visit:country'],
          'order_by': <List<String>>[
            <String>['visitors', 'desc'],
          ],
          'pagination': <String, dynamic>{'limit': 10},
          'include': <String, dynamic>{'imports': true},
        }),
      );
      expect(rows, hasLength(3));
      expect(rows[0].name, 'US');
      expect(rows[0].visitors, 532);
    });

    test('breakdown by UTM medium drops the row for untagged visits', () async {
      const String body =
          '{"results": [{"dimensions": ["(not set)"], "metrics": [900]}, {"dimensions": ["email"], "metrics": [40]}]}';
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response(body, 200);
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<BreakdownRow> rows = await api.breakdown(
        'example.com',
        const DateRangeSel.d30(),
        BreakdownDimension.utmMedium,
      );

      expect(jsonDecode(captured!.body)['dimensions'], <String>['visit:utm_medium']);
      expect(rows.single.name, 'email');
      expect(rows.single.visitors, 40);
    });

    test('a UTM breakdown asks for one extra row and still returns the limit', () async {
      const String body =
          '{"results": [{"dimensions": ["(not set)"], "metrics": [900]}, {"dimensions": ["email"], "metrics": [40]}, '
          '{"dimensions": ["cpc"], "metrics": [30]}]}';
      const String untouched =
          '{"results": [{"dimensions": ["email"], "metrics": [40]}, {"dimensions": ["cpc"], "metrics": [30]}, '
          '{"dimensions": ["social"], "metrics": [20]}]}';
      final List<http.Request> requests = <http.Request>[];
      final List<String> bodies = <String>[body, untouched];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        return http.Response(bodies[requests.length - 1], 200);
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<BreakdownRow> withPlaceholder = await api.breakdown(
        'example.com',
        const DateRangeSel.d30(),
        BreakdownDimension.utmMedium,
        limit: 2,
      );
      final List<BreakdownRow> withoutPlaceholder = await api.breakdown(
        'example.com',
        const DateRangeSel.d30(),
        BreakdownDimension.utmMedium,
        limit: 2,
      );

      expect(jsonDecode(requests[0].body)['pagination'], <String, dynamic>{'limit': 3});
      expect(withPlaceholder.map((BreakdownRow r) => r.name), <String>['email', 'cpc']);
      expect(withoutPlaceholder.map((BreakdownRow r) => r.name), <String>['email', 'cpc']);
    });

    test('breakdown by browser keeps its "(not set)" row', () async {
      const String body =
          '{"results": [{"dimensions": ["Chrome"], "metrics": [350]}, {"dimensions": ["(not set)"], "metrics": [35]}]}';
      final MockClient client = MockClient((http.Request request) async => http.Response(body, 200));
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final List<BreakdownRow> rows = await api.breakdown(
        'example.com',
        const DateRangeSel.d30(),
        BreakdownDimension.browser,
      );

      expect(rows.map((BreakdownRow r) => r.name), <String>['Chrome', '(not set)']);
    });
  });

  group('error mapping', () {
    PlausibleApiV2 apiReturning(int statusCode, String body) {
      final MockClient client = MockClient((http.Request request) async {
        return http.Response(body, statusCode);
      });
      return PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');
    }

    test('401 throws UnauthorizedException', () {
      final PlausibleApiV2 api = apiReturning(401, '{}');
      expect(() => api.aggregate('example.com', const DateRangeSel.d30()), throwsA(isA<UnauthorizedException>()));
    });

    test('404 throws NotFoundEndpointException', () {
      final PlausibleApiV2 api = apiReturning(404, '{}');
      expect(() => api.aggregate('example.com', const DateRangeSel.d30()), throwsA(isA<NotFoundEndpointException>()));
    });

    test('429 throws RateLimitedException', () {
      final PlausibleApiV2 api = apiReturning(429, '{}');
      expect(() => api.aggregate('example.com', const DateRangeSel.d30()), throwsA(isA<RateLimitedException>()));
    });

    test('500 throws ServerException with the status code', () {
      final PlausibleApiV2 api = apiReturning(500, '{}');
      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('a null metric in a zero-traffic range reads as 0, not an error', () async {
      // views/visit is a ratio, so an empty range is exactly where a server has
      // nothing to divide and answers null.
      final PlausibleApiV2 api = apiReturning(200, '{"results":[{"metrics":[0,0,0,null,0,0]}]}');

      final AggregateStats stats = await api.aggregate('example.com', const DateRangeSel.d30());

      expect(stats.visitors, 0);
      expect(stats.viewsPerVisit, 0);
    });

    test('a 200 with a garbage body throws ServerException', () {
      final PlausibleApiV2 api = apiReturning(200, 'not json');
      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 200)),
      );
    });

    test('a thrown SocketException surfaces as a non-proxied NetworkException', () {
      final MockClient client = MockClient((http.Request request) async {
        throw const SocketException('connection refused');
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<NetworkException>().having((NetworkException e) => e.isProxied, 'isProxied', false)),
      );
    });

    test('a thrown ClientException surfaces as a NetworkException', () {
      final MockClient client = MockClient((http.Request request) async {
        throw http.ClientException('Connection closed before full header was received');
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      expect(
        () => api.aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<NetworkException>().having((NetworkException e) => e.host, 'host', 'plausible.example.org')),
      );
    });

    test('the bare Exception socks5_proxy throws surfaces as a NetworkException', () {
      final MockClient client = MockClient((http.Request request) async {
        throw Exception('Command handling failed. With error: hostUnreachable');
      });
      final PlausibleApiV2 api = PlausibleApiV2(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      expect(() => api.aggregate('example.com', const DateRangeSel.d30()), throwsA(isA<NetworkException>()));
    });

    test('a proxied client flags its NetworkException as proxied', () {
      final MockClient client = MockClient((http.Request request) async {
        throw Exception('Command handling failed. With error: hostUnreachable');
      });
      final PlausibleApiV2 api = PlausibleApiV2(
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
