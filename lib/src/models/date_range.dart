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

  /// Value to send as the v1 "period" query parameter. v1 takes the same
  /// strings as [v2Shorthand], plus a 'custom' keyword that v2 has no
  /// equivalent for — v2 sends the date pair as the range itself.
  String get v1Period => v2Shorthand ?? 'custom';

  /// Value to send as the v1 "date" query parameter: an inclusive
  /// "YYYY-MM-DD,YYYY-MM-DD" pair for a custom range, null for presets (whose
  /// window is already implied by [v1Period]).
  String? get v1Date =>
      _preset == _Preset.custom ? '${_isoDate(from!)},${_isoDate(to!)}' : null;

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

  /// Parses a `meta.time_labels` entry, or a v1 timeseries row's date. Hourly
  /// labels are timestamps (with or without a UTC offset); daily and monthly
  /// labels are plain "YYYY-MM-DD" strings (monthly always day 01) —
  /// DateTime.parse handles all three.
  ///
  /// Older servers format the clock parts without padding ("2024-01-15 14:0:0"),
  /// which DateTime.parse rejects; retry those loosely rather than losing the
  /// whole chart to one sloppy label. Anything that isn't a date at all still
  /// throws, but says which label it choked on — impossible dates included.
  DateTime parseTimeLabel(String label) {
    final Match? match = _looseLabel.firstMatch(label.trim());
    // The loose pattern covers the plain and naive forms too, so this is where
    // the label's own numbers meet the calendar. Neither parser below rejects
    // an out-of-range part — DateTime.parse('2024-13-45') answers 2025-02-14 —
    // and a confident wrong point on the chart is worse than a missing one.
    // (An hourly label carrying a UTC offset doesn't match the pattern and
    // goes unchecked; those come from the server's own formatter.)
    if (match != null && !_isRealTime(match)) {
      throw FormatException('unrecognised time label', label);
    }

    try {
      return DateTime.parse(label);
    } on FormatException {
      if (match == null) throw FormatException('unrecognised time label', label);
      return DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4) ?? '0'),
        int.parse(match.group(5) ?? '0'),
        int.parse(match.group(6) ?? '0'),
      );
    }
  }

  /// Whether a [_looseLabel] match names a date and clock that exist.
  static bool _isRealTime(Match match) {
    final int year = int.parse(match.group(1)!);
    final int month = int.parse(match.group(2)!);
    if (month < 1 || month > 12) return false;
    // Day 0 of the next month is the last day of this one; in UTC so that no
    // DST shift can move it.
    final int day = int.parse(match.group(3)!);
    if (day < 1 || day > DateTime.utc(year, month + 1, 0).day) return false;
    return int.parse(match.group(4) ?? '0') <= 23 &&
        int.parse(match.group(5) ?? '0') <= 59 &&
        int.parse(match.group(6) ?? '0') <= 59;
  }

  /// "YYYY-M-D" with an optional " H:M(:S)" or "TH:M(:S)" clock, any part
  /// allowed to be unpadded.
  static final RegExp _looseLabel = RegExp(
    r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
  );

  static String _isoDate(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  static String _shortDate(DateTime date) => DateFormat('d MMM').format(date);

  @override
  bool operator ==(Object other) =>
      other is DateRangeSel && other._preset == _preset && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(_preset, from, to);
}
