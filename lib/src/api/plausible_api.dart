// Stats API surface. Implemented twice: PlausibleApiV2 over /api/v2/query, and
// PlausibleApiV1 over the legacy /api/v1/stats/* routes for servers too old to
// have the v2 one. NotFoundEndpointException is what picks between them.

import '../models/date_range.dart';
import '../models/stats.dart';

abstract class PlausibleApi {
  Future<AggregateStats> aggregate(String siteId, DateRangeSel range);

  Future<List<TimeseriesPoint>> timeseries(String siteId, DateRangeSel range);

  Future<List<BreakdownRow>> breakdown(
    String siteId,
    DateRangeSel range,
    BreakdownDimension dimension, {
    int limit = 15,
  });
}
