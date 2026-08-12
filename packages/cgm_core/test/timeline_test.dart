import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  group('TimelineSorting', () {
    test('sortedByTime orders ascending and is stable on ties', () {
      final t = DateTime.utc(2026, 1, 1, 12);
      final a = HeartRateSample(
        timestamp: t,
        bpm: 60,
        source: DataSource.manual,
      );
      final b = HeartRateSample(
        timestamp: t,
        bpm: 61,
        source: DataSource.manual,
      );
      final earlier = HeartRateSample(
        timestamp: DateTime.utc(2026, 1, 1, 11),
        bpm: 59,
        source: DataSource.manual,
      );

      final sorted = <HeartRateSample>[a, b, earlier].sortedByTime();
      expect(sorted[0], earlier);
      // stable: a stays before b on the tie.
      expect(sorted[1], a);
      expect(sorted[2], b);
    });

    test('inWindow filters inclusively and sorts', () {
      final entries = <TimelineEntry>[
        HeartRateSample(
          timestamp: DateTime.utc(2026, 1, 1, 8),
          bpm: 60,
          source: DataSource.manual,
        ),
        HeartRateSample(
          timestamp: DateTime.utc(2026, 1, 1, 10),
          bpm: 70,
          source: DataSource.manual,
        ),
        HeartRateSample(
          timestamp: DateTime.utc(2026, 1, 1, 12),
          bpm: 80,
          source: DataSource.manual,
        ),
      ];

      final window = entries.inWindow(
        DateTime.utc(2026, 1, 1, 9),
        DateTime.utc(2026, 1, 1, 12),
      );
      expect(window.length, 2);
      expect((window.first as HeartRateSample).bpm, 70);
      expect((window.last as HeartRateSample).bpm, 80);
    });
  });

  group('mergeTimelines', () {
    test('interleaves heterogeneous entries chronologically', () {
      final reading = CgmReading(
        valueMgdl: 110,
        source: CgmRecordSource.standard,
        recordedAt: DateTime.utc(2026, 1, 1, 9, 5),
      );
      final meal = HealthEvent(
        id: 'm',
        timestamp: DateTime.utc(2026, 1, 1, 9),
        type: HealthEventType.meal,
      );
      final workout = ActivitySample(
        start: DateTime.utc(2026, 1, 1, 9, 10),
        end: DateTime.utc(2026, 1, 1, 9, 40),
        type: ActivityType.workout,
        source: DataSource.appleHealth,
      );

      final merged = mergeTimelines(<List<TimelineEntry>>[
        <TimelineEntry>[reading],
        <TimelineEntry>[meal, workout],
      ]);

      expect(merged.map((e) => e.timelineKind).toList(), [
        TimelineEntryKind.event, // 09:00
        TimelineEntryKind.cgmReading, // 09:05
        TimelineEntryKind.activity, // 09:10
      ]);
    });

    test('CgmReading without recordedAt sorts to the epoch', () {
      final anchored = CgmReading(
        valueMgdl: 100,
        source: CgmRecordSource.standard,
        recordedAt: DateTime.utc(2026, 1, 1),
      );
      const unanchored = CgmReading(valueMgdl: 95, source: CgmRecordSource.raw);

      final merged = mergeTimelines(<List<TimelineEntry>>[
        <TimelineEntry>[anchored, unanchored],
      ]);
      expect(merged.first, unanchored);
      expect(
        merged.first.timelineTimestamp,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    });

    test('empty input yields empty list', () {
      expect(mergeTimelines(const <List<TimelineEntry>>[]), isEmpty);
    });
  });
}
