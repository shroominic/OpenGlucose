import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/meal_response_card.dart';
import 'package:openglucose/src/today_cockpit.dart';

final _mealAt = DateTime.utc(2026, 8, 15, 8);

MealResponseSummary summary({
  MealResponseSummaryStatus status = MealResponseSummaryStatus.ready,
  int mealCount = 1,
  int sufficientMealCount = 1,
  double? coverage = 100,
  double? peakDelta = 42,
  Duration? timeToPeak = const Duration(minutes: 55),
}) {
  final response = MealResponse(
    mealId: 'm1',
    mealAt: _mealAt,
    status: sufficientMealCount > 0
        ? MealResponseStatus.sufficient
        : MealResponseStatus.insufficientCoverage,
    baselineReadingCount: 2,
    postMealReadingCount: 4,
    observedDuration: const Duration(hours: 2),
    coveragePercent: coverage ?? 0,
    baselineMgdl: 100,
    peakMgdl: peakDelta == null ? null : 100 + peakDelta,
    peakDeltaMgdl: peakDelta,
    timeToPeak: timeToPeak,
  );
  return MealResponseSummary(
    status: status,
    responses: mealCount == 0
        ? const <MealResponse>[]
        : <MealResponse>[response],
    mealCount: mealCount,
    sufficientMealCount: sufficientMealCount,
    postMealReadingCount: 4,
    averageCoveragePercent: coverage,
    averagePeakDeltaMgdl: peakDelta,
    averageTimeToPeak: timeToPeak,
    policy: const MealResponsePolicy(),
    safetyBoundary: 'Local observations only; not causal or medical advice.',
  );
}

void main() {
  testWidgets('renders compact meal response metrics and safety boundary', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MealResponseCard(summary: summary())),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('mealResponseCard')),
      findsOneWidget,
    );
    expect(find.text('Meal response'), findsOneWidget);
    expect(find.text('+42 mg/dL'), findsOneWidget);
    expect(find.text('55 min'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(
      find.text('Local observations only; not causal or medical advice.'),
      findsOneWidget,
    );
  });

  testWidgets('explains when response data is not ready', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MealResponseCard(
            summary: summary(
              status: MealResponseSummaryStatus.insufficientData,
              sufficientMealCount: 0,
              coverage: 22.5,
              peakDelta: null,
              timeToPeak: null,
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('Not enough readings yet'), findsOneWidget);
    expect(find.textContaining('two-hour window'), findsOneWidget);
    expect(find.text('Peak delta'), findsNothing);
  });

  testWidgets('Today cockpit accepts a meal response builder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayCockpit(
            readings: const <CgmReading>[],
            preferences: const DisplayPreferences(),
            now: DateTime.utc(2026, 8, 15, 12),
            mealResponseBuilder: summary,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('mealResponseCard')),
      findsOneWidget,
    );
  });
}
