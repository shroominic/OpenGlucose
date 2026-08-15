import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  final fixedNow = DateTime.utc(2026, 8, 15, 8, 30);
  late InMemoryHealthRepository repository;
  late JournalService journal;
  var nextId = 0;

  setUp(() {
    repository = InMemoryHealthRepository();
    nextId = 0;
    journal = JournalService(
      repository: repository,
      clock: () => fixedNow,
      idGenerator: () => 'test-${++nextId}',
    );
  });

  test('logs a meal with deterministic identity and UTC timestamp', () async {
    final event = await journal.logMeal(
      at: DateTime.parse('2026-08-15T15:00:00+07:00'),
      carbsGrams: 42,
      description: 'rice bowl',
      tags: const ['lunch'],
    );

    expect(event.id, 'meal-test-1');
    expect(event.timestamp, DateTime.utc(2026, 8, 15, 8));
    expect(event.source, DataSource.manual);
    expect((event.payload! as MealPayload).carbsGrams, 42);
    expect((await journal.queryEvents()).single.id, event.id);
  });

  test('logs exercise and notes with ergonomic payloads', () async {
    final exercise = await journal.logExercise(
      activity: 'walking',
      duration: const Duration(minutes: 25),
      intensity: ExerciseIntensity.moderate,
      energyKcal: 120,
    );
    final note = await journal.logNote(text: 'Felt steady after lunch.');

    expect(exercise.id, 'exercise-test-1');
    expect(exercise.timestamp, fixedNow);
    expect(
      (exercise.payload! as ExercisePayload).duration,
      const Duration(minutes: 25),
    );
    expect(note.id, 'note-test-2');
    expect((note.payload! as NotePayload).text, 'Felt steady after lunch.');
  });

  test('rejects blank notes and empty generated identifiers', () async {
    expect(
      () => journal.logNote(text: ' \n\t'),
      throwsA(isA<FormatException>()),
    );

    final invalid = JournalService(
      repository: repository,
      idGenerator: () => '   ',
    );
    expect(() => invalid.logMeal(), throwsA(isA<StateError>()));
  });

  test('loads mixed context streams in one sorted timeline', () async {
    await journal.logNote(
      at: DateTime.utc(2026, 8, 15, 9),
      text: 'after breakfast',
    );
    await journal.logMeal(at: DateTime.utc(2026, 8, 15, 7), carbsGrams: 30);
    await journal.importActivity(<ActivitySample>[
      ActivitySample(
        start: DateTime.utc(2026, 8, 15, 8),
        end: DateTime.utc(2026, 8, 15, 8, 30),
        type: ActivityType.workout,
        source: DataSource.appleHealth,
        workoutLabel: 'walk',
      ),
    ]);
    await journal.importSleep(<SleepSample>[
      SleepSample(
        start: DateTime.utc(2026, 8, 15, 6),
        end: DateTime.utc(2026, 8, 15, 6, 30),
        stage: SleepStage.light,
        source: DataSource.healthConnect,
      ),
    ]);
    await journal.importHeartRate(<HeartRateSample>[
      HeartRateSample(
        timestamp: DateTime.utc(2026, 8, 15, 8, 15),
        bpm: 72,
        source: DataSource.appleHealth,
      ),
    ]);

    final context = await journal.loadContext(
      window: TimeWindow(
        start: DateTime.utc(2026, 8, 15, 6),
        end: DateTime.utc(2026, 8, 15, 10),
      ),
    );

    expect(context.events, hasLength(2));
    expect(context.activitySamples, hasLength(1));
    expect(context.sleepSamples, hasLength(1));
    expect(context.heartRateSamples, hasLength(1));
    expect(
      context.timeline.map((entry) => entry.timelineKind),
      <TimelineEntryKind>[
        TimelineEntryKind.sleep,
        TimelineEntryKind.event,
        TimelineEntryKind.activity,
        TimelineEntryKind.heartRate,
        TimelineEntryKind.event,
      ],
    );
  });

  test('loadContextForDay uses local calendar boundaries', () async {
    await journal.logNote(
      at: DateTime(2026, 8, 15, 23, 59),
      text: 'same local day',
    );
    await journal.logNote(at: DateTime(2026, 8, 16), text: 'next local day');

    final context = await journal.loadContextForDay(DateTime(2026, 8, 15));
    expect(context.events, hasLength(1));
    expect(
      (context.events.single.payload! as NotePayload).text,
      'same local day',
    );
  });
}
