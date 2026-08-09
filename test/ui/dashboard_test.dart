import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/models/date_range.dart';
import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/stats.dart';
import 'package:drausible/src/providers/config_providers.dart';
import 'package:drausible/src/providers/stats_providers.dart';
import 'package:drausible/src/repositories/config_repository.dart';
import 'package:drausible/src/ui/screens/dashboard_screen.dart';
import 'package:drausible/src/ui/screens/server_edit_screen.dart';

const String _serverId = 'srv1';
const String _siteId = 'site1';

/// Stands in for the stored config, so an error can find the server it
/// belongs to. The other tests leave it empty, which is what a server deleted
/// under an open dashboard looks like.
class _StoredConfig extends ConfigNotifier {
  @override
  ConfigState build() => ConfigState(
    servers: <Server>[Server(id: _serverId, name: 'My server', baseUrl: Uri.parse('https://plausible.example.org'))],
  );
}

OverviewData _fakeOverview({int visitors = 1423, int pageviews = 3200}) {
  return OverviewData(
    aggregate: AggregateStats(
      visitors: visitors,
      pageviews: pageviews,
      bounceRate: 47,
      visitDurationSeconds: 161,
    ),
    timeseries: <TimeseriesPoint>[
      TimeseriesPoint(time: DateTime(2026, 7, 1), visitors: 10),
      TimeseriesPoint(time: DateTime(2026, 7, 2), visitors: 20),
    ],
  );
}

/// A range the site was live through with nothing to show for it.
OverviewData _zeroOverview() {
  return OverviewData(
    aggregate: AggregateStats(visitors: 0, pageviews: 0, bounceRate: 0, visitDurationSeconds: 0),
    timeseries: <TimeseriesPoint>[
      TimeseriesPoint(time: DateTime(2026, 7, 1), visitors: 0),
      TimeseriesPoint(time: DateTime(2026, 7, 2), visitors: 0),
    ],
  );
}

Future<void> _pump(WidgetTester tester, List<Override> overrides) async {
  // Phone-portrait viewport; the metric grid switches to 4 columns on
  // anything wider, which moves everything these tests tap on.
  tester.view.physicalSize = const Size(420, 890);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        home: DashboardScreen(serverId: _serverId, siteId: _siteId, title: 'example.com'),
      ),
    ),
  );
}

