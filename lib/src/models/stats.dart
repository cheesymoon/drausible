// Domain shapes for Plausible stats — decoupled from the v2 JSON wire format.

class AggregateStats {
  AggregateStats({
    required this.visitors,
    required this.pageviews,
    required this.bounceRate,
    required this.visitDurationSeconds,
  });

  final int visitors;
  final int pageviews;
  final double bounceRate;
  final int visitDurationSeconds;
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
  source('visit:source'),
  country('visit:country'),
  device('visit:device'),
  browser('visit:browser'),
  os('visit:os');

  const BreakdownDimension(this.v2Dimension);

  final String v2Dimension;
}
