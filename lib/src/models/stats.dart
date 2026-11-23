// Domain shapes for Plausible stats, decoupled from the v2 JSON wire format.

class AggregateStats {
  AggregateStats({
    required this.visitors,
    required this.pageviews,
    required this.bounceRate,
    required this.visitDurationSeconds,
    this.visits,
    this.viewsPerVisit,
  });

  final int visitors;
  final int pageviews;
  final double bounceRate;
  final int visitDurationSeconds;

  /// Null when the server never reported them. Servers too old for these two
  /// metrics reject a request that asks for them, so the dashboard leaves those
  /// cards out rather than showing a zero it made up.
  final int? visits;
  final double? viewsPerVisit;
}

class TimeseriesPoint {
  TimeseriesPoint({required this.time, required this.visitors});

  final DateTime time;
  final int visitors;
}

class BreakdownRow {
  BreakdownRow({required this.name, required this.visitors});

  final String name;
  final int visitors;
}

enum BreakdownDimension {
  page('event:page'),
  entryPage('visit:entry_page'),
  exitPage('visit:exit_page'),
  source('visit:source'),
  utmMedium('visit:utm_medium'),
  utmSource('visit:utm_source'),
  utmCampaign('visit:utm_campaign'),
  country('visit:country'),
  device('visit:device'),
  browser('visit:browser'),
  os('visit:os');

  const BreakdownDimension(this.v2Dimension);

  final String v2Dimension;

  /// UTM reports have one placeholder row for visits without a tag, which the
  /// API clients drop.
  bool get isUtm => v2Dimension.startsWith('visit:utm_');
}
