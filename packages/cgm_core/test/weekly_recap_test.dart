import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

/// Reference "now": a Monday noon, local, so day bucketing is deterministic.
/// 2026-06-22 is a Monday.
final DateTime _now = DateTime(2026, 6, 22, 12);

CgmReading _reading(double mgdl, DateTime at) {
  return CgmReading(
    valueMgdl: mgdl,
    source: CgmRecordSource.standard,
    recordedAt: at,
  );
}

/// All readings for one day at [value], every [stepMinutes] from 08:00.
List<CgmReading> _flatDay(DateTime day, double value, {int count = 6}) {
  return <CgmReading>[
    for (var i = 0; i < count; i++)
      _reading(value, DateTime(day.year, day.month, day.day, 8 + i)),
  ];
}

void main() {
  group('WeeklyRecapAnalytics.recap window', () {
    test('covers today plus the previous six calendar days', () {
      final recap = WeeklyRecapAnalytics.recap(const [], now: _now);
      expect(recap.weekStart, DateTime(2026, 6, 16)); // Tue six days back
      expect(recap.weekEnd, DateTime(2026, 6, 23)); // exclusive
      expect(recap.days, hasLength(7));
      expect(recap.days.first.date, DateTime(2026, 6, 16));
      expect(recap.days.last.date, DateTime(2026, 6, 22));
    });

    test('empty week yields no data and null best/worst', () {
      final recap = WeeklyRecapAnalytics.recap(const [], now: _now);
      expect(recap.hasData, isFalse);
      expect(recap.thisWeek.hasData, isFalse);
      expect(recap.bestDay, isNull);
      expect(recap.worstDay, isNull);
      expect(recap.topSpikes, isEmpty);
      expect(recap.averageDelta.hasComparison, isFalse);
      expect(recap.timeInRangeDelta.hasComparison, isFalse);
      // Every weekday average is null but all 7 weekdays are present.
      expect(recap.dayOfWeekAverages, hasLength(7));
      expect(
        recap.dayOfWeekAverages.every((d) => d.averageMgdl == null),
        isTrue,
      );
    });
  });

  group('per-day bucketing', () {
    test('assigns readings to the correct local day', () {
      final readings = <CgmReading>[
        ..._flatDay(DateTime(2026, 6, 20), 100), // in range
        ..._flatDay(DateTime(2026, 6, 21), 250), // above range
        ..._flatDay(DateTime(2026, 6, 22), 50), // below range
      ];
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);

      final byDate = {for (final d in recap.days) d.date: d};
      expect(byDate[DateTime(2026, 6, 20)]!.stats.timeInRangePercent, 100);
      expect(byDate[DateTime(2026, 6, 21)]!.stats.timeAboveRangePercent, 100);
      expect(byDate[DateTime(2026, 6, 22)]!.stats.timeBelowRangePercent, 100);
      // Days without readings carry empty stats.
      expect(byDate[DateTime(2026, 6, 16)]!.hasData, isFalse);
    });

    test('readings outside the week are excluded', () {
      final readings = <CgmReading>[
        // Two days before the window opens (2026-06-16).
        ..._flatDay(DateTime(2026, 6, 14), 100),
        ..._flatDay(DateTime(2026, 6, 20), 100),
      ];
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);
      expect(recap.thisWeek.readingCount, 6);
    });
  });

  group('best / worst day by time-in-range', () {
    test('picks highest and lowest TIR days', () {
      final readings = <CgmReading>[
        ..._flatDay(DateTime(2026, 6, 18), 100), // 100% TIR -> best
        ..._flatDay(DateTime(2026, 6, 19), 250), // 0% TIR -> worst
        ..._flatDay(DateTime(2026, 6, 20), 90), // 100% TIR but not first
      ];
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);
      expect(recap.bestDay!.date, DateTime(2026, 6, 18));
      expect(recap.bestDay!.stats.timeInRangePercent, 100);
      expect(recap.worstDay!.date, DateTime(2026, 6, 19));
      expect(recap.worstDay!.stats.timeInRangePercent, 0);
    });

    test('single day with data is both best and worst', () {
      final readings = _flatDay(DateTime(2026, 6, 20), 120);
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);
      expect(recap.bestDay!.date, DateTime(2026, 6, 20));
      expect(recap.worstDay!.date, DateTime(2026, 6, 20));
    });
  });

  group('week-over-week deltas', () {
    test('computes average / TIR / variability deltas across weeks', () {
      // This week: steady 100 (in range). Last week: steady 200 (above).
      final readings = <CgmReading>[
        ..._flatDay(DateTime(2026, 6, 20), 100), // this week
        ..._flatDay(DateTime(2026, 6, 13), 200), // last week (Sat before)
      ];
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);

      expect(recap.averageDelta.current, closeTo(100, 0.001));
      expect(recap.averageDelta.previous, closeTo(200, 0.001));
      expect(recap.averageDelta.delta, closeTo(-100, 0.001));

      expect(recap.timeInRangeDelta.current, 100);
      expect(recap.timeInRangeDelta.previous, 0);
      expect(recap.timeInRangeDelta.delta, 100);
    });

    test('delta is null when one week has no data', () {
      final readings = _flatDay(DateTime(2026, 6, 20), 100); // this week only
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);
      expect(recap.averageDelta.current, isNotNull);
      expect(recap.averageDelta.previous, isNull);
      expect(recap.averageDelta.delta, isNull);
      expect(recap.averageDelta.hasComparison, isFalse);
    });

    test('flat detection respects epsilon', () {
      const flat = WeekDelta(current: 100, previous: 100.02);
      expect(flat.isFlat(), isTrue);
      const moved = WeekDelta(current: 100, previous: 90);
      expect(moved.isFlat(), isFalse);
    });
  });

  group('top spikes', () {
    test('captures peak and amplitude, ordered by amplitude', () {
      final day = DateTime(2026, 6, 20);
      final readings = <CgmReading>[
        _reading(100, DateTime(day.year, day.month, day.day, 8)),
        _reading(190, DateTime(day.year, day.month, day.day, 9)), // spike A
        _reading(260, DateTime(day.year, day.month, day.day, 10)), // peak A
        _reading(100, DateTime(day.year, day.month, day.day, 11)), // back down
        _reading(210, DateTime(day.year, day.month, day.day, 12)), // spike B
        _reading(100, DateTime(day.year, day.month, day.day, 13)),
      ];
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);
      expect(recap.topSpikes, hasLength(2));
      // A: peak 260 from baseline 100 -> amplitude 160 (strongest, first).
      expect(recap.topSpikes.first.peakMgdl, 260);
      expect(recap.topSpikes.first.riseFromMgdl, 100);
      expect(recap.topSpikes.first.amplitudeMgdl, closeTo(160, 0.001));
      // B: peak 210 from baseline 100 -> amplitude 110.
      expect(recap.topSpikes[1].peakMgdl, 210);
    });

    test('caps at maxTopSpikes', () {
      final day = DateTime(2026, 6, 20);
      final readings = <CgmReading>[];
      var hour = 0;
      for (var i = 0; i < 5; i++) {
        readings.add(
          _reading(100, DateTime(day.year, day.month, day.day, hour++)),
        );
        readings.add(
          _reading(
            200.0 + i * 10,
            DateTime(day.year, day.month, day.day, hour++),
          ),
        );
      }
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);
      expect(recap.topSpikes, hasLength(WeeklyRecapAnalytics.maxTopSpikes));
      // Strongest first: the 240 spike.
      expect(recap.topSpikes.first.peakMgdl, 240);
    });

    test('no spikes when nothing exceeds the high bound', () {
      final recap = WeeklyRecapAnalytics.recap(
        _flatDay(DateTime(2026, 6, 20), 120),
        now: _now,
      );
      expect(recap.topSpikes, isEmpty);
    });
  });

  group('day-of-week averages', () {
    test('groups readings by weekday Mon..Sun', () {
      // 2026-06-20 is a Saturday (weekday 6), 2026-06-22 is Monday (1).
      final readings = <CgmReading>[
        ..._flatDay(DateTime(2026, 6, 22), 100), // Monday
        ..._flatDay(DateTime(2026, 6, 20), 160), // Saturday
      ];
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);
      final byWeekday = {
        for (final d in recap.dayOfWeekAverages) d.weekday: d.averageMgdl,
      };
      expect(byWeekday[DateTime.monday], closeTo(100, 0.001));
      expect(byWeekday[DateTime.saturday], closeTo(160, 0.001));
      expect(byWeekday[DateTime.wednesday], isNull); // no data
    });

    test('weights weekday average by reading count', () {
      // Same weekday only appears once in a 7-day window, so a weighted mean
      // over that day equals the day average.
      final readings = <CgmReading>[
        ..._flatDay(DateTime(2026, 6, 21), 100, count: 2), // Sunday
        _reading(220, DateTime(2026, 6, 21, 20)), // Sunday extra
      ];
      final recap = WeeklyRecapAnalytics.recap(readings, now: _now);
      final sunday = recap.dayOfWeekAverages
          .firstWhere((d) => d.weekday == DateTime.sunday)
          .averageMgdl;
      // (100 + 100 + 220) / 3 = 140.
      expect(sunday, closeTo(140, 0.001));
    });
  });

  group('partial weeks', () {
    test('handles a week with a single day of readings', () {
      final recap = WeeklyRecapAnalytics.recap(
        _flatDay(DateTime(2026, 6, 22), 110),
        now: _now,
      );
      expect(recap.hasData, isTrue);
      expect(recap.days.where((d) => d.hasData), hasLength(1));
      expect(recap.thisWeek.averageMgdl, closeTo(110, 0.001));
    });
  });
}
