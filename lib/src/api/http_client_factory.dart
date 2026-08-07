// Builds an http.Client for a server, routed through its SOCKS5 proxy (e.g.
// Tor) when configured.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart';

import '../models/server.dart';

http.Client buildClientFor(Server server) {
  final ProxyConfig? proxy = server.proxy;
  final HttpClient httpClient = HttpClient()
    ..connectionTimeout = Duration(seconds: proxy == null ? 15 : 30);

  if (proxy != null) {
    // ProxySettings wants an InternetAddress, not a hostname; the UI
    // validates the proxy host is an IP before it ever reaches here.
    final InternetAddress? address = InternetAddress.tryParse(proxy.host);
    if (address == null) {
      throw ArgumentError('Proxy host must be an IP address, got "${proxy.host}"');
    }
    SocksTCPClient.assignToHttpClient(httpClient, <ProxySettings>[ProxySettings(address, proxy.port)]);
  }

  return IOClient(httpClient);
}