void main() {
  final ({String serverId, String siteId, DateRangeSel range}) args30 = (
    serverId: _serverId,
    siteId: _siteId,
    range: const DateRangeSel.d30(),
  );
  final ({String serverId, String siteId, DateRangeSel range}) args7 = (
    serverId: _serverId,
    siteId: _siteId,
    range: const DateRangeSel.d7(),
  );

  testWidgets('shows the four metric values for the default 30-day range', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
    ]);
    await tester.pumpAndSettle();

    expect(find.text(NumberFormat.compact().format(1423)), findsOneWidget);
    expect(find.text(NumberFormat.compact().format(3200)), findsOneWidget);
    expect(find.text('47%'), findsOneWidget);
    expect(find.text('2m 41s'), findsOneWidget);
  });

  testWidgets('metric cards sit in one row on a wide (landscape) viewport', (
    WidgetTester tester,
  ) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
    ]);
    tester.view.physicalSize = const Size(890, 420);
    await tester.pumpAndSettle();

    final double visitorsY = tester.getTopLeft(find.text('Visitors')).dy;
    final double durationY = tester.getTopLeft(find.text('Visit duration')).dy;
    // Same row (small offset from text centering) - a 2x2 stack would put
    // this card a full row (~100px) lower.
    expect((durationY - visitorsY).abs(), lessThan(40));
  });

  testWidgets('switching the range chip queries the provider with the new range', (
    WidgetTester tester,
  ) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview(visitors: 1423)),
      overviewProvider(args7).overrideWith((Ref ref) async => _fakeOverview(visitors: 555)),
    ]);
    await tester.pumpAndSettle();
    expect(find.text(NumberFormat.compact().format(1423)), findsOneWidget);

    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();

    expect(find.text(NumberFormat.compact().format(555)), findsOneWidget);
    expect(find.text(NumberFormat.compact().format(1423)), findsNothing);
  });

  testWidgets('shows the ApiException message and a retry button on error', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => throw const UnauthorizedException()),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('API key rejected'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
  });

  testWidgets('tapping retry re-fetches and shows data on success', (WidgetTester tester) async {
    int callCount = 0;
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async {
        callCount++;
        if (callCount == 1) throw const UnauthorizedException();
        return _fakeOverview();
      }),
    ]);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.text(NumberFormat.compact().format(1423)), findsOneWidget);
  });

  ({String serverId, String siteId, DateRangeSel range, BreakdownDimension dimension}) breakdownArgs(
    BreakdownDimension dimension,
  ) => (serverId: _serverId, siteId: _siteId, range: args30.range, dimension: dimension);

  List<BreakdownRow> fakeRows(List<(String, int)> entries) => <BreakdownRow>[
    for (final (String name, int visitors) in entries) BreakdownRow(name: name, visitors: visitors),
  ];

  testWidgets('the realtime badge shows the current visitor count', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(breakdownArgs(BreakdownDimension.page)).overrideWith((Ref ref) async => <BreakdownRow>[]),
      realtimeProvider((
        serverId: _serverId,
        siteId: _siteId,
      )).overrideWith((Ref ref) => Stream<int>.value(23)),
    ]);
    // The dot pulses forever once a value arrives, so pumpAndSettle would
    // time out here, so pump a fixed number of frames instead.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('23'), findsOneWidget);
  });

  testWidgets('the badge drops its count when polling stops on a rate limit', (WidgetTester tester) async {
    final StreamController<int> live = StreamController<int>();
    addTearDown(live.close);
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(breakdownArgs(BreakdownDimension.page)).overrideWith((Ref ref) async => <BreakdownRow>[]),
      realtimeProvider((serverId: _serverId, siteId: _siteId)).overrideWith((Ref ref) => live.stream),
    ]);
    live.add(23);
    await tester.pump();
    await tester.pump();
    expect(find.text('23'), findsOneWidget);

    live.addError(const RateLimitedException());
    await tester.pump();
    await tester.pump();

    // A count nothing is refreshing is worse than no count at all.
    expect(find.text('23'), findsNothing);
  });

  testWidgets('the Pages tab renders breakdown rows with their counts', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(
        breakdownArgs(BreakdownDimension.page),
      ).overrideWith((Ref ref) async => fakeRows(<(String, int)>[('/blog', 812), ('/pricing', 340)])),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('/blog'), findsOneWidget);
    expect(find.text(NumberFormat.compact().format(812)), findsOneWidget);
    expect(find.text('/pricing'), findsOneWidget);
    expect(find.text(NumberFormat.compact().format(340)), findsOneWidget);
  });

  testWidgets('the Countries tab renders a flag and the full country name', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(breakdownArgs(BreakdownDimension.page)).overrideWith((Ref ref) async => <BreakdownRow>[]),
      breakdownProvider(
        breakdownArgs(BreakdownDimension.country),
      ).overrideWith((Ref ref) async => fakeRows(<(String, int)>[('DE', 120)])),
    ]);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Countries'));
    await tester.tap(find.text('Countries'));
    await tester.pumpAndSettle();

    expect(find.text('🇩🇪 Germany'), findsOneWidget);
  });

  testWidgets('flicking the breakdown area moves to the next tab and back', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(
        breakdownArgs(BreakdownDimension.page),
      ).overrideWith((Ref ref) async => fakeRows(<(String, int)>[('/pricing', 340)])),
      breakdownProvider(
        breakdownArgs(BreakdownDimension.source),
      ).overrideWith((Ref ref) async => fakeRows(<(String, int)>[('Hacker News', 90)])),
    ]);
    await tester.pumpAndSettle();

    final Finder area = find.text('/pricing');
    await tester.ensureVisible(area);
    await tester.fling(area, const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Hacker News'), findsOneWidget);

    await tester.fling(find.text('Hacker News'), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text('/pricing'), findsOneWidget);
  });

  testWidgets('the tab height glides between two differently sized tabs', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(breakdownArgs(BreakdownDimension.page)).overrideWith(
        (Ref ref) async =>
            fakeRows(<(String, int)>[for (int i = 0; i < 10; i++) ('/page$i', 100 - i)]),
      ),
      breakdownProvider(
        breakdownArgs(BreakdownDimension.source),
      ).overrideWith((Ref ref) async => fakeRows(<(String, int)>[('Direct / None', 5)])),
    ]);
    await tester.pumpAndSettle();

    final Finder box = find.ancestor(
      of: find.byKey(breakdownTabContentKey),
      matching: find.byType(AnimatedSize),
    );
    final double tall = tester.getSize(box).height;

    await tester.ensureVisible(find.text('Sources'));
    await tester.tap(find.text('Sources'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final double midway = tester.getSize(box).height;

    await tester.pumpAndSettle();
    final double short = tester.getSize(box).height;

    expect(short, lessThan(tall));
    // Caught partway down rather than already arrived.
    expect(midway, greaterThan(short));
    expect(midway, lessThan(tall));
  });

  testWidgets('a short breakdown still fills the minimum tab height', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(
        breakdownArgs(BreakdownDimension.page),
      ).overrideWith((Ref ref) async => fakeRows(<(String, int)>[('/', 10)])),
    ]);
    await tester.pumpAndSettle();

    // One row is far shorter than the floor, so the floor is what shows.
    expect(tester.getSize(find.byKey(breakdownTabContentKey)).height, greaterThanOrEqualTo(190.0));
  });

  testWidgets('switching the Devices SegmentedButton queries the matching dimension', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(breakdownArgs(BreakdownDimension.page)).overrideWith((Ref ref) async => <BreakdownRow>[]),
      breakdownProvider(
        breakdownArgs(BreakdownDimension.device),
      ).overrideWith((Ref ref) async => fakeRows(<(String, int)>[('Desktop', 500)])),
      breakdownProvider(
        breakdownArgs(BreakdownDimension.browser),
      ).overrideWith((Ref ref) async => fakeRows(<(String, int)>[('Firefox', 90)])),
    ]);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Devices'));
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
    expect(find.text('Desktop'), findsOneWidget);

    await tester.ensureVisible(find.text('Browser'));
    await tester.tap(find.text('Browser'));
    await tester.pumpAndSettle();

    expect(find.text('Firefox'), findsOneWidget);
    expect(find.text('Desktop'), findsNothing);
  });

  testWidgets('a breakdown error shows a one-line message and a retry that recovers', (
    WidgetTester tester,
  ) async {
    int callCount = 0;
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(breakdownArgs(BreakdownDimension.page)).overrideWith((Ref ref) async {
        callCount++;
        if (callCount == 1) throw const UnauthorizedException();
        return fakeRows(<(String, int)>[('/blog', 812)]);
      }),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('API key rejected'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(TextButton, 'Retry'));
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.text('/blog'), findsOneWidget);
  });

  testWidgets('a failure through a proxy blames the proxy and names Orbot', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(
        args30,
      ).overrideWith((Ref ref) async => throw const NetworkException('example.onion', isProxied: true)),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Could not reach example.onion through the proxy'), findsOneWidget);
    expect(find.textContaining('Orbot'), findsOneWidget);
  });

  testWidgets('a rejected key opens the server settings from the error', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      configProvider.overrideWith(_StoredConfig.new),
      overviewProvider(args30).overrideWith((Ref ref) async => throw const UnauthorizedException()),
    ]);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.widgetWithText(TextButton, 'Edit server'));
    await tester.tap(find.widgetWithText(TextButton, 'Edit server'));
    await tester.pumpAndSettle();

    expect(find.byType(ServerEditScreen), findsOneWidget);
  });

  testWidgets('no edit shortcut when the server is no longer in the config', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => throw const UnauthorizedException()),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('API key rejected'), findsOneWidget);
    expect(find.text('Edit server'), findsNothing);
  });

  testWidgets('an all-zero range explains that the domain has to match', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _zeroOverview()),
      breakdownProvider(breakdownArgs(BreakdownDimension.page)).overrideWith((Ref ref) async => <BreakdownRow>[]),
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('the one in Plausible'), findsOneWidget);
  });

  testWidgets('any traffic at all keeps the empty-data hint away', (WidgetTester tester) async {
    await _pump(tester, <Override>[
      overviewProvider(args30).overrideWith((Ref ref) async => _fakeOverview()),
      breakdownProvider(breakdownArgs(BreakdownDimension.page)).overrideWith((Ref ref) async => <BreakdownRow>[]),
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('the one in Plausible'), findsNothing);
  });
}
