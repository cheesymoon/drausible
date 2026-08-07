import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/api/realtime_api.dart';

void main() {
  group('request shape', () {
    test('gets the realtime visitors endpoint with site_id and the auth header', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response('17', 200);
      });
      final RealtimeApi api = RealtimeApi(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      final int visitors = await api.currentVisitors('example.com');

      expect(captured!.method, 'GET');
      expect(
        captured!.url.toString(),
        'https://plausible.example.org/api/v1/stats/realtime/visitors?site_id=example.com',
      );
      expect(captured!.headers['Authorization'], 'Bearer secret-key');
      expect(visitors, 17);
    });

    test('a trailing slash on the base url does not duplicate', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response('3', 200);
      });
      final RealtimeApi api = RealtimeApi(client, Uri.parse('https://plausible.example.org/'), 'secret-key');

      await api.currentVisitors('example.com');

      expect(
        captured!.url.toString(),
        'https://plausible.example.org/api/v1/stats/realtime/visitors?site_id=example.com',
      );
    });

    test('url-encodes a site id with reserved characters', () async {
      http.Request? captured;
      final MockClient client = MockClient((http.Request request) async {
        captured = request;
        return http.Response('0', 200);
      });
      final RealtimeApi api = RealtimeApi(client, Uri.parse('https://plausible.example.org'), 'secret-key');

      await api.currentVisitors('my site.com/x');

      expect(captured!.url.query, 'site_id=my+site.com%2Fx');
      expect(captured!.url.queryParameters['site_id'], 'my site.com/x');
    });
  });

  group('error mapping', () {
    RealtimeApi apiReturning(int statusCode, String body) {
      final MockClient client = MockClient((http.Request request) async {
        return http.Response(body, statusCode);
      });
      return RealtimeApi(client, Uri.parse('https://plausible.example.org'), 'secret-key');
    }

    test('401 throws UnauthorizedException', () {
      final RealtimeApi api = apiReturning(401, '{}');
      expect(() => api.currentVisitors('example.com'), throwsA(isA<UnauthorizedException>()));
    });

    test('404 throws NotFoundEndpointException', () {
      final RealtimeApi api = apiReturning(404, '{}');
      expect(() => api.currentVisitors('example.com'), throwsA(isA<NotFoundEndpointException>()));
    });

    test('429 throws RateLimitedException', () {
      final RealtimeApi api = apiReturning(429, '{}');
      expect(() => api.currentVisitors('example.com'), throwsA(isA<RateLimitedException>()));
    });

    test('500 throws ServerException with the status code', () {
      final RealtimeApi api = apiReturning(500, '{}');
      expect(
        () => api.currentVisitors('example.com'),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('a 200 with a garbage body throws ServerException', () {
      final RealtimeApi api = apiReturning(200, 'not json');
      expect(
        () => api.currentVisitors('example.com'),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 200)),
      );
    });

    test('a 200 with a JSON object instead of a bare integer throws ServerException', () {
      final RealtimeApi api = apiReturning(200, '{"visitors": 17}');
      expect(
        () => api.currentVisitors('example.com'),
        throwsA(isA<ServerException>().having((ServerException e) => e.statusCode, 'statusCode', 200)),
      );
    });
  });
}
