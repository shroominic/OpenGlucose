import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/context_timeline/context_timeline_models.dart';

final contextFixtureNow = DateTime.utc(2026, 8, 24, 12);

ContextTimelineSnapshot richContextFixture({
  bool sampleData = true,
  RecentContextGap? gap,
  List<ContextTimelineLaneStatus>? statuses,
}) {
  final now = contextFixtureNow;
  return ContextTimelineSnapshot(
    glucoseReadings: <CgmReading>[
      _reading(now.subtract(const Duration(hours: 23)), 96),
      _reading(now.subtract(const Duration(hours: 12)), 108),
      _reading(now.subtract(const Duration(hours: 4)), 118),
      _reading(now.subtract(const Duration(minutes: 25)), 151),
    ],
    events: <HealthEvent>[
      HealthEvent(
        id: 'note-1',
        timestamp: now.subtract(const Duration(hours: 8)),
        type: HealthEventType.note,
        payload: const NotePayload(text: 'Felt rested'),
        source: DataSource.manual,
      ),
      HealthEvent(
        id: 'meal-1',
        timestamp: now.subtract(const Duration(hours: 2)),
        type: HealthEventType.meal,
        payload: const MealPayload(carbsGrams: 42, description: 'Lunch'),
        source: DataSource.manual,
      ),
      HealthEvent(
        id: 'exercise-1',
        timestamp: now.subtract(const Duration(hours: 5)),
        type: HealthEventType.exercise,
        payload: const ExercisePayload(
          activity: 'Walk',
          duration: Duration(minutes: 30),
        ),
        source: DataSource.manual,
      ),
    ],
    sleepSamples: <SleepSample>[
      SleepSample(
        start: now.subtract(const Duration(hours: 26)),
        end: now.subtract(const Duration(hours: 18)),
        stage: SleepStage.asleep,
        source: DataSource.appleHealth,
      ),
    ],
    activitySamples: <ActivitySample>[
      ActivitySample(
        start: now.subtract(const Duration(hours: 6)),
        end: now.subtract(const Duration(hours: 5)),
        type: ActivityType.workout,
        source: DataSource.appleHealth,
        workoutLabel: 'Cycling',
      ),
      ActivitySample(
        start: now.subtract(const Duration(hours: 3)),
        end: now.subtract(const Duration(hours: 2)),
        type: ActivityType.steps,
        source: DataSource.healthConnect,
        steps: 1200,
      ),
    ],
    heartRateSamples: <HeartRateSample>[
      HeartRateSample(
        timestamp: now.subtract(const Duration(hours: 3)),
        bpm: 72,
        source: DataSource.appleHealth,
      ),
      HeartRateSample(
        timestamp: now.subtract(const Duration(minutes: 45)),
        bpm: 86,
        source: DataSource.appleHealth,
      ),
    ],
    laneStatuses:
        statuses ??
        const <ContextTimelineLaneStatus>[
          ContextTimelineLaneStatus(
            lane: ContextTimelineLane.mealsAndNotes,
            availability: ContextDataAvailability.available,
            source: DataSource.manual,
          ),
          ContextTimelineLaneStatus(
            lane: ContextTimelineLane.sleep,
            availability: ContextDataAvailability.available,
            source: DataSource.appleHealth,
          ),
          ContextTimelineLaneStatus(
            lane: ContextTimelineLane.activity,
            availability: ContextDataAvailability.available,
            source: DataSource.appleHealth,
          ),
          ContextTimelineLaneStatus(
            lane: ContextTimelineLane.heartRate,
            availability: ContextDataAvailability.partial,
            source: DataSource.appleHealth,
          ),
        ],
    recentContextGap:
        gap ??
        RecentContextGap(
          id: 'gap-newest',
          start: now.subtract(const Duration(minutes: 45)),
          end: now.subtract(const Duration(minutes: 20)),
        ),
    isSampleData: sampleData,
  );
}

CgmReading _reading(DateTime recordedAt, double value) => CgmReading(
  valueMgdl: value,
  source: CgmRecordSource.vendor,
  recordedAt: recordedAt,
);
