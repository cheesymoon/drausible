import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/api_exception.dart';
import '../../models/date_range.dart';
import '../../models/site.dart';
import '../../models/stats.dart';
import '../../providers/config_providers.dart';
import '../../providers/stats_providers.dart';
import '../../util/countries.dart';

typedef _OverviewArgs = ({String serverId, String siteId, DateRangeSel range});
typedef _BreakdownArgs = ({String serverId, String siteId, DateRangeSel range, BreakdownDimension dimension});

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({required this.serverId, required this.siteId, required this.title, super.key});

  final String serverId;
  final String siteId;
  final String title;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  static const String _lastRangeKey = 'last_range';

  DateRangeSel _range = const DateRangeSel.d30();

  _OverviewArgs get _args => (serverId: widget.serverId, siteId: widget.siteId, range: _range);

  @override
  void initState() {
    super.initState();
    // Prefs are already loaded by the time any dashboard opens.
    final SharedPreferences? prefs = ref.read(sharedPreferencesProvider).valueOrNull;
    final DateRangeSel? saved = DateRangeSel.fromShorthand(prefs?.getString(_lastRangeKey));
    if (saved != null) _range = saved;
  }

  void _selectRange(DateRangeSel range) {
    setState(() => _range = range);
    // Presets persist; a fixed custom date pair would be stale next visit.
    // Await the prefs future - right after startup valueOrNull can still be
    // null and the write would silently vanish.
    final String? shorthand = range.v2Shorthand;
    if (shorthand != null) {
      unawaited(
        ref
            .read(sharedPreferencesProvider.future)
            .then((SharedPreferences prefs) => prefs.setString(_lastRangeKey, shorthand)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<OverviewData> overview = ref.watch(overviewProvider(_args));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[_RealtimeBadge(serverId: widget.serverId, siteId: widget.siteId)],
      ),
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
          // Whole family: the visible breakdown tab must refetch too.
          ref.invalidate(breakdownProvider);
          return ref.refresh(overviewProvider(_args).future);
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          // Extra bottom room so gesture bars don't sit on the last row.
          padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + MediaQuery.paddingOf(context).bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _RangeSelector(selected: _range, onSelected: _selectRange),
              const SizedBox(height: 16),
              overview.when(
                // A refetch keeps the numbers on screen instead of dropping
                // back to the skeleton: writing a freshly probed api version
                // rebuilds this provider, and the dashboard shouldn't blink
                // for it. A genuine first load has no value to keep, so it
                // still gets the skeleton.
                skipLoadingOnReload: true,
                data: (OverviewData data) => _DashboardBody(
                  serverId: widget.serverId,
                  siteId: widget.siteId,
                  data: data,
                  range: _range,
                ),
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
  const _DashboardBody({required this.serverId, required this.siteId, required this.data, required this.range});

  final String serverId;
  final String siteId;
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
        const SizedBox(height: 24),
        _BreakdownTabs(serverId: serverId, siteId: siteId, range: range),
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
    // 2x2 on portrait phones, one row of four when there's width for it
    // (landscape, tablets, split screen).
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 640;
        return GridView.count(
          crossAxisCount: wide ? 4 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: wide ? 1.9 : 1.6,
          children: <Widget>[
            _MetricCard(label: 'Visitors', value: compact.format(stats.visitors), tone: _CardTone.primary),
            _MetricCard(label: 'Pageviews', value: compact.format(stats.pageviews), tone: _CardTone.secondary),
            _MetricCard(label: 'Bounce rate', value: '${stats.bounceRate.round()}%', tone: _CardTone.tertiary),
            _MetricCard(
              label: 'Visit duration',
              value: _formatDuration(stats.visitDurationSeconds),
              tone: _CardTone.neutral,
            ),
          ],
        );
      },
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

/// Which slice of the color scheme a metric card is painted with.
enum _CardTone { primary, secondary, tertiary, neutral }

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value, required this.tone});

  final String label;
  final String value;
  final _CardTone tone;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (tone) {
      _CardTone.primary => (colorScheme.primaryContainer, colorScheme.onPrimaryContainer),
      _CardTone.secondary => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      _CardTone.tertiary => (colorScheme.tertiaryContainer, colorScheme.onTertiaryContainer),
      _CardTone.neutral => (colorScheme.surfaceContainerHighest, colorScheme.onSurface),
    };
    return Card(
      color: background,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              value,
              style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: foreground),
            ),
            const SizedBox(height: 4),
            Text(label, style: textTheme.bodySmall?.copyWith(color: foreground.withValues(alpha: 0.75))),
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
              // Anchored to the top of the plot so it doesn't ride the line
              // up and down while scrubbing.
              showOnTopOfTheChartBoxArea: true,
              fitInsideHorizontally: true,
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
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    colorScheme.primary.withValues(alpha: 0.35),
                    colorScheme.primary.withValues(alpha: 0.02),
                  ],
                ),
              ),
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

