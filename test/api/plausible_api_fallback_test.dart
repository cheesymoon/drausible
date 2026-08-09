import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/api/plausible_api_fallback.dart';
import 'package:drausible/src/models/date_range.dart';
import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/stats.dart';

Future<String> _fixture(String name) => File('test/fixtures/$name').readAsString();

PlausibleApiWithFallback _api(http.Client client, ApiVersionResolver resolver) => PlausibleApiWithFallback(
  client,
  Uri.parse('https://plausible.example.org'),
  'secret-key',
  resolver: resolver,
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
  if (body.containsKey('pagination')) return http.Response(await _fixture('v2_breakdown.json'), 200);
  if (body.containsKey('dimensions')) return http.Response(await _fixture('v2_timeseries.json'), 200);
  return http.Response(await _fixture('v2_aggregate.json'), 200);
}

void main() {
  group('probing an unknown server', () {
    test('a server that answers the v2 probe is pinned to v2', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        return _v2Reply(request);
      });
      final ApiVersionResolver resolver = ApiVersionResolver();

      final AggregateStats stats = await _api(client, resolver).aggregate('example.com', const DateRangeSel.d30());

      expect(resolver.version, ApiVersion.v2);
      expect(stats.visitors, 1423);
      expect(requests, hasLength(2));
      expect(requests.first.method, 'POST');
      expect(requests.first.url.path, '/api/v2/query');
      expect(requests.first.headers['Authorization'], 'Bearer secret-key');
      expect(
        jsonDecode(requests.first.body),
        equals(<String, dynamic>{
          'site_id': 'example.com',
          'metrics': <String>['visitors'],
          'date_range': 'day',
        }),
      );
      // The probe asks nothing useful, so the real call still goes out.
      expect(_isV2Probe(requests.last), isFalse);
    });

    test('a 404 from v2 followed by a working v1 route pins v1', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        // What a legacy server actually answers: a 404 carrying an HTML page,
        // which is why the probe reads the status and not the body.
        if (request.url.path == '/api/v2/query') {
          return http.Response('<html><body>404 not found</body></html>', 404);
        }
        return http.Response(await _fixture('v1_aggregate.json'), 200);
      });
      final ApiVersionResolver resolver = ApiVersionResolver();

      final AggregateStats stats = await _api(client, resolver).aggregate('example.com', const DateRangeSel.d30());

      expect(resolver.version, ApiVersion.v1);
      expect(stats.visitors, 1423);
      expect(requests, hasLength(3));
      expect(requests[1].method, 'GET');
      expect(requests[1].url.path, '/api/v1/stats/aggregate');
      expect(
        requests[1].url.queryParameters,
        equals(<String, String>{'site_id': 'example.com', 'period': 'day', 'metrics': 'visitors'}),
      );
      // The real call asks for all four metrics over the range that was asked for.
      expect(requests[2].url.queryParameters['period'], '30d');
      expect(requests[2].url.queryParameters['metrics'], 'visitors,pageviews,bounce_rate,visit_duration');
    });

    test('both routes answering 404 leaves the server unknown', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        return http.Response('{}', 404);
      });
      final ApiVersionResolver resolver = ApiVersionResolver();

      await expectLater(
        _api(client, resolver).aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<NotFoundEndpointException>()),
      );

      // A 404 on its own never pins v1. v1 has to answer for real first.
      expect(resolver.version, ApiVersion.unknown);
      expect(requests, hasLength(2));
    });

    test('a 401 from the v2 probe leaves the server unknown and skips v1', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        return http.Response('{}', 401);
      });
      final ApiVersionResolver resolver = ApiVersionResolver();

      await expectLater(
        _api(client, resolver).aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<UnauthorizedException>()),
      );

      // What a v2 server says about a site_id it doesn't have. Not a verdict
      // on the API version, so nothing gets pinned.
      expect(resolver.version, ApiVersion.unknown);
      expect(requests, hasLength(1));
    });

    test('a 200 that is not JSON leaves the server unknown', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        return http.Response('<html><body>Sign in to this network</body></html>', 200);
      });
      final ApiVersionResolver resolver = ApiVersionResolver();

      await expectLater(
        _api(client, resolver).aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 200)),
      );

      expect(resolver.version, ApiVersion.unknown);
      expect(requests, hasLength(1));
    });

    test('a transport failure leaves the server unknown', () async {
      final MockClient client = MockClient((http.Request request) async {
        throw const SocketException('connection reset');
      });
      final ApiVersionResolver resolver = ApiVersionResolver();

      await expectLater(
        _api(client, resolver).aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<NetworkException>()),
      );

      expect(resolver.version, ApiVersion.unknown);
    });

    test('calls that start together share one probe', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        // Hold the probe open so the other two calls have to queue behind it.
        if (_isV2Probe(request)) await Future<void>.delayed(const Duration(milliseconds: 10));
        return _v2Reply(request);
      });
      final ApiVersionResolver resolver = ApiVersionResolver();
      final PlausibleApiWithFallback api = _api(client, resolver);

      await Future.wait<dynamic>(<Future<dynamic>>[
        api.aggregate('example.com', const DateRangeSel.d30()),
        api.timeseries('example.com', const DateRangeSel.d30()),
        api.breakdown('example.com', const DateRangeSel.d30(), BreakdownDimension.country),
      ]);

      expect(requests.where(_isV2Probe), hasLength(1));
      expect(requests, hasLength(4));
    });
  });

  group('a server whose version is already known', () {
    test('v2 goes straight to the v2 route without probing', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        return _v2Reply(request);
      });

      await _api(client, ApiVersionResolver(ApiVersion.v2)).aggregate('example.com', const DateRangeSel.d30());

      expect(requests, hasLength(1));
      expect(_isV2Probe(requests.single), isFalse);
    });

    test('v1 goes straight to the v1 route without probing', () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient client = MockClient((http.Request request) async {
        requests.add(request);
        return http.Response(await _fixture('v1_timeseries.json'), 200);
      });

      final List<TimeseriesPoint> points = await _api(
        client,
        ApiVersionResolver(ApiVersion.v1),
      ).timeseries('example.com', const DateRangeSel.d7());

      expect(points, hasLength(3));
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/v1/stats/timeseries');
    });

    test('a 404 from a v1 route drops the pin so the next call probes again', () async {
      final MockClient client = MockClient((http.Request request) async => http.Response('{}', 404));
      final ApiVersionResolver resolver = ApiVersionResolver(ApiVersion.v1);

      await expectLater(
        _api(client, resolver).aggregate('example.com', const DateRangeSel.d30()),
        throwsA(isA<NotFoundEndpointException>()),
      );

      expect(resolver.version, ApiVersion.unknown);
    });
  });
}
