import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/journal/fast_journal_controller.dart';
import 'package:openglucose/src/journal/fast_journal_store.dart';

void main() {
  final now = DateTime.utc(2026, 8, 24, 12);

  RecentGlucoseRise rise({
    DateTime? startedAt,
    DateTime? lastObservedAt,
    DateTime? linkWindowStart,
    DateTime? linkWindowEnd,
    double highestMgdl = 115,
  }) => RecentGlucoseRise(
    startedAt: startedAt ?? now.subtract(const Duration(minutes: 30)),
    lastObservedAt: lastObservedAt ?? now.subtract(const Duration(minutes: 10)),
    highestMgdl: highestMgdl,
    linkWindowStart: linkWindowStart ?? now.subtract(const Duration(hours: 1)),
    linkWindowEnd: linkWindowEnd ?? now.add(const Duration(hours: 1)),
  );

  FastJournalController controller({
    required FastJournalStore store,
    RecentGlucoseRise? recentRise,
    List<String> ids = const <String>['journal-1'],
  }) {
    var nextId = 0;
    return FastJournalController(
      store: store,
      recentRise: (_) => recentRise,
      idFactory: () => ids[nextId++],
      clock: () => now,
    );
  }

  group('FastJournalController', () {
    test(
      'persists typed local entries with their selected time and manual source',
      () async {
        final store = _InMemoryFastJournalStore();
        final journal = controller(
          store: store,
          ids: const <String>['meal', 'activity', 'sleep'],
        );
        final mealAt = DateTime.utc(2026, 8, 24, 7, 15);
        final activityAt = DateTime.utc(2026, 8, 24, 8);
        final sleepAt = DateTime.utc(2026, 8, 23, 22, 30);

        await journal.load();
        await journal.save(
          FastJournalDraft(
            kind: FastJournalKind.meal,
            startedAt: mealAt,
            label: 'Breakfast',
          ),
        );
        await journal.save(
          FastJournalDraft(
            kind: FastJournalKind.activity,
            startedAt: activityAt,
            label: 'Walk',
            duration: const Duration(minutes: 25),
          ),
        );
        await journal.save(
          FastJournalDraft(
            kind: FastJournalKind.sleep,
            startedAt: sleepAt,
            label: 'Early night',
            duration: const Duration(hours: 7),
          ),
        );

        final persisted = await store.queryFastJournalEntries(limit: 20);
        expect(persisted.map((entry) => entry.kind), <FastJournalKind>[
          FastJournalKind.activity,
          FastJournalKind.meal,
          FastJournalKind.sleep,
        ]);
        expect(
          persisted.last.occurredAt,
          sleepAt,
          reason: 'The selected time is not replaced with save time.',
        );
        expect(persisted.first.label, 'Walk');
        expect(persisted.first.duration, const Duration(minutes: 25));
        expect(persisted.last.label, 'Early night');
        expect(persisted.last.duration, const Duration(hours: 7));
        expect(
          persisted.every((entry) => entry.source == DataSource.manual),
          isTrue,
        );

        expect(journal.entries.map((entry) => entry.id), <String>[
          'activity',
          'meal',
          'sleep',
        ]);
      },
    );

    test(
      'links only the injected newest rise and never falls back to an older one',
      () async {
        final store = _InMemoryFastJournalStore();
        final latest = rise(
          startedAt: now.subtract(const Duration(minutes: 45)),
          lastObservedAt: now.subtract(const Duration(minutes: 25)),
          highestMgdl: 121,
        );
        final journal = controller(
          store: store,
          recentRise: latest,
          ids: const <String>['near-rise', 'second-entry'],
        );

        await journal.load();
        expect(journal.latestEligibleRise?.startedAt, latest.startedAt);
        expect(journal.latestEligibleRise?.highestMgdl, 121);

        final attached = await journal.save(
          FastJournalDraft(
            kind: FastJournalKind.meal,
            startedAt: now.subtract(const Duration(minutes: 15)),
          ),
          attachToLatestRise: true,
        );
        expect(attached.riseReference?.startedAt, latest.startedAt);
        expect(journal.latestEligibleRise, isNull);

        final laterEntry = await journal.save(
          FastJournalDraft(kind: FastJournalKind.activity, startedAt: now),
          attachToLatestRise: true,
        );
        expect(laterEntry.riseReference, isNull);
      },
    );

    test(
      'does not restore a cue when its durable claim is older than the list',
      () async {
        final store = _InMemoryFastJournalStore();
        final latest = rise();
        await store.saveFastJournalEntry(
          entry: FastJournalEntry(
            id: 'old-linked-entry',
            kind: FastJournalKind.meal,
            occurredAt: now.subtract(const Duration(days: 3)),
          ),
          requestedRise: latest.reference,
        );
        for (
          var index = 0;
          index < FastJournalController.maxDiaryEntries;
          index++
        ) {
          await store.saveFastJournalEntry(
            entry: FastJournalEntry(
              id: 'newer-entry-$index',
              kind: FastJournalKind.activity,
              occurredAt: now.add(Duration(minutes: index)),
            ),
          );
        }
        final journal = controller(store: store, recentRise: latest);

        await journal.load();

        expect(
          journal.entries,
          hasLength(FastJournalController.maxDiaryEntries),
        );
        expect(journal.latestEligibleRise, isNull);
      },
    );

    test(
      'does not link a historical or future selected time outside its window',
      () async {
        final store = _InMemoryFastJournalStore();
        final latest = rise(
          linkWindowStart: now.subtract(const Duration(minutes: 20)),
          linkWindowEnd: now.add(const Duration(minutes: 20)),
        );
        final journal = controller(
          store: store,
          recentRise: latest,
          ids: const <String>['past', 'future'],
        );

        await journal.load();
        expect(
          journal.latestEligibleRiseFor(
            now.subtract(const Duration(hours: 2)),
          ),
          isNull,
        );
        expect(
          journal.latestEligibleRiseFor(now.add(const Duration(hours: 2))),
          isNull,
        );

        final past = await journal.save(
          FastJournalDraft(
            kind: FastJournalKind.meal,
            startedAt: now.subtract(const Duration(hours: 2)),
          ),
          attachToLatestRise: true,
        );
        final future = await journal.save(
          FastJournalDraft(
            kind: FastJournalKind.activity,
            startedAt: now.add(const Duration(hours: 2)),
          ),
          attachToLatestRise: true,
        );

        expect(past.riseReference, isNull);
        expect(future.riseReference, isNull);
      },
    );

    test('uses an inclusive start and exclusive end link window', () async {
      final latest = rise(
        linkWindowStart: now,
        linkWindowEnd: now.add(const Duration(minutes: 30)),
      );
      final journal = controller(
        store: _InMemoryFastJournalStore(),
        recentRise: latest,
      );

      await journal.load();

      expect(journal.latestEligibleRiseFor(now), isNotNull);
      expect(
        journal.latestEligibleRiseFor(now.add(const Duration(minutes: 30))),
        isNull,
      );
    });

    test(
      'serializes concurrent saves so the newest rise is claimed only once',
      () async {
        final store = _InMemoryFastJournalStore();
        final latest = rise();
        final first = controller(
          store: store,
          recentRise: latest,
          ids: const <String>['first'],
        );
        final second = controller(
          store: store,
          recentRise: latest,
          ids: const <String>['second'],
        );

        await Future.wait(<Future<void>>[first.load(), second.load()]);
        final saved = await Future.wait(<Future<FastJournalEntry>>[
          first.save(
            FastJournalDraft(kind: FastJournalKind.meal, startedAt: now),
            attachToLatestRise: true,
          ),
          second.save(
            FastJournalDraft(kind: FastJournalKind.activity, startedAt: now),
            attachToLatestRise: true,
          ),
        ]);

        expect(saved, hasLength(2));
        expect(
          saved.where((entry) => entry.riseReference != null),
          hasLength(1),
        );
        expect(await store.queryFastJournalEntries(limit: 20), hasLength(2));
      },
    );

    test(
      'keeps a rise unlinked when the person does not choose the option',
      () async {
        final journal = controller(
          store: _InMemoryFastJournalStore(),
          recentRise: rise(),
        );

        await journal.load();
        final entry = await journal.save(
          FastJournalDraft(kind: FastJournalKind.sleep, startedAt: now),
        );

        expect(entry.riseReference, isNull);
        expect(journal.latestEligibleRise, isNotNull);
      },
    );

    test('does not offer a cue until analytics injects a candidate', () async {
      final journal = controller(store: _InMemoryFastJournalStore());

      await journal.load();

      expect(journal.latestEligibleRise, isNull);
    });

    test('rejects only malformed injected candidates', () {
      final invalid = FastJournalController.selectLatestEligibleRise(
        newestQualifyingRise: rise(
          startedAt: now.subtract(const Duration(minutes: 5)),
          lastObservedAt: now.subtract(const Duration(minutes: 10)),
        ),
        referencedRises: const <FastJournalRiseReference>[],
      );
      expect(invalid, isNull);
    });
  });
}

