import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/context_timeline/compact_context_timeline.dart';
import 'package:openglucose/src/context_timeline/context_timeline_models.dart';

import 'context_timeline_fixture.dart';

void main() {
  testWidgets('context is collapsed by default and expands as read-only', (
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
    expect(find.text('Recent glucose rise'), findsNothing);

    await tester.tap(find.text('Show context'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('contextTimelinePlot')),
      findsOneWidget,
    );
    expect(find.text('SAMPLE DATA — NOT FROM A SENSOR'), findsOneWidget);
    expect(find.text('Recent glucose rise'), findsOneWidget);
    expect(
      find.text(
        'No context is attached to this recent glucose rise. This does not identify a cause.',
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
    expect(drafts.single.gap.id, 'gap-newest');
  });

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
}) => MaterialApp(
  home: Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: CompactContextTimeline(
          source: source,
          now: contextFixtureNow,
          onAttachmentRequested: onAttachmentRequested,
        ),
      ),
    ),
  ),
);
