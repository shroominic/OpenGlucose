import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/context_timeline/compact_context_timeline.dart';
import 'package:openglucose/src/context_timeline/context_timeline_models.dart';

import 'context_timeline_fixture.dart';

void main() {
  testWidgets(
    'context is collapsed by default and expands as a non-persistent preview',
    (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final drafts = <ContextAttachmentDraft>[];
      await tester.pumpWidget(
        _host(
          source: FixedContextTimelineSource(richContextFixture()).call,
          onAttachmentRequested: drafts.add,
        ),
      );

      expect(find.text('Show context'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('contextTimelinePlot')),
        findsNothing,
      );
      expect(find.text('Optional context'), findsNothing);

      await tester.tap(find.text('Show context'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('contextTimelinePlot')),
        findsOneWidget,
      );
      expect(find.text('SAMPLE DATA — NOT FROM A SENSOR'), findsOneWidget);
      expect(find.text('Optional context'), findsOneWidget);
      expect(
        find.text(
          'You can prepare a context draft for reflection. This preview does not assess glucose patterns or identify a cause.',
        ),
        findsOneWidget,
      );
      expect(find.text('Lunch'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('heartRateSummary')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('contextRange-threeHours')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey<String>('contextRange-threeHours')),
            )
            .selected,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey<String>('contextItem-event:exercise-1')),
        findsNothing,
      );

      final mealItem = find.byKey(
        const ValueKey<String>('contextItem-event:meal-1'),
      );
      await tester.ensureVisible(mealItem);
      await tester.tap(mealItem);
      await tester.pumpAndSettle();
      expect(find.text('Source: Manual entry'), findsOneWidget);
      expect(find.textContaining('Exact window:'), findsOneWidget);
      expect(find.text('Qualification: Available'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('requestContextAttachment')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Create an unsaved context draft'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('attachmentDraft-meal')),
      );
      await tester.pumpAndSettle();
      expect(drafts, hasLength(1));
      expect(drafts.single.kind, ContextAttachmentKind.meal);
      expect(drafts.single.prompt.id, 'gap-newest');
    },
  );

  testWidgets('no accessible data stays explicit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        source: const FixedContextTimelineSource(
          ContextTimelineSnapshot(),
        ).call,
      ),
    );

    await tester.tap(find.text('Show context'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('contextAvailabilitySummary')),
      findsOneWidget,
    );
    expect(find.textContaining('No accessible data'), findsWidgets);
    expect(find.textContaining('0 glucose readings'), findsNothing);
  });

  testWidgets(
    'generic attachment prompts make no glucose claim with no glucose data or stale context',
    (tester) async {
      final prompt = ContextAttachmentPrompt(
        id: 'unqualified-prompt',
        start: contextFixtureNow.subtract(const Duration(minutes: 30)),
        end: contextFixtureNow.subtract(const Duration(minutes: 10)),
      );
      await tester.pumpWidget(
        _host(
          source: FixedContextTimelineSource(
            ContextTimelineSnapshot(
              attachmentPrompt: prompt,
              laneStatuses: const <ContextTimelineLaneStatus>[
                ContextTimelineLaneStatus(
                  lane: ContextTimelineLane.mealsAndNotes,
                  availability: ContextDataAvailability.stale,
                  source: DataSource.manual,
                ),
              ],
            ),
          ).call,
        ),
      );

      await tester.tap(find.text('Show context'));
      await tester.pumpAndSettle();

      expect(find.text('Optional context'), findsOneWidget);
      expect(find.textContaining('glucose rise'), findsNothing);
      expect(
        find.text(
          'You can prepare a context draft for reflection. This preview does not assess glucose patterns or identify a cause.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Stale data'), findsWidgets);
      expect(find.textContaining('0 glucose readings'), findsNothing);
    },
  );

  testWidgets('does not show an older attachment prompt outside the range', (
    tester,
  ) async {
    final oldPrompt = ContextAttachmentPrompt(
      id: 'old-prompt',
      start: contextFixtureNow.subtract(const Duration(hours: 5)),
      end: contextFixtureNow.subtract(const Duration(hours: 4)),
    );
    await tester.pumpWidget(
      _host(
        initialRange: ContextTimelineRange.threeHours,
        source: FixedContextTimelineSource(
          ContextTimelineSnapshot(attachmentPrompt: oldPrompt),
        ).call,
      ),
    );

    await tester.tap(find.text('Show context'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('contextAttachmentPrompt')),
      findsNothing,
    );
    expect(find.textContaining('glucose rise'), findsNothing);
  });

  testWidgets('heart-rate details list each represented source', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        source: FixedContextTimelineSource(
          ContextTimelineSnapshot(
            heartRateSamples: <HeartRateSample>[
              HeartRateSample(
                timestamp: contextFixtureNow.subtract(
                  const Duration(hours: 2),
                ),
                bpm: 71,
                source: DataSource.appleHealth,
              ),
              HeartRateSample(
                timestamp: contextFixtureNow.subtract(
                  const Duration(minutes: 30),
                ),
                bpm: 82,
                source: DataSource.healthConnect,
              ),
            ],
            laneStatuses: const <ContextTimelineLaneStatus>[
              ContextTimelineLaneStatus(
                lane: ContextTimelineLane.heartRate,
                availability: ContextDataAvailability.available,
              ),
            ],
          ),
        ).call,
      ),
    );

    await tester.tap(find.text('Show context'));
    await tester.pumpAndSettle();
    final summary = find.byKey(const ValueKey<String>('heartRateSummary'));
    await tester.ensureVisible(summary);
    await tester.tap(summary);
    await tester.pumpAndSettle();

    expect(find.text('Sources: Apple Health, Health Connect'), findsOneWidget);
    expect(find.text('Source: Health Connect'), findsNothing);
  });

  testWidgets('exposes the expanded preview to a screen reader', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(source: FixedContextTimelineSource(richContextFixture()).call),
    );
    await tester.tap(find.text('Show context'));
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey<String>('contextTimelinePlot')),
          )
          .label,
      allOf(
        contains('Glucose-first contextual timeline'),
        contains('4 glucose readings'),
        contains('heart-rate samples'),
      ),
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey<String>('contextAttachmentPrompt')),
          )
          .label,
      contains('does not assess glucose patterns'),
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey<String>('contextAvailabilitySummary')),
          )
          .label,
      allOf(contains('Context availability'), contains('Partial data')),
    );
    semantics.dispose();
  });

  testWidgets('renders a deterministic redacted sample preview', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(source: FixedContextTimelineSource(richContextFixture()).call),
    );
    await tester.tap(find.text('Show context'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey<String>('compactContextTimeline')),
      matchesGoldenFile(
        '../../../docs/architecture/context-timeline-preview-sample.png',
      ),
    );
  });

  testWidgets(
    'context preview handles compact widths, 200 percent text, and reduced motion',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));

      for (final width in <double>[375, 390, 430]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: _host(
              source: FixedContextTimelineSource(richContextFixture()).call,
            ),
          ),
        );
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'collapsed width $width',
        );

        await tester.tap(find.text('Show context'));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'expanded width $width');
      }
    },
  );
}

Widget _host({
  required ContextTimelineSource source,
  ValueChanged<ContextAttachmentDraft>? onAttachmentRequested,
  ContextTimelineRange initialRange = ContextTimelineRange.oneDay,
}) => MaterialApp(
  home: Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: CompactContextTimeline(
          source: source,
          now: contextFixtureNow,
          initialRange: initialRange,
          onAttachmentRequested: onAttachmentRequested,
        ),
      ),
    ),
  ),
);
