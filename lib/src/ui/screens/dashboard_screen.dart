import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../api/api_exception.dart';
import '../../models/date_range.dart';
import '../../models/site.dart';
import '../../models/stats.dart';
import '../../providers/config_providers.dart';
import '../../providers/stats_providers.dart';

typedef _OverviewArgs = ({String serverId, String siteId, DateRangeSel range});

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({required this.serverId, required this.siteId, required this.title, super.key});

  final String serverId;
  final String siteId;
  final String title;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  DateRangeSel _range = const DateRangeSel.d30();

  _OverviewArgs get _args => (serverId: widget.serverId, siteId: widget.siteId, range: _range);

  @override
  Widget build(BuildContext context) {
    final AsyncValue<OverviewData> overview = ref.watch(overviewProvider(_args));

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: RefreshIndicator(
        onRefresh: () {
          // Evict first, otherwise the refetch would be served by the 60s cache.
          // The cache is keyed by domain, not by our site record id.
          final String domain = ref
              .read(configProvider)
              .sites
              .firstWhere((Site s) => s.id == widget.siteId)
              .domain;
          ref.read(statsRepositoryProvider).evictSite(widget.serverId, domain);
          return ref.refresh(overviewProvider(_args).future);
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _RangeSelector(
                selected: _range,
                onSelected: (DateRangeSel range) => setState(() => _range = range),
              ),
              const SizedBox(height: 16),
              overview.when(
                data: (OverviewData data) => _DashboardBody(data: data, range: _range),
                loading: () => const _DashboardSkeleton(),
                error: (Object error, StackTrace stackTrace) => _DashboardError(
                  error: error,
                  onRetry: () => ref.invalidate(overviewProvider(_args)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.selected, required this.onSelected});

  final DateRangeSel selected;
  final ValueChanged<DateRangeSel> onSelected;

  static const List<DateRangeSel> _presets = <DateRangeSel>[
    DateRangeSel.day(),
    DateRangeSel.d7(),
    DateRangeSel.d30(),
    DateRangeSel.month(),
    DateRangeSel.mo6(),
    DateRangeSel.mo12(),
  ];

  @override
  Widget build(BuildContext context) {
    final bool isCustom = !_presets.contains(selected);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final DateRangeSel preset in _presets) ...<Widget>[
            ChoiceChip(
              label: Text(preset.label()),
              selected: !isCustom && preset == selected,
              onSelected: (_) => onSelected(preset),
            ),
            const SizedBox(width: 8),
          ],
          ChoiceChip(
            label: Text(isCustom ? selected.label() : 'Custom…'),
            selected: isCustom,
            onSelected: (_) => unawaited(_pickCustomRange(context)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustomRange(BuildContext context) async {
    final DateTime now = DateTime.now();
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 730)),
      lastDate: now,
      initialDateRange: DateTimeRange(start: now.subtract(const Duration(days: 30)), end: now),
    );
    if (picked != null) onSelected(DateRangeSel.custom(picked.start, picked.end));
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({required this.data, required this.range});

  final OverviewData data;
  final DateRangeSel range;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _MetricGrid(stats: data.aggregate),
        const SizedBox(height: 16),
        _TimeseriesChart(points: data.timeseries, range: range),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.stats});

  final AggregateStats stats;

  @override
  Widget build(BuildContext context) {
    final NumberFormat compact = NumberFormat.compact();
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: <Widget>[
        _MetricCard(label: 'Visitors', value: compact.format(stats.visitors)),
        _MetricCard(label: 'Pageviews', value: compact.format(stats.pageviews)),
        _MetricCard(label: 'Bounce rate', value: '${stats.bounceRate.round()}%'),
        _MetricCard(label: 'Visit duration', value: _formatDuration(stats.visitDurationSeconds)),
      ],
    );
  }
}

