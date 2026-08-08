// Transport shared by the API clients: joining a path onto a server's base
// url, and the one send path that bounds a request and turns every transport
// failure into a NetworkException.

import 'package:http/http.dart' as http;

import 'api_exception.dart';

// Budget for a whole request, also used as the connect timeout when the client
// is built. Proxied requests get longer: a Tor circuit takes its time before
// any bytes move.
Duration requestTimeout({required bool isProxied}) =>
    isProxied ? const Duration(seconds: 30) : const Duration(seconds: 15);

// Appends path to baseUrl without doubling the slash between them.
Uri joinApiPath(Uri baseUrl, String path) {
  final String base = baseUrl.toString();
  final String trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return Uri.parse('$trimmed$path');
}

// Runs send under an overall timeout and reports anything the transport throws
// as a NetworkException for url's host. The timeout is the point: HttpClient's
// connectionTimeout only covers the connect, so a connection that stalls after
// that would otherwise hang forever.
Future<http.Response> sendRequest(
  Uri url, {
  required bool isProxied,
  required Future<http.Response> Function() send,
}) async {
  try {
    return await send().timeout(requestTimeout(isProxied: isProxied));
  } on ApiException {
    rethrow;
  } on Exception {
    // Broad on purpose. Covers SocketException, TimeoutException,
    // HandshakeException, http.ClientException (what IOClient makes of a
    // dart:io HttpException, e.g. a client closed mid-request) and the bare
    // Exception socks5_proxy throws when the hop fails after the handshake
    // ("Command handling failed. With error: hostUnreachable"). Error
    // subclasses are not Exceptions, so real bugs still surface.
    throw NetworkException(url.host, isProxied: isProxied);
  }
}
