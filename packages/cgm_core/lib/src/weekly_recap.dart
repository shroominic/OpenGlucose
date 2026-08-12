import 'cgm_models.dart';
import 'glucose_analytics.dart';

/// Aggregations powering the weekly recap / trends screen.
///
/// Wellness framing: everything here surfaces *patterns and observations* for
/// self-experimentation over a 7-day window. None of it is a medical metric,
/// diagnosis, or a substitute for clinical measurement.
///
/// All glucose figures stay in mg/dL; the UI layer converts to the user's unit.

/// Per-day summary inside a recap week.
class DailyRecap {
  const DailyRecap({
    required this.date,
    required this.weekday,
    required this.stats,
  });

  /// The calendar day this summary covers (date-only, local midnight).
  final DateTime date;

  /// `DateTime.weekday` (1 = Monday … 7 = Sunday) for day-of-week grouping.
  final int weekday;

  /// The glucose stats for readings on this day (timeframe = last7d marker;
  /// the readings are pre-filtered to the day).
  final GlucoseStats stats;

  bool get hasData => stats.hasData;
}

/// A week-over-week change for a single numeric observation.
///
/// [current] / [previous] are the raw values (or null when not computable for
/// that week). [delta] is `current - previous` when both exist, else null.
class WeekDelta {
  const WeekDelta({required this.current, required this.previous})
    : delta = (current != null && previous != null) ? current - previous : null;

  final double? current;
  final double? previous;
  final double? delta;

  /// True when both weeks have a comparable value.
  bool get hasComparison => delta != null;

  /// True when the change is effectively zero (within [epsilon]).
  bool isFlat({double epsilon = 0.05}) =>
      delta != null && delta!.abs() <= epsilon;
}

/// A notable upward swing within the week, for the "top spikes" card.
class RecapSpike {
  const RecapSpike({
    required this.at,
    required this.peakMgdl,
    required this.riseFromMgdl,
  });

  /// When the peak reading occurred.
  final DateTime at;

  /// The highest reading reached during this above-range excursion.
  final double peakMgdl;

  /// The reading the excursion rose from (last in/below-range value before it,
  /// or the first above-range value when there was no prior reading).
  final double riseFromMgdl;

  /// How far the peak rose above [riseFromMgdl].
  double get amplitudeMgdl => peakMgdl - riseFromMgdl;
}

/// Average reading for a given day-of-week across the week (Mon…Sun pattern).
class DayOfWeekAverage {
  const DayOfWeekAverage({required this.weekday, required this.averageMgdl});

  /// `DateTime.weekday` (1 = Monday … 7 = Sunday).
  final int weekday;

  /// Mean of that weekday's readings in mg/dL, or null when none.
  final double? averageMgdl;
}

/// Immutable bundle summarising one recap week plus week-over-week deltas.
class WeeklyRecap {
  const WeeklyRecap({
    required this.weekStart,
    required this.weekEnd,
    required this.bounds,
    required this.thisWeek,
    required this.lastWeek,
    required this.days,
    required this.bestDay,
    required this.worstDay,
    required this.topSpikes,
    required this.dayOfWeekAverages,
    required this.averageDelta,
    required this.timeInRangeDelta,
    required this.variabilityDelta,
  });

  /// Inclusive local-midnight start of the current recap week.
  final DateTime weekStart;

  /// Exclusive end (== [weekStart] + 7 days) of the current recap week.
  final DateTime weekEnd;

  final GlucoseRangeBounds bounds;

  /// Stats over all of this week's readings.
  final GlucoseStats thisWeek;

  /// Stats over the prior 7-day window.
  final GlucoseStats lastWeek;

  /// Per-day breakdown for the current week, ordered oldest → newest, one entry
  /// per calendar day in `[weekStart, weekEnd)` (days without readings still
  /// appear, with empty stats).
  final List<DailyRecap> days;

  /// The day with the highest time-in-range this week, or null when no day had
  /// readings.
  final DailyRecap? bestDay;

  /// The day with the lowest time-in-range (among days with readings), or null.
  final DailyRecap? worstDay;

  /// Largest upward swings this week, strongest first (capped, see [recap]).
  final List<RecapSpike> topSpikes;

