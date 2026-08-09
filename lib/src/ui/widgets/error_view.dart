// What the user reads when a stats fetch fails: the headline off the
// exception, and a line about what to do with it.

import 'package:flutter/material.dart';

import '../../api/api_exception.dart';

class ErrorDetails {
  const ErrorDetails(this.message, {this.hint, this.canEditServer = false});

  final String message;

  /// The quieter second line. Null where there is nothing honest to suggest.
  final String? hint;

  /// True when the hint points at the server's settings, so there is a button
  /// for getting there.
  final bool canEditServer;
}

/// Kept free of BuildContext so the copy can be tested on its own.
ErrorDetails describeError(Object error) => switch (error) {
  NetworkException(isProxied: true, :final String message) => ErrorDetails(
    message,
    hint:
        'The proxy didn\'t answer. Orbot, or whatever SOCKS5 proxy you use, needs to be running on the '
        'host and port saved here.',
    canEditServer: true,
  ),
  NetworkException(:final String message) => ErrorDetails(
    message,
    hint: 'Check the server URL, and that this phone can reach it.',
    canEditServer: true,
  ),
  UnauthorizedException(:final String message) => ErrorDetails(
    message,
    hint: 'The key may have been revoked, or it may belong to a different Plausible server.',
    canEditServer: true,
  ),
  RateLimitedException(:final String message) => ErrorDetails(
    message,
    hint: 'Plausible allows 600 requests an hour. Live visitors stop for ten minutes and then pick up again.',
  ),
  NotFoundEndpointException(:final String message) => ErrorDetails(
    message,
    hint:
        'This server didn\'t answer on either the v2 or the v1 stats API. The URL should be the '
        'Plausible host itself, not a dashboard page.',
    canEditServer: true,
  ),
  ApiException(:final String message) => ErrorDetails(message),
  _ => const ErrorDetails('Something went wrong'),
};

/// Fills the page, for an overview that failed as a whole.
class ErrorView extends StatelessWidget {
  const ErrorView({required this.error, required this.onRetry, this.onEditServer, super.key});

  final Object error;
  final VoidCallback onRetry;

  /// Null when there is no server left to open.
  final VoidCallback? onEditServer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ErrorDetails details = describeError(error);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(details.message, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            if (details.hint != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                details.hint!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
            if (details.canEditServer && onEditServer != null)
              TextButton(onPressed: onEditServer, child: const Text('Edit server')),
          ],
        ),
      ),
    );
  }
}

/// The same failure in one row, when only a breakdown tab failed.
class InlineErrorView extends StatelessWidget {
  const InlineErrorView({required this.error, required this.onRetry, super.key});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ErrorDetails details = describeError(error);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(details.message, style: theme.textTheme.bodySmall),
                // Clipped rather than allowed to grow: this sits in a tab whose
                // height the rest of the page is anchored to.
                if (details.hint != null)
                  Text(
                    details.hint!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
