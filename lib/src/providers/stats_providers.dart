// Riverpod wiring for the stats domain. No codegen, just plain providers.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api/api_exception.dart';
import '../api/http_client_factory.dart';
import '../api/plausible_api_fallback.dart';
import '../api/realtime_api.dart';
import '../models/date_range.dart';
import '../models/server.dart';
import '../models/site.dart';
import '../models/stats.dart';
import '../repositories/config_repository.dart';
import '../repositories/stats_repository.dart';
import 'config_providers.dart';

// A server or site can be deleted while a provider keyed by its id is still
// alive: a dashboard mid-refresh, a preview still loading. Plain firstWhere
// answers that with a bare StateError; these say what went missing.
Server? _serverOrNull(ConfigState config, String serverId) {
  for (final Server server in config.servers) {
    if (server.id == serverId) return server;
  }
  return null;
}

Server _serverById(ConfigState config, String serverId) =>
    _serverOrNull(config, serverId) ?? (throw StateError('No server with id $serverId'));

Site _siteById(ConfigState config, String siteId) => config.sites.firstWhere(
  (Site s) => s.id == siteId,
  orElse: () => throw StateError('No site with id $siteId'),
);

/// One http.Client per server, rebuilt (and the old one closed) whenever that
/// server's transport changes.
final ProviderFamily<http.Client, String> httpClientProvider = Provider.family<http.Client, String>((
  ref,
  serverId,
) {
  // Narrowed to the proxy on purpose, since it is all buildClientFor reads.
  // Watching the whole Server would close this client when a rename, or a
  // freshly probed api version, is written, and IOClient.close() aborts the
  // requests it still has in flight.
  final ProxyConfig? proxy = ref.watch(
    configProvider.select((ConfigState config) => _serverById(config, serverId).proxy),
  );
  final http.Client client = buildClientFor(proxy);
  ref.onDispose(client.close);
  return client;
});

/// Which stats API each server speaks, held in memory for the app's lifetime.
/// Seeded from the persisted version, so a server detected on an earlier run
/// never probes again. Invalidate an entry to force a re-probe ("Re-check").
final ProviderFamily<ApiVersionResolver, String> apiVersionResolverProvider =
    Provider.family<ApiVersionResolver, String>((ref, serverId) {
      // read, not watch: the probe's answer is written back to this very
      // server, and rebuilding on that would throw the answer away.
      return ApiVersionResolver(_serverById(ref.read(configProvider), serverId).apiVersion);
    });

/// Servers that have answered 429, and when they may be asked again. Plausible
/// allows 600 requests an hour and the realtime badge alone spends 120 of them,
/// so polling straight through a 429 keeps the account locked out for longer.
/// Any fetch that hits the limit trips this; it lapses on its own.
class RateLimitGate {
  RateLimitGate({DateTime Function() now = DateTime.now}) : _now = now;

  static const Duration cooldown = Duration(minutes: 10);

  final DateTime Function() _now;
  final Map<String, DateTime> _suspendedUntil = <String, DateTime>{};

  void trip(String serverId) {
    _suspendedUntil[serverId] = _now().add(cooldown);
  }

  bool isSuspended(String serverId) {
    final DateTime? until = _suspendedUntil[serverId];
    return until != null && _now().isBefore(until);
  }
}

final Provider<RateLimitGate> rateLimitGateProvider = Provider<RateLimitGate>((ref) => RateLimitGate());

final Provider<StatsRepository> statsRepositoryProvider = Provider<StatsRepository>((ref) {
  // Servers whose probed version is being written right now.
  final Set<String> persisting = <String>{};

  return StatsRepository(
    getApiKey: ref.read(configProvider.notifier).getApiKey,
    apiFactory: (Server server, String apiKey) {
      final http.Client client = ref.read(httpClientProvider(server.id));
      return PlausibleApiWithFallback(
        client,
        server.baseUrl,
        apiKey,
        resolver: ref.read(apiVersionResolverProvider(server.id)),
        isProxied: server.proxy != null,
      );
    },
    onRateLimited: (Server server) => ref.read(rateLimitGateProvider).trip(server.id),
    onFetched: (Server server) {
      // Against the live config rather than the snapshot the fetch carried:
      // aggregate and timeseries settle a moment apart on the same probe, and
      // both hold a snapshot from before it. The marker covers them settling
      // close enough together that neither has seen the other's write yet.
      // Read before the resolver, which throws for a server deleted mid-fetch
      // and would turn a fetch that worked into an error.
      final Server? current = _serverOrNull(ref.read(configProvider), server.id);
      if (current == null) return;
      final ApiVersion detected = ref.read(apiVersionResolverProvider(server.id)).version;
      if (current.apiVersion == detected) return;
      if (!persisting.add(server.id)) return;
      // Fire and forget: the fetch that carried the probe has already
      // answered, and this write only has to land before the app asks this
      // server for anything else.
      unawaited(
        ref
            .read(configProvider.notifier)
            .updateServer(current.copyWith(apiVersion: detected))
            .whenComplete(() => persisting.remove(server.id))
            // A failed write is a no-op, not something to raise: nothing has
            // been shown to the user yet, and the next probe derives the same
            // answer again.
            .onError<Object>((Object error, StackTrace stackTrace) {}),
      );
    },
  );
});

