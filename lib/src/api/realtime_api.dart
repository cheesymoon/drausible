// Current-visitors count over the v1 realtime endpoint. Kept separate from
// PlausibleApiV2 since this is a v1-only route that every Plausible server
// speaks regardless of its v2 support.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

class RealtimeApi {
  RealtimeApi(this._client, this._baseUrl, this._apiKey);

  final http.Client _client;
  final Uri _baseUrl;
  final String _apiKey;

  Future<int> currentVisitors(String siteId) async {
    final http.Response response = await _send(_visitorsUrl(siteId));
    throwForStatusCode(response.statusCode);
    try {
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! int) throw const FormatException('response body is not an integer');
      return decoded;
    } on FormatException {
      throw ServerException(response.statusCode);
    }
  }

  Uri _visitorsUrl(String siteId) {
    final String base = _baseUrl.toString();
    final String trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return Uri.parse('$trimmed/api/v1/stats/realtime/visitors')
        .replace(queryParameters: <String, String>{'site_id': siteId});
  }

  Future<http.Response> _send(Uri url) async {
    try {
      return await _client.get(url, headers: <String, String>{'Authorization': 'Bearer $_apiKey'});
    } on SocketException {
      throw NetworkException(url.host);
    } on TimeoutException {
      throw NetworkException(url.host);
    } on HandshakeException {
      throw NetworkException(url.host);
    }
  }
}
