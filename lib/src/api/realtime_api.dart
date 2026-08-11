// Current-visitors count over the v1 realtime endpoint. Kept separate from
// PlausibleApiV2 since this is a v1-only route that every Plausible server
// speaks regardless of its v2 support.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'api_http.dart';

class RealtimeApi {
  RealtimeApi(this._client, this._baseUrl, this._apiKey, {bool isProxied = false}) : _isProxied = isProxied;

  final http.Client _client;
  final Uri _baseUrl;
  final String _apiKey;
  final bool _isProxied;

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
    return joinApiPath(
      _baseUrl,
      '/api/v1/stats/realtime/visitors',
    ).replace(queryParameters: <String, String>{'site_id': siteId});
  }

  Future<http.Response> _send(Uri url) {
    return sendRequest(
      url,
      isProxied: _isProxied,
      send: () => _client.get(url, headers: <String, String>{'Authorization': 'Bearer $_apiKey'}),
    );
  }
}
