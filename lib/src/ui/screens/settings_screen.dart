import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

import '../../backup/backup_codec.dart';
import '../../models/server.dart';
import '../../providers/config_providers.dart';
import '../../providers/settings_providers.dart';
import '../../providers/stats_providers.dart';
import '../../repositories/config_repository.dart';

const int _minPassphraseLength = 8;

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Deriving the key from the passphrase runs on this isolate and takes seconds
  // on the old phones this app supports, so the tile has to show it is working
  // and refuse the second tap that would start a second derivation.
  _BackupTask? _task;

  @override
  Widget build(BuildContext context) {
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
          const _SectionHeader('Backup'),
          ListTile(
            title: const Text('Export backup'),
            subtitle: const Text('Encrypt servers, sites, and API keys'),
            trailing: _task == _BackupTask.export ? const _TaskSpinner() : null,
            onTap: _task != null
                ? null
                : () {
                    unawaited(_exportBackup(context, ref));
                  },
          ),
          ListTile(
            title: const Text('Import backup'),
            subtitle: const Text('Replace this device config from an encrypted backup'),
            trailing: _task == _BackupTask.import ? const _TaskSpinner() : null,
            onTap: _task != null
                ? null
                : () {
                    unawaited(_importBackup(context, ref));
                  },
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

  /// Marks a backup task as running for as long as [action] takes, which both
  /// shows the spinner and leaves the tiles unresponsive to a second tap.
  Future<T> _whileBusy<T>(_BackupTask task, Future<T> Function() action) async {
    setState(() => _task = task);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _task = null);
    }
  }

  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    final String? passphrase = await _showPassphraseDialog(context, mode: _PassphraseMode.create);
    if (passphrase == null) return;

    final _ExportTarget? target = context.mounted ? await _chooseExportTarget(context) : null;
    if (target == null) return;

    try {
      final String envelope = await _whileBusy(_BackupTask.export, () async {
        final BackupPayload payload = await ref.read(configProvider.notifier).exportBackupPayload();
        return ref.read(backupCodecProvider).encode(payload, passphrase);
      });

      switch (target) {
        case _ExportTarget.clipboard:
          await Clipboard.setData(ClipboardData(text: envelope));
          if (context.mounted) _showSnackBar(context, 'Backup copied to clipboard');
          break;
        case _ExportTarget.save:
          // A null path means the save sheet was dismissed, which is not
          // something to report back as a result.
          if (await _saveBackupFile(envelope) == null) return;
          if (context.mounted) _showSnackBar(context, 'Backup saved');
          break;
        case _ExportTarget.file:
          await _shareBackupFile(envelope);
          if (context.mounted) _showSnackBar(context, 'Backup ready to share');
          break;
      }
    } on Object {
      if (context.mounted) _showSnackBar(context, 'Backup export failed');
    }
  }

  Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    final _ImportSource? source = await _chooseImportSource(context);
    if (source == null) return;

    try {
      final String? envelope = await _readImportEnvelope(source);
      if (envelope == null || envelope.trim().isEmpty) {
        if (context.mounted) _showSnackBar(context, 'No backup found');
        return;
      }

      final String? passphrase = context.mounted
          ? await _showPassphraseDialog(context, mode: _PassphraseMode.enter)
          : null;
      if (passphrase == null) return;

      final BackupPayload payload = await _whileBusy(
        _BackupTask.import,
        () => ref.read(backupCodecProvider).decode(envelope, passphrase),
      );
      final ConfigState current = (await ref.read(configRepositoryProvider.future)).state;
      final bool confirmed = context.mounted ? await _confirmImport(context, current, payload) : false;
      if (!confirmed) return;

      await ref.read(configProvider.notifier).importBackup(payload);
      _invalidateStatsAfterImport(ref, current, payload);
      if (context.mounted) _showSnackBar(context, 'Backup imported');
    } on BackupException catch (error) {
      if (context.mounted) _showSnackBar(context, _backupErrorMessage(error));
    } on Object {
      if (context.mounted) _showSnackBar(context, 'Backup import failed');
    }
  }

  Future<String?> _readImportEnvelope(_ImportSource source) async {
    switch (source) {
      case _ImportSource.clipboard:
        final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
        return data?.text;
      case _ImportSource.file:
        const file_selector.XTypeGroup jsonFiles = file_selector.XTypeGroup(
          label: 'Drausible backup',
          extensions: <String>['json'],
        );
        final file_selector.XFile? file = await file_selector.openFile(
          acceptedTypeGroups: <file_selector.XTypeGroup>[jsonFiles],
        );
        return file?.readAsString();
    }
  }

  Future<String?> _saveBackupFile(String envelope) {
    return FilePicker.saveFile(
      dialogTitle: 'Save Drausible backup',
      fileName: _backupFileName(),
      bytes: utf8.encode(envelope),
    );
  }

  Future<void> _shareBackupFile(String envelope) async {
    final Directory tempDirectory = await getTemporaryDirectory();
    final File file = File('${tempDirectory.path}/${_backupFileName()}');
    await file.writeAsString(envelope);
    await share_plus.SharePlus.instance.share(
      share_plus.ShareParams(
        files: <share_plus.XFile>[share_plus.XFile(file.path, mimeType: 'application/json')],
        subject: 'Drausible backup',
      ),
    );
  }

  String _backupFileName() => 'drausible-backup-${_timestamp()}.json';

  String _timestamp() {
    final DateTime now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<_ExportTarget?> _chooseExportTarget(BuildContext context) {
    return showDialog<_ExportTarget>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('Export backup'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_ExportTarget.clipboard),
            child: const Text('Copy to clipboard'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_ExportTarget.save),
            child: const Text('Save to file'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_ExportTarget.file),
            child: const Text('Share file'),
          ),
        ],
      ),
    );
  }

  Future<_ImportSource?> _chooseImportSource(BuildContext context) {
    return showDialog<_ImportSource>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('Import backup'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_ImportSource.clipboard),
            child: const Text('Paste from clipboard'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_ImportSource.file),
            child: const Text('Pick file'),
          ),
        ],
      ),
    );
  }

  Future<String?> _showPassphraseDialog(BuildContext context, {required _PassphraseMode mode}) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) => _PassphraseDialog(mode: mode),
    );
  }

  Future<bool> _confirmImport(BuildContext context, ConfigState current, BackupPayload incoming) async {
    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Replace current config?'),
            content: Text(
              'Replace ${_count(current.servers.length, 'server')} / ${_count(current.sites.length, 'site')} '
              'with ${_count(incoming.servers.length, 'server')} / ${_count(incoming.sites.length, 'site')}?',
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Replace')),
            ],
          ),
        ) ??
        false;
  }

  String _count(int count, String label) => '$count $label${count == 1 ? '' : 's'}';

  String _backupErrorMessage(BackupException error) {
    return switch (error.kind) {
      BackupExceptionKind.wrongPassphrase => 'Wrong passphrase or damaged backup',
      BackupExceptionKind.unsupportedVersion => 'This backup version is not supported',
      BackupExceptionKind.malformed => 'This is not a valid Drausible backup',
    };
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _invalidateStatsAfterImport(WidgetRef ref, ConfigState previous, BackupPayload incoming) {
    final Set<String> serverIds = <String>{
      for (final Server server in previous.servers) server.id,
      for (final Server server in incoming.servers) server.id,
    };
    for (final String serverId in serverIds) {
      ref.invalidate(apiVersionResolverProvider(serverId));
    }
    ref.invalidate(statsRepositoryProvider);
  }
}