/// Current-visitor pill in the AppBar. Stops watching the provider (and so
/// its 30s polling) while the app isn't in the foreground.
class _RealtimeBadge extends ConsumerStatefulWidget {
  const _RealtimeBadge({required this.serverId, required this.siteId});

  final String serverId;
  final String siteId;

  @override
  ConsumerState<_RealtimeBadge> createState() => _RealtimeBadgeState();
}

class _RealtimeBadgeState extends ConsumerState<_RealtimeBadge> with WidgetsBindingObserver {
  bool _watching = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool watching = state == AppLifecycleState.resumed;
    if (watching != _watching) setState(() => _watching = watching);
  }

  @override
  Widget build(BuildContext context) {
    final int? visitors = _watching
        ? ref.watch(realtimeProvider((serverId: widget.serverId, siteId: widget.siteId))).valueOrNull
        : null;

    return Tooltip(
      message: 'Visitors right now',
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _PulsingDot(active: visitors != null),
            if (visitors != null) ...<Widget>[const SizedBox(width: 6), Text('$visitors')],
          ],
        ),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.active});

  final bool active;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(_PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    final bool shouldPulse = widget.active && !MediaQuery.of(context).disableAnimations;
    if (shouldPulse && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!shouldPulse && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Color color = widget.active ? colorScheme.primary : colorScheme.onSurfaceVariant.withValues(alpha: 0.3);
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
      child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    );
  }
}

/// Wraps the selected tab's content, so a test can measure its height.
@visibleForTesting
const Key breakdownTabContentKey = Key('breakdown-tab-content');

/// TabBar for Pages/Sources/Countries/Devices. No TabBarView — the screen is
/// one SingleChildScrollView, so only the selected tab's list is built below
/// the bar, which is also what makes the other tabs' providers lazy. Swiping
/// moves between them anyway, and the content sits on a minimum height so
/// switching doesn't jolt the page.
class _BreakdownTabs extends StatelessWidget {
  const _BreakdownTabs({required this.serverId, required this.siteId, required this.range});

  final String serverId;
  final String siteId;
  final DateRangeSel range;

  static const List<String> _labels = <String>['Pages', 'Sources', 'Countries', 'Devices'];

  /// Roughly five rows. The tabs hold very different row counts, so without a
  /// floor the page lurches every time you switch to a shorter one.
  static const double _minTabHeight = 190;

  /// Below this a horizontal drag is a stray thumb movement, not a flick.
  static const double _swipeVelocity = 200;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _labels.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: <Widget>[for (final String label in _labels) Tab(text: label)],
          ),
          const SizedBox(height: 12),
          Builder(
            builder: (BuildContext context) {
              final TabController controller = DefaultTabController.of(context);
              return GestureDetector(
                // A flick, not a TabBarView: the screen is a single scroll
                // view, so a TabBarView would need a fixed height and would
                // give the tabs their own nested scrolling — and it would
                // build all four, losing the laziness above. The page's
                // vertical drags are untouched; the two axes don't compete.
                behavior: HitTestBehavior.opaque,
                onHorizontalDragEnd: (DragEndDetails details) => _swipe(controller, details),
                // Tabs still differ in height once past the floor, so the
                // remaining change is glided rather than snapped. Anchored at
                // the top, so the rows stay put and only the bottom edge moves.
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    key: breakdownTabContentKey,
                    constraints: const BoxConstraints(minHeight: _minTabHeight),
                    child: _SelectedBreakdownTab(serverId: serverId, siteId: siteId, range: range),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static void _swipe(TabController controller, DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < _swipeVelocity) return;
    // Dragging left (negative) reveals the tab to the right, as the tab bar
    // itself moves.
    final int next = velocity < 0 ? controller.index + 1 : controller.index - 1;
    if (next >= 0 && next < _labels.length) controller.animateTo(next);
  }
}

class _SelectedBreakdownTab extends StatefulWidget {
  const _SelectedBreakdownTab({required this.serverId, required this.siteId, required this.range});

  final String serverId;
  final String siteId;
  final DateRangeSel range;

  @override
  State<_SelectedBreakdownTab> createState() => _SelectedBreakdownTabState();
}

class _SelectedBreakdownTabState extends State<_SelectedBreakdownTab> {
  int _index = 0;
  TabController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final TabController controller = DefaultTabController.of(context);
    if (_controller != controller) {
      _controller?.removeListener(_onTabControllerChanged);
      _controller = controller..addListener(_onTabControllerChanged);
    }
  }

  void _onTabControllerChanged() {
    if (_controller!.index != _index) setState(() => _index = _controller!.index);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTabControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_index) {
      case 0:
        return _BreakdownList(
          serverId: widget.serverId,
          siteId: widget.siteId,
          range: widget.range,
          dimension: BreakdownDimension.page,
        );
      case 1:
        return _BreakdownList(
          serverId: widget.serverId,
          siteId: widget.siteId,
          range: widget.range,
          dimension: BreakdownDimension.source,
        );
      case 2:
        return _BreakdownList(
          serverId: widget.serverId,
          siteId: widget.siteId,
          range: widget.range,
          dimension: BreakdownDimension.country,
        );
      default:
        return _DevicesTab(serverId: widget.serverId, siteId: widget.siteId, range: widget.range);
    }
  }
}

