import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/context_timeline/context_timeline_models.dart';

import 'context_timeline_fixture.dart';

void main() {
  group('ContextTimelineProjection', () {
    test('keeps typed context aligned to the selected time window', () {
      final projection = ContextTimelineProjection.compose(
        snapshot: richContextFixture(),
        now: contextFixtureNow,
        range: ContextTimelineRange.oneDay,
      );

      expect(projection.glucoseReadings, hasLength(4));
      expect(
        projection.items.map((item) => item.kind),
        containsAll(<ContextTimelineItemKind>[
          ContextTimelineItemKind.meal,
          ContextTimelineItemKind.note,
          ContextTimelineItemKind.workout,
          ContextTimelineItemKind.movement,
          ContextTimelineItemKind.sleep,
          ContextTimelineItemKind.heartRate,
        ]),
      );
      final sleep = projection.items.firstWhere(
        (item) => item.kind == ContextTimelineItemKind.sleep,
      );
      expect(sleep.source, DataSource.appleHealth);
      expect(sleep.isInterval, isTrue);
      expect(sleep.start.isBefore(projection.window.start), isTrue);
      expect(sleep.end.isAfter(projection.window.start), isTrue);
      expect(projection.heartRateSamples, hasLength(2));
    });

    test('uses range filtering without inventing context', () {
      final projection = ContextTimelineProjection.compose(
        snapshot: richContextFixture(),
        now: contextFixtureNow,
        range: ContextTimelineRange.threeHours,
      );

      expect(projection.glucoseReadings, hasLength(1));
      expect(
        projection.items.map((item) => item.kind),
        contains(ContextTimelineItemKind.meal),
      );
      expect(
        projection.items.map((item) => item.kind),
        isNot(contains(ContextTimelineItemKind.sleep)),
      );
      expect(
        projection.items.map((item) => item.kind),
        isNot(contains(ContextTimelineItemKind.workout)),
      );
    });

    test('surfaces at most one generic attachment prompt in range', () {
      final newest = ContextAttachmentPrompt(
        id: 'prompt-newest',
        start: contextFixtureNow.subtract(const Duration(minutes: 35)),
        end: contextFixtureNow.subtract(const Duration(minutes: 15)),
      );
      final projection = ContextTimelineProjection.compose(
        snapshot: richContextFixture(attachmentPrompt: newest),
        now: contextFixtureNow,
        range: ContextTimelineRange.threeHours,
      );

      expect(projection.attachmentPrompt, same(newest));

      final attached = ContextTimelineProjection.compose(
        snapshot: richContextFixture(
          attachmentPrompt: ContextAttachmentPrompt(
            id: 'already-attached-prompt',
            start: newest.start,
            end: newest.end,
            hasAttachedContext: true,
          ),
        ),
        now: contextFixtureNow,
        range: ContextTimelineRange.threeHours,
      );
      expect(attached.attachmentPrompt, isNull);

      final old = ContextTimelineProjection.compose(
        snapshot: richContextFixture(
          attachmentPrompt: ContextAttachmentPrompt(
            id: 'old-prompt',
            start: contextFixtureNow.subtract(const Duration(days: 2)),
            end: contextFixtureNow.subtract(const Duration(days: 1, hours: 23)),
          ),
        ),
        now: contextFixtureNow,
        range: ContextTimelineRange.oneDay,
      );
      expect(old.attachmentPrompt, isNull);
    });

    test('keeps unavailable context distinct from an empty numeric value', () {
      final projection = ContextTimelineProjection.compose(
        snapshot: const ContextTimelineSnapshot(),
        now: contextFixtureNow,
        range: ContextTimelineRange.oneDay,
      );

      for (final lane in ContextTimelineLane.values) {
        expect(
          projection.statusFor(lane).availability,
          ContextDataAvailability.noAccessibleData,
        );
      }
      expect(projection.items, isEmpty);
      expect(projection.heartRateSamples, isEmpty);
      expect(projection.glucoseReadings, isEmpty);
    });

    test('marks unqualified supplied context as partial, not available', () {
      final projection = ContextTimelineProjection.compose(
        snapshot: ContextTimelineSnapshot(
          heartRateSamples: <HeartRateSample>[
            HeartRateSample(
              timestamp: contextFixtureNow.subtract(const Duration(minutes: 5)),
              bpm: 70,
              source: DataSource.appleHealth,
            ),
          ],
        ),
        now: contextFixtureNow,
        range: ContextTimelineRange.oneDay,
      );

      expect(
        projection.statusFor(ContextTimelineLane.heartRate).availability,
        ContextDataAvailability.partial,
      );
    });

    test('does not call out-of-window fallback context partial data', () {
      final projection = ContextTimelineProjection.compose(
        snapshot: ContextTimelineSnapshot(
          heartRateSamples: <HeartRateSample>[
            HeartRateSample(
              timestamp: contextFixtureNow.subtract(const Duration(hours: 4)),
              bpm: 70,
              source: DataSource.appleHealth,
            ),
          ],
        ),
        now: contextFixtureNow,
        range: ContextTimelineRange.threeHours,
      );

      expect(projection.heartRateSamples, isEmpty);
      expect(
        projection.statusFor(ContextTimelineLane.heartRate).availability,
        ContextDataAvailability.noAccessibleData,
      );
    });

    test('preserves an explicit stale status for the selected window', () {
      final projection = ContextTimelineProjection.compose(
        snapshot: const ContextTimelineSnapshot(
          laneStatuses: <ContextTimelineLaneStatus>[
            ContextTimelineLaneStatus(
              lane: ContextTimelineLane.heartRate,
              availability: ContextDataAvailability.stale,
              source: DataSource.appleHealth,
            ),
          ],
        ),
        now: contextFixtureNow,
        range: ContextTimelineRange.threeHours,
      );

      expect(
        projection.statusFor(ContextTimelineLane.heartRate).availability,
        ContextDataAvailability.stale,
      );
    });
  });
}
