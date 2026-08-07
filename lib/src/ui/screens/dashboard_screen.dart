import 'package:flutter/material.dart';

const List<String> _periods = <String>['Today', '7d', '30d', 'Month'];

const List<({String label, String value})> _metrics =
    <({String label, String value})>[
  (label: 'Visitors', value: '1.4k'),
  (label: 'Pageviews', value: '3.2k'),
  (label: 'Bounce rate', value: '47%'),
  (label: 'Visit duration', value: '2m 41s'),
];

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({required this.siteDomain, super.key});

  final String siteDomain;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedPeriod = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.siteDomain)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _PeriodChips(
            selectedIndex: _selectedPeriod,
            onSelected: (int index) => setState(() => _selectedPeriod = index),
          ),
          const SizedBox(height: 16),
          const _MetricGrid(),
          const SizedBox(height: 16),
          const _ChartPlaceholder(),
        ],
      ),
    );
  }
}

class _PeriodChips extends StatelessWidget {
  const _PeriodChips({required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: <Widget>[
        for (int i = 0; i < _periods.length; i++)
          ChoiceChip(
            label: Text(_periods[i]),
            selected: selectedIndex == i,
            onSelected: (_) => onSelected(i),
          ),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: <Widget>[
        for (final ({String label, String value}) metric in _metrics)
          _MetricCard(label: metric.label, value: metric.value),
      ],
    );
  }
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
            Text(
              value,
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartPlaceholder extends StatelessWidget {
  const _ChartPlaceholder();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 180,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: CustomPaint(
        painter: _BarChartPainter(color: colorScheme.primary),
        size: Size.infinite,
      ),
    );
  }
}

// Rough sketch of a visitor chart — swapped for a real chart later.
class _BarChartPainter extends CustomPainter {
  _BarChartPainter({required this.color});

  final Color color;

  static const List<double> _heights = <double>[
    0.3, 0.6, 0.4, 0.8, 0.5, 0.9, 0.35, 0.7,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    final double barWidth = size.width / (_heights.length * 2 - 1);
    for (int i = 0; i < _heights.length; i++) {
      final double barHeight = size.height * _heights[i];
      final double left = i * barWidth * 2;
      final Rect rect = Rect.fromLTWH(
        left,
        size.height - barHeight,
        barWidth,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarChartPainter oldDelegate) =>
      oldDelegate.color != color;
}
