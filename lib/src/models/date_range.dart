// Selected reporting window. Immutable and used as a Riverpod family arg /
// cache key, so equality has to be exact.

import 'package:intl/intl.dart';

enum _Preset { day, d7, d30, month, mo6, mo12, custom }

class DateRangeSel {
  const DateRangeSel.day() : this._(_Preset.day);
  const DateRangeSel.d7() : this._(_Preset.d7);
  const DateRangeSel.d30() : this._(_Preset.d30);
  const DateRangeSel.month() : this._(_Preset.month);
  const DateRangeSel.mo6() : this._(_Preset.mo6);
  const DateRangeSel.mo12() : this._(_Preset.mo12);

  /// [from]/[to] are inclusive calendar dates (time-of-day is ignored).
  const DateRangeSel.custom(DateTime from, DateTime to) : this._(_Preset.custom, from: from, to: to);

  const DateRangeSel._(this._preset, {this.from, this.to});

  final _Preset _preset;
  final DateTime? from;
  final DateTime? to;

  /// v2 date_range shorthand, or null for a custom range (which needs the
  /// [from, to] pair instead).
  String? get v2Shorthand => switch (_preset) {
    _Preset.day => 'day',
    _Preset.d7 => '7d',
    _Preset.d30 => '30d',
    _Preset.month => 'month',
    _Preset.mo6 => '6mo',
    _Preset.mo12 => '12mo',
    _Preset.custom => null,
  };

  /// Preset for a stored shorthand, or null for unknown input. Used to
  /// restore the last picked range across app starts.
  static DateRangeSel? fromShorthand(String? shorthand) => switch (shorthand) {
    'day' => const DateRangeSel.day(),
    '7d' => const DateRangeSel.d7(),
    '30d' => const DateRangeSel.d30(),
    'month' => const DateRangeSel.month(),
    '6mo' => const DateRangeSel.mo6(),
    '12mo' => const DateRangeSel.mo12(),
    _ => null,
  };

  /// Value to send as the v2 query body's "date_range": the shorthand string,
  /// or a ["YYYY-MM-DD", "YYYY-MM-DD"] pair for a custom range.
  Object get v2DateRange {
    final String? shorthand = v2Shorthand;
    if (shorthand != null) return shorthand;
    return <String>[_isoDate(from!), _isoDate(to!)];
  }

  /// Query dimension for a timeseries: hourly buckets for "day", daily
  /// buckets otherwise.
  String get timeDimension => _preset == _Preset.day ? 'time:hour' : 'time';

  String label() => switch (_preset) {
    _Preset.day => 'Today',
    _Preset.d7 => '7 days',
    _Preset.d30 => '30 days',
    _Preset.month => 'Month',
    _Preset.mo6 => '6 months',
    _Preset.mo12 => '12 months',
    _Preset.custom => '${_shortDate(from!)} – ${_shortDate(to!)}',
  };

  /// Parses a `meta.time_labels` entry. Hourly labels are timestamps (with or
  /// without a UTC offset); daily and monthly labels are plain "YYYY-MM-DD"
  /// strings (monthly always day 01) — DateTime.parse handles all three.
  DateTime parseTimeLabel(String label) => DateTime.parse(label);

  static String _isoDate(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  static String _shortDate(DateTime date) => DateFormat('d MMM').format(date);

  @override
  bool operator ==(Object other) =>
      other is DateRangeSel && other._preset == _preset && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(_preset, from, to);
}
