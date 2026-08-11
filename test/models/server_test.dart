import 'package:flutter_test/flutter_test.dart';

import 'package:drausible/src/models/server.dart';

void main() {
  group('Server', () {
    test('round-trips through json without a proxy', () {
      final Server server = Server(
        id: 'abc123',
        name: 'My server',
        baseUrl: Uri.parse('https://plausible.example.org'),
        apiVersion: ApiVersion.v2,
      );

      final Server decoded = Server.fromJson(server.toJson());

      expect(decoded.id, server.id);
      expect(decoded.name, server.name);
      expect(decoded.baseUrl, server.baseUrl);
      expect(decoded.proxy, isNull);
      expect(decoded.apiVersion, ApiVersion.v2);
    });

    test('round-trips through json with a proxy', () {
      final Server server = Server(
        id: 'def456',
        name: 'Onion server',
        baseUrl: Uri.parse('http://example.onion'),
        proxy: ProxyConfig(host: '127.0.0.1', port: 9050),
      );

      final Server decoded = Server.fromJson(server.toJson());

      expect(decoded.proxy?.host, '127.0.0.1');
      expect(decoded.proxy?.port, 9050);
      expect(decoded.apiVersion, ApiVersion.unknown);
    });

    test('copyWith replaces fields and can clear the proxy', () {
      final Server server = Server(
        id: 'id1',
        name: 'name',
        baseUrl: Uri.parse('https://a.example'),
        proxy: ProxyConfig(host: '127.0.0.1', port: 9050),
      );

      final Server updated = server.copyWith(name: 'new name', clearProxy: true);

      expect(updated.id, 'id1');
      expect(updated.name, 'new name');
      expect(updated.proxy, isNull);
      expect(updated.baseUrl, server.baseUrl);
    });
  });

  group('ApiVersion', () {
    test('serializes to and from its name', () {
      for (final ApiVersion version in ApiVersion.values) {
        expect(ApiVersion.values.byName(version.name), version);
      }
    });

    test('defaults to unknown for missing data', () {
      final Server server = Server(id: 'id', name: 'name', baseUrl: Uri.parse('https://a.example'));

      expect(server.apiVersion, ApiVersion.unknown);
    });
  });
}
