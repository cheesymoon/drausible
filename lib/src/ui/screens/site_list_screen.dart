import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/id.dart';
import '../../models/server.dart';
import '../../models/site.dart';
import '../../providers/config_providers.dart';
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
              itemCount: sites.length,
              itemBuilder: (BuildContext context, int index) {
                final Site site = sites[index];
                final String title = site.displayName ?? site.domain;
                return ListTile(
                  title: Text(title),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      unawaited(_confirmDelete(context, ref, site));
                    },
                  ),
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
              'them by domain. Sites are added one by one.',
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
