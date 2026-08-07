// A tracked site on a Plausible server.

class Site {
  Site({required this.id, required this.serverId, required this.domain, this.displayName});

  final String id;
  final String serverId;
  final String domain;
  final String? displayName;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'serverId': serverId,
    'domain': domain,
    'displayName': displayName,
  };

  factory Site.fromJson(Map<String, dynamic> json) {
    return Site(
      id: json['id'] as String,
      serverId: json['serverId'] as String,
      domain: json['domain'] as String,
      displayName: json['displayName'] as String?,
    );
  }
}
