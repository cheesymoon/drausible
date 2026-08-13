import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/server.dart';
import '../models/site.dart';

const String backupFormat = 'drausible.backup';
const int backupVersion = 1;
const int defaultBackupIterations = 150000;

/// Room for a future version to raise the work factor, without letting a
/// corrupt or hostile envelope stall an old phone for tens of seconds before
/// the passphrase can even be reported as wrong.
const int maxBackupIterations = 300000;

const int _saltLength = 16;
const int _nonceLength = 12;
const int _gcmMacLength = 16;

class BackupPayload {
  const BackupPayload({required this.servers, required this.sites, required this.apiKeys});

  final List<Server> servers;
  final List<Site> sites;
  final Map<String, String> apiKeys;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schemaVersion': 1,
    'servers': <dynamic>[for (final Server server in servers) server.toJson()],
    'sites': <dynamic>[for (final Site site in sites) site.toJson()],
    'apiKeys': apiKeys,
  };

  factory BackupPayload.fromJson(Map<String, dynamic> json) {
    final List<dynamic> serversJson = json['servers'] as List<dynamic>? ?? <dynamic>[];
    final List<dynamic> sitesJson = json['sites'] as List<dynamic>? ?? <dynamic>[];
    final Map<String, dynamic> apiKeysJson = json['apiKeys'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return BackupPayload(
      servers: <Server>[for (final dynamic server in serversJson) Server.fromJson(server as Map<String, dynamic>)],
      sites: <Site>[for (final dynamic site in sitesJson) Site.fromJson(site as Map<String, dynamic>)],
      apiKeys: <String, String>{
        for (final MapEntry<String, dynamic> entry in apiKeysJson.entries) entry.key: entry.value as String,
      },
    );
  }
}

enum BackupExceptionKind { wrongPassphrase, malformed, unsupportedVersion }

class BackupException implements Exception {
  const BackupException(this.kind, [this.message]);

  final BackupExceptionKind kind;
  final String? message;

  @override
  String toString() => 'BackupException($kind${message == null ? '' : ': $message'})';
}

class BackupCodec {
  BackupCodec({Random? random, Pbkdf2? kdf, AesGcm? cipher, this.defaultIterations = defaultBackupIterations})
    : _random = random ?? Random.secure(),
      _kdfFactory = kdf == null ? _defaultKdf : ((int _) => kdf),
      _cipher = cipher ?? AesGcm.with256bits();

  final Random _random;
  final Pbkdf2 Function(int iterations) _kdfFactory;
  final AesGcm _cipher;
  final int defaultIterations;

  Future<String> encode(BackupPayload payload, String passphrase, {int? iterations}) async {
    final int iterationCount = iterations ?? defaultIterations;
    _validateIterations(iterationCount);

    final List<int> salt = _randomBytes(_saltLength);
    final List<int> nonce = _randomBytes(_nonceLength);
    final SecretKey secretKey = await _deriveKey(passphrase, salt, iterationCount);
    final List<int> plainText = utf8.encode(jsonEncode(payload.toJson()));
    final SecretBox box = await _cipher.encrypt(plainText, secretKey: secretKey, nonce: nonce);
    final List<int> cipherTextWithTag = <int>[...box.cipherText, ...box.mac.bytes];

    return jsonEncode(<String, dynamic>{
      'format': backupFormat,
      'version': backupVersion,
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': iterationCount,
      'salt': base64Encode(salt),
      'cipher': 'aes-256-gcm',
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(cipherTextWithTag),
    });
  }

  Future<BackupPayload> decode(String envelopeJson, String passphrase) async {
    final Map<String, dynamic> envelope = _decodeEnvelope(envelopeJson);
    _validateEnvelope(envelope);

    final int iterations = envelope['iterations'] as int;
    final List<int> salt = _decodeBase64Field(envelope, 'salt', _saltLength);
    final List<int> nonce = _decodeBase64Field(envelope, 'nonce', _nonceLength);
    final List<int> cipherTextWithTag = _decodeBase64Field(envelope, 'ciphertext', null);
    if (cipherTextWithTag.length <= _gcmMacLength) {
      throw const BackupException(BackupExceptionKind.malformed, 'ciphertext is too short');
    }

    final int tagStart = cipherTextWithTag.length - _gcmMacLength;
    final SecretBox box = SecretBox(
      cipherTextWithTag.sublist(0, tagStart),
      nonce: nonce,
      mac: Mac(cipherTextWithTag.sublist(tagStart)),
    );
    final SecretKey secretKey = await _deriveKey(passphrase, salt, iterations);

    final List<int> clearBytes;
    try {
      clearBytes = await _cipher.decrypt(box, secretKey: secretKey);
    } on SecretBoxAuthenticationError {
      throw const BackupException(BackupExceptionKind.wrongPassphrase);
    }

    try {
      final Object? payloadJson = jsonDecode(utf8.decode(clearBytes));
      if (payloadJson is! Map<String, dynamic>) {
        throw const FormatException('payload is not an object');
      }
      final int schemaVersion = payloadJson['schemaVersion'] as int? ?? 1;
      if (schemaVersion != 1) {
        throw const BackupException(BackupExceptionKind.unsupportedVersion);
      }
      return BackupPayload.fromJson(payloadJson);
    } on BackupException {
      rethrow;
    } on Object catch (error) {
      throw BackupException(BackupExceptionKind.malformed, error.toString());
    }
  }

  List<int> _randomBytes(int length) {
    return Uint8List.fromList(<int>[for (int i = 0; i < length; i++) _random.nextInt(256)]);
  }

  Future<SecretKey> _deriveKey(String passphrase, List<int> salt, int iterations) {
    return _kdfFactory(iterations).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
  }

  static Pbkdf2 _defaultKdf(int iterations) => Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);

  static Map<String, dynamic> _decodeEnvelope(String envelopeJson) {
    try {
      final Object? decoded = jsonDecode(envelopeJson);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('envelope is not an object');
      }
      return decoded;
    } on Object catch (error) {
      throw BackupException(BackupExceptionKind.malformed, error.toString());
    }
  }

  static void _validateEnvelope(Map<String, dynamic> envelope) {
    if (envelope['format'] != backupFormat) {
      throw const BackupException(BackupExceptionKind.malformed, 'unsupported format');
    }
    if (envelope['version'] != backupVersion) {
      throw const BackupException(BackupExceptionKind.unsupportedVersion);
    }
    if (envelope['kdf'] != 'pbkdf2-hmac-sha256' || envelope['cipher'] != 'aes-256-gcm') {
      throw const BackupException(BackupExceptionKind.unsupportedVersion);
    }
    final Object? iterations = envelope['iterations'];
    if (iterations is! int) {
      throw const BackupException(BackupExceptionKind.malformed, 'invalid iterations');
    }
    _validateIterations(iterations);
  }

  static void _validateIterations(int iterations) {
    if (iterations <= 0 || iterations > maxBackupIterations) {
      throw const BackupException(BackupExceptionKind.malformed, 'invalid iterations');
    }
  }

  static List<int> _decodeBase64Field(Map<String, dynamic> envelope, String field, int? expectedLength) {
    try {
      final Object? value = envelope[field];
      if (value is! String) {
        throw FormatException('$field is not a string');
      }
      final List<int> bytes = base64Decode(value);
      if (expectedLength != null && bytes.length != expectedLength) {
        throw FormatException('$field has the wrong length');
      }
      return bytes;
    } on Object catch (error) {
      throw BackupException(BackupExceptionKind.malformed, error.toString());
    }
  }
}
