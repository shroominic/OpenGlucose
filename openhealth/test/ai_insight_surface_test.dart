import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/ai/ai_insight_surface.dart';

void main() {
  final windowStart = DateTime.utc(2026, 8, 14);
  final windowEnd = DateTime.utc(2026, 8, 15);

  MetabolicObservation observation() => MetabolicObservation(
    id: 'glucose-level',
    kind: ObservationKind.glucoseLevel,
    title: 'Typical glucose level',
    summary: 'Average glucose was 110 mg/dL across 24 readings.',
    windowStart: windowStart,
    windowEnd: windowEnd,
    evidence: <ObservationEvidence>[
      ObservationEvidence(
        id: 'average',
        kind: EvidenceKind.glucose,
        label: 'Average glucose',
        value: 110,
        unit: 'mg/dL',
        sampleCount: 24,
        windowStart: windowStart,
        windowEnd: windowEnd,
        source: 'cgm',
      ),
    ],
  );

  AiInsight insight({String body = 'Your mornings look steadier.'}) =>
      AiInsight(
        id: 'insight-1',
        createdAt: windowEnd,
        category: AiInsightCategory.summary,
        title: 'A small pattern to explore',
        body: body,
        windowStart: windowStart,
        windowEnd: windowEnd,
        evidence: observation().evidence,
      );

  test(
    'starts disabled by default and never calls a missing generator',
    () async {
      var calls = 0;
      final controller = AiInsightSurfaceController(
        generate: () async {
          calls++;
          return insight();
        },
      );

      expect(controller.state.status, AiInsightSurfaceStatus.disabled);
      await controller.generate();

      expect(calls, 0);
      expect(controller.state.status, AiInsightSurfaceStatus.disabled);
    },
  );

  test(
    'exposes loading and ready states while consuming local observations',
    () async {
      final completer = Completer<AiInsight?>();
      final controller = AiInsightSurfaceController(
        enabled: true,
        observations: <MetabolicObservation>[observation()],
        generate: () => completer.future,
      );

      final generation = controller.generate();
      expect(controller.state.status, AiInsightSurfaceStatus.loading);
      completer.complete(insight());
      await generation;

      expect(controller.state.status, AiInsightSurfaceStatus.ready);
      expect(
        controller.state.observations.single.title,
        'Typical glucose level',
      );
      expect(controller.state.insight?.title, 'A small pattern to explore');
    },
  );

  test('converts generation failures into a retryable error state', () async {
    final controller = AiInsightSurfaceController(
      enabled: true,
      generate: () async =>
          throw const AiGenerationException('provider unavailable'),
    );

    await controller.generate();

    expect(controller.state.status, AiInsightSurfaceStatus.error);
    expect(controller.state.errorMessage, 'provider unavailable');
  });

  testWidgets('renders privacy-safe body, evidence, and wellness boundary', (
    tester,
  ) async {
    final controller = AiInsightSurfaceController(
      enabled: true,
      observations: <MetabolicObservation>[observation()],
      insight: insight(
        body:
            'Try comparing your mornings.\nNote: my private journal says hello.\n'
            'Key sk-test_123456789 should never be shown.',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AiInsightSurface(controller: controller)),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('aiInsightSurface')),
      findsOneWidget,
    );
    expect(find.text('A small pattern to explore'), findsOneWidget);
    expect(find.textContaining('private journal says hello'), findsNothing);
    expect(find.textContaining('sk-test_123456789'), findsNothing);
    expect(find.textContaining('Average glucose'), findsOneWidget);
    expect(find.textContaining('Wellness only'), findsOneWidget);
  });

  testWidgets('shows a disabled explanation and opt-in action', (tester) async {
    final controller = AiInsightSurfaceController();
    var enabled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiInsightSurface(
            controller: controller,
            onEnable: () {
              enabled = true;
              controller.enabled = true;
            },
          ),
        ),
      ),
    );

    expect(find.text('AI insights are off'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('aiInsightEnableButton')),
    );
    expect(enabled, isTrue);
    await tester.pump();
    expect(find.text('AI insights need a little more data'), findsOneWidget);
  });
}
