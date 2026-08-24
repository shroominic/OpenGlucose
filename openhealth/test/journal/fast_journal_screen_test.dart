import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/journal/fast_journal_controller.dart';
import 'package:openglucose/src/journal/fast_journal_screen.dart';

void main() {
  testWidgets('quick add creates a local diary entry with safe rise wording', (
    tester,
  ) async {
    final repository = InMemoryHealthRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FastJournalScreen(
            recentRise: (now) => RecentGlucoseRise(
              startedAt: now.subtract(const Duration(minutes: 30)),
              lastObservedAt: now.subtract(const Duration(minutes: 10)),
              highestMgdl: 115,
            ),
            repositoryOpener: () async => repository,
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

    final entries = await repository.queryEvents();
    expect(entries, hasLength(1));
    expect(entries.single.type, HealthEventType.meal);
    expect(entries.single.source, DataSource.manual);
    expect(entries.single.riseReference, isNotNull);
    expect(find.text('Meal'), findsOneWidget);
  });
}