class _DevicesTab extends StatefulWidget {
  const _DevicesTab({required this.serverId, required this.siteId, required this.range});

  final String serverId;
  final String siteId;
  final DateRangeSel range;

  @override
  State<_DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<_DevicesTab> {
  BreakdownDimension _dimension = BreakdownDimension.device;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SegmentedButton<BreakdownDimension>(
          segments: const <ButtonSegment<BreakdownDimension>>[
            ButtonSegment<BreakdownDimension>(value: BreakdownDimension.device, label: Text('Device')),
            ButtonSegment<BreakdownDimension>(value: BreakdownDimension.browser, label: Text('Browser')),
            ButtonSegment<BreakdownDimension>(value: BreakdownDimension.os, label: Text('OS')),
          ],
          selected: <BreakdownDimension>{_dimension},
          onSelectionChanged: (Set<BreakdownDimension> selected) => setState(() => _dimension = selected.first),
        ),
        const SizedBox(height: 12),
        _BreakdownList(serverId: widget.serverId, siteId: widget.siteId, range: widget.range, dimension: _dimension),
      ],
    );
  }
}

class _BreakdownList extends ConsumerWidget {
  const _BreakdownList({required this.serverId, required this.siteId, required this.range, required this.dimension});

  final String serverId;
  final String siteId;
  final DateRangeSel range;
  final BreakdownDimension dimension;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final _BreakdownArgs args = (serverId: serverId, siteId: siteId, range: range, dimension: dimension);
    final AsyncValue<List<BreakdownRow>> breakdown = ref.watch(breakdownProvider(args));

    return breakdown.when(
      // As on the overview above: a config write shouldn't blank rows that are
      // already on screen.
      skipLoadingOnReload: true,
      data: (List<BreakdownRow> rows) =>
          _BreakdownRows(rows: rows, isCountry: dimension == BreakdownDimension.country),
      loading: () => const _BreakdownSkeleton(),
      error: (Object error, StackTrace stackTrace) => _BreakdownError(
        message: error is ApiException ? error.message : 'Something went wrong',
        onRetry: () => ref.invalidate(breakdownProvider(args)),
      ),
    );
  }
}

class _BreakdownRows extends StatelessWidget {
  const _BreakdownRows({required this.rows, required this.isCountry});

  final List<BreakdownRow> rows;
  final bool isCountry;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('No data for this range', style: Theme.of(context).textTheme.bodyMedium),
        ),
      );
    }

    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final NumberFormat compact = NumberFormat.compact();
    final int maxVisitors = rows.map((BreakdownRow r) => r.visitors).reduce((int a, int b) => a > b ? a : b);

    // Countries usually arrive as ISO codes; anything else renders as-is
    // (no orphan space when there's no flag to show).
    String rowLabel(String name) {
      if (!isCountry) return name;
      final String flag = countryFlag(name);
      return flag.isEmpty ? countryName(name) : '$flag ${countryName(name)}';
    }

    return Column(
      children: <Widget>[
        for (final BreakdownRow row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Stack(
              children: <Widget>[
                FractionallySizedBox(
                  widthFactor: maxVisitors == 0 ? 0 : row.visitors / maxVisitors,
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                SizedBox(
                  height: 32,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            rowLabel(row.name),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(compact.format(row.visitors)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BreakdownSkeleton extends StatelessWidget {
  const _BreakdownSkeleton();

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Column(
      children: <Widget>[
        for (int i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              height: 32,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
            ),
          ),
      ],
    );
  }
}

class _BreakdownError extends StatelessWidget {
  const _BreakdownError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(message, style: Theme.of(context).textTheme.bodySmall)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
