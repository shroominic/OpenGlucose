import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

/// Reference time for deterministic windowing in tests.
final DateTime _now = DateTime.utc(2026, 6, 22, 12);

CgmReading _reading(double mgdl, {DateTime? at, int? minute}) {
  return CgmReading(
    valueMgdl: mgdl,
    source: CgmRecordSource.standard,
    recordedAt: at,
    sensorMinute: minute,
  );
}

/// Builds [count] readings, one per [stepMinutes], ending at [_now].
List<CgmReading> _series(
  List<double> values, {
  int stepMinutes = 5,
  DateTime? endingAt,
}) {
  final end = endingAt ?? _now;
  final readings = <CgmReading>[];
  for (var i = 0; i < values.length; i++) {
    final offsetFromEnd = (values.length - 1 - i) * stepMinutes;
    readings.add(
      _reading(values[i], at: end.subtract(Duration(minutes: offsetFromEnd))),
    );
  }
  return readings;
}

void main() {
  group('readingsInTimeframe', () {
    test('keeps readings inside the window and drops older ones', () {
      final readings = <CgmReading>[
        _reading(100, at: _now.subtract(const Duration(hours: 1))),
        _reading(110, at: _now.subtract(const Duration(hours: 23))),
        _reading(120, at: _now.subtract(const Duration(hours: 25))),
      ];
      final windowed = GlucoseAnalytics.readingsInTimeframe(
        readings,
        AnalyticsTimeframe.last24h,
        now: _now,
      );
      expect(windowed.length, 2);
      expect(windowed.map((r) => r.valueMgdl), containsAll(<double>[100, 110]));
    });

    test('excludes readings without a timestamp', () {
      final readings = <CgmReading>[
        _reading(100, at: _now.subtract(const Duration(hours: 1))),
        _reading(110, minute: 42),
      ];
      final windowed = GlucoseAnalytics.readingsInTimeframe(
        readings,
        AnalyticsTimeframe.last24h,
        now: _now,
      );
      expect(windowed.length, 1);
    });

    test('excludes readings in the future relative to now', () {
      final readings = <CgmReading>[
        _reading(100, at: _now.add(const Duration(minutes: 30))),
        _reading(110, at: _now.subtract(const Duration(minutes: 30))),
      ];
      final windowed = GlucoseAnalytics.readingsInTimeframe(
        readings,
        AnalyticsTimeframe.last7d,
        now: _now,
      );
      expect(windowed.length, 1);
      expect(windowed.single.valueMgdl, 110);
    });

    test('7d and 14d windows widen inclusion', () {
      final readings = <CgmReading>[
        _reading(100, at: _now.subtract(const Duration(days: 6))),
        _reading(110, at: _now.subtract(const Duration(days: 10))),
      ];
      expect(
        GlucoseAnalytics.readingsInTimeframe(
          readings,
          AnalyticsTimeframe.last7d,
          now: _now,
        ).length,
        1,
      );
      expect(
        GlucoseAnalytics.readingsInTimeframe(
          readings,
          AnalyticsTimeframe.last14d,
          now: _now,
        ).length,
        2,
      );
    });
  });

  group('average / SD / CV', () {
    test('average of a known series', () {
      final readings = _series(<double>[90, 100, 110]);
      expect(GlucoseAnalytics.average(readings), closeTo(100, 1e-9));
    });

    test('average is null for empty', () {
      expect(GlucoseAnalytics.average(const <CgmReading>[]), isNull);
    });

    test('population standard deviation of a known series', () {
      // values 2,4,4,4,5,5,7,9 -> mean 5, population SD 2.
      final readings = _series(<double>[2, 4, 4, 4, 5, 5, 7, 9]);
      expect(GlucoseAnalytics.standardDeviation(readings), closeTo(2.0, 1e-9));
    });

    test('standard deviation is zero for a flat series', () {
      final readings = _series(<double>[120, 120, 120, 120]);
      expect(GlucoseAnalytics.standardDeviation(readings), closeTo(0, 1e-9));
    });

    test('coefficient of variation is SD/mean*100', () {
      final readings = _series(<double>[2, 4, 4, 4, 5, 5, 7, 9]);
      // SD 2, mean 5 -> CV 40%.
      expect(
        GlucoseAnalytics.coefficientOfVariation(readings),
        closeTo(40.0, 1e-9),
      );
    });

    test('coefficient of variation is null when empty', () {
      expect(
        GlucoseAnalytics.coefficientOfVariation(const <CgmReading>[]),
        isNull,
      );
    });
  });

  group('estimated GMI', () {
    test('uses the standard linear approximation', () {
      // mean 154 -> 3.31 + 0.02392*154 = 6.99368.
      final readings = _series(<double>[154]);
      expect(
        GlucoseAnalytics.estimatedGmi(readings),
        closeTo(3.31 + 0.02392 * 154, 1e-9),
      );
    });

    test('is null when empty', () {
      expect(GlucoseAnalytics.estimatedGmi(const <CgmReading>[]), isNull);
    });
  });

  group('spikeCount', () {
    test('counts each upward crossing of the high bound once', () {
      // 100 -> 200 (spike) -> 150 (back) -> 210 (spike) = 2.
      final readings = _series(<double>[100, 200, 150, 210]);
      expect(GlucoseAnalytics.spikeCount(readings), 2);
    });

    test('sustained above-range counts as a single spike', () {
      final readings = _series(<double>[100, 200, 210, 220, 150]);
      expect(GlucoseAnalytics.spikeCount(readings), 1);
    });

    test('an already-high first sample is not an upward crossing', () {
      final readings = _series(<double>[200, 210, 220]);
      expect(GlucoseAnalytics.spikeCount(readings), 0);
    });

    test('no crossings yields zero', () {
      final readings = _series(<double>[100, 120, 140, 160]);
      expect(GlucoseAnalytics.spikeCount(readings), 0);
    });

    test('respects custom high bound', () {
      final readings = _series(<double>[100, 150, 100, 150]);
      expect(
        GlucoseAnalytics.spikeCount(
          readings,
          bounds: const GlucoseRangeBounds(lowMgdl: 70, highMgdl: 140),
        ),
        2,
      );
    });

    test('orders by timestamp before counting', () {
      // Provide out-of-order; ascending values are 100,200,150,210 -> 2 spikes.
      final readings = <CgmReading>[
        _reading(210, at: _now),
        _reading(100, at: _now.subtract(const Duration(minutes: 15))),
        _reading(150, at: _now.subtract(const Duration(minutes: 5))),
        _reading(200, at: _now.subtract(const Duration(minutes: 10))),
      ];
      expect(GlucoseAnalytics.spikeCount(readings), 2);
    });
  });

  group('summarize', () {
    test('time-in-range / below / above sum to 100', () {
      // 2 below(<70), 4 in-range, 2 above(>180) of 8 -> 25/50/25.
      final readings = _series(<double>[60, 65, 90, 120, 150, 170, 200, 210]);
      final stats = GlucoseAnalytics.summarize(
        readings,
        timeframe: AnalyticsTimeframe.last24h,
        now: _now,
      );
      expect(stats.readingCount, 8);
      expect(stats.timeBelowRangePercent, closeTo(25, 1e-9));
      expect(stats.timeInRangePercent, closeTo(50, 1e-9));
      expect(stats.timeAboveRangePercent, closeTo(25, 1e-9));
      expect(
        stats.timeBelowRangePercent +
            stats.timeInRangePercent +
            stats.timeAboveRangePercent,
        closeTo(100, 1e-9),
      );
    });

    test('boundary values are inclusive in range', () {
      final readings = _series(<double>[70, 180]);
      final stats = GlucoseAnalytics.summarize(
        readings,
        timeframe: AnalyticsTimeframe.last24h,
        now: _now,
      );
      expect(stats.timeInRangePercent, closeTo(100, 1e-9));
      expect(stats.timeBelowRangePercent, 0);
      expect(stats.timeAboveRangePercent, 0);
    });

    test('reports min, max and average', () {
      final readings = _series(<double>[80, 120, 200]);
      final stats = GlucoseAnalytics.summarize(
        readings,
        timeframe: AnalyticsTimeframe.last24h,
        now: _now,
      );
      expect(stats.minMgdl, 80);
      expect(stats.maxMgdl, 200);
      expect(stats.averageMgdl, closeTo(133.3333, 1e-3));
    });

    test('filters by timeframe before summarising', () {
      final readings = <CgmReading>[
        _reading(100, at: _now.subtract(const Duration(hours: 1))),
        _reading(300, at: _now.subtract(const Duration(days: 3))),
      ];
      final stats = GlucoseAnalytics.summarize(
        readings,
        timeframe: AnalyticsTimeframe.last24h,
        now: _now,
      );
      expect(stats.readingCount, 1);
      expect(stats.maxMgdl, 100);
    });

    test('preFiltered skips windowing', () {
      final readings = <CgmReading>[
        _reading(300, at: _now.subtract(const Duration(days: 30))),
      ];
      final stats = GlucoseAnalytics.summarize(
        readings,
        timeframe: AnalyticsTimeframe.last24h,
        now: _now,
        preFiltered: true,
      );
      expect(stats.readingCount, 1);
    });

    test('empty window produces a null-metric empty result', () {
      final stats = GlucoseAnalytics.summarize(
        const <CgmReading>[],
        timeframe: AnalyticsTimeframe.last7d,
        now: _now,
      );
      expect(stats.hasData, isFalse);
      expect(stats.readingCount, 0);
      expect(stats.averageMgdl, isNull);
      expect(stats.standardDeviationMgdl, isNull);
      expect(stats.coefficientOfVariationPercent, isNull);
      expect(stats.estimatedGmiPercent, isNull);
      expect(stats.spikeCount, 0);
      expect(stats.timeInRangePercent, 0);
    });

    test('custom bounds change bucketing', () {
      final readings = _series(<double>[80, 100, 160]);
      final stats = GlucoseAnalytics.summarize(
        readings,
        timeframe: AnalyticsTimeframe.last24h,
        now: _now,
        bounds: const GlucoseRangeBounds(lowMgdl: 90, highMgdl: 140),
      );
      // 80 below, 100 in, 160 above.
      expect(stats.timeBelowRangePercent, closeTo(33.3333, 1e-3));
      expect(stats.timeInRangePercent, closeTo(33.3333, 1e-3));
      expect(stats.timeAboveRangePercent, closeTo(33.3333, 1e-3));
    });

    test('all-in-range synthetic day reads as 100% TIR with low CV', () {
      // A tight, well-controlled synthetic day around 110 mg/dL.
      final values = List<double>.generate(
        288,
        (i) => 110 + 8 * (i.isEven ? 1 : -1).toDouble(),
      );
      final readings = _series(values);
      final stats = GlucoseAnalytics.summarize(
        readings,
        timeframe: AnalyticsTimeframe.last24h,
        now: _now,
      );
      expect(stats.timeInRangePercent, closeTo(100, 1e-9));
      expect(stats.spikeCount, 0);
      expect(stats.coefficientOfVariationPercent, lessThan(15));
    });
  });

  group('GlucoseRangeBounds', () {
    test('rejects inverted bounds', () {
      expect(
        () => GlucoseRangeBounds(lowMgdl: 200, highMgdl: 100),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
