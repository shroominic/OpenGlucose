import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

/// A reusable contract test suite for any [HealthRepository] implementation.
///
/// [factory] must return a fresh, empty repository each time it is called.
/// The same suite runs against the in-memory fake here and against the
/// sqflite-backed store in the Flutter app, guaranteeing they agree.
void runHealthRepositoryContractTests(
  HealthRepository Function() factory,
) {
  late HealthRepository repo;

  setUp(() async {
    repo = factory();
    await repo.init();
  });

  tearDown(() async {
    await repo.close();
  });

  HealthEvent meal(String id, DateTime ts, {double? carbs}) => HealthEvent(
    id: id,
    timestamp: ts,
    type: HealthEventType.meal,
    payload: MealPayload(carbsGrams: carbs, description: 'm$id'),
  );

  group('events', () {
    test('round-trips a single event', () async {
      final e = meal('e1', DateTime.utc(2026, 1, 1, 8), carbs: 42);
      await repo.upsertEvent(e);

      final loaded = await repo.getEvent('e1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 'e1');
      expect(loaded.type, HealthEventType.meal);
      expect((loaded.payload as MealPayload).carbsGrams, 42);
      expect(loaded.timestamp, DateTime.utc(2026, 1, 1, 8));
    });

    test('upsert replaces by id', () async {
      await repo.upsertEvent(meal('e1', DateTime.utc(2026, 1, 1, 8), carbs: 10));
      await repo.upsertEvent(meal('e1', DateTime.utc(2026, 1, 1, 9), carbs: 99));

      final all = await repo.queryEvents();
      expect(all, hasLength(1));
      expect(all.single.timestamp, DateTime.utc(2026, 1, 1, 9));
      expect((all.single.payload as MealPayload).carbsGrams, 99);
    });

    test('bulk insert and query-by-window (half-open) + chronological', () async {
      await repo.upsertEvents([
        meal('a', DateTime.utc(2026, 1, 1, 6)),
        meal('b', DateTime.utc(2026, 1, 1, 8)),
        meal('c', DateTime.utc(2026, 1, 1, 10)),
        meal('d', DateTime.utc(2026, 1, 1, 12)),
      ]);

      final windowed = await repo.queryEvents(
        window: TimeWindow(
          start: DateTime.utc(2026, 1, 1, 8),
          end: DateTime.utc(2026, 1, 1, 12),
        ),
      );
      // start inclusive (b), end exclusive (d excluded).
      expect(windowed.map((e) => e.id), ['b', 'c']);
    });

    test('query filters by type', () async {
      await repo.upsertEvents([
        meal('m', DateTime.utc(2026, 1, 1, 8)),
        HealthEvent(
          id: 'n',
          timestamp: DateTime.utc(2026, 1, 1, 9),
          type: HealthEventType.note,
          payload: const NotePayload(text: 'hi'),
        ),
      ]);

      final notes = await repo.queryEvents(types: {HealthEventType.note});
      expect(notes.map((e) => e.id), ['n']);
    });

    test('delete removes one event', () async {
      await repo.upsertEvent(meal('e1', DateTime.utc(2026, 1, 1, 8)));
      await repo.deleteEvent('e1');
      expect(await repo.getEvent('e1'), isNull);
      expect(await repo.queryEvents(), isEmpty);
    });
  });

  group('activity samples', () {
    test('bulk insert, window + type filter, delete-by-window', () async {
      await repo.upsertActivitySamples([
        ActivitySample(
          start: DateTime.utc(2026, 1, 1, 6),
          end: DateTime.utc(2026, 1, 1, 7),
          type: ActivityType.steps,
          source: DataSource.appleHealth,
          steps: 1000,
        ),
        ActivitySample(
          start: DateTime.utc(2026, 1, 1, 9),
          end: DateTime.utc(2026, 1, 1, 10),
          type: ActivityType.workout,
          source: DataSource.appleHealth,
          workoutLabel: 'cycling',
        ),
      ]);

      final steps = await repo.queryActivitySamples(
        types: {ActivityType.steps},
      );
      expect(steps, hasLength(1));
      expect(steps.single.steps, 1000);

      final removed = await repo.deleteActivitySamples(
        window: TimeWindow(
          start: DateTime.utc(2026, 1, 1, 6),
          end: DateTime.utc(2026, 1, 1, 8),
        ),
      );
      expect(removed, 1);
      final remaining = await repo.queryActivitySamples();
      expect(remaining.map((s) => s.workoutLabel), ['cycling']);
    });
  });

  group('sleep samples', () {
    test('round-trip + window query', () async {
      await repo.upsertSleepSamples([
        SleepSample(
          start: DateTime.utc(2026, 1, 1, 23),
          end: DateTime.utc(2026, 1, 2, 1),
          stage: SleepStage.deep,
          source: DataSource.healthConnect,
        ),
        SleepSample(
          start: DateTime.utc(2026, 1, 2, 1),
          end: DateTime.utc(2026, 1, 2, 2),
          stage: SleepStage.rem,
          source: DataSource.healthConnect,
        ),
      ]);

      final all = await repo.querySleepSamples();
      expect(all.map((s) => s.stage), [SleepStage.deep, SleepStage.rem]);

      final early = await repo.querySleepSamples(
        window: TimeWindow(end: DateTime.utc(2026, 1, 2, 1)),
      );
      expect(early.map((s) => s.stage), [SleepStage.deep]);
    });
  });

  group('heart-rate samples', () {
    test('bulk insert + window query + delete-by-window', () async {
      await repo.upsertHeartRateSamples([
        for (var i = 0; i < 5; i++)
          HeartRateSample(
            timestamp: DateTime.utc(2026, 1, 1, 8, i),
            bpm: 60.0 + i,
            source: DataSource.appleHealth,
          ),
      ]);

      final mid = await repo.queryHeartRateSamples(
        window: TimeWindow(
          start: DateTime.utc(2026, 1, 1, 8, 1),
          end: DateTime.utc(2026, 1, 1, 8, 4),
        ),
      );
      expect(mid.map((s) => s.bpm), [61, 62, 63]);

      final removed = await repo.deleteHeartRateSamples();
      expect(removed, 5);
      expect(await repo.queryHeartRateSamples(), isEmpty);
    });
  });

  group('AI insights', () {
    test('upsert/replace, window+category filter, delete', () async {
      await repo.upsertInsight(
        AiInsight(
          id: 'i1',
          createdAt: DateTime.utc(2026, 1, 1, 9),
          category: AiInsightCategory.pattern,
          title: 'pattern',
        ),
      );
      await repo.upsertInsight(
        AiInsight(
          id: 'i2',
          createdAt: DateTime.utc(2026, 1, 2, 9),
          category: AiInsightCategory.summary,
          title: 'summary',
        ),
      );
      // Replace i1 in place.
      await repo.upsertInsight(
        AiInsight(
          id: 'i1',
          createdAt: DateTime.utc(2026, 1, 1, 9),
          category: AiInsightCategory.pattern,
          title: 'pattern v2',
        ),
      );

      final patterns = await repo.queryInsights(
        categories: {AiInsightCategory.pattern},
      );
      expect(patterns, hasLength(1));
      expect(patterns.single.title, 'pattern v2');

      final firstDay = await repo.queryInsights(
        window: TimeWindow(end: DateTime.utc(2026, 1, 2)),
      );
      expect(firstDay.map((i) => i.id), ['i1']);

      await repo.deleteInsight('i1');
      final left = await repo.queryInsights();
      expect(left.map((i) => i.id), ['i2']);
    });
  });

  test('clear wipes everything', () async {
    await repo.upsertEvent(meal('e', DateTime.utc(2026, 1, 1)));
    await repo.upsertSleepSamples([
      SleepSample(
        start: DateTime.utc(2026, 1, 1),
        end: DateTime.utc(2026, 1, 1, 1),
        stage: SleepStage.light,
        source: DataSource.manual,
      ),
    ]);
    await repo.upsertInsight(
      AiInsight(
        id: 'i',
        createdAt: DateTime.utc(2026, 1, 1),
        category: AiInsightCategory.custom,
        title: 't',
      ),
    );

    await repo.clear();

    expect(await repo.queryEvents(), isEmpty);
    expect(await repo.querySleepSamples(), isEmpty);
    expect(await repo.queryInsights(), isEmpty);
  });
}
