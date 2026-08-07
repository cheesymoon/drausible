import 'package:flutter_test/flutter_test.dart';

import 'package:drausible/src/models/date_range.dart';

void main() {
  group('presets', () {
    final List<({DateRangeSel range, String shorthand, String timeDimension, String label})> cases =
        <({DateRangeSel range, String shorthand, String timeDimension, String label})>[
          (range: const DateRangeSel.day(), shorthand: 'day', timeDimension: 'time:hour', label: 'Today'),
          (range: const DateRangeSel.d7(), shorthand: '7d', timeDimension: 'time', label: '7 days'),
          (range: const DateRangeSel.d30(), shorthand: '30d', timeDimension: 'time', label: '30 days'),
          (range: const DateRangeSel.month(), shorthand: 'month', timeDimension: 'time', label: 'Month'),
          (range: const DateRangeSel.mo6(), shorthand: '6mo', timeDimension: 'time', label: '6 months'),
          (range: const DateRangeSel.mo12(), shorthand: '12mo', timeDimension: 'time', label: '12 months'),
        ];

    for (final (
          :DateRangeSel range,
          :String shorthand,
          :String timeDimension,
          :String label,
        )
        in cases) {
      test('$shorthand maps shorthand, date range, time dimension and label', () {
        expect(range.v2Shorthand, shorthand);
        expect(range.v2DateRange, shorthand);
        expect(range.timeDimension, timeDimension);
        expect(range.label(), label);
      });
    }
  });

  group('custom range', () {
    final DateRangeSel range = DateRangeSel.custom(DateTime(2024, 1, 3), DateTime(2024, 2, 7));

    test('has no shorthand and sends a zero-padded ISO pair', () {
      expect(range.v2Shorthand, isNull);
      expect(range.v2DateRange, <String>['2024-01-03', '2024-02-07']);
    });

    test('uses the plain time dimension', () {
      expect(range.timeDimension, 'time');
    });

    test('formats a short date-to-date label', () {
      expect(range.label(), '3 Jan – 7 Feb');
    });

    test('zero-pads single-digit month and day', () {
      final DateRangeSel earlyRange = DateRangeSel.custom(DateTime(2024, 3, 5), DateTime(2024, 3, 9));
      expect(earlyRange.v2DateRange, <String>['2024-03-05', '2024-03-09']);
    });
  });

  group('parseTimeLabel', () {
    // Format detection is purely string-shape based, not tied to the preset.
    const DateRangeSel range = DateRangeSel.d30();

    test('parses an hourly label with a UTC offset', () {
      final DateTime dt = range.parseTimeLabel('2024-01-15T13:00:00+00:00');
      expect(dt.isUtc, isTrue);
      expect(dt.year, 2024);
      expect(dt.month, 1);
      expect(dt.day, 15);
      expect(dt.hour, 13);
    });

    test('parses a naive hourly label', () {
      final DateTime dt = range.parseTimeLabel('2024-01-15 13:00:00');
      expect(dt.year, 2024);
      expect(dt.month, 1);
      expect(dt.day, 15);
      expect(dt.hour, 13);
    });

    test('parses a daily label', () {
      final DateTime dt = range.parseTimeLabel('2024-01-15');
      expect(dt.year, 2024);
      expect(dt.month, 1);
      expect(dt.day, 15);
    });

    test('parses a monthly label (always day 01)', () {
      final DateTime dt = range.parseTimeLabel('2024-02-01');
      expect(dt.year, 2024);
      expect(dt.month, 2);
      expect(dt.day, 1);
    });
  });

  group('equality', () {
    test('presets of the same kind are equal', () {
      expect(const DateRangeSel.d30(), const DateRangeSel.d30());
      expect(const DateRangeSel.d30().hashCode, const DateRangeSel.d30().hashCode);
    });

    test('different presets are not equal', () {
      expect(const DateRangeSel.d30(), isNot(const DateRangeSel.d7()));
    });

    test('custom ranges compare by from/to', () {
      final DateRangeSel a = DateRangeSel.custom(DateTime(2024, 1, 3), DateTime(2024, 2, 7));
      final DateRangeSel b = DateRangeSel.custom(DateTime(2024, 1, 3), DateTime(2024, 2, 7));
      final DateRangeSel c = DateRangeSel.custom(DateTime(2024, 1, 4), DateTime(2024, 2, 7));

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('a preset is never equal to a custom range', () {
      final DateRangeSel custom = DateRangeSel.custom(DateTime(2024, 1, 3), DateTime(2024, 2, 7));
      expect(const DateRangeSel.d30(), isNot(custom));
    });
  });
}