/// "2m 41s", or just "41s" under a minute.
String _formatDuration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final int minutes = seconds ~/ 60;
  final int remainingSeconds = seconds % 60;
  return '${minutes}m ${remainingSeconds}s';
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(value, style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(label, style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _TimeseriesChart extends StatelessWidget {
  const _TimeseriesChart({required this.points, required this.range});

  final List<TimeseriesPoint> points;
  final DateRangeSel range;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Text('No data for this range', style: Theme.of(context).textTheme.bodyMedium),
        ),
      );
    }

    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final TextStyle? axisStyle = Theme.of(context).textTheme.bodySmall;
    final NumberFormat compact = NumberFormat.compact();
    final _BottomAxis bottomAxis = _bottomAxis(points, range);

    final List<FlSpot> spots = <FlSpot>[
      for (int i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].visitors.toDouble()),
    ];
    final double dataMaxY = points
        .map((TimeseriesPoint point) => point.visitors)
        .reduce((int a, int b) => a > b ? a : b)
        .toDouble();
    final double chartMaxY = dataMaxY <= 0 ? 1 : dataMaxY * 1.1;
    final double yInterval = _tickInterval(chartMaxY.round(), 4);

    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: chartMaxY,
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: yInterval,
            getDrawingHorizontalLine: (double value) =>
                FlLine(color: colorScheme.outlineVariant, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: yInterval,
                getTitlesWidget: (double value, TitleMeta meta) => SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(compact.format(value), style: axisStyle),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: bottomAxis.interval,
                getTitlesWidget: (double value, TitleMeta meta) {
                  final int index = value.round();
                  if (index < 0 || index >= points.length) return const SizedBox.shrink();
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    child: Text(bottomAxis.label(points[index].time), style: axisStyle),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (List<LineBarSpot> spots) => <LineTooltipItem>[
                for (final LineBarSpot spot in spots)
                  LineTooltipItem(
                    '${DateFormat('d MMM').format(points[spot.x.toInt()].time)} · ${spot.y.toInt()} visitors',
                    const TextStyle(color: Colors.white),
                  ),
              ],
            ),
          ),
          lineBarsData: <LineChartBarData>[
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: colorScheme.primary,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: colorScheme.primary.withValues(alpha: 0.1)),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _BottomAxis = ({String Function(DateTime) label, double interval});

/// Hourly labels for a single-day range, otherwise daily ("d MMM") or, once
/// points are roughly a month apart (6mo/12mo), monthly ("MMM").
_BottomAxis _bottomAxis(List<TimeseriesPoint> points, DateRangeSel range) {
  if (range.timeDimension == 'time:hour') {
    final DateFormat hourFormat = DateFormat('HH:00');
    return (label: (DateTime time) => hourFormat.format(time), interval: _tickInterval(points.length, 4));
  }
  final bool isMonthly =
      points.length >= 2 && points[1].time.difference(points[0].time).inDays >= 20;
  final DateFormat dayFormat = DateFormat(isMonthly ? 'MMM' : 'd MMM');
  return (
    label: (DateTime time) => dayFormat.format(time),
    interval: _tickInterval(points.length, isMonthly ? 6 : 5),
  );
}

double _tickInterval(int pointCount, int desiredLabels) {
  if (pointCount <= 1) return 1;
  final double raw = (pointCount / desiredLabels).ceilToDouble();
  return raw < 1 ? 1 : raw;
}

class _DashboardSkeleton extends StatelessWidget {
  const _DashboardSkeleton();

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.surfaceContainerHighest;
    final BorderRadius radius = BorderRadius.circular(16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.6,
          children: <Widget>[
            for (int i = 0; i < 4; i++) Container(decoration: BoxDecoration(color: color, borderRadius: radius)),
          ],
        ),
        const SizedBox(height: 16),
        Container(height: 200, decoration: BoxDecoration(color: color, borderRadius: radius)),
      ],
    );
  }
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final Object err = error;
    final String message = err is ApiException ? err.message : 'Something went wrong';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(message, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