enum _BackupTask { export, import }

class _TaskSpinner extends StatelessWidget {
  const _TaskSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2));
  }
}

enum _ExportTarget { clipboard, save, file }

enum _ImportSource { clipboard, file }

enum _PassphraseMode { create, enter }

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.mode});

  final _PassphraseMode mode;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _passphraseController = TextEditingController();
  final TextEditingController _confirmationController = TextEditingController();

  bool get _isCreate => widget.mode == _PassphraseMode.create;

  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // The keyboard is up the whole time this dialog is on screen, which
      // leaves create mode taller than what is left of a phone display.
      scrollable: true,
      title: Text(_isCreate ? 'Choose backup passphrase' : 'Enter backup passphrase'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_isCreate)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'This passphrase is not stored and cannot be recovered. Without it, the backup cannot be restored.',
                ),
              ),
            TextFormField(
              controller: _passphraseController,
              decoration: const InputDecoration(labelText: 'Passphrase'),
              obscureText: true,
              validator: (String? value) {
                if ((value ?? '').length < _minPassphraseLength) {
                  return 'Use at least $_minPassphraseLength characters';
                }
                return null;
              },
            ),
            if (_isCreate)
              TextFormField(
                controller: _confirmationController,
                decoration: const InputDecoration(labelText: 'Repeat passphrase'),
                obscureText: true,
                validator: (String? value) {
                  if (value != _passphraseController.text) {
                    return 'Passphrases do not match';
                  }
                  return null;
                },
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              Navigator.of(context).pop(_passphraseController.text);
            }
          },
          child: Text(_isCreate ? 'Continue' : 'Unlock'),
        ),
      ],
    );
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
        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
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
