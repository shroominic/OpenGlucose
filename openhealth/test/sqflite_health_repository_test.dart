import 'dart:convert';
import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/context_bridge/context_attachment_fact.dart';
import 'package:openglucose/src/context_bridge/context_attachment_writer.dart';
import 'package:openglucose/src/journal/fast_journal_store.dart';
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

  ContextBridgeCandidateId candidateId([
    String token = '0123456789abcdef01234567',
  ]) => ContextBridgeCandidateId('ctx-candidate-$token');

  ContextBridgeEpisodeKey episodeKey([
    String token = 'fedcba9876543210fedcba98',
  ]) => ContextBridgeEpisodeKey('ctx-episode-$token');

  ContextAttachmentFact attachmentFact({
    String id = 'attachment-fact',
    required String journalEntryId,
    ContextBridgeCandidateId? candidate,
    ContextBridgeEpisodeKey? episode,
  }) => ContextAttachmentFact(
    id: id,
    journalEntryId: journalEntryId,
    candidateId: candidate ?? candidateId(),
    episodeKey: episode ?? episodeKey(),
    calculationVersion: 'recent-observed-rise-v1',
    episodeStart: DateTime.utc(2026, 1, 2, 20),
    peakAt: DateTime.utc(2026, 1, 2, 20, 15),
    attachmentWindowStart: DateTime.utc(2026, 1, 2, 19, 45),
    attachmentWindowEnd: DateTime.utc(2026, 1, 2, 20, 30),
    occurredAt: DateTime.utc(2026, 1, 2, 20, 10),
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

  group('fast journal', () {
    FastJournalEntry entry(String id, DateTime occurredAt) => FastJournalEntry(
      id: id,
      kind: FastJournalKind.sleep,
      occurredAt: occurredAt,
      label: 'Early night',
      duration: const Duration(hours: 7),
    );

    FastJournalRiseReference rise(DateTime startedAt) =>
        FastJournalRiseReference(
          startedAt: startedAt,
          lastObservedAt: startedAt.add(const Duration(minutes: 20)),
        );

    test('round-trips the isolated manual journal protocol', () async {
      final startedAt = DateTime.utc(2026, 1, 2, 20);
      final saved = await repo.saveFastJournalEntry(
        entry: entry('sleep-1', DateTime.utc(2026, 1, 2, 22)),
        requestedRise: rise(startedAt),
      );

      final loaded = await repo.queryFastJournalEntries(limit: 20);

      expect(saved.kind, FastJournalKind.sleep);
      expect(saved.source, DataSource.manual);
      expect(saved.riseReference?.startedAt, startedAt);
      expect(
        saved.riseReference?.lastObservedAt,
        DateTime.utc(2026, 1, 2, 20, 20),
      );
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'sleep-1');
      expect(loaded.single.duration, const Duration(hours: 7));
      expect(await repo.queryEvents(), isEmpty);
    });

    test('atomically gives concurrent saves one newest-rise claim', () async {
      final candidate = rise(DateTime.utc(2026, 1, 2, 20));

      final saved = await Future.wait(<Future<FastJournalEntry>>[
        repo.saveFastJournalEntry(
          entry: entry('first', DateTime.utc(2026, 1, 2, 21)),
          requestedRise: candidate,
        ),
        repo.saveFastJournalEntry(
          entry: entry('second', DateTime.utc(2026, 1, 2, 22)),
          requestedRise: candidate,
        ),
      ]);

      expect(
        saved.where((journalEntry) => journalEntry.riseReference != null),
        hasLength(1),
      );
      final loaded = await repo.queryFastJournalEntries(limit: 20);
      expect(
        loaded.where((journalEntry) => journalEntry.riseReference != null),
        hasLength(1),
      );
    });

    test('queries manual entries in an explicit bounded range', () async {
      await repo.saveFastJournalEntry(
        entry: entry('old', DateTime.utc(2026, 1, 1, 22)),
      );
      await repo.saveFastJournalEntry(
        entry: entry('in-range', DateTime.utc(2026, 1, 2, 22)),
      );

      final entries = await repo.queryFastJournalEntries(
        window: TimeWindow(
          start: DateTime.utc(2026, 1, 2),
          end: DateTime.utc(2026, 1, 3),
        ),
        limit: 20,
      );

      expect(entries.map((journalEntry) => journalEntry.id), <String>[
        'in-range',
      ]);
    });

    test(
      'a v0.1.4-style health-event reader ignores the isolated journal table',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'openglucose-fast-journal-',
        );
        final path = '${directory.path}${Platform.pathSeparator}health.db';
        final initial = SqfliteHealthRepository(
          path: path,
          databaseFactory: databaseFactoryFfi,
        );
        try {
          await initial.init();
          await initial.upsertEvent(
            meal('legacy-meal', DateTime.utc(2026, 1, 2, 8), carbs: 30),
          );
          await initial.saveFastJournalEntry(
            entry: entry('new-sleep', DateTime.utc(2026, 1, 2, 22)),
            requestedRise: rise(DateTime.utc(2026, 1, 2, 20)),
          );
          await initial.claimContextAttachmentFact(
            attachmentFact(
              journalEntryId: 'new-sleep',
              candidate: candidateId('111111111111111111111111'),
              episode: episodeKey('222222222222222222222222'),
            ),
          );
          await initial.close();

          // The released v0.1.4 repository opens this database as schema one.
          // sqflite lowers the version marker but leaves additive unknown
          // tables in place. Its event reader touches only health_events.
          final legacyDatabase = await databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(version: 1),
          );
          expect(await legacyDatabase.getVersion(), 1);
          final legacyRows = await legacyDatabase.query('health_events');
          final legacyEvents = legacyRows
              .map(
                (row) => HealthEvent.fromJson(
                  jsonDecode(row['data']! as String) as Map<String, Object?>,
                ),
              )
              .toList(growable: false);
          expect(legacyEvents.map((event) => event.id), <String>[
            'legacy-meal',
          ]);
          await legacyDatabase.close();

          final recovered = SqfliteHealthRepository(
            path: path,
            databaseFactory: databaseFactoryFfi,
          );
          await recovered.init();
          final journals = await recovered.queryFastJournalEntries(limit: 20);
          expect(journals.map((journalEntry) => journalEntry.id), <String>[
            'new-sleep',
          ]);
          final facts = await recovered.queryContextAttachmentFacts(
            window: TimeWindow(
              start: DateTime.utc(2026, 1, 2),
              end: DateTime.utc(2026, 1, 3),
            ),
          );
          expect(facts.map((fact) => fact.candidateId.value), <String>[
            'ctx-candidate-111111111111111111111111',
          ]);
          await recovered.close();
        } finally {
          await initial.close();
          await directory.delete(recursive: true);
        }
      },
    );
  });

  group('context attachment facts', () {
    test(
      'writes one linked diary entry and episode fact in one local transaction',
      () async {
        final entry = FastJournalEntry(
          id: 'transactional-note',
          kind: FastJournalKind.note,
          occurredAt: DateTime.utc(2026, 1, 2, 20, 10),
          label: 'Private detail',
        );
        final fact = attachmentFact(
          id: 'transactional-fact',
          journalEntryId: entry.id,
          candidate: candidateId('0123456789abcdef01234567'),
          episode: episodeKey('fedcba9876543210fedcba98'),
        );

        final saved = await repo.saveContextAttachment(
          entry: entry,
          fact: fact,
        );

        expect(saved.status, ContextAttachmentSaveStatus.saved);
        expect(saved.entry?.riseReference?.startedAt, fact.episodeStart);
        expect(
          (await repo.queryFastJournalEntries(limit: 20)).map(
            (journal) => journal.id,
          ),
          <String>[entry.id],
        );
        expect(
          (await repo.queryContextAttachmentFacts()).map((item) => item.id),
          <String>[fact.id],
        );

        final duplicateEntry = FastJournalEntry(
          id: 'second-note',
          kind: FastJournalKind.activity,
          occurredAt: DateTime.utc(2026, 1, 2, 20, 10),
        );
        final duplicate = attachmentFact(
          id: 'second-fact',
          journalEntryId: duplicateEntry.id,
          candidate: candidateId('111111111111111111111111'),
          episode: fact.episodeKey,
        );
        final alreadyClaimed = await repo.saveContextAttachment(
          entry: duplicateEntry,
          fact: duplicate,
        );

        expect(
          alreadyClaimed.status,
          ContextAttachmentSaveStatus.alreadyClaimed,
        );
        expect(
          (await repo.queryFastJournalEntries(limit: 20)).map(
            (journal) => journal.id,
          ),
          <String>[entry.id],
        );
      },
    );

    test(
      'rolls back the diary entry when a fact ID is an unrelated collision',
      () async {
        final firstEntry = FastJournalEntry(
          id: 'first-linked-entry',
          kind: FastJournalKind.meal,
          occurredAt: DateTime.utc(2026, 1, 2, 20, 10),
        );
        final firstFact = attachmentFact(
          id: 'shared-fact-id',
          journalEntryId: firstEntry.id,
          candidate: candidateId('222222222222222222222222'),
          episode: episodeKey('333333333333333333333333'),
        );
        await repo.saveContextAttachment(entry: firstEntry, fact: firstFact);

        final secondEntry = FastJournalEntry(
          id: 'must-rollback-entry',
          kind: FastJournalKind.note,
          occurredAt: DateTime.utc(2026, 1, 3, 20, 10),
        );
        final secondFact = ContextAttachmentFact(
          id: firstFact.id,
          journalEntryId: secondEntry.id,
          candidateId: candidateId('444444444444444444444444'),
          episodeKey: episodeKey('555555555555555555555555'),
          calculationVersion: 'recent-observed-rise-v1',
          episodeStart: DateTime.utc(2026, 1, 3, 20),
          peakAt: DateTime.utc(2026, 1, 3, 20, 15),
          attachmentWindowStart: DateTime.utc(2026, 1, 3, 19, 45),
          attachmentWindowEnd: DateTime.utc(2026, 1, 3, 20, 30),
          occurredAt: secondEntry.occurredAt,
        );

        await expectLater(
          repo.saveContextAttachment(entry: secondEntry, fact: secondFact),
          throwsStateError,
        );

        expect(
          (await repo.queryFastJournalEntries(limit: 20)).map(
            (journal) => journal.id,
          ),
          <String>[firstEntry.id],
        );
        expect(
          (await repo.queryContextAttachmentFacts()).map((fact) => fact.id),
          <String>[firstFact.id],
        );
      },
    );

    test(
      'round-trips bounded additive facts without changing health events',
      () async {
        await repo.saveFastJournalEntry(
          entry: FastJournalEntry(
            id: 'journal-linked',
            kind: FastJournalKind.meal,
            occurredAt: DateTime.utc(2026, 1, 2, 20, 10),
            label: 'Dinner',
          ),
        );
        final fact = attachmentFact(
          journalEntryId: 'journal-linked',
          candidate: candidateId('333333333333333333333333'),
          episode: episodeKey('444444444444444444444444'),
        );

        expect(await repo.claimContextAttachmentFact(fact), same(fact));

        final inRange = await repo.queryContextAttachmentFacts(
          window: TimeWindow(
            start: DateTime.utc(2026, 1, 2, 20),
            end: DateTime.utc(2026, 1, 2, 21),
          ),
          episodeKey: fact.episodeKey,
        );
        final outOfRange = await repo.queryContextAttachmentFacts(
          window: TimeWindow(end: DateTime.utc(2026, 1, 2, 20)),
        );

        expect(inRange, hasLength(1));
        expect(inRange.single.toJson(), fact.toJson());
        expect(outOfRange, isEmpty);
        expect(await repo.queryEvents(), isEmpty);
      },
    );

    test(
      'atomically claims one stable episode across concurrent peak revisions',
      () async {
        await repo.saveFastJournalEntry(
          entry: FastJournalEntry(
            id: 'journal-first',
            kind: FastJournalKind.meal,
            occurredAt: DateTime.utc(2026, 1, 2, 20, 10),
          ),
        );
        await repo.saveFastJournalEntry(
          entry: FastJournalEntry(
            id: 'journal-later',
            kind: FastJournalKind.activity,
            occurredAt: DateTime.utc(2026, 1, 2, 20, 11),
          ),
        );
        final sharedEpisode = episodeKey('555555555555555555555555');
        final firstPeak = attachmentFact(
          id: 'fact-first',
          journalEntryId: 'journal-first',
          candidate: candidateId('666666666666666666666666'),
          episode: sharedEpisode,
        );
        final laterPeak = attachmentFact(
          id: 'fact-later',
          journalEntryId: 'journal-later',
          candidate: candidateId('777777777777777777777777'),
          episode: sharedEpisode,
        );

        final claims = await Future.wait<ContextAttachmentFact?>(
          <Future<ContextAttachmentFact?>>[
            repo.claimContextAttachmentFact(firstPeak),
            repo.claimContextAttachmentFact(laterPeak),
          ],
        );

        expect(firstPeak.candidateId.value, isNot(laterPeak.candidateId.value));
        expect(claims.whereType<ContextAttachmentFact>(), hasLength(1));
        final persisted = await repo.queryContextAttachmentFacts(
          episodeKey: sharedEpisode,
        );
        expect(persisted, hasLength(1));
        expect(persisted.single.episodeKey.value, sharedEpisode.value);
      },
    );

    test('fails an unrelated duplicate attachment fact ID collision', () async {
      await repo.saveFastJournalEntry(
        entry: FastJournalEntry(
          id: 'journal-original',
          kind: FastJournalKind.meal,
          occurredAt: DateTime.utc(2026, 1, 2, 20, 10),
        ),
      );
      await repo.saveFastJournalEntry(
        entry: FastJournalEntry(
          id: 'journal-unrelated',
          kind: FastJournalKind.activity,
          occurredAt: DateTime.utc(2026, 1, 2, 20, 11),
        ),
      );
      final claimed = attachmentFact(
        id: 'shared-fact-id',
        journalEntryId: 'journal-original',
        candidate: candidateId('888888888888888888888888'),
        episode: episodeKey('999999999999999999999999'),
      );
      final collision = attachmentFact(
        id: 'shared-fact-id',
        journalEntryId: 'journal-unrelated',
        candidate: candidateId('aaaaaaaaaaaaaaaaaaaaaaaa'),
        episode: episodeKey('bbbbbbbbbbbbbbbbbbbbbbbb'),
      );

      expect(await repo.claimContextAttachmentFact(claimed), same(claimed));
      await expectLater(
        repo.claimContextAttachmentFact(collision),
        throwsStateError,
      );

      final facts = await repo.queryContextAttachmentFacts();
      expect(facts, hasLength(1));
      expect(facts.single.toJson(), claimed.toJson());
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
    await repo.saveFastJournalEntry(
      entry: FastJournalEntry(
        id: 'clear-journal',
        kind: FastJournalKind.meal,
        occurredAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await repo.claimContextAttachmentFact(
      attachmentFact(
        id: 'clear-fact',
        journalEntryId: 'clear-journal',
      ),
    );
    await repo.clear();
    expect(await repo.queryEvents(), isEmpty);
    expect(await repo.queryHeartRateSamples(), isEmpty);
    expect(await repo.queryImportTombstones(), isEmpty);
    expect(await repo.queryInsights(), isEmpty);
    expect(await repo.queryFastJournalEntries(limit: 20), isEmpty);
    expect(await repo.queryContextAttachmentFacts(), isEmpty);
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
      'upgrades schema-four facts without fabricating episode scope',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'openglucose-context-schema-four-',
        );
        final path = '${directory.path}${Platform.pathSeparator}health.db';
        try {
          final schemaFour = await databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(
              version: 4,
              onCreate: (db, version) async {
                await db.execute('''
                  CREATE TABLE fast_journal_entries (
                    id TEXT PRIMARY KEY,
                    occurred_at_ms INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    rise_started_at_us INTEGER,
                    data TEXT NOT NULL
                  )
                ''');
                await db.execute('''
                  CREATE TABLE context_attachment_facts (
                    id TEXT PRIMARY KEY,
                    journal_entry_id TEXT NOT NULL,
                    occurred_at_ms INTEGER NOT NULL,
                    candidate_id TEXT NOT NULL,
                    calculation_version TEXT NOT NULL,
                    data TEXT NOT NULL,
                    FOREIGN KEY (journal_entry_id)
                      REFERENCES fast_journal_entries(id) ON DELETE CASCADE
                  )
                ''');
                await db.execute(
                  'CREATE UNIQUE INDEX idx_context_attachment_candidate '
                  'ON context_attachment_facts(candidate_id, '
                  'calculation_version)',
                );
              },
            ),
          );
          final journal = FastJournalEntry(
            id: 'legacy-journal',
            kind: FastJournalKind.meal,
            occurredAt: DateTime.utc(2026, 1, 2, 20, 10),
          );
          await schemaFour.insert('fast_journal_entries', <String, Object?>{
            'id': journal.id,
            'occurred_at_ms': journal.occurredAt.millisecondsSinceEpoch,
            'kind': journal.kind.name,
            'rise_started_at_us': null,
            'data': jsonEncode(journal.toJson()),
          });
          final legacyFact = <String, Object?>{
            'formatVersion': 1,
            'id': 'legacy-fact',
            'journalEntryId': 'legacy-journal',
            'candidateId': 'ctx-suggestion-schema-four',
            'calculationVersion': 'recent-observed-rise-v1',
            'episodeStart': '2026-01-02T20:00:00.000Z',
            'peakAt': '2026-01-02T20:15:00.000Z',
            'attachmentWindowStart': '2026-01-02T19:45:00.000Z',
            'attachmentWindowEnd': '2026-01-02T20:30:00.000Z',
            'occurredAt': '2026-01-02T20:10:00.000Z',
          };
          await schemaFour.insert('context_attachment_facts', <String, Object?>{
            'id': 'legacy-fact',
            'journal_entry_id': 'legacy-journal',
            'occurred_at_ms': DateTime.utc(
              2026,
              1,
              2,
              20,
              10,
            ).millisecondsSinceEpoch,
            'candidate_id': 'ctx-suggestion-schema-four',
            'calculation_version': 'recent-observed-rise-v1',
            'data': jsonEncode(legacyFact),
          });
          await schemaFour.close();

          final upgraded = SqfliteHealthRepository(
            path: path,
            databaseFactory: databaseFactoryFfi,
          );
          await upgraded.init();
          final facts = await upgraded.queryContextAttachmentFacts();
          expect(facts, hasLength(1));
          expect(facts.single.isStableEpisodeClaim, isFalse);
          expect(facts.single.candidateId.value, 'ctx-suggestion-schema-four');
          await expectLater(
            upgraded.claimContextAttachmentFact(facts.single),
            throwsArgumentError,
          );

          final inspected = await databaseFactoryFfi.openDatabase(path);
          final columns = await inspected.rawQuery(
            'PRAGMA table_info(context_attachment_facts)',
          );
          expect(
            columns.map((column) => column['name']),
            contains('episode_key'),
          );
          await inspected.close();
          await upgraded.close();
        } finally {
          await databaseFactoryFfi.deleteDatabase(path);
          await directory.delete(recursive: true);
        }
      },
    );

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
