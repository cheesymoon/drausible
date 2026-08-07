// Typed errors from the Plausible Stats API. Callers branch on the concrete
// type rather than parsing messages.

abstract class ApiException implements Exception {
  const ApiException();

  String get message;

  @override
  String toString() => message;
}

/// Connection never completed: DNS/refused/timeout/TLS handshake failures,
/// or (when proxied) the SOCKS hop itself.
class NetworkException extends ApiException {
  const NetworkException(this.host, {this.isProxied = false});

  final String host;
  final bool isProxied;

  @override
  String get message =>
      isProxied ? 'Could not reach $host through the proxy' : 'Could not reach $host';
}

class UnauthorizedException extends ApiException {
  const UnauthorizedException();

  @override
  String get message => 'API key rejected';
}

class RateLimitedException extends ApiException {
  const RateLimitedException();

  @override
  String get message => 'Rate limited by server';
}

/// 404 on the API route itself (not a 404 the app expected) — signals the
/// server doesn't speak this API version, driving v1 fallback probing.
class NotFoundEndpointException extends ApiException {
  const NotFoundEndpointException();

  @override
  String get message => 'API endpoint not found';
}

/// Any other non-2xx status, or a 2xx response whose body wasn't the JSON
/// shape expected.
class ServerException extends ApiException {
  const ServerException(this.statusCode);

  final int statusCode;

  @override
  String get message => 'Unexpected server response ($statusCode)';
}
