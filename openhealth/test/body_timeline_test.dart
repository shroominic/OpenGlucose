import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/body_timeline.dart';
import 'package:openglucose/src/body_timeline_context.dart';
import 'package:openglucose/src/display_preferences.dart';

void main() {
  final now = DateTime.utc(2026, 8, 15, 12);

  CgmReading reading(double value, int minutesAgo) => CgmReading(
    valueMgdl: value,
    source: CgmRecordSource.standard,
    recordedAt: now.subtract(Duration(minutes: minutesAgo)),
  );

  test('builds a newest-first mixed timeline with source labels', () {
    final context = JournalContext(
      window: TimeWindow.all,
      events: <HealthEvent>[
        HealthEvent(
          id: 'meal-1',
          timestamp: now.subtract(const Duration(minutes: 20)),
          type: HealthEventType.meal,
          payload: const MealPayload(description: 'Breakfast'),
        ),
      ],
      activitySamples: <ActivitySample>[
        ActivitySample(
          start: now.subtract(const Duration(minutes: 40)),
          end: now.subtract(const Duration(minutes: 25)),
          type: ActivityType.steps,
          source: DataSource.appleHealth,
          steps: 1200,
        ),
      ],
      sleepSamples: const <SleepSample>[],
      heartRateSamples: <HeartRateSample>[
        HeartRateSample(
          timestamp: now.subtract(const Duration(minutes: 10)),
          bpm: 72,
          source: DataSource.healthConnect,
        ),
      ],
    );
    final observation = MetabolicObservation(
      id: 'obs-1',
      kind: ObservationKind.activityContext,
      title: 'Activity context',
      summary: 'A local observation with bounded evidence.',
      windowStart: now.subtract(const Duration(hours: 1)),
      windowEnd: now.subtract(const Duration(minutes: 5)),
      evidence: <ObservationEvidence>[
        ObservationEvidence(
          id: 'evidence-1',
          kind: EvidenceKind.activity,
          label: 'Steps',
          windowStart: now.subtract(const Duration(hours: 1)),
          windowEnd: now,
          sampleCount: 1,
          value: 1200,
          unit: 'steps',
        ),
      ],
    );

    final items = BodyTimeline.buildItems(
      readings: <CgmReading>[reading(110, 30)],
      context: context,
      observations: <MetabolicObservation>[observation],
      now: now,
    );

    expect(items, hasLength(5));
    expect(items.first.kind, BodyTimelineItemKind.observation);
    expect(items.first.title, 'Activity context');
    expect(items[1].kind, BodyTimelineItemKind.heartRate);
    expect(items[2].kind, BodyTimelineItemKind.event);
    expect(items[3].kind, BodyTimelineItemKind.glucose);
    expect(items.last.kind, BodyTimelineItemKind.activity);
    expect(items[1].sourceLabel, 'Health Connect');
    expect(items.last.sourceLabel, 'Apple Health');
    expect(items[3].freshnessLabel, '30 min ago');
  });

  testWidgets('renders mixed rows and evidence without clinical claims', (
    tester,
  ) async {
    final context = JournalContext(
      window: TimeWindow.all,
      events: <HealthEvent>[
        HealthEvent(
          id: 'note-1',
          timestamp: now.subtract(const Duration(minutes: 2)),
          type: HealthEventType.note,
          payload: const NotePayload(text: 'Felt steady'),
        ),
      ],
      activitySamples: const <ActivitySample>[],
      sleepSamples: const <SleepSample>[],
      heartRateSamples: const <HeartRateSample>[],
    );
    final observation = MetabolicObservation(
      id: 'obs-1',
      kind: ObservationKind.coverage,
      title: 'Coverage',
      summary: 'A bounded local summary.',
      windowStart: now.subtract(const Duration(hours: 1)),
      windowEnd: now,
      evidence: <ObservationEvidence>[
        ObservationEvidence(
          id: 'evidence-1',
          kind: EvidenceKind.coverage,
          label: 'Readings',
          windowStart: now.subtract(const Duration(hours: 1)),
          windowEnd: now,
          sampleCount: 1,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BodyTimelineCard(
            readings: <CgmReading>[reading(112, 5)],
            context: context,
            observations: <MetabolicObservation>[observation],
            now: now,
            preferences: const DisplayPreferences(),
          ),
        ),
      ),
    );

    expect(find.text('Body timeline'), findsOneWidget);
    expect(find.text('Felt steady'), findsOneWidget);
    expect(find.text('112 mg/dL'), findsOneWidget);
    expect(find.text('Coverage'), findsOneWidget);
    expect(
      find.text('Local wellness context—not medical advice.'),
      findsOneWidget,
    );
    expect(find.textContaining('diagnos'), findsNothing);
  });

  testWidgets('shows local context loading and error states', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BodyTimelineCard(
            readings: const <CgmReading>[],
            contextStatus: BodyTimelineContextStatus.loading,
          ),
        ),
      ),
    );
    expect(find.text('Loading local context…'), findsOneWidget);
    expect(find.textContaining('No body context yet.'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BodyTimelineCard(
            readings: const <CgmReading>[],
            contextStatus: BodyTimelineContextStatus.error,
            contextError: 'Could not load local body context. Try again.',
          ),
        ),
      ),
    );
    expect(
      find.text('Could not load local body context. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('No body context yet.'), findsNothing);
  });
}
