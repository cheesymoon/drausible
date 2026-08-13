import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:drausible/src/backup/backup_codec.dart';
import 'package:drausible/src/models/server.dart';
import 'package:drausible/src/models/site.dart';

BackupExceptionKind _kind(Object error) => (error as BackupException).kind;

Matcher throwsBackup(BackupExceptionKind kind) {
  return throwsA(isA<BackupException>().having(_kind, 'kind', kind));
}

void main() {
  final Server server = Server(
    id: 'srv1',
    name: 'Self-hosted',
    baseUrl: Uri.parse('https://plausible.example.org'),
    proxy: ProxyConfig(host: '127.0.0.1', port: 9050),
    apiVersion: ApiVersion.v2,
  );
  final Site site = Site(id: 'site1', serverId: 'srv1', domain: 'example.com', displayName: 'Example');
  final BackupPayload payload = BackupPayload(
    servers: <Server>[server],
    sites: <Site>[site],
    apiKeys: const <String, String>{'srv1': 'secret-key'},
  );

  test('round trip preserves servers, sites, and api keys', () async {
    final BackupCodec codec = BackupCodec(random: Random(1), defaultIterations: 2);

    final String envelope = await codec.encode(payload, 'correct horse battery staple');
    final Map<String, dynamic> envelopeJson = jsonDecode(envelope) as Map<String, dynamic>;
    final BackupPayload decoded = await codec.decode(envelope, 'correct horse battery staple');

    expect(envelopeJson['format'], backupFormat);
    expect(envelopeJson['version'], backupVersion);
    expect(envelopeJson['kdf'], 'pbkdf2-hmac-sha256');
    expect(envelopeJson['iterations'], 2);
    expect(envelopeJson['cipher'], 'aes-256-gcm');
    expect(envelope, isNot(contains('secret-key')));
    expect(decoded.servers.single, server);
    expect(decoded.sites.single.domain, 'example.com');
    expect(decoded.sites.single.displayName, 'Example');
    expect(decoded.apiKeys, <String, String>{'srv1': 'secret-key'});
  });

  test('wrong passphrase raises wrongPassphrase', () async {
    final BackupCodec codec = BackupCodec(random: Random(2), defaultIterations: 2);
    final String envelope = await codec.encode(payload, 'correct horse battery staple');

    await expectLater(codec.decode(envelope, 'wrong passphrase'), throwsBackup(BackupExceptionKind.wrongPassphrase));
  });

  test('tampered ciphertext raises wrongPassphrase', () async {
    final BackupCodec codec = BackupCodec(random: Random(3), defaultIterations: 2);
    final String envelope = await codec.encode(payload, 'correct horse battery staple');
    final Map<String, dynamic> json = jsonDecode(envelope) as Map<String, dynamic>;
    final List<int> cipherText = base64Decode(json['ciphertext'] as String);
    cipherText[0] ^= 1;
    json['ciphertext'] = base64Encode(cipherText);

    await expectLater(
      codec.decode(jsonEncode(json), 'correct horse battery staple'),
      throwsBackup(BackupExceptionKind.wrongPassphrase),
    );
  });

  test('malformed JSON raises malformed', () async {
    final BackupCodec codec = BackupCodec(defaultIterations: 2);

    await expectLater(codec.decode('not json', 'passphrase'), throwsBackup(BackupExceptionKind.malformed));
  });

  test('iteration count above the supported maximum raises malformed before deriving a key', () async {
    final BackupCodec codec = BackupCodec(random: Random(4), defaultIterations: 2);
    final String envelope = await codec.encode(payload, 'correct horse battery staple');
    final Map<String, dynamic> json = jsonDecode(envelope) as Map<String, dynamic>
      ..['iterations'] = maxBackupIterations + 1;

    await expectLater(
      codec.decode(jsonEncode(json), 'correct horse battery staple'),
      throwsBackup(BackupExceptionKind.malformed),
    );
  });

  test('future envelope version raises unsupportedVersion', () async {
    final BackupCodec codec = BackupCodec(random: Random(5), defaultIterations: 2);
    final String envelope = await codec.encode(payload, 'correct horse battery staple');
    final Map<String, dynamic> json = jsonDecode(envelope) as Map<String, dynamic>..['version'] = backupVersion + 1;

    await expectLater(
      codec.decode(jsonEncode(json), 'correct horse battery staple'),
      throwsBackup(BackupExceptionKind.unsupportedVersion),
    );
  });

  test('empty config round trips', () async {
    final BackupCodec codec = BackupCodec(random: Random(6), defaultIterations: 2);
    const BackupPayload empty = BackupPayload(servers: <Server>[], sites: <Site>[], apiKeys: <String, String>{});

    final BackupPayload decoded = await codec.decode(await codec.encode(empty, 'correct horse'), 'correct horse');

    expect(decoded.servers, isEmpty);
    expect(decoded.sites, isEmpty);
    expect(decoded.apiKeys, isEmpty);
  });
}
