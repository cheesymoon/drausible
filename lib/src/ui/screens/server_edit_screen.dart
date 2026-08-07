import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/id.dart';
import '../../models/server.dart';
import '../../providers/config_providers.dart';

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
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://plausible.example.org',
              ),
              keyboardType: TextInputType.url,
              validator: _validateUrl,
            ),
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
                decoration: const InputDecoration(
                  labelText: 'Proxy host',
                  helperText: 'IP address, e.g. 127.0.0.1',
                ),
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
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : () => unawaited(_save()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
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
      final Server server = Server(
        id: generateId(),
        name: _nameController.text.trim(),
        baseUrl: baseUrl,
        proxy: proxy,
      );
      await notifier.addServer(server, apiKey!);
    } else {
      final Server server = existing.copyWith(
        name: _nameController.text.trim(),
        baseUrl: baseUrl,
        proxy: proxy,
        clearProxy: proxy == null,
      );
      await notifier.updateServer(server, apiKey: apiKey);
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }
}
