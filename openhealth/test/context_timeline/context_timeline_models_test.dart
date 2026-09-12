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

    test('surfaces only the adapter-provided newest open context gap', () {
      final newest = RecentContextGap(
        id: 'newest',
        start: contextFixtureNow.subtract(const Duration(minutes: 35)),
        end: contextFixtureNow.subtract(const Duration(minutes: 15)),
      );
      final projection = ContextTimelineProjection.compose(
        snapshot: richContextFixture(gap: newest),
        now: contextFixtureNow,
        range: ContextTimelineRange.threeHours,
      );

      expect(projection.recentContextGap, same(newest));

      final attached = ContextTimelineProjection.compose(
        snapshot: richContextFixture(
          gap: RecentContextGap(
            id: 'already-attached',
            start: newest.start,
            end: newest.end,
            hasAttachedContext: true,
          ),
        ),
        now: contextFixtureNow,
        range: ContextTimelineRange.threeHours,
      );
      expect(attached.recentContextGap, isNull);

      final old = ContextTimelineProjection.compose(
        snapshot: richContextFixture(
          gap: RecentContextGap(
            id: 'old',
            start: contextFixtureNow.subtract(const Duration(days: 2)),
            end: contextFixtureNow.subtract(const Duration(days: 1, hours: 23)),
          ),
        ),
        now: contextFixtureNow,
        range: ContextTimelineRange.oneDay,
      );
      expect(old.recentContextGap, isNull);
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
  });
}
