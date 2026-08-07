import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/models/date_range.dart';
import 'package:drausible/src/models/stats.dart';
import 'package:drausible/src/providers/stats_providers.dart';
import 'package:drausible/src/ui/screens/dashboard_screen.dart';

const String _serverId = 'srv1';
const String _siteId = 'site1';

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

Future<void> _pump(WidgetTester tester, List<Override> overrides) async {
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
}
