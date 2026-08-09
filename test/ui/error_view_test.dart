import 'package:flutter_test/flutter_test.dart';

import 'package:drausible/src/api/api_exception.dart';
import 'package:drausible/src/ui/widgets/error_view.dart';

void main() {
  test('a proxied connection failure blames the proxy, not the server', () {
    final ErrorDetails details = describeError(const NetworkException('example.onion', isProxied: true));

    expect(details.message, 'Could not reach example.onion through the proxy');
    expect(details.hint, contains('Orbot'));
    // The hint sends the reader to the proxy host and port, so it offers a
    // way to get there.
    expect(details.canEditServer, isTrue);
  });

  test('a plain connection failure points at the URL and the phone', () {
    final ErrorDetails details = describeError(const NetworkException('plausible.example.org'));

    expect(details.message, 'Could not reach plausible.example.org');
    expect(details.hint, contains('server URL'));
    expect(details.hint, isNot(contains('Orbot')));
  });

  test('a rejected key offers the server settings', () {
    final ErrorDetails details = describeError(const UnauthorizedException());

    expect(details.message, 'API key rejected');
    expect(details.hint, contains('revoked'));
    expect(details.canEditServer, isTrue);
  });

  test('rate limiting names the hourly allowance and the realtime pause', () {
    final ErrorDetails details = describeError(const RateLimitedException());

    expect(details.message, 'Rate limited by server');
    expect(details.hint, contains('600'));
    expect(details.hint, contains('Live visitors'));
    // Nothing in the server's settings would help with waiting.
    expect(details.canEditServer, isFalse);
  });

  test('a missing endpoint says the URL should be the Plausible host', () {
    final ErrorDetails details = describeError(const NotFoundEndpointException());

    expect(details.message, 'API endpoint not found');
    expect(details.hint, contains('dashboard page'));
    expect(details.canEditServer, isTrue);
  });

  test('an unexpected status carries the message alone', () {
    final ErrorDetails details = describeError(const ServerException(503));

    expect(details.message, 'Unexpected server response (503)');
    expect(details.hint, isNull);
  });

  test('anything that is not an ApiException falls back', () {
    final ErrorDetails details = describeError(StateError('no site with id site1'));

    expect(details.message, 'Something went wrong');
    expect(details.hint, isNull);
    expect(details.canEditServer, isFalse);
  });
}
