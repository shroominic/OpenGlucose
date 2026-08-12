import 'dart:math' as math;

import 'cgm_models.dart';

/// Analytics timeframe windows for summarising recent readings.
///
/// These are wellness/self-experimentation observation windows, not clinical
/// reporting periods.
enum AnalyticsTimeframe {
  last24h,
  last7d,
  last14d;

  /// Length of the window.
  Duration get duration => switch (this) {
    AnalyticsTimeframe.last24h => const Duration(hours: 24),
    AnalyticsTimeframe.last7d => const Duration(days: 7),
    AnalyticsTimeframe.last14d => const Duration(days: 14),
  };

  /// Short human label, e.g. "24h".
  String get label => switch (this) {
    AnalyticsTimeframe.last24h => '24h',
    AnalyticsTimeframe.last7d => '7d',
    AnalyticsTimeframe.last14d => '14d',
  };
}

/// Inclusive low / exclusive-comparable range bounds (in mg/dL) used to bucket
/// readings into below / in-range / above. Defaults mirror the common
/// wellness "in range" band of 70–180 mg/dL (~3.9–10 mmol/L).
class GlucoseRangeBounds {
  const GlucoseRangeBounds({this.lowMgdl = 70, this.highMgdl = 180})
    : assert(lowMgdl < highMgdl, 'lowMgdl must be below highMgdl');

  final double lowMgdl;
  final double highMgdl;

  static const GlucoseRangeBounds standard = GlucoseRangeBounds();
}

/// Immutable result of summarising a list of readings over a window.
///
/// All glucose figures are kept in mg/dL; the UI layer converts to the user's
/// preferred unit. Percentages are 0..100.
class GlucoseStats {
  const GlucoseStats({
    required this.timeframe,
    required this.bounds,
    required this.readingCount,
    required this.timeInRangePercent,
    required this.timeBelowRangePercent,
    required this.timeAboveRangePercent,
    required this.averageMgdl,
    required this.standardDeviationMgdl,
    required this.coefficientOfVariationPercent,
    required this.estimatedGmiPercent,
    required this.spikeCount,
    required this.minMgdl,
    required this.maxMgdl,
  });

  /// Empty result for when there are no readings in the window.
  factory GlucoseStats.empty({
    required AnalyticsTimeframe timeframe,
    required GlucoseRangeBounds bounds,
  }) {
    return GlucoseStats(
      timeframe: timeframe,
      bounds: bounds,
      readingCount: 0,
      timeInRangePercent: 0,
      timeBelowRangePercent: 0,
      timeAboveRangePercent: 0,
      averageMgdl: null,
      standardDeviationMgdl: null,
      coefficientOfVariationPercent: null,
      estimatedGmiPercent: null,
      spikeCount: 0,
      minMgdl: null,
      maxMgdl: null,
    );
  }

  final AnalyticsTimeframe timeframe;
  final GlucoseRangeBounds bounds;

  /// Number of readings that fell inside the window.
  final int readingCount;

  /// Share of readings inside [GlucoseRangeBounds] (0..100).
  final double timeInRangePercent;

  /// Share of readings below the low bound (0..100).
  final double timeBelowRangePercent;

  /// Share of readings above the high bound (0..100).
  final double timeAboveRangePercent;

  /// Arithmetic mean of readings, or null when there are none.
  final double? averageMgdl;

  /// Population standard deviation, or null when there are none.
  final double? standardDeviationMgdl;

  /// Variability: SD / mean * 100, or null when not computable.
  final double? coefficientOfVariationPercent;

  /// GMI-style estimate derived from the average. This is a rough
  /// self-experimentation indicator, not a lab value. Null when no average.
  final double? estimatedGmiPercent;

  /// Count of upward swings that crossed the high bound (a rise from
  /// in/below-range up across [GlucoseRangeBounds.highMgdl]).
  final int spikeCount;

  final double? minMgdl;
  final double? maxMgdl;

  bool get hasData => readingCount > 0;
}

