// Riverpod wiring for the stats domain. No codegen — plain providers.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api/http_client_factory.dart';
import '../api/plausible_api_v2.dart';
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
  // select() + Server's value equality keep the client alive across unrelated
  // config edits; only a change to this server rebuilds (and closes) it.
  final Server server = ref.watch(
    configProvider.select(
      (ConfigState s) => s.servers.firstWhere((Server s) => s.id == serverId),
    ),
  );
  final http.Client client = buildClientFor(server);
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
