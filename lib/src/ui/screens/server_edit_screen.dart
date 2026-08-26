import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/id.dart';
import '../../models/server.dart';
import '../../models/site.dart';
import '../../providers/config_providers.dart';
import '../../providers/stats_providers.dart';
import '../../repositories/config_repository.dart';
import '../../repositories/stats_repository.dart';

/// Create mode when server is null, edit mode (prefilled) otherwise.
class ServerEditScreen extends ConsumerStatefulWidget {
  const ServerEditScreen({this.server, super.key});

  final Server? server;

  @override
  ConsumerState<ServerEditScreen> createState() => _ServerEditScreenState();
}

class _ServerEditScreenState extends ConsumerState<ServerEditScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _proxyHostController;
  late final TextEditingController _proxyPortController;

  late bool _useProxy;
  late bool _insecure;
  late final bool _acknowledgedAtOpen;
  bool _obscureApiKey = true;
  bool _saving = false;

  bool get _isEditing => widget.server != null;

  @override
  void initState() {
    super.initState();
    final Server? server = widget.server;
    _nameController = TextEditingController(text: server?.name ?? '');
    _urlController = TextEditingController(text: server?.baseUrl.toString() ?? '');
    _apiKeyController = TextEditingController();
    _useProxy = server?.proxy != null;
    _proxyHostController = TextEditingController(text: server?.proxy?.host ?? '127.0.0.1');
    _proxyPortController = TextEditingController(text: (server?.proxy?.port ?? 9050).toString());

    _insecure = _isInsecure(_urlController.text);
    // A server already stored on http was acknowledged when it was added.
    // Renaming it shouldn't mean ticking the box a second time.
    _acknowledgedAtOpen = _insecure;
    _urlController.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _apiKeyController.dispose();
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit server' : 'Add server')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Server name'),
              validator: (String? value) => (value == null || value.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'Base URL', hintText: 'https://plausible.example.org'),
              keyboardType: TextInputType.url,
              validator: _validateUrl,
            ),
            if (_insecure) ...<Widget>[const SizedBox(height: 12), _buildInsecureWarning()],
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiKeyController,
              obscureText: _obscureApiKey,
              decoration: InputDecoration(
                labelText: 'API key',
                helperText: _isEditing ? 'Leave blank to keep the current key.' : null,
                suffixIcon: IconButton(
                  icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                ),
              ),
              validator: _validateApiKey,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Connect through SOCKS5 proxy'),
              value: _useProxy,
              onChanged: (bool value) => setState(() => _useProxy = value),
            ),
            if (_useProxy) ...<Widget>[
              TextFormField(
                controller: _proxyHostController,
                decoration: const InputDecoration(labelText: 'Proxy host', helperText: 'IP address, e.g. 127.0.0.1'),
                // The SOCKS client wants a literal IP; hostnames would only
                // blow up later when the first request goes out.
                validator: (String? value) {
                  final String host = value?.trim() ?? '';
                  if (host.isEmpty) return 'Enter a host';
                  if (InternetAddress.tryParse(host) == null) {
                    return 'Use an IP address (hostnames don\'t work here)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _proxyPortController,
                decoration: const InputDecoration(labelText: 'Proxy port'),
                keyboardType: TextInputType.number,
                validator: _validateProxyPort,
              ),
              const SizedBox(height: 8),
              Text(
                'For .onion addresses, run Orbot and point this at its SOCKS5 port.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_isEditing) _buildApiVersionRow(),
            const SizedBox(height: 24),
            FilledButton(onPressed: _saving ? null : () => unawaited(_save()), child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  void _onUrlChanged() {
    final bool insecure = _isInsecure(_urlController.text);
    if (insecure != _insecure) setState(() => _insecure = insecure);
  }

  /// Tor encrypts and authenticates the hop itself, so plain http to a .onion
  /// host is not the cleartext problem this warns about.
  static bool _isInsecure(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'http') return false;
    return !uri.host.toLowerCase().endsWith('.onion');
  }

  /// Only ever built for an http host. The checkbox is a form field so Save
  /// refuses to go through until it is ticked.
  Widget _buildInsecureWarning() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return FormField<bool>(
      initialValue: _acknowledgedAtOpen,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (bool? acknowledged) => (acknowledged ?? false) ? null : 'Tick the box to connect over http',
      builder: (FormFieldState<bool> field) {
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          decoration: BoxDecoration(
            color: colors.errorContainer,
            border: Border.all(color: colors.error),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, color: colors.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Unencrypted connection',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: colors.onErrorContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Your API key and your stats cross the network in the clear, where anyone '
                          'else on it can read them. Inside a WireGuard or Tailscale tunnel they are '
                          'already encrypted. On shared wifi, assume they are not.',
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: colors.error,
                checkColor: colors.onError,
                title: Text(
                  'I know what I\'m doing',
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.onErrorContainer),
                ),
                value: field.value ?? false,
                onChanged: (bool? value) => field.didChange(value ?? false),
              ),
              if (field.hasError)
                Text(
                  field.errorText!,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.error, fontWeight: FontWeight.bold),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Edit mode only. The version is read off the live config rather than the
  /// server this screen opened with, so one detected while the screen sits
  /// open shows up here.
  Widget _buildApiVersionRow() {
    final Server server = widget.server!;
    final ApiVersion version = ref.watch(
      configProvider.select(
        (ConfigState config) =>
            config.servers.firstWhere((Server s) => s.id == server.id, orElse: () => server).apiVersion,
      ),
    );

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Stats API'),
      subtitle: Text(_versionLabel(version)),
      trailing: TextButton(onPressed: () => unawaited(_reCheck(server.id)), child: const Text('Re-check')),
    );
  }

  static String _versionLabel(ApiVersion version) => switch (version) {
    ApiVersion.v2 => 'Version 2',
    ApiVersion.v1 => 'Version 1, as older servers use',
    ApiVersion.unknown => 'Not detected yet',
  };

  /// Forgets the detected version. Nothing goes out over the network here; the
  /// next stats load works it out again.
  Future<void> _reCheck(String serverId) async {
    final ConfigState config = ref.read(configProvider);
    final Server current = config.servers.firstWhere((Server s) => s.id == serverId, orElse: () => widget.server!);

    // The write has to land before the invalidate: the resolver seeds itself
    // from the config it is built with, so dropping it first would only bring
    // back the version we are trying to forget.
    await ref.read(configProvider.notifier).updateServer(current.copyWith(apiVersion: ApiVersion.unknown));
    if (!mounted) return;
    ref.invalidate(apiVersionResolverProvider(serverId));

    // Whatever is still in the 60s cache was fetched through the old version,
    // and a cache hit never reaches the resolver at all.
    final StatsRepository repository = ref.read(statsRepositoryProvider);
    for (final Site site in config.sites.where((Site s) => s.serverId == serverId)) {
      repository.evictSite(serverId, site.domain);
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Cleared. The next stats load detects it again.')));
  }

  String? _validateApiKey(String? value) {
    if (_isEditing) return null;
    return (value == null || value.isEmpty) ? 'Enter an API key' : null;
  }

  String? _validateUrl(String? value) {
    final String text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter a base URL';
    final Uri? uri = Uri.tryParse(text);
    if (uri == null || !uri.isAbsolute || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return 'Enter a valid http or https URL';
    }
    if (uri.host.toLowerCase().endsWith('.onion') && !_useProxy) {
      return 'Tor (.onion) addresses need the SOCKS5 proxy turned on';
    }
    return null;
  }

  String? _validateProxyPort(String? value) {
    final int? port = int.tryParse(value ?? '');
    if (port == null || port <= 0 || port > 65535) return 'Enter a valid port';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final Uri baseUrl = Uri.parse(_urlController.text.trim());
    final ProxyConfig? proxy = _useProxy
        ? ProxyConfig(host: _proxyHostController.text.trim(), port: int.parse(_proxyPortController.text.trim()))
        : null;
    final String? apiKey = _apiKeyController.text.isEmpty ? null : _apiKeyController.text;

    final ConfigNotifier notifier = ref.read(configProvider.notifier);
    final Server? existing = widget.server;
    if (existing == null) {
      final Server server = Server(id: generateId(), name: _nameController.text.trim(), baseUrl: baseUrl, proxy: proxy);
      await notifier.addServer(server, apiKey!);
    } else {
      // A different host is a different server: what the old one spoke says
      // nothing about this one.
      final bool hostChanged = baseUrl != existing.baseUrl;
      final Server server = existing.copyWith(
        name: _nameController.text.trim(),
        baseUrl: baseUrl,
        proxy: proxy,
        clearProxy: proxy == null,
        apiVersion: hostChanged ? ApiVersion.unknown : null,
      );
      await notifier.updateServer(server, apiKey: apiKey);
      // The resolver holds the old host's answer in memory for the app's
      // lifetime, so the reset above would never be read without this.
      if (hostChanged && mounted) ref.invalidate(apiVersionResolverProvider(existing.id));
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }
}
