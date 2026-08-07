import 'package:flutter_test/flutter_test.dart';

import 'package:drausible/src/models/site.dart';

void main() {
  group('Site', () {
    test('round-trips through json with a display name', () {
      final Site site = Site(
        id: 's1',
        serverId: 'srv1',
        domain: 'example.com',
        displayName: 'Example',
      );

      final Site decoded = Site.fromJson(site.toJson());

      expect(decoded.id, site.id);
      expect(decoded.serverId, site.serverId);
      expect(decoded.domain, site.domain);
      expect(decoded.displayName, site.displayName);
    });

    test('round-trips through json without a display name', () {
      final Site site = Site(id: 's2', serverId: 'srv1', domain: 'blog.example.com');

      final Site decoded = Site.fromJson(site.toJson());

      expect(decoded.displayName, isNull);
      expect(decoded.domain, 'blog.example.com');
    });
  });
}
