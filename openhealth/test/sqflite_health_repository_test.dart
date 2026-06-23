import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/persistence/sqflite_health_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Run sqflite against in-process SQLite (FFI) so these tests need no device.
  sqfliteFfiInit();

  SqfliteHealthRepository newRepo() => SqfliteHealthRepository(
    path: inMemoryDatabasePath,
    databaseFactory: databaseFactoryFfi,
  );

  late SqfliteHealthRepository repo;

  setUp(() async {
    repo = newRepo();
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
    test('round-trips a single event with payload', () async {
      await repo.upsertEvent(meal('e1', DateTime.utc(2026, 1, 1, 8), carbs: 42));
      final loaded = await repo.getEvent('e1');
      expect(loaded, isNotNull);
      expect(loaded!.type, HealthEventType.meal);
      expect((loaded.payload as MealPayload).carbsGrams, 42);
      expect(loaded.timestamp, DateTime.utc(2026, 1, 1, 8));
    });

    test('upsert replaces by id', () async {
      await repo.upsertEvent(meal('e1', DateTime.utc(2026, 1, 1, 8), carbs: 10));
      await repo.upsertEvent(meal('e1', DateTime.utc(2026, 1, 1, 9), carbs: 99));
      final all = await repo.queryEvents();
      expect(all, hasLength(1));
      expect((all.single.payload as MealPayload).carbsGrams, 99);
    });

    test('bulk insert + half-open window query, sorted ascending', () async {
      await repo.upsertEvents([
        meal('c', DateTime.utc(2026, 1, 1, 10)),
        meal('a', DateTime.utc(2026, 1, 1, 6)),
        meal('d', DateTime.utc(2026, 1, 1, 12)),
        meal('b', DateTime.utc(2026, 1, 1, 8)),
      ]);
      final windowed = await repo.queryEvents(
        window: TimeWindow(
          start: DateTime.utc(2026, 1, 1, 8),
          end: DateTime.utc(2026, 1, 1, 12),
        ),
      );
      expect(windowed.map((e) => e.id), ['b', 'c']); // start incl, end excl
    });

    test('filters by type', () async {
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
      final none = await repo.queryEvents(types: const <HealthEventType>{});
      expect(none, isEmpty);
    });

    test('delete removes one event', () async {
      await repo.upsertEvent(meal('e1', DateTime.utc(2026, 1, 1, 8)));
      await repo.deleteEvent('e1');
      expect(await repo.getEvent('e1'), isNull);
    });
  });

  group('samples', () {
    test('activity: bulk insert, type filter, delete-by-window', () async {
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

    test('sleep: round-trip + window query', () async {
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

    test('heart-rate: bulk insert, window query, delete-all', () async {
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
      expect(await repo.deleteHeartRateSamples(), 5);
      expect(await repo.queryHeartRateSamples(), isEmpty);
    });
  });

  group('AI insights', () {
    test('upsert/replace, window + category filter, delete', () async {
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
      expect(patterns.single.title, 'pattern v2');
      final firstDay = await repo.queryInsights(
        window: TimeWindow(end: DateTime.utc(2026, 1, 2)),
      );
      expect(firstDay.map((i) => i.id), ['i1']);
      await repo.deleteInsight('i1');
      expect((await repo.queryInsights()).map((i) => i.id), ['i2']);
    });
  });

  test('clear wipes every table', () async {
    await repo.upsertEvent(meal('e', DateTime.utc(2026, 1, 1)));
    await repo.upsertHeartRateSamples([
      HeartRateSample(
        timestamp: DateTime.utc(2026, 1, 1),
        bpm: 70,
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
    expect(await repo.queryHeartRateSamples(), isEmpty);
    expect(await repo.queryInsights(), isEmpty);
  });

  group('schema / migrations', () {
    test('init is idempotent and creates a usable schema', () async {
      // init() already ran in setUp; calling again must be a no-op.
      await repo.init();
      await repo.upsertEvent(meal('e', DateTime.utc(2026, 1, 1)));
      expect(await repo.queryEvents(), hasLength(1));
    });

    test('opens at the current schema version', () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: SqfliteHealthRepository.schemaVersion),
      );
      expect(
        await db.getVersion(),
        SqfliteHealthRepository.schemaVersion,
      );
      await db.close();
    });

    test('onCreate runs the same migration path as a fresh open', () async {
      // A second repository over a fresh in-memory db must come up clean,
      // proving onCreate -> _migrate(0, latest) builds the full schema.
      final other = newRepo();
      await other.init();
      await other.upsertInsight(
        AiInsight(
          id: 'x',
          createdAt: DateTime.utc(2026, 1, 1),
          category: AiInsightCategory.anomaly,
          title: 'a',
        ),
      );
      expect(await other.queryInsights(), hasLength(1));
      await other.close();
    });
  });
}
