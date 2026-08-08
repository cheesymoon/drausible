import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../providers/settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        children: <Widget>[
          const _SectionHeader('Theme'),
          RadioListTile<ThemeMode>(
            title: const Text('System default'),
            value: ThemeMode.system,
            groupValue: themeMode,
            onChanged: (ThemeMode? mode) => _setMode(ref, mode),
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Light'),
            value: ThemeMode.light,
            groupValue: themeMode,
            onChanged: (ThemeMode? mode) => _setMode(ref, mode),
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Dark'),
            value: ThemeMode.dark,
            groupValue: themeMode,
            onChanged: (ThemeMode? mode) => _setMode(ref, mode),
          ),
          const Divider(),
          const _SectionHeader('About'),
          const _AboutTile(),
          ListTile(
            title: const Text('Open-source licenses'),
            onTap: () {
              unawaited(_showLicenses(context));
            },
          ),
        ],
      ),
    );
  }

  void _setMode(WidgetRef ref, ThemeMode? mode) {
    if (mode == null) return;
    unawaited(ref.read(themeModeProvider.notifier).setMode(mode));
  }

  Future<void> _showLicenses(BuildContext context) async {
    final PackageInfo info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showLicensePage(context: context, applicationName: 'Drausible', applicationVersion: info.version);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _AboutTile extends StatelessWidget {
  const _AboutTile();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (BuildContext context, AsyncSnapshot<PackageInfo> snapshot) {
        final String? version = snapshot.data?.version;
        return ListTile(
          title: const Text('Drausible'),
          subtitle: const Text('Plausible Analytics on your phone'),
          trailing: version == null ? null : Text(version),
        );
      },
    );
  }
}
