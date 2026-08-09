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

      test('$shorthand sends the same string as a v1 period, with no date', () {
        expect(range.v1Period, shorthand);
        expect(range.v1Date, isNull);
      });
    }
  });

  group('custom range', () {
    final DateRangeSel range = DateRangeSel.custom(DateTime(2024, 1, 3), DateTime(2024, 2, 7));

    test('has no shorthand and sends a zero-padded ISO pair', () {
      expect(range.v2Shorthand, isNull);
      expect(range.v2DateRange, <String>['2024-01-03', '2024-02-07']);
    });

    test('sends the v1 period keyword and a comma-joined ISO pair', () {
      expect(range.v1Period, 'custom');
      expect(range.v1Date, '2024-01-03,2024-02-07');
    });

    test('uses the plain time dimension', () {
      expect(range.timeDimension, 'time');
    });

    test('formats a short date-to-date label', () {
      expect(range.label(), '3 Jan - 7 Feb');
    });

    test('zero-pads single-digit month and day', () {
      final DateRangeSel earlyRange = DateRangeSel.custom(DateTime(2024, 3, 5), DateTime(2024, 3, 9));
      expect(earlyRange.v2DateRange, <String>['2024-03-05', '2024-03-09']);
      expect(earlyRange.v1Date, '2024-03-05,2024-03-09');
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

    test('parses an hourly label whose clock parts are not padded', () {
      final DateTime dt = range.parseTimeLabel('2024-01-15 14:0:0');
      expect(dt.year, 2024);
      expect(dt.month, 1);
      expect(dt.day, 15);
      expect(dt.hour, 14);
      expect(dt.minute, 0);
    });

    test('parses a date whose month and day are not padded', () {
      final DateTime dt = range.parseTimeLabel('2024-1-5');
      expect(dt.year, 2024);
      expect(dt.month, 1);
      expect(dt.day, 5);
    });

    test('throws a FormatException naming the label it choked on', () {
      expect(
        () => range.parseTimeLabel('last tuesday'),
        throwsA(
          isA<FormatException>().having((FormatException e) => e.source, 'source', 'last tuesday'),
        ),
      );
    });

    test('throws on an impossible date instead of rolling it over', () {
      // Bare DateTime() would answer 2025-02-14 and 2024-03-02 for these.
      expect(() => range.parseTimeLabel('2024-13-45'), throwsFormatException);
      expect(() => range.parseTimeLabel('2024-02-31'), throwsFormatException);
      expect(() => range.parseTimeLabel('2024-01-15 25:00'), throwsFormatException);
    });

    test('accepts the 29th of a leap February', () {
      final DateTime dt = range.parseTimeLabel('2024-2-29');
      expect(dt.month, 2);
      expect(dt.day, 29);
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

  group('fromShorthand', () {
    test('round-trips every preset through its shorthand', () {
      const List<DateRangeSel> presets = <DateRangeSel>[
        DateRangeSel.day(),
        DateRangeSel.d7(),
        DateRangeSel.d30(),
        DateRangeSel.month(),
        DateRangeSel.mo6(),
        DateRangeSel.mo12(),
      ];
      for (final DateRangeSel preset in presets) {
        expect(DateRangeSel.fromShorthand(preset.v2Shorthand), preset);
      }
    });

    test('returns null for unknown or null input', () {
      expect(DateRangeSel.fromShorthand('yesteryear'), isNull);
      expect(DateRangeSel.fromShorthand(null), isNull);
    });
  });
}
