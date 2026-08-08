// Riverpod wiring for the stats domain. No codegen — plain providers.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api/api_exception.dart';
import '../api/http_client_factory.dart';
import '../api/plausible_api_v2.dart';
import '../api/realtime_api.dart';
import '../models/date_range.dart';
import '../models/server.dart';
import '../models/site.dart';
import '../models/stats.dart';
import '../repositories/config_repository.dart';
import '../repositories/stats_repository.dart';
import 'config_providers.dart';

/// One http.Client per server, rebuilt (and the old one closed) whenever that
/// server's config changes.
final ProviderFamily<http.Client, String> httpClientProvider = Provider.family<http.Client, String>((
  ref,
  serverId,
) {
  // Narrowed to the proxy on purpose - it is all buildClientFor reads.
  // Watching the whole Server would close this client on an edit that has
  // nothing to do with the transport, and IOClient.close() aborts the
  // requests it still has in flight.
  final ProxyConfig? proxy = ref.watch(
    configProvider.select(
      (ConfigState s) => s.servers.firstWhere((Server s) => s.id == serverId).proxy,
    ),
  );
  final http.Client client = buildClientFor(proxy);
  ref.onDispose(client.close);
  return client;
});

final Provider<StatsRepository> statsRepositoryProvider = Provider<StatsRepository>((ref) {
  return StatsRepository(
    getApiKey: ref.read(configProvider.notifier).getApiKey,
    apiFactory: (Server server, String apiKey) {
      final http.Client client = ref.read(httpClientProvider(server.id));
      return PlausibleApiV2(client, server.baseUrl, apiKey);
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
          final Server server = config.servers.firstWhere((Server s) => s.id == args.serverId);
          final Site site = config.sites.firstWhere((Site s) => s.id == args.siteId);
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
      final Server server = config.servers.firstWhere((Server s) => s.id == args.serverId);
      final Site site = config.sites.firstWhere((Site s) => s.id == args.siteId);
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
      final Server server = config.servers.firstWhere((Server s) => s.id == args.serverId);
      final Site site = config.sites.firstWhere((Site s) => s.id == args.siteId);
      final StatsRepository repository = ref.watch(statsRepositoryProvider);

      final List<dynamic> results = await Future.wait<dynamic>(<Future<dynamic>>[
        repository.aggregate(server, site, const DateRangeSel.day()),
        repository.timeseries(server, site, const DateRangeSel.day()),
      ]);

      return (visitors: (results[0] as AggregateStats).visitors, points: results[1] as List<TimeseriesPoint>);
    });

/// Current visitor count, polled every 30s. Only the first fetch failing
/// surfaces as a stream error — later failed ticks are skipped so the UI
/// keeps showing the last known value instead of blanking out.
final AutoDisposeStreamProviderFamily<int, ({String serverId, String siteId})> realtimeProvider =
    StreamProvider.autoDispose.family<int, ({String serverId, String siteId})>((ref, args) {
      final ConfigState config = ref.watch(configProvider);
      final Server server = config.servers.firstWhere((Server s) => s.id == args.serverId);
      final Site site = config.sites.firstWhere((Site s) => s.id == args.siteId);
      final http.Client client = ref.watch(httpClientProvider(args.serverId));
      final ConfigNotifier notifier = ref.read(configProvider.notifier);

      final StreamController<int> controller = StreamController<int>();
      bool first = true;

      Future<void> poll() async {
        try {
          final String? apiKey = await notifier.getApiKey(server.id);
          if (apiKey == null) throw const UnauthorizedException();
          final int visitors = await RealtimeApi(client, server.baseUrl, apiKey).currentVisitors(site.domain);
          if (!controller.isClosed) controller.add(visitors);
        } catch (error, stackTrace) {
          // Keep the last value on the stream instead of erroring out, unless
          // this was the very first fetch and there's no last value to show.
          if (first && !controller.isClosed) controller.addError(error, stackTrace);
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