class _InMemoryFastJournalStore implements FastJournalStore {
  final Map<String, FastJournalEntry> _entries = <String, FastJournalEntry>{};
  final Set<int> _claimedRiseStarts = <int>{};
  Future<void> _tail = Future<void>.value();

  @override
  Future<List<FastJournalEntry>> queryFastJournalEntries({
    required int limit,
  }) async {
    final entries = _entries.values.toList(growable: false)
      ..sort((left, right) {
        final byTime = right.occurredAt.compareTo(left.occurredAt);
        return byTime != 0 ? byTime : right.id.compareTo(left.id);
      });
    return entries.take(limit).toList(growable: false);
  }

  @override
  Future<bool> isFastJournalRiseClaimed({
    required DateTime riseStartedAt,
  }) async => _claimedRiseStarts.contains(
    riseStartedAt.toUtc().microsecondsSinceEpoch,
  );

  @override
  Future<FastJournalEntry> saveFastJournalEntry({
    required FastJournalEntry entry,
    FastJournalRiseReference? requestedRise,
  }) {
    final scheduled = _tail.then((_) {
      final key = requestedRise?.startedAt.toUtc().microsecondsSinceEpoch;
      final attached = key != null && _claimedRiseStarts.add(key)
          ? entry.copyWith(riseReference: requestedRise)
          : entry;
      _entries[attached.id] = attached;
      return attached;
    });
    _tail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return scheduled;
  }
}
