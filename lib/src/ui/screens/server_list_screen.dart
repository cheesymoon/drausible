import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/server.dart';
import '../../providers/config_providers.dart';
import 'server_edit_screen.dart';
import 'settings_screen.dart';
import 'site_list_screen.dart';

enum _ServerAction { edit, delete }

enum _AppMenuAction { settings }

class ServerListScreen extends ConsumerWidget {
  const ServerListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Server> servers = ref.watch(configProvider).servers;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drausible'),
        actions: <Widget>[
          PopupMenuButton<_AppMenuAction>(
            onSelected: (_AppMenuAction action) {
              switch (action) {
                case _AppMenuAction.settings:
                  unawaited(
                    Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: (BuildContext context) => const SettingsScreen())),
                  );
              }
            },
            itemBuilder: (BuildContext context) => const <PopupMenuEntry<_AppMenuAction>>[
              PopupMenuItem<_AppMenuAction>(value: _AppMenuAction.settings, child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: servers.isEmpty
          ? const _EmptyState()
          : ListView.builder(
              padding: EdgeInsets.only(bottom: 88 + MediaQuery.paddingOf(context).bottom),
              itemCount: servers.length,
              itemBuilder: (BuildContext context, int index) {
                final Server server = servers[index];
                return ListTile(
                  title: Text(server.name),
                  subtitle: Text(server.baseUrl.host),
                  trailing: PopupMenuButton<_ServerAction>(
                    onSelected: (_ServerAction action) {
                      unawaited(_handleAction(context, ref, server, action));
                    },
                    itemBuilder: (BuildContext context) => const <PopupMenuEntry<_ServerAction>>[
                      PopupMenuItem<_ServerAction>(value: _ServerAction.edit, child: Text('Edit')),
                      PopupMenuItem<_ServerAction>(value: _ServerAction.delete, child: Text('Delete')),
                    ],
                  ),
                  onTap: () {
                    unawaited(
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (BuildContext context) => SiteListScreen(server: server)),
                      ),
                    );
                  },
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          unawaited(
            Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (BuildContext context) => const ServerEditScreen())),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _handleAction(BuildContext context, WidgetRef ref, Server server, _ServerAction action) async {
    switch (action) {
      case _ServerAction.edit:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (BuildContext context) => ServerEditScreen(server: server)));
      case _ServerAction.delete:
        final bool? confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete server?'),
            content: const Text('Its sites and API key go with it.'),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        );
        if (confirmed ?? false) {
          await ref.read(configProvider.notifier).deleteServer(server.id);
        }
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.dns_outlined, size: 64, color: colorScheme.outline),
          const SizedBox(height: 16),
          Text('Add your first Plausible server', style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
