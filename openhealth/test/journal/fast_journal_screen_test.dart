import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/journal/fast_journal_controller.dart';
import 'package:openglucose/src/journal/fast_journal_screen.dart';
import 'package:openglucose/src/journal/fast_journal_store.dart';
import 'package:openglucose/src/persistence/health_repository_lifecycle.dart';

void main() {
  testWidgets('quick add creates a local diary entry with safe rise wording', (
    tester,
  ) async {
    final repository = _SharedJournalRepository();
    final lifecycle = AppHealthRepositoryLifecycle(() async => repository);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FastJournalScreen(
            recentRise: (now) => RecentGlucoseRise(
              startedAt: now.subtract(const Duration(minutes: 30)),
              lastObservedAt: now.subtract(const Duration(minutes: 10)),
              highestMgdl: 115,
              linkWindowStart: now.subtract(const Duration(hours: 1)),
              linkWindowEnd: now.add(const Duration(hours: 1)),
            ),
            repositoryLifecycle: lifecycle,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Private local diary'), findsOneWidget);
    expect(find.text('No diary entries yet.'), findsOneWidget);
    expect(find.textContaining('does not identify causes'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('fastJournalQuickAdd')));
    await tester.pumpAndSettle();

    expect(find.text('Quick add'), findsWidgets);
    expect(find.text('Save meal'), findsOneWidget);
    expect(find.text('Link near the latest observed rise'), findsOneWidget);
    expect(
      find.text('This records timing only. It does not identify a cause.'),
      findsOneWidget,
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save meal'));
    await tester.pumpAndSettle();

    final entries = await repository.queryFastJournalEntries(limit: 20);
    expect(entries, hasLength(1));
    expect(entries.single.kind, FastJournalKind.meal);
    expect(entries.single.source, DataSource.manual);
    expect(entries.single.riseReference, isNotNull);
  });

  testWidgets(
    'leaving Diary after an Apple Health import keeps the shared repository open',
    (tester) async {
      final repository = _SharedJournalRepository();
      final lifecycle = AppHealthRepositoryLifecycle(() async => repository);
      final importedRepository = await lifecycle.acquire();
      await importedRepository.upsertActivitySamples(<ActivitySample>[
        ActivitySample(
          start: DateTime.utc(2026, 8, 24, 8),
          end: DateTime.utc(2026, 8, 24, 8, 30),
          type: ActivityType.workout,
          source: DataSource.appleHealth,
        ),
      ]);

      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: FastJournalScreen(repositoryLifecycle: lifecycle),
                    ),
                  ),
                ),
                child: const Text('Open diary'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open diary'));
      await tester.pumpAndSettle();
      expect(find.text('Private local diary'), findsOneWidget);

      // Popping the route must not close the shared Sqflite-compatible owner.
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(repository.closeCalls, 0);

      final afterDiary = await lifecycle.acquire();
      expect(await afterDiary.queryActivitySamples(), hasLength(1));

      await lifecycle.dispose();
      expect(repository.closeCalls, 1);
    },
  );
}

class _SharedJournalRepository extends InMemoryHealthRepository
    implements FastJournalStore {
  final Map<String, FastJournalEntry> _journal = <String, FastJournalEntry>{};
  final Set<int> _claimedRiseStarts = <int>{};
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
    await super.close();
  }

  @override
  Future<List<FastJournalEntry>> queryFastJournalEntries({
    TimeWindow window = TimeWindow.all,
    required int limit,
  }) async {
    final entries = _journal.values.toList()
      ..removeWhere((entry) => !window.contains(entry.occurredAt))
      ..sort((left, right) => right.occurredAt.compareTo(left.occurredAt));
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
  }) async {
    final riseStart = requestedRise?.startedAt.toUtc().microsecondsSinceEpoch;
    final persisted = riseStart != null && _claimedRiseStarts.add(riseStart)
        ? entry.copyWith(riseReference: requestedRise)
        : entry;
    _journal[persisted.id] = persisted;
    return persisted;
  }
}
