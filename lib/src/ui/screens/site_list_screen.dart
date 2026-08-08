import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/id.dart';
import '../../models/server.dart';
import '../../models/site.dart';
import '../../models/stats.dart';
import '../../providers/config_providers.dart';
import '../../providers/stats_providers.dart';
import 'dashboard_screen.dart';

class SiteListScreen extends ConsumerWidget {
  const SiteListScreen({required this.server, super.key});

  final Server server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Site> sites = ref
        .watch(configProvider)
        .sites
        .where((Site site) => site.serverId == server.id)
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text(server.name)),
      body: sites.isEmpty
          ? const _EmptyState()
          : ListView.builder(
              padding: EdgeInsets.only(bottom: 88 + MediaQuery.paddingOf(context).bottom),
              itemCount: sites.length,
              itemBuilder: (BuildContext context, int index) {
                final Site site = sites[index];
                final String title = site.displayName ?? site.domain;
                return ListTile(
                  title: Text(title),
                  trailing: _SitePreview(serverId: server.id, siteId: site.id),
                  onTap: () {
                    unawaited(
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) =>
                              DashboardScreen(serverId: server.id, siteId: site.id, title: title),
                        ),
                      ),
                    );
                  },
                  onLongPress: () {
                    unawaited(_confirmDelete(context, ref, site));
                  },
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add site',
        onPressed: () {
          unawaited(_showAddSiteDialog(context, ref));
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, Site site) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete site?'),
        content: Text('Remove ${site.displayName ?? site.domain}.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(configProvider.notifier).deleteSite(site.id);
    }
  }

  Future<void> _showAddSiteDialog(BuildContext context, WidgetRef ref) async {
    final Site? site = await showDialog<Site>(
      context: context,
      builder: (BuildContext context) => _AddSiteDialog(serverId: server.id),
    );
    if (site != null) {
      await ref.read(configProvider.notifier).addSite(site);
    }
  }
}

/// Sparkline + today's visitor count. Reserves its loading-state width so
/// the title doesn't jump once data arrives; collapses to nothing on error
/// so the row stays clean and tappable.
class _SitePreview extends ConsumerWidget {
  const _SitePreview({required this.serverId, required this.siteId});

  final String serverId;
  final String siteId;

  static const double _sparklineWidth = 56;
  static const double _sparklineHeight = 24;
  static const double _placeholderWidth = _sparklineWidth + 8 + 32;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<({int visitors, List<TimeseriesPoint> points})> preview = ref.watch(
      sitePreviewProvider((serverId: serverId, siteId: siteId)),
    );
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return preview.when(
      data: (({int visitors, List<TimeseriesPoint> points}) data) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CustomPaint(
            size: const Size(_sparklineWidth, _sparklineHeight),
            painter: _SparklinePainter(points: data.points, color: colorScheme.primary),
          ),
          const SizedBox(width: 8),
          Text(
            NumberFormat.compact().format(data.visitors),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      loading: () => const SizedBox(width: _placeholderWidth, height: _sparklineHeight),
      error: (Object error, StackTrace stackTrace) => const SizedBox.shrink(),
    );
  }
}

/// Flat line at the bottom when every point is zero (or there are none).
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.points, required this.color});

  final List<TimeseriesPoint> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final int maxVisitors = points.isEmpty
        ? 0
        : points.map((TimeseriesPoint p) => p.visitors).reduce((int a, int b) => a > b ? a : b);
    if (maxVisitors <= 0) {
      final double y = size.height - paint.strokeWidth / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }

    final double stepX = points.length > 1 ? size.width / (points.length - 1) : 0;
    final Path path = Path();
    for (int i = 0; i < points.length; i++) {
      final double x = points.length > 1 ? i * stepX : size.width / 2;
      final double y = size.height - (points[i].visitors / maxVisitors) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.language, size: 64, color: colorScheme.outline),
            const SizedBox(height: 16),
            Text('Add your first site', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Plausible servers don\'t let the app list your sites, so you add '
              'them by domain. Sites are added one by one. Long-press a site to remove it.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddSiteDialog extends StatefulWidget {
  const _AddSiteDialog({required this.serverId});

  final String serverId;

  @override
  State<_AddSiteDialog> createState() => _AddSiteDialogState();
}

class _AddSiteDialogState extends State<_AddSiteDialog> {
  static final RegExp _domainPattern = RegExp(
    r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
  );

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _domainController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();

  @override
  void dispose() {
    _domainController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add site'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              controller: _domainController,
              decoration: const InputDecoration(
                labelText: 'Domain',
                hintText: 'example.com',
                helperText: 'Exactly as it appears in your Plausible dashboard —\n'
                    'the part after the host in its URL, e.g. /example.com.\n'
                    'It can differ from the server\'s own domain.',
                helperMaxLines: 3,
              ),
              validator: _validateDomain,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _displayNameController,
              decoration: const InputDecoration(labelText: 'Display name (optional)'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }

  String? _validateDomain(String? value) {
    final String domain = (value ?? '').trim();
    if (domain.isEmpty) return 'Enter a domain';
    if (domain != domain.toLowerCase()) return 'Use lowercase';
    if (domain.contains('://') || domain.contains('/')) return 'No scheme or path, just the domain';
    if (!_domainPattern.hasMatch(domain)) return 'Enter a bare domain, like example.com';
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final String displayName = _displayNameController.text.trim();
    Navigator.pop(
      context,
      Site(
        id: generateId(),
        serverId: widget.serverId,
        domain: _domainController.text.trim(),
        displayName: displayName.isEmpty ? null : displayName,
      ),
    );
  }
}