class OverviewData {
  OverviewData({required this.aggregate, required this.timeseries});

  final AggregateStats aggregate;
  final List<TimeseriesPoint> timeseries;
}

final AutoDisposeFutureProviderFamily<OverviewData, ({String serverId, String siteId, DateRangeSel range})>
overviewProvider =
    FutureProvider.autoDispose
        .family<OverviewData, ({String serverId, String siteId, DateRangeSel range})>((ref, args) async {
          final ConfigState config = ref.watch(configProvider);
          final Server server = _serverById(config, args.serverId);
          final Site site = _siteById(config, args.siteId);
          final StatsRepository repository = ref.watch(statsRepositoryProvider);

          final List<dynamic> results = await Future.wait<dynamic>(<Future<dynamic>>[
            repository.aggregate(server, site, args.range),
            repository.timeseries(server, site, args.range),
          ]);

          return OverviewData(
            aggregate: results[0] as AggregateStats,
            timeseries: results[1] as List<TimeseriesPoint>,
          );
        });

final AutoDisposeFutureProviderFamily<
  List<BreakdownRow>,
  ({String serverId, String siteId, DateRangeSel range, BreakdownDimension dimension})
>
breakdownProvider = FutureProvider.autoDispose
    .family<List<BreakdownRow>, ({String serverId, String siteId, DateRangeSel range, BreakdownDimension dimension})>((
      ref,
      args,
    ) async {
      final ConfigState config = ref.watch(configProvider);
      final Server server = _serverById(config, args.serverId);
      final Site site = _siteById(config, args.siteId);
      final StatsRepository repository = ref.watch(statsRepositoryProvider);
      return repository.breakdown(server, site, args.range, args.dimension);
    });

/// Today's visitor count and hourly points for a site row's sparkline
/// preview. Same "day" range as the dashboard's Today chip, so it rides the
/// same 60s repo cache when a user opens that site next.
final AutoDisposeFutureProviderFamily<({int visitors, List<TimeseriesPoint> points}), ({String serverId, String siteId})>
sitePreviewProvider = FutureProvider.autoDispose
    .family<({int visitors, List<TimeseriesPoint> points}), ({String serverId, String siteId})>((ref, args) async {
      final ConfigState config = ref.watch(configProvider);
      final Server server = _serverById(config, args.serverId);
      final Site site = _siteById(config, args.siteId);
      final StatsRepository repository = ref.watch(statsRepositoryProvider);

      final List<dynamic> results = await Future.wait<dynamic>(<Future<dynamic>>[
        repository.aggregate(server, site, const DateRangeSel.day()),
        repository.timeseries(server, site, const DateRangeSel.day()),
      ]);

      return (visitors: (results[0] as AggregateStats).visitors, points: results[1] as List<TimeseriesPoint>);
    });

/// Current visitor count, polled every 30s. Only the first fetch failing
/// surfaces as a stream error. Later failed ticks are skipped so the UI
/// keeps showing the last known value instead of blanking out. Being rate
/// limited is the exception: polling stops for the cooldown, and a count nobody
/// is refreshing would sit there looking live for ten minutes.
final AutoDisposeStreamProviderFamily<int, ({String serverId, String siteId})> realtimeProvider =
    StreamProvider.autoDispose.family<int, ({String serverId, String siteId})>((ref, args) {
      final ConfigState config = ref.watch(configProvider);
      final Server server = _serverById(config, args.serverId);
      final Site site = _siteById(config, args.siteId);
      final http.Client client = ref.watch(httpClientProvider(args.serverId));
      final ConfigNotifier notifier = ref.read(configProvider.notifier);
      final RateLimitGate gate = ref.read(rateLimitGateProvider);

      final StreamController<int> controller = StreamController<int>();
      bool first = true;

      Future<void> poll() async {
        if (gate.isSuspended(server.id)) {
          // Tripped by any 429 on this server, so this skips ticks over a limit
          // a dashboard fetch ran into as much as one of its own.
          if (!controller.isClosed) controller.addError(const RateLimitedException(), StackTrace.empty);
          return;
        }
        try {
          final String? apiKey = await notifier.getApiKey(server.id);
          if (apiKey == null) throw const UnauthorizedException();
          final int visitors = await RealtimeApi(
            client,
            server.baseUrl,
            apiKey,
            isProxied: server.proxy != null,
          ).currentVisitors(site.domain);
          if (!controller.isClosed) controller.add(visitors);
        } catch (error, stackTrace) {
          final bool rateLimited = error is RateLimitedException;
          if (rateLimited) gate.trip(server.id);
          // Keep the last value on the stream instead of erroring out, unless
          // this was the very first fetch and there's no last value to show.
          if ((first || rateLimited) && !controller.isClosed) controller.addError(error, stackTrace);
        }
        first = false;
      }

      unawaited(poll());
      final Timer timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(poll()));

      ref.onDispose(() {
        timer.cancel();
        unawaited(controller.close());
      });

      return controller.stream;
    });
