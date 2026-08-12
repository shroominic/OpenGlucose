import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  group('ActivitySample', () {
    test('construction, duration & timeline contract', () {
      final sample = ActivitySample(
        start: DateTime.utc(2026, 1, 1, 9),
        end: DateTime.utc(2026, 1, 1, 9, 30),
        type: ActivityType.workout,
        source: DataSource.healthConnect,
        energyKcal: 250,
        distanceMeters: 4200,
        workoutLabel: 'cycling',
      );
      expect(sample.duration, const Duration(minutes: 30));
      expect(sample.timelineTimestamp, sample.start);
      expect(sample.timelineKind, TimelineEntryKind.activity);
    });

    test('json round-trip', () {
      final sample = ActivitySample(
        start: DateTime.utc(2026, 1, 1, 9),
        end: DateTime.utc(2026, 1, 1, 9, 30),
        type: ActivityType.steps,
        source: DataSource.appleHealth,
        steps: 1200,
      );
      final out = ActivitySample.fromJson(sample.toJson());
      expect(out.start, sample.start);
      expect(out.end, sample.end);
      expect(out.type, ActivityType.steps);
      expect(out.source, DataSource.appleHealth);
      expect(out.steps, 1200);
    });

    test('unknown type & bad dates fall back gracefully', () {
      final out = ActivitySample.fromJson(const {
        'type': 'mystery',
        'source': 'mystery',
        'start': 'not-a-date',
      });
      expect(out.type, ActivityType.other);
      expect(out.source, DataSource.manual);
      expect(out.start, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
      // end falls back to start when missing.
      expect(out.end, out.start);
    });

    test('copyWith', () {
      final sample = ActivitySample(
        start: DateTime.utc(2026, 1, 1),
        end: DateTime.utc(2026, 1, 1, 1),
        type: ActivityType.steps,
        source: DataSource.manual,
        steps: 100,
      );
      expect(sample.copyWith(steps: 200).steps, 200);
      expect(sample.copyWith(steps: 200).start, sample.start);
    });
  });

  group('SleepSample', () {
    test('json round-trip & timeline contract', () {
      final sample = SleepSample(
        start: DateTime.utc(2026, 1, 1, 23),
        end: DateTime.utc(2026, 1, 2, 1),
        stage: SleepStage.deep,
        source: DataSource.appleHealth,
      );
      expect(sample.duration, const Duration(hours: 2));
      expect(sample.timelineKind, TimelineEntryKind.sleep);

      final out = SleepSample.fromJson(sample.toJson());
      expect(out.stage, SleepStage.deep);
      expect(out.start, sample.start);
      expect(out.end, sample.end);
      expect(out.source, DataSource.appleHealth);
    });

    test('unknown stage falls back to asleep', () {
      final out = SleepSample.fromJson(const {
        'start': '2026-01-01T00:00:00.000Z',
        'end': '2026-01-01T01:00:00.000Z',
        'stage': 'dreaming',
        'source': 'manual',
      });
      expect(out.stage, SleepStage.asleep);
    });
  });

  group('HeartRateSample', () {
    test('json round-trip & timeline contract', () {
      final sample = HeartRateSample(
        timestamp: DateTime.utc(2026, 1, 1, 12),
        bpm: 72,
        source: DataSource.healthConnect,
      );
      expect(sample.timelineTimestamp, sample.timestamp);
      expect(sample.timelineKind, TimelineEntryKind.heartRate);

      final out = HeartRateSample.fromJson(sample.toJson());
      expect(out.bpm, 72);
      expect(out.timestamp, sample.timestamp);
      expect(out.source, DataSource.healthConnect);
    });

    test('missing bpm defaults to 0', () {
      final out = HeartRateSample.fromJson(const {
        'timestamp': '2026-01-01T00:00:00.000Z',
        'source': 'manual',
      });
      expect(out.bpm, 0);
    });
  });

  group('DataSource', () {
    test('round-trips by key and falls back to manual', () {
      for (final source in DataSource.values) {
        expect(DataSource.fromKey(source.key), source);
      }
      expect(DataSource.fromKey('nope'), DataSource.manual);
      expect(DataSource.fromKey(null), DataSource.manual);
    });
  });
}
