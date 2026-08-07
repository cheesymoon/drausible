// Stats API surface. PlausibleApiV2 is the only implementation today; a v1
// fallback can implement the same interface once NotFoundEndpointException
// drives that probing.

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