  /// Average reading per weekday across this week (Mon…Sun), for spotting
  /// day-of-week patterns. Always 7 entries (Mon→Sun); [DayOfWeekAverage
  /// .averageMgdl] is null for weekdays with no readings.
  final List<DayOfWeekAverage> dayOfWeekAverages;

  /// This-week-vs-last-week change in average glucose.
  final WeekDelta averageDelta;

  /// This-week-vs-last-week change in time-in-range percent.
  final WeekDelta timeInRangeDelta;

  /// This-week-vs-last-week change in variability (CV percent).
  final WeekDelta variabilityDelta;

  bool get hasData => thisWeek.hasData;
}

/// Computes [WeeklyRecap] aggregations from a flat list of readings.
abstract final class WeeklyRecapAnalytics {
  /// Maximum number of spikes surfaced in [WeeklyRecap.topSpikes].
  static const int maxTopSpikes = 3;

  /// Returns the local-midnight date for [moment] (year/month/day only).
  static DateTime dayStart(DateTime moment) {
    final local = moment.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static DateTime _calendarDay(DateTime day, int offset) =>
      DateTime(day.year, day.month, day.day + offset);

  /// Builds the recap for the 7-day window ending at [now] (defaults to
  /// [DateTime.now]). The current week is `[weekStart, weekStart + 7d)` where
  /// [weekStart] is the local midnight 6 days before today, so "this week" is
  /// today plus the previous six calendar days. The prior week is the seven
  /// calendar days immediately before that.
  static WeeklyRecap recap(
    List<CgmReading> readings, {
    GlucoseRangeBounds bounds = GlucoseRangeBounds.standard,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final today = dayStart(reference);
    // Current week covers today and the previous six days → 7 calendar days.
    final weekStart = _calendarDay(today, -6);
    final weekEnd = _calendarDay(weekStart, 7);
    final lastWeekStart = _calendarDay(weekStart, -7);

    final thisWeekReadings = _inDayRange(readings, weekStart, weekEnd);
    final lastWeekReadings = _inDayRange(readings, lastWeekStart, weekStart);

    final thisWeek = GlucoseAnalytics.summarize(
      thisWeekReadings,
      timeframe: AnalyticsTimeframe.last7d,
      bounds: bounds,
      preFiltered: true,
    );
    final lastWeek = GlucoseAnalytics.summarize(
      lastWeekReadings,
      timeframe: AnalyticsTimeframe.last7d,
      bounds: bounds,
      preFiltered: true,
    );

    final days = _buildDays(thisWeekReadings, weekStart, weekEnd, bounds);
    final (best, worst) = _bestAndWorst(days);

    return WeeklyRecap(
      weekStart: weekStart,
      weekEnd: weekEnd,
      bounds: bounds,
      thisWeek: thisWeek,
      lastWeek: lastWeek,
      days: days,
      bestDay: best,
      worstDay: worst,
      topSpikes: _topSpikes(thisWeekReadings, bounds),
      dayOfWeekAverages: _dayOfWeekAverages(days),
      averageDelta: WeekDelta(
        current: thisWeek.averageMgdl,
        previous: lastWeek.averageMgdl,
      ),
      timeInRangeDelta: WeekDelta(
        current: thisWeek.hasData ? thisWeek.timeInRangePercent : null,
        previous: lastWeek.hasData ? lastWeek.timeInRangePercent : null,
      ),
      variabilityDelta: WeekDelta(
        current: thisWeek.coefficientOfVariationPercent,
        previous: lastWeek.coefficientOfVariationPercent,
      ),
    );
  }

  /// Readings recorded in `[start, end)` (by local day), timestamped only.
  static List<CgmReading> _inDayRange(
    List<CgmReading> readings,
    DateTime start,
    DateTime end,
  ) {
    return readings
        .where((reading) {
          final at = reading.recordedAt;
          if (at == null) return false;
          final local = at.toLocal();
          return !local.isBefore(start) && local.isBefore(end);
        })
        .toList(growable: false);
  }

  /// One [DailyRecap] per calendar day in `[weekStart, weekEnd)`.
  static List<DailyRecap> _buildDays(
    List<CgmReading> weekReadings,
    DateTime weekStart,
    DateTime weekEnd,
    GlucoseRangeBounds bounds,
  ) {
    // Bucket readings by their local day-start.
    final byDay = <DateTime, List<CgmReading>>{};
    for (final reading in weekReadings) {
      final at = reading.recordedAt;
      if (at == null) continue;
      final key = dayStart(at);
      (byDay[key] ??= <CgmReading>[]).add(reading);
    }

    final days = <DailyRecap>[];
    for (
      var day = weekStart;
      day.isBefore(weekEnd);
      day = _calendarDay(day, 1)
    ) {
      final dayReadings = byDay[day] ?? const <CgmReading>[];
      final stats = GlucoseAnalytics.summarize(
        dayReadings,
        timeframe: AnalyticsTimeframe.last24h,
        bounds: bounds,
        preFiltered: true,
      );
      days.add(DailyRecap(date: day, weekday: day.weekday, stats: stats));
    }
    return days;
  }

  /// Best (highest TIR) and worst (lowest TIR) days among those with readings.
  static (DailyRecap?, DailyRecap?) _bestAndWorst(List<DailyRecap> days) {
    DailyRecap? best;
    DailyRecap? worst;
    for (final day in days) {
      if (!day.hasData) continue;
      if (best == null ||
          day.stats.timeInRangePercent > best.stats.timeInRangePercent) {
        best = day;
      }
      if (worst == null ||
          day.stats.timeInRangePercent < worst.stats.timeInRangePercent) {
        worst = day;
      }
    }
    return (best, worst);
  }

  /// Largest above-range excursions this week, strongest amplitude first.
  static List<RecapSpike> _topSpikes(
    List<CgmReading> weekReadings,
    GlucoseRangeBounds bounds,
  ) {
    final ordered = weekReadings.where((r) => r.recordedAt != null).toList()
      ..sort((a, b) => a.recordedAt!.compareTo(b.recordedAt!));

    final spikes = <RecapSpike>[];
    var inSpike = false;
    var baseline = 0.0; // last in/below-range value before the excursion
    var peak = 0.0;
    DateTime? peakAt;

    void flush() {
      if (inSpike && peakAt != null) {
        spikes.add(
          RecapSpike(at: peakAt!, peakMgdl: peak, riseFromMgdl: baseline),
        );
      }
      inSpike = false;
      peakAt = null;
    }

    double lastBelowOrIn = double.nan;
    DateTime? previousAt;
    for (final reading in ordered) {
      final recordedAt = reading.recordedAt!;
      if (previousAt != null &&
          recordedAt.difference(previousAt) > const Duration(hours: 6)) {
        flush();
        lastBelowOrIn = double.nan;
      }
      previousAt = recordedAt;
      final value = reading.valueMgdl;
      final isAbove = value > bounds.highMgdl;
      if (isAbove) {
        if (!inSpike) {
          inSpike = true;
          baseline = lastBelowOrIn.isNaN ? value : lastBelowOrIn;
          peak = value;
          peakAt = reading.recordedAt;
        } else if (value > peak) {
          peak = value;
          peakAt = reading.recordedAt;
        }
      } else {
        flush();
        lastBelowOrIn = value;
      }
    }
    flush();

    spikes.sort((a, b) => b.amplitudeMgdl.compareTo(a.amplitudeMgdl));
    return spikes.take(maxTopSpikes).toList(growable: false);
  }

  /// Mean reading per weekday (Mon→Sun) across the week's days.
  static List<DayOfWeekAverage> _dayOfWeekAverages(List<DailyRecap> days) {
    final sums = List<double>.filled(7, 0); // index 0 = Monday … 6 = Sunday
    final counts = List<int>.filled(7, 0);
    for (final day in days) {
      final avg = day.stats.averageMgdl;
      if (avg == null) continue;
      final idx = day.weekday - 1;
      sums[idx] += avg * day.stats.readingCount;
      counts[idx] += day.stats.readingCount;
    }
    return <DayOfWeekAverage>[
      for (var i = 0; i < 7; i++)
        DayOfWeekAverage(
          weekday: i + 1,
          averageMgdl: counts[i] == 0 ? null : sums[i] / counts[i],
        ),
    ];
  }
}
