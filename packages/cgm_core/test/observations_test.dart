import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

List<CgmReading> _readings(DateTime start) =>
    List<CgmReading>.generate(145, (i) {
      final value = i == 24 ? 210.0 : 100.0 + (i % 5) * 10;
      return CgmReading(
        valueMgdl: value,
        source: CgmRecordSource.vendor,
        recordedAt: start.add(Duration(minutes: i * 5)),
      );
    });

void main() {
  final start = DateTime.utc(2026, 6, 1, 8);
  final end = start.add(const Duration(hours: 24));

  test('generates deterministic evidence-backed observations with context', () {
    final events = <HealthEvent>[
      HealthEvent(
        id: 'meal',
        timestamp: start.add(const Duration(hours: 1)),
        type: HealthEventType.meal,
        payload: const MealPayload(carbsGrams: 45),
      ),
    ];
    final activity = <ActivitySample>[
      ActivitySample(
        start: start.add(const Duration(hours: 2)),
        end: start.add(const Duration(hours: 3)),
        type: ActivityType.steps,
        source: DataSource.appleHealth,
        steps: 1200,
      ),
    ];
    final sleep = <SleepSample>[
      SleepSample(
        start: start.subtract(const Duration(hours: 1)),
        end: start.add(const Duration(hours: 1)),
        stage: SleepStage.asleep,
        source: DataSource.appleHealth,
      ),
    ];
    final heartRate = <HeartRateSample>[
      HeartRateSample(
        timestamp: start.add(const Duration(hours: 2)),
        bpm: 72,
        source: DataSource.appleHealth,
      ),
    ];

    final observations = MetabolicObservationEngine.generate(
      readings: _readings(start),
      events: events,
      activitySamples: activity,
      sleepSamples: sleep,
      heartRateSamples: heartRate,
      windowStart: start,
      windowEnd: end,
    );
    final kinds = observations.map((item) => item.kind).toSet();
    expect(
      kinds,
      containsAll(<ObservationKind>[
        ObservationKind.coverage,
        ObservationKind.glucoseLevel,
        ObservationKind.glucoseRange,
        ObservationKind.variability,
        ObservationKind.spike,
        ObservationKind.mealContext,
        ObservationKind.activityContext,
        ObservationKind.sleepContext,
        ObservationKind.heartRateContext,
      ]),
    );
    expect(observations.every((item) => item.isEvidenceBacked), isTrue);
    expect(
      observations
          .expand((item) => item.evidence)
          .every((item) => item.sampleCount >= 0 && item.windowEnd == end),
      isTrue,
    );

    final repeated = MetabolicObservationEngine.generate(
      readings: _readings(start),
      events: events,
      activitySamples: activity,
      sleepSamples: sleep,
      heartRateSamples: heartRate,
      windowStart: start,
      windowEnd: end,
    );
    expect(
      repeated.map((item) => item.id).toList(),
      observations.map((item) => item.id).toList(),
    );
  });

  test('observation and evidence JSON round-trip', () {
    final observation = MetabolicObservationEngine.generate(
      readings: _readings(start),
      events: const <HealthEvent>[],
      windowStart: start,
      windowEnd: end,
    ).first;
    final restored = MetabolicObservation.fromJson(observation.toJson());
    expect(restored.id, observation.id);
    expect(restored.evidence.first.id, observation.evidence.first.id);
    expect(restored.caveat, isNotEmpty);
  });
}