/// Pure-Dart glucose analytics over [CgmReading] lists.
///
/// Wellness framing: these surface observations and patterns for
/// self-experimentation. They are not medical metrics, diagnoses, or a
/// substitute for clinical measurement.
abstract final class GlucoseAnalytics {
  /// Filters [readings] to those recorded within [timeframe] relative to [now]
  /// (defaults to [DateTime.now]). Readings without a timestamp are excluded
  /// because they cannot be placed in a window.
  static List<CgmReading> readingsInTimeframe(
    List<CgmReading> readings,
    AnalyticsTimeframe timeframe, {
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final cutoff = reference.subtract(timeframe.duration);
    return readings
        .where((reading) {
          final at = reading.recordedAt;
          if (at == null) return false;
          return !at.isBefore(cutoff) && !at.isAfter(reference);
        })
        .toList(growable: false);
  }

  /// Arithmetic mean of reading values in mg/dL, or null when empty.
  static double? average(List<CgmReading> readings) {
    if (readings.isEmpty) return null;
    var sum = 0.0;
    for (final reading in readings) {
      sum += reading.valueMgdl;
    }
    return sum / readings.length;
  }

  /// Population standard deviation in mg/dL, or null when empty.
  static double? standardDeviation(List<CgmReading> readings) {
    final mean = average(readings);
    if (mean == null) return null;
    var sumSq = 0.0;
    for (final reading in readings) {
      final delta = reading.valueMgdl - mean;
      sumSq += delta * delta;
    }
    return math.sqrt(sumSq / readings.length);
  }

  /// Coefficient of variation as a percentage (SD / mean * 100), or null.
  static double? coefficientOfVariation(List<CgmReading> readings) {
    final mean = average(readings);
    final sd = standardDeviation(readings);
    if (mean == null || sd == null || mean == 0) return null;
    return sd / mean * 100;
  }

  /// GMI-style estimate from the mean glucose, using the widely cited
  /// linear approximation `3.31 + 0.02392 * meanMgdl`. Returns a rough
  /// self-experimentation indicator (percent), not a lab A1c. Null when empty.
  static double? estimatedGmi(List<CgmReading> readings) {
    final mean = average(readings);
    if (mean == null) return null;
    return 3.31 + 0.02392 * mean;
  }

  /// Counts upward swings that cross [bounds.highMgdl]: each transition from a
  /// value at/below the high bound to a value above it counts once. Consecutive
  /// above-range readings are a single spike until the value drops back to/below
  /// the bound.
  static int spikeCount(
    List<CgmReading> readings, {
    GlucoseRangeBounds bounds = GlucoseRangeBounds.standard,
  }) {
    final ordered = _orderedByTime(readings);
    if (ordered.length < 2) {
      return 0;
    }
    var count = 0;
    var wasAbove = ordered.first.valueMgdl > bounds.highMgdl;
    for (final reading in ordered.skip(1)) {
      final isAbove = reading.valueMgdl > bounds.highMgdl;
      if (isAbove && !wasAbove) count++;
      wasAbove = isAbove;
    }
    return count;
  }

  /// Computes the full [GlucoseStats] bundle for [readings] over [timeframe].
  ///
  /// Pass already-windowed readings via [preFiltered] to skip the timeframe
  /// filter (useful when the caller has its own windowing); otherwise the list
  /// is filtered against [timeframe] relative to [now].
  static GlucoseStats summarize(
    List<CgmReading> readings, {
    required AnalyticsTimeframe timeframe,
    GlucoseRangeBounds bounds = GlucoseRangeBounds.standard,
    DateTime? now,
    bool preFiltered = false,
  }) {
    final windowed = preFiltered
        ? readings
        : readingsInTimeframe(readings, timeframe, now: now);
    if (windowed.isEmpty) {
      return GlucoseStats.empty(timeframe: timeframe, bounds: bounds);
    }

    var below = 0;
    var inRange = 0;
    var above = 0;
    var min = windowed.first.valueMgdl;
    var max = windowed.first.valueMgdl;
    for (final reading in windowed) {
      final value = reading.valueMgdl;
      if (value < bounds.lowMgdl) {
        below++;
      } else if (value > bounds.highMgdl) {
        above++;
      } else {
        inRange++;
      }
      if (value < min) min = value;
      if (value > max) max = value;
    }

    final total = windowed.length;
    final mean = average(windowed);
    final sd = standardDeviation(windowed);
    final cv = coefficientOfVariation(windowed);

    return GlucoseStats(
      timeframe: timeframe,
      bounds: bounds,
      readingCount: total,
      timeInRangePercent: inRange / total * 100,
      timeBelowRangePercent: below / total * 100,
      timeAboveRangePercent: above / total * 100,
      averageMgdl: mean,
      standardDeviationMgdl: sd,
      coefficientOfVariationPercent: cv,
      estimatedGmiPercent: estimatedGmi(windowed),
      spikeCount: spikeCount(windowed, bounds: bounds),
      minMgdl: min,
      maxMgdl: max,
    );
  }

  static List<CgmReading> _orderedByTime(List<CgmReading> readings) {
    final timed = readings
        .where((reading) => reading.recordedAt != null)
        .toList();
    if (timed.length == readings.length) {
      timed.sort((a, b) => a.recordedAt!.compareTo(b.recordedAt!));
      return timed;
    }
    // Fall back to input order when timestamps are missing (e.g. minute-indexed
    // history) so spikes are still counted in arrival order.
    return readings;
  }
}
