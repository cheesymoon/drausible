import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';
import 'package:drausible/src/models/stats.dart';
import 'package:drausible/src/providers/config_providers.dart';
import 'package:drausible/src/providers/stats_providers.dart';
import 'package:drausible/src/repositories/config_repository.dart';
import 'package:drausible/src/ui/screens/site_list_screen.dart';

class FakeKeyStore implements KeyStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

final Server _server = Server(id: 'srv1', name: 'My server', baseUrl: Uri.parse('https://plausible.example.org'));
final Site _site = Site(id: 'site1', serverId: 'srv1', domain: 'example.com');
final Site _otherSite = Site(id: 'site2', serverId: 'srv1', domain: 'other.example.com');
const ({String serverId, String siteId}) _previewArgs = (serverId: 'srv1', siteId: 'site1');
const ({String serverId, String siteId}) _otherPreviewArgs = (serverId: 'srv1', siteId: 'site2');

Future<void> _pump(WidgetTester tester, List<Override> overrides, {List<Site>? sites}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'config_v1': jsonEncode(<String, dynamic>{
      'schemaVersion': 1,
      'servers': <dynamic>[_server.toJson()],
      'sites': <dynamic>[
        for (final Site site in sites ?? <Site>[_site]) site.toJson(),
      ],
    }),
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[keyStoreProvider.overrideWithValue(FakeKeyStore()), ...overrides],
      child: MaterialApp(home: SiteListScreen(server: _server)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the compact visitor count for the site preview', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      sitePreviewProvider(_previewArgs).overrideWith(
        (Ref ref) async => (
          visitors: 1423,
          points: <TimeseriesPoint>[
            TimeseriesPoint(time: DateTime(2026, 8, 7, 0), visitors: 10),
            TimeseriesPoint(time: DateTime(2026, 8, 7, 1), visitors: 20),
          ],
        ),
      ),
    ]);

    expect(find.text('example.com'), findsOneWidget);
    expect(find.text(NumberFormat.compact().format(1423)), findsOneWidget);
  });

  testWidgets('loading state renders no visitor count', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      sitePreviewProvider(
        _previewArgs,
      ).overrideWith((Ref ref) => Completer<({int visitors, List<TimeseriesPoint> points})>().future),
    ]);

    final Finder tile = find.byType(ListTile);
    expect(tile, findsOneWidget);
    // Only the title Text remains, with no count rendered while the preview loads.
    expect(find.descendant(of: tile, matching: find.byType(Text)), findsOneWidget);
  });

  testWidgets('pull-to-refresh reloads site previews', (WidgetTester tester) async {
    int loads = 0;
    await _pump(tester, <Override>[
      sitePreviewProvider(_previewArgs).overrideWith((Ref ref) async {
        loads += 1;
        return (visitors: loads, points: <TimeseriesPoint>[]);
      }),
    ]);

    expect(loads, 1);
    expect(find.text('1'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('one failing preview does not stop the others refreshing', (WidgetTester tester) async {
    int loads = 0;
    await _pump(
      tester,
      <Override>[
        sitePreviewProvider(_previewArgs).overrideWith((Ref ref) async => throw StateError('preview failed')),
        sitePreviewProvider(_otherPreviewArgs).overrideWith((Ref ref) async {
          loads += 1;
          return (visitors: loads, points: <TimeseriesPoint>[]);
        }),
      ],
      sites: <Site>[_site, _otherSite],
    );

    expect(loads, 1);

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    await tester.pumpAndSettle();

    // The rejected refresh must not reach RefreshIndicator, and must not
    // cancel the sites queued behind it.
    expect(loads, 2);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('long-press opens delete confirm and deleting removes the row', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      sitePreviewProvider(_previewArgs).overrideWith((Ref ref) async => (visitors: 5, points: <TimeseriesPoint>[])),
    ]);

    expect(find.text('example.com'), findsOneWidget);

    await tester.longPress(find.text('example.com'));
    await tester.pumpAndSettle();

    expect(find.text('Delete site?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('example.com'), findsNothing);
  });
}
