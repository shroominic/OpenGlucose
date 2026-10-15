import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/evidence_observation_card.dart';

void main() {
  final start = DateTime.utc(2026, 8, 15);
  final end = start.add(const Duration(hours: 24));

  MetabolicObservation observation({
    required String id,
    required ObservationKind kind,
    required String title,
    required String summary,
    required double value,
    required String unit,
  }) {
    return MetabolicObservation(
      id: id,
      kind: kind,
      title: title,
      summary: summary,
      windowStart: start,
      windowEnd: end,
      evidence: <ObservationEvidence>[
        ObservationEvidence(
          id: '$id-evidence',
          kind: EvidenceKind.glucose,
          label: title,
          value: value,
          unit: unit,
          sampleCount: 144,
          windowStart: start,
          windowEnd: end,
        ),
      ],
    );
  }

  testWidgets('renders observations, evidence, and safety boundary', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EvidenceObservationCard(
            observations: <MetabolicObservation>[
              observation(
                id: 'average',
                kind: ObservationKind.glucoseLevel,
                title: 'Typical glucose level',
                summary: 'Average glucose was 112 mg/dL.',
                value: 112,
                unit: 'mg/dL',
              ),
              observation(
                id: 'range',
                kind: ObservationKind.glucoseRange,
                title: 'Glucose range distribution',
                summary: 'Most readings were in range.',
                value: 92.5,
                unit: '%',
              ),
            ],
            safetyBoundary: 'Local wellness observations only.',
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('evidenceObservationCard')),
      findsOneWidget,
    );
    expect(find.text('What your data shows'), findsOneWidget);
    expect(find.text('Typical glucose level'), findsOneWidget);
    expect(find.text('112 mg/dL · 144 samples'), findsOneWidget);
    expect(find.text('Local wellness observations only.'), findsOneWidget);
  });

  testWidgets('hides card when no evidence-backed observations exist', (
    tester,
  ) async {
    final observation = MetabolicObservation(
      id: 'empty',
      kind: ObservationKind.coverage,
      title: 'Not renderable',
      summary: 'Missing evidence',
      windowStart: start,
      windowEnd: end,
      evidence: const <ObservationEvidence>[],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EvidenceObservationCard(
            observations: <MetabolicObservation>[observation],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('evidenceObservationCard')),
      findsNothing,
    );
  });
}
