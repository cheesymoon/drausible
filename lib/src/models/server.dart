// A Plausible server a user has added. Not probed yet if apiVersion is unknown.

/// SOCKS5 proxy, e.g. 127.0.0.1:9050 for routing .onion servers through Tor.
class ProxyConfig {
  ProxyConfig({required this.host, required this.port});

  final String host;
  final int port;

  Map<String, dynamic> toJson() => <String, dynamic>{'host': host, 'port': port};

  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    return ProxyConfig(host: json['host'] as String, port: json['port'] as int);
  }

  @override
  bool operator ==(Object other) => other is ProxyConfig && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

enum ApiVersion { unknown, v1, v2 }

class Server {
  Server({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.proxy,
    this.apiVersion = ApiVersion.unknown,
  });

  final String id;
  final String name;
  final Uri baseUrl;
  final ProxyConfig? proxy;
  final ApiVersion apiVersion;

  /// Pass clearProxy: true to remove an existing proxy (proxy: null alone is
  /// indistinguishable from "leave unchanged").
  Server copyWith({String? name, Uri? baseUrl, ProxyConfig? proxy, bool clearProxy = false, ApiVersion? apiVersion}) {
    return Server(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      proxy: clearProxy ? null : (proxy ?? this.proxy),
      apiVersion: apiVersion ?? this.apiVersion,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'baseUrl': baseUrl.toString(),
    'proxy': proxy?.toJson(),
    'apiVersion': apiVersion.name,
  };

  factory Server.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? proxyJson = json['proxy'] as Map<String, dynamic>?;
    return Server(
      id: json['id'] as String,
      name: json['name'] as String,
      baseUrl: Uri.parse(json['baseUrl'] as String),
      proxy: proxyJson == null ? null : ProxyConfig.fromJson(proxyJson),
      apiVersion: ApiVersion.values.byName(json['apiVersion'] as String? ?? 'unknown'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Server &&
      other.id == id &&
      other.name == name &&
      other.baseUrl == baseUrl &&
      other.proxy == proxy &&
      other.apiVersion == apiVersion;

  @override
  int get hashCode => Object.hash(id, name, baseUrl, proxy, apiVersion);
}
