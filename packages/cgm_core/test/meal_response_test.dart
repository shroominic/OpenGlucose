import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

CgmReading reading(DateTime at, double value, {bool provisional = false}) {
  return CgmReading(
    valueMgdl: value,
    source: CgmRecordSource.vendor,
    recordedAt: at,
    isDisplayProvisional: provisional,
  );
}

HealthEvent meal(String id, DateTime at, {double? carbs}) {
  return HealthEvent(
    id: id,
    timestamp: at,
    type: HealthEventType.meal,
    payload: MealPayload(carbsGrams: carbs, description: 'meal $id'),
  );
}

void main() {
  final mealAt = DateTime.utc(2026, 8, 15, 8);

  test('pairs a meal with baseline and bounded post-meal response', () {
    final result = MealResponseAnalytics.analyze(
      events: <HealthEvent>[meal('m1', mealAt, carbs: 45)],
      readings: <CgmReading>[
        reading(mealAt.subtract(const Duration(minutes: 30)), 100),
        reading(mealAt.subtract(const Duration(minutes: 15)), 110),
        reading(mealAt, 105),
        reading(mealAt.add(const Duration(minutes: 30)), 140),
        reading(mealAt.add(const Duration(hours: 1)), 165),
        reading(mealAt.add(const Duration(hours: 2)), 130),
        reading(mealAt.add(const Duration(hours: 3)), 220),
      ],
    );

    expect(result.status, MealResponseSummaryStatus.ready);
    expect(result.mealCount, 1);
    expect(result.sufficientMealCount, 1);
    expect(result.averageCoveragePercent, closeTo(100, 1e-9));
    expect(result.averagePeakDeltaMgdl, closeTo(60, 1e-9));
    expect(result.averageTimeToPeak, const Duration(hours: 1));
    expect(result.responses.single.status, MealResponseStatus.sufficient);
    expect(result.responses.single.carbsGrams, 45);
    expect(result.responses.single.postMealReadingCount, 4);
  });

  test('reports explicit no-meal and no-glucose states', () {
    final noMeals = MealResponseAnalytics.analyze(
      events: const <HealthEvent>[],
      readings: const <CgmReading>[],
    );
    expect(noMeals.status, MealResponseSummaryStatus.noMeals);

    final noReadings = MealResponseAnalytics.analyze(
      events: <HealthEvent>[meal('m1', mealAt)],
      readings: const <CgmReading>[],
    );
    expect(noReadings.status, MealResponseSummaryStatus.noGlucoseReadings);
    expect(
      noReadings.responses.single.status,
      MealResponseStatus.noPostMealReadings,
    );
    expect(noReadings.averagePeakDeltaMgdl, isNull);
  });

  test('reports insufficient baseline, post-meal readings, and coverage', () {
    final baselineMissing = MealResponseAnalytics.analyze(
      events: <HealthEvent>[meal('m1', mealAt)],
      readings: <CgmReading>[
        reading(mealAt.add(const Duration(minutes: 15)), 150),
        reading(mealAt.add(const Duration(minutes: 30)), 160),
        reading(mealAt.add(const Duration(minutes: 45)), 170),
      ],
    );
    expect(
      baselineMissing.responses.single.status,
      MealResponseStatus.noBaseline,
    );

    final postReadingsMissing = MealResponseAnalytics.analyze(
      events: <HealthEvent>[meal('m1', mealAt)],
      readings: <CgmReading>[
        reading(mealAt.subtract(const Duration(minutes: 15)), 100),
        reading(mealAt.subtract(const Duration(minutes: 5)), 105),
        reading(mealAt.add(const Duration(minutes: 15)), 150),
      ],
    );
    expect(
      postReadingsMissing.responses.single.status,
      MealResponseStatus.insufficientPostMealReadings,
    );

    final coverageMissing = MealResponseAnalytics.analyze(
      events: <HealthEvent>[meal('m1', mealAt)],
      readings: <CgmReading>[
        reading(mealAt.subtract(const Duration(minutes: 15)), 100),
        reading(mealAt.subtract(const Duration(minutes: 5)), 105),
        reading(mealAt.add(const Duration(minutes: 15)), 150),
        reading(mealAt.add(const Duration(minutes: 30)), 160),
        reading(mealAt.add(const Duration(minutes: 45)), 170),
      ],
    );
    expect(
      coverageMissing.responses.single.status,
      MealResponseStatus.insufficientCoverage,
    );
    expect(
      coverageMissing.responses.single.coveragePercent,
      closeTo(37.5, 1e-9),
    );
    expect(coverageMissing.averagePeakDeltaMgdl, isNull);
  });

  test('excludes provisional readings and future meals deterministically', () {
    final result = MealResponseAnalytics.analyze(
      events: <HealthEvent>[
        meal('future', mealAt.add(const Duration(days: 1))),
        meal('m1', mealAt),
      ],
      readings: <CgmReading>[
        reading(mealAt.subtract(const Duration(minutes: 30)), 100),
        reading(
          mealAt.subtract(const Duration(minutes: 15)),
          110,
          provisional: true,
        ),
        reading(mealAt, 100),
        reading(mealAt.add(const Duration(minutes: 30)), 140),
        reading(mealAt.add(const Duration(hours: 1)), 160),
        reading(mealAt.add(const Duration(hours: 2)), 120),
      ],
      now: mealAt.add(const Duration(hours: 2)),
    );

    expect(result.mealCount, 1);
    expect(result.responses.single.baselineReadingCount, 1);
    expect(result.responses.single.status, MealResponseStatus.noBaseline);
  });

  test('keeps response ordering stable and does not claim causality', () {
    final result = MealResponseAnalytics.analyze(
      events: <HealthEvent>[
        meal('m2', mealAt.add(const Duration(hours: 3))),
        meal('m1', mealAt),
      ],
      readings: <CgmReading>[
        reading(mealAt.subtract(const Duration(minutes: 30)), 100),
        reading(mealAt.subtract(const Duration(minutes: 15)), 100),
        reading(mealAt, 100),
        reading(mealAt.add(const Duration(hours: 1)), 140),
        reading(mealAt.add(const Duration(hours: 2)), 100),
        reading(mealAt.add(const Duration(hours: 2, minutes: 30)), 100),
        reading(mealAt.add(const Duration(hours: 3)), 100),
        reading(mealAt.add(const Duration(hours: 4)), 140),
        reading(mealAt.add(const Duration(hours: 5)), 100),
      ],
    );

    expect(result.responses.map((item) => item.mealId), <String>['m1', 'm2']);
    expect(result.safetyBoundary, contains('not causal'));
  });
}
