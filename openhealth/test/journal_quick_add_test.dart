import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/journal_quick_add.dart';

void main() {
  testWidgets('meal quick-add saves through the injected local service', (
    tester,
  ) async {
    final repository = InMemoryHealthRepository();
    var factoryCalls = 0;
    final at = DateTime.utc(2026, 8, 15, 12);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JournalQuickAddSheet(
            now: () => at,
            serviceFactory: () async {
              factoryCalls += 1;
              return JournalService(repository: repository);
            },
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('journalMealDescriptionField')),
      'Breakfast',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('journalMealCarbsField')),
      '42',
    );
    await tester.tap(find.byKey(const ValueKey<String>('journalSaveButton')));
    await tester.pumpAndSettle();

    expect(factoryCalls, 1);
    final event = (await repository.queryEvents()).single;
    expect(event.type, HealthEventType.meal);
    expect(event.timestamp, at);
    expect((event.payload! as MealPayload).description, 'Breakfast');
    expect((event.payload! as MealPayload).carbsGrams, 42);
    expect(find.text('Saved locally'), findsOneWidget);
  });

  testWidgets('empty note is rejected before the service is opened', (
    tester,
  ) async {
    var factoryCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JournalQuickAddSheet(
            serviceFactory: () async {
              factoryCalls += 1;
              return JournalService(repository: InMemoryHealthRepository());
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('journalNoteChip')));
    await tester.tap(find.byKey(const ValueKey<String>('journalSaveButton')));
    await tester.pump();

    expect(factoryCalls, 0);
    expect(find.text('Add a note before saving.'), findsOneWidget);
  });

  test('controller exposes a local today summary after saving', () async {
    final repository = InMemoryHealthRepository();
    final at = DateTime.utc(2026, 8, 15, 12);
    final controller = JournalQuickAddController(
      now: () => at,
      serviceFactory: () async => JournalService(repository: repository),
    );

    final saved = await controller.saveNote(text: 'Felt steady');

    expect(saved, isNotNull);
    expect(controller.todayEventCount, 1);
    expect(controller.todayContext?.events, hasLength(1));
    expect(controller.todayContext?.events.single.type, HealthEventType.note);
    expect(controller.latestSummary, 'Note: Felt steady');
    expect(controller.summaryText, '1 journal entry today');
    controller.dispose();
  });
}
