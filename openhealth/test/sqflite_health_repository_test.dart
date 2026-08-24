import 'dart:io';

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
      await repo.upsertEvent(
        meal('e1', DateTime.utc(2026, 1, 1, 8), carbs: 42),
      );
      final loaded = await repo.getEvent('e1');
      expect(loaded, isNotNull);
      expect(loaded!.type, HealthEventType.meal);
      final payload = loaded.payload;
      expect(payload, isA<MealPayload>());
      if (payload is MealPayload) {
        expect(payload.carbsGrams, 42);
      }
      expect(loaded.timestamp, DateTime.utc(2026, 1, 1, 8));
    });

    test('upsert replaces by id', () async {
      await repo.upsertEvent(
        meal('e1', DateTime.utc(2026, 1, 1, 8), carbs: 10),
      );
      await repo.upsertEvent(
        meal('e1', DateTime.utc(2026, 1, 1, 9), carbs: 99),
      );
      final all = await repo.queryEvents();
      expect(all, hasLength(1));
      final payload = all.single.payload;
      expect(payload, isA<MealPayload>());
      if (payload is MealPayload) {
        expect(payload.carbsGrams, 99);
      }
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

    test(
      'source identity replaces updates and remains platform-scoped',
      () async {
        await repo.upsertActivitySamples([
          ActivitySample(
            start: DateTime.utc(2026, 1, 1, 8),
            end: DateTime.utc(2026, 1, 1, 8, 15),
            type: ActivityType.steps,
            source: DataSource.appleHealth,
            steps: 100,
            provenance: const HealthSampleProvenance(
              identity: HealthImportIdentity(
                platform: HealthSourcePlatform.appleHealth,
                externalId: 'fixture-record-1',
              ),
              sourceRevision: 'revision-1',
            ),
          ),
        ]);
        await repo.upsertActivitySamples([
          ActivitySample(
            start: DateTime.utc(2026, 1, 1, 9),
            end: DateTime.utc(2026, 1, 1, 9, 15),
            type: ActivityType.steps,
            source: DataSource.appleHealth,
            steps: 250,
            provenance: const HealthSampleProvenance(
              identity: HealthImportIdentity(
                platform: HealthSourcePlatform.appleHealth,
                externalId: 'fixture-record-1',
              ),
              sourceRevision: 'revision-2',
            ),
          ),
          ActivitySample(
            start: DateTime.utc(2026, 1, 1, 10),
            end: DateTime.utc(2026, 1, 1, 10, 15),
            type: ActivityType.steps,
            source: DataSource.healthConnect,
            steps: 300,
            provenance: const HealthSampleProvenance(
              identity: HealthImportIdentity(
                platform: HealthSourcePlatform.healthConnect,
                externalId: 'fixture-record-1',
              ),
            ),
          ),
        ]);

        final samples = await repo.queryActivitySamples();
        expect(samples, hasLength(2));
        expect(samples.map((sample) => sample.steps), [250, 300]);
        expect(samples.first.provenance!.sourceRevision, 'revision-2');
      },
    );

    test(
      'expiry removes only aged records for the requested source platform',
      () async {
        await repo.upsertHeartRateSamples([
          HeartRateSample(
            timestamp: DateTime.utc(2026, 1, 1, 8),
            bpm: 60,
            source: DataSource.appleHealth,
            provenance: const HealthSampleProvenance(
              identity: HealthImportIdentity(
                platform: HealthSourcePlatform.appleHealth,
                externalId: 'expired-apple',
              ),
            ),
          ),
          HeartRateSample(
            timestamp: DateTime.utc(2026, 1, 2, 8),
            bpm: 61,
            source: DataSource.appleHealth,
            provenance: const HealthSampleProvenance(
              identity: HealthImportIdentity(
                platform: HealthSourcePlatform.appleHealth,
                externalId: 'recent-apple',
              ),
            ),
          ),
          HeartRateSample(
            timestamp: DateTime.utc(2026, 1, 1, 8),
            bpm: 62,
            source: DataSource.healthConnect,
            provenance: const HealthSampleProvenance(
              identity: HealthImportIdentity(
                platform: HealthSourcePlatform.healthConnect,
                externalId: 'expired-other',
              ),
            ),
          ),
          HeartRateSample(
            timestamp: DateTime.utc(2026, 1, 1, 8),
            bpm: 63,
            source: DataSource.appleHealth,
          ),
        ]);

        final removed = await repo.purgeImportedSamplesBefore(
          kind: HealthSampleKind.heartRate,
          platform: HealthSourcePlatform.appleHealth,
          cutoff: DateTime.utc(2026, 1, 2),
        );

        expect(removed, 1);
        final remaining = await repo.queryHeartRateSamples();
        expect(remaining, hasLength(3));
        expect(
          remaining.map((sample) => sample.provenance?.identity.externalId),
          containsAll(<String?>['recent-apple', 'expired-other', null]),
        );
      },
    );

    test(
      'tombstone removes an imported record, then a re-import clears it',
      () async {
        const identity = HealthImportIdentity(
          platform: HealthSourcePlatform.appleHealth,
          externalId: 'fixture-record-2',
        );
        await repo.upsertHeartRateSamples([
          HeartRateSample(
            timestamp: DateTime.utc(2026, 1, 1, 12),
            bpm: 72,
            source: DataSource.appleHealth,
            provenance: const HealthSampleProvenance(identity: identity),
          ),
        ]);
        await repo.reconcileImportTombstones([
          const HealthImportTombstone(
            kind: HealthSampleKind.heartRate,
            provenance: HealthSampleProvenance(
              identity: identity,
              sourceRevision: 'revision-3',
              isDeleted: true,
            ),
          ),
        ]);

        expect(await repo.queryHeartRateSamples(), isEmpty);
        final tombstones = await repo.queryImportTombstones(
          kind: HealthSampleKind.heartRate,
        );
        expect(tombstones, hasLength(1));
        expect(tombstones.single.provenance.sourceRevision, 'revision-3');

        await repo.upsertHeartRateSamples([
          HeartRateSample(
            timestamp: DateTime.utc(2026, 1, 1, 12, 5),
            bpm: 74,
            source: DataSource.appleHealth,
            provenance: const HealthSampleProvenance(
              identity: identity,
              sourceRevision: 'revision-4',
            ),
          ),
        ]);

        final reimported = await repo.queryHeartRateSamples();
        expect(reimported, hasLength(1));
        expect(reimported.single.bpm, 74);
        expect(reimported.single.provenance!.sourceRevision, 'revision-4');
        expect(await repo.queryImportTombstones(), isEmpty);
      },
    );
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
    await repo.reconcileImportTombstones([
      const HealthImportTombstone(
        kind: HealthSampleKind.heartRate,
        provenance: HealthSampleProvenance(
          identity: HealthImportIdentity(
            platform: HealthSourcePlatform.appleHealth,
            externalId: 'fixture-clear-tombstone',
          ),
          isDeleted: true,
        ),
      ),
    ]);
    await repo.clear();
    expect(await repo.queryEvents(), isEmpty);
    expect(await repo.queryHeartRateSamples(), isEmpty);
    expect(await repo.queryImportTombstones(), isEmpty);
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
        options: OpenDatabaseOptions(
          version: SqfliteHealthRepository.schemaVersion,
        ),
      );
      expect(await db.getVersion(), SqfliteHealthRepository.schemaVersion);
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

    test(
      'upgrades a schema-v1 database without rewriting legacy rows',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'openglucose-health-v1-',
        );
        final path = '${directory.path}${Platform.pathSeparator}health.db';
        try {
          final v1 = await databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(
              version: 1,
              onCreate: (db, version) async {
                await db.execute('''
                CREATE TABLE activity_samples (
                  row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  start_ms INTEGER NOT NULL,
                  type TEXT NOT NULL,
                  data TEXT NOT NULL
                )
              ''');
                await db.execute('''
                CREATE TABLE sleep_samples (
                  row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  start_ms INTEGER NOT NULL,
                  data TEXT NOT NULL
                )
              ''');
                await db.execute('''
                CREATE TABLE heart_rate_samples (
                  row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  timestamp_ms INTEGER NOT NULL,
                  data TEXT NOT NULL
                )
              ''');
              },
            ),
          );
          await v1.insert('activity_samples', <String, Object?>{
            'start_ms': DateTime.utc(2026, 1, 1, 8).millisecondsSinceEpoch,
            'type': ActivityType.steps.key,
            'data':
                '{'
                '"formatVersion":1,'
                '"start":"2026-01-01T08:00:00.000Z",'
                '"end":"2026-01-01T08:15:00.000Z",'
                '"type":"steps",'
                '"source":"appleHealth",'
                '"steps":100'
                '}',
          });
          await v1.close();

          final upgraded = SqfliteHealthRepository(
            path: path,
            databaseFactory: databaseFactoryFfi,
          );
          await upgraded.init();
          final samples = await upgraded.queryActivitySamples();
          expect(samples, hasLength(1));
          expect(samples.single.steps, 100);
          expect(samples.single.provenance, isNull);

          await upgraded.upsertActivitySamples([
            ActivitySample(
              start: DateTime.utc(2026, 1, 1, 9),
              end: DateTime.utc(2026, 1, 1, 9, 15),
              type: ActivityType.steps,
              source: DataSource.appleHealth,
              steps: 200,
              provenance: const HealthSampleProvenance(
                identity: HealthImportIdentity(
                  platform: HealthSourcePlatform.appleHealth,
                  externalId: 'fixture-upgraded-record',
                ),
              ),
            ),
          ]);
          await upgraded.upsertActivitySamples([
            ActivitySample(
              start: DateTime.utc(2026, 1, 1, 10),
              end: DateTime.utc(2026, 1, 1, 10, 15),
              type: ActivityType.steps,
              source: DataSource.appleHealth,
              steps: 250,
              provenance: const HealthSampleProvenance(
                identity: HealthImportIdentity(
                  platform: HealthSourcePlatform.appleHealth,
                  externalId: 'fixture-upgraded-record',
                ),
              ),
            ),
          ]);
          final reconciled = await upgraded.queryActivitySamples();
          expect(reconciled, hasLength(2));
          expect(reconciled.last.steps, 250);
          await upgraded.close();

          final inspected = await databaseFactoryFfi.openDatabase(path);
          expect(
            await inspected.getVersion(),
            SqfliteHealthRepository.schemaVersion,
          );
          final columns = await inspected.rawQuery(
            'PRAGMA table_info(activity_samples)',
          );
          expect(
            columns.map((column) => column['name']),
            containsAll(['identity_platform', 'external_id']),
          );
          final tables = await inspected.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [SqfliteHealthRepository.tableImportTombstones],
          );
          expect(tables, isNotEmpty);
          await inspected.close();
        } finally {
          await databaseFactoryFfi.deleteDatabase(path);
          await directory.delete(recursive: true);
        }
      },
    );

    test(
      'rejects an unknown newer schema without lowering its version',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'openglucose-health-future-schema-',
        );
        final path = '${directory.path}${Platform.pathSeparator}health.db';
        try {
          final current = SqfliteHealthRepository(
            path: path,
            databaseFactory: databaseFactoryFfi,
          );
          await current.init();
          await current.close();

          final future = await databaseFactoryFfi.openDatabase(path);
          const futureVersion = SqfliteHealthRepository.schemaVersion + 1;
          await future.setVersion(futureVersion);
          await future.close();

          final older = SqfliteHealthRepository(
            path: path,
            databaseFactory: databaseFactoryFfi,
          );
          await expectLater(older.init(), throwsA(isA<StateError>()));
          await older.close();

          final inspected = await databaseFactoryFfi.openDatabase(path);
          expect(await inspected.getVersion(), futureVersion);
          await inspected.close();
        } finally {
          await databaseFactoryFfi.deleteDatabase(path);
          await directory.delete(recursive: true);
        }
      },
    );

    test(
      'recovers after a schema-v1 binary lowers the v2 version marker',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'openglucose-health-v2-v1-v2-',
        );
        final path = '${directory.path}${Platform.pathSeparator}health.db';
        try {
          const identity = HealthImportIdentity(
            platform: HealthSourcePlatform.appleHealth,
            externalId: 'fixture-downgrade-record',
          );
          final initial = SqfliteHealthRepository(
            path: path,
            databaseFactory: databaseFactoryFfi,
          );
          await initial.init();
          await initial.upsertActivitySamples([
            ActivitySample(
              start: DateTime.utc(2026, 1, 1, 8),
              end: DateTime.utc(2026, 1, 1, 8, 15),
              type: ActivityType.steps,
              source: DataSource.appleHealth,
              steps: 100,
              provenance: const HealthSampleProvenance(identity: identity),
            ),
          ]);
          await initial.close();

          // The shipped v1 repository has no onDowngrade callback. sqflite
          // lowers user_version, but leaves the additive v2 table shape.
          final legacyV1 = await databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(version: 1),
          );
          expect(await legacyV1.getVersion(), 1);
          final v2Columns = await legacyV1.rawQuery(
            'PRAGMA table_info(activity_samples)',
          );
          expect(
            v2Columns.map((column) => column['name']),
            containsAll(['identity_platform', 'external_id']),
          );
          await legacyV1.insert('activity_samples', <String, Object?>{
            'start_ms': DateTime.utc(2026, 1, 1, 9).millisecondsSinceEpoch,
            'type': ActivityType.steps.key,
            'data':
                '{'
                '"formatVersion":1,'
                '"start":"2026-01-01T09:00:00.000Z",'
                '"end":"2026-01-01T09:15:00.000Z",'
                '"type":"steps",'
                '"source":"appleHealth",'
                '"steps":200'
                '}',
          });
          await legacyV1.close();

          final recovered = SqfliteHealthRepository(
            path: path,
            databaseFactory: databaseFactoryFfi,
          );
          await recovered.init();
          final recoveredSamples = await recovered.queryActivitySamples();
          expect(recoveredSamples, hasLength(2));
          expect(
            recoveredSamples
                .singleWhere((sample) => sample.provenance == null)
                .steps,
            200,
          );
          expect(
            recoveredSamples
                .singleWhere((sample) => sample.provenance != null)
                .steps,
            100,
          );

          // The restored v2 import index still replaces the source record.
          await recovered.upsertActivitySamples([
            ActivitySample(
              start: DateTime.utc(2026, 1, 1, 10),
              end: DateTime.utc(2026, 1, 1, 10, 15),
              type: ActivityType.steps,
              source: DataSource.appleHealth,
              steps: 300,
              provenance: const HealthSampleProvenance(identity: identity),
            ),
          ]);
          final reconciled = await recovered.queryActivitySamples();
          expect(reconciled, hasLength(2));
          expect(
            reconciled.singleWhere((sample) => sample.provenance != null).steps,
            300,
          );
          await recovered.close();

          final inspected = await databaseFactoryFfi.openDatabase(path);
          expect(
            await inspected.getVersion(),
            SqfliteHealthRepository.schemaVersion,
          );
          await inspected.close();
        } finally {
          await databaseFactoryFfi.deleteDatabase(path);
          await directory.delete(recursive: true);
        }
      },
    );
  });
}
