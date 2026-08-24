import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/journal/fast_journal_controller.dart';

void main() {
  final now = DateTime.utc(2026, 8, 24, 12);

  RecentGlucoseRise rise({
    DateTime? startedAt,
    DateTime? lastObservedAt,
    double highestMgdl = 115,
  }) => RecentGlucoseRise(
    startedAt: startedAt ?? now.subtract(const Duration(minutes: 30)),
    lastObservedAt: lastObservedAt ?? now.subtract(const Duration(minutes: 10)),
    highestMgdl: highestMgdl,
  );

  FastJournalController controller({
    required HealthRepository repository,
    RecentGlucoseRise? recentRise,
    List<String> ids = const <String>['journal-1'],
  }) {
    var nextId = 0;
    return FastJournalController(
      repository: repository,
      recentRise: (_) => recentRise,
      idFactory: () => ids[nextId++],
      clock: () => now,
    );
  }

  group('FastJournalController', () {
    test(
      'persists typed local entries and retains the chosen start time',
      () async {
        final repository = InMemoryHealthRepository();
        final journal = controller(
          repository: repository,
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

        final persisted = await repository.queryEvents();
        expect(persisted.map((event) => event.type), <HealthEventType>[
          HealthEventType.sleep,
          HealthEventType.meal,
          HealthEventType.exercise,
        ]);
        expect(
          persisted.first.timestamp,
          sleepAt,
          reason: 'The selected start time is not replaced with save time.',
        );
        final meal = persisted[1].payload! as MealPayload;
        expect(meal.description, 'Breakfast');
        final activity = persisted[2].payload! as ExercisePayload;
        expect(activity.activity, 'Walk');
        expect(activity.duration, const Duration(minutes: 25));
        final sleep = persisted.first.payload! as SleepPayload;
        expect(sleep.description, 'Early night');
        expect(sleep.duration, const Duration(hours: 7));
        expect(
          persisted.every((event) => event.source == DataSource.manual),
          isTrue,
        );

        expect(
          journal.entries.map((event) => event.id),
          <String>['activity', 'meal', 'sleep'],
          reason: 'The compact diary is newest first.',
        );
      },
    );

    test(
      'links only the injected newest rise and never falls back to an older one',
      () async {
        final repository = InMemoryHealthRepository();
        final latest = rise(
          startedAt: now.subtract(const Duration(minutes: 45)),
          lastObservedAt: now.subtract(const Duration(minutes: 25)),
          highestMgdl: 121,
        );
        final journal = controller(
          repository: repository,
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
      'keeps a rise unlinked when the person does not choose the option',
      () async {
        final repository = InMemoryHealthRepository();
        final journal = controller(repository: repository, recentRise: rise());

        await journal.load();
        final entry = await journal.save(
          FastJournalDraft(kind: FastJournalKind.sleep, startedAt: now),
        );

        expect(entry.riseReference, isNull);
        expect(journal.latestEligibleRise, isNotNull);
      },
    );

    test('does not offer a cue until analytics injects a candidate', () async {
      final journal = controller(repository: InMemoryHealthRepository());

      await journal.load();

      expect(journal.latestEligibleRise, isNull);
    });

    test('rejects only malformed injected candidates', () {
      final invalid = FastJournalController.selectLatestEligibleRise(
        newestQualifyingRise: rise(
          startedAt: now.subtract(const Duration(minutes: 5)),
          lastObservedAt: now.subtract(const Duration(minutes: 10)),
        ),
        referencedRises: const <GlucoseRiseReference>[],
      );
      expect(invalid, isNull);
    });
  });
}
