import 'dart:math' as math;

import '../cgm_models.dart';
import '../health_event.dart';

/// Privacy-conscious summary statistics derived from a window of glucose
/// readings and journal events.
///
/// The point of this type is to *avoid sending raw data dumps* to an LLM: we
/// reduce potentially thousands of per-minute readings to a handful of
/// aggregate numbers, and events to anonymized counts/aggregates, before any
/// prompt is built. This minimizes what could ever leave the device when the
/// user opts into a BYO-key call.
class GlucoseSummary {
  const GlucoseSummary({
    required this.windowStart,
    required this.windowEnd,
    required this.readingCount,
    required this.unit,
    this.average,
    this.minimum,
    this.maximum,
    this.standardDeviation,
    this.timeInRangePercent,
    this.timeBelowRangePercent,
    this.timeAboveRangePercent,
    this.estimatedA1c,
    this.mealCount = 0,
    this.exerciseCount = 0,
    this.totalCarbsGrams,
    this.noteCount = 0,
  });

  final DateTime windowStart;
  final DateTime windowEnd;
  final int readingCount;
  final GlucoseUnit unit;
  final double? average;
  final double? minimum;
  final double? maximum;
  final double? standardDeviation;

  /// Percentage of readings within the configured target range.
  final double? timeInRangePercent;
  final double? timeBelowRangePercent;
  final double? timeAboveRangePercent;

  /// Estimated A1c (%) from mean glucose, for context only — not a lab value.
  final double? estimatedA1c;

  final int mealCount;
  final int exerciseCount;

  /// Total logged carbohydrates over the window, if any meals carried macros.
  final double? totalCarbsGrams;
  final int noteCount;

  bool get hasData => readingCount > 0;

  /// Builds a summary over [readings] and [events] within `[windowStart,
  /// windowEnd]`, reducing raw series to aggregates.
  ///
  /// [targetLowMgdl]/[targetHighMgdl] default to the common wellness 70–180
  /// mg/dL range used for time-in-range; values are always computed in mg/dL
  /// and reported in [unit].
  factory GlucoseSummary.fromData({
    required DateTime windowStart,
    required DateTime windowEnd,
    required List<CgmReading> readings,
    required List<HealthEvent> events,
    GlucoseUnit unit = GlucoseUnit.mgdl,
    double targetLowMgdl = 70,
    double targetHighMgdl = 180,
  }) {
    final values = readings
        .map((reading) => reading.valueMgdl)
        .where((value) => value > 0)
        .toList(growable: false);

    int mealCount = 0;
    int exerciseCount = 0;
    int noteCount = 0;
    double carbs = 0;
    bool sawCarbs = false;
    for (final event in events) {
      switch (event.type) {
        case HealthEventType.meal:
          mealCount++;
          final payload = event.payload;
          if (payload is MealPayload && payload.carbsGrams != null) {
            carbs += payload.carbsGrams!;
            sawCarbs = true;
          }
        case HealthEventType.exercise:
          exerciseCount++;
        case HealthEventType.note:
          noteCount++;
        case HealthEventType.insulin:
        case HealthEventType.medication:
        case HealthEventType.custom:
          break;
      }
    }

    if (values.isEmpty) {
      return GlucoseSummary(
        windowStart: windowStart,
        windowEnd: windowEnd,
        readingCount: 0,
        unit: unit,
        mealCount: mealCount,
        exerciseCount: exerciseCount,
        totalCarbsGrams: sawCarbs ? carbs : null,
        noteCount: noteCount,
      );
    }

    final count = values.length;
    final sum = values.fold<double>(0, (acc, value) => acc + value);
    final mean = sum / count;
    final variance =
        values.fold<double>(0, (acc, value) {
          final delta = value - mean;
          return acc + delta * delta;
        }) /
        count;
    final stdDev = math.sqrt(variance);

    final inRange = values
        .where((v) => v >= targetLowMgdl && v <= targetHighMgdl)
        .length;
    final below = values.where((v) => v < targetLowMgdl).length;
    final above = values.where((v) => v > targetHighMgdl).length;

    double toUnit(double mgdl) => unit.convertFromMgdl(mgdl);

    return GlucoseSummary(
      windowStart: windowStart,
      windowEnd: windowEnd,
      readingCount: count,
      unit: unit,
      average: toUnit(mean),
      minimum: toUnit(values.reduce(math.min)),
      maximum: toUnit(values.reduce(math.max)),
      standardDeviation: toUnit(stdDev),
      timeInRangePercent: 100 * inRange / count,
      timeBelowRangePercent: 100 * below / count,
      timeAboveRangePercent: 100 * above / count,
      // ADAG estimate; context only, not a clinical A1c.
      estimatedA1c: (mean + 46.7) / 28.7,
      mealCount: mealCount,
      exerciseCount: exerciseCount,
      totalCarbsGrams: sawCarbs ? carbs : null,
      noteCount: noteCount,
    );
  }
}
