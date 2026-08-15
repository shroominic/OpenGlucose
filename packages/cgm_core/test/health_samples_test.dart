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
      expect(sample.toJson()['formatVersion'], 1);
      expect(sample.toJson()['start'], '2026-01-01T09:00:00.000Z');
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

    test('preserves source identity metadata for incremental imports', () {
      final sample = ActivitySample(
        start: DateTime.utc(2026, 1, 1, 9),
        end: DateTime.utc(2026, 1, 1, 9, 30),
        type: ActivityType.steps,
        source: DataSource.appleHealth,
        steps: 1200,
        metadata: const HealthSampleMetadata(
          externalId: 'healthkit-uuid',
          sourceId: 'com.apple.Health',
          sourceName: 'Apple Health',
          deviceId: 'watch-fixture',
          deviceModel: 'Watch',
          recordingMethod: 'automatic',
        ),
      );
      final out = ActivitySample.fromJson(sample.toJson());
      expect(out.metadata?.externalId, 'healthkit-uuid');
      expect(out.metadata?.sourceId, 'com.apple.Health');
      expect(
        out.metadata?.identityKey(out.source),
        'appleHealth:healthkit-uuid',
      );
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
  });

  group('persisted health-sample validation', () {
    Map<String, Object?> activityJson({int? formatVersion = 1}) =>
        <String, Object?>{
          'formatVersion': ?formatVersion,
          'start': '2026-01-01T09:00:00.000Z',
          'end': '2026-01-01T09:30:00.000Z',
          'type': 'steps',
          'source': 'appleHealth',
          'steps': 1200,
        };

    Map<String, Object?> sleepJson({int? formatVersion = 1}) =>
        <String, Object?>{
          'formatVersion': ?formatVersion,
          'start': '2026-01-01T23:00:00.000Z',
          'end': '2026-01-02T01:00:00.000Z',
          'stage': 'deep',
          'source': 'appleHealth',
        };

    Map<String, Object?> heartJson({int? formatVersion = 1}) =>
        <String, Object?>{
          'formatVersion': ?formatVersion,
          'timestamp': '2026-01-01T12:00:00.000Z',
          'bpm': 72,
          'source': 'healthConnect',
        };

    test('accepts unversioned and explicit v0 legacy records', () {
      for (final formatVersion in <int?>[null, 0]) {
        expect(
          ActivitySample.fromJson(
            activityJson(formatVersion: formatVersion),
          ).steps,
          1200,
        );
        expect(
          SleepSample.fromJson(sleepJson(formatVersion: formatVersion)).stage,
          SleepStage.deep,
        );
        expect(
          HeartRateSample.fromJson(heartJson(formatVersion: formatVersion)).bpm,
          72,
        );
      }
    });

    test('normalizes offset timestamps and serializes UTC', () {
      final sample = HeartRateSample.fromJson(<String, Object?>{
        ...heartJson(),
        'timestamp': '2026-01-01T19:00:00.000+07:00',
      });
      expect(sample.timestamp, DateTime.utc(2026, 1, 1, 12));
      expect(sample.timestamp.isUtc, isTrue);
      expect(sample.toJson()['timestamp'], '2026-01-01T12:00:00.000Z');
    });

    test('v1 requires timezone while v0 remains readable', () {
      expect(
        () => HeartRateSample.fromJson(<String, Object?>{
          ...heartJson(),
          'timestamp': '2026-01-01T12:00:00.000',
        }),
        throwsA(isA<FormatException>()),
      );
      final legacy = HeartRateSample.fromJson(<String, Object?>{
        ...heartJson(formatVersion: 0),
        'timestamp': '2026-01-01T12:00:00.000',
      });
      expect(legacy.timestamp.isUtc, isTrue);
    });

    test('rejects unsupported versions for every sample type', () {
      final cases = <({String name, void Function() decode})>[];
      for (final version in <Object?>[-1, 2, 1.0, '1', null]) {
        cases
          ..add((
            name: 'activity $version',
            decode: () => ActivitySample.fromJson(<String, Object?>{
              ...activityJson(),
              'formatVersion': version,
            }),
          ))
          ..add((
            name: 'sleep $version',
            decode: () => SleepSample.fromJson(<String, Object?>{
              ...sleepJson(),
              'formatVersion': version,
            }),
          ))
          ..add((
            name: 'heart $version',
            decode: () => HeartRateSample.fromJson(<String, Object?>{
              ...heartJson(),
              'formatVersion': version,
            }),
          ));
      }

      for (final testCase in cases) {
        expect(
          testCase.decode,
          throwsA(isA<FormatException>()),
          reason: testCase.name,
        );
      }
    });

    test('rejects malformed activity fields and invalid ranges', () {
      final cases = <({String name, Map<String, Object?> json})>[
        (
          name: 'missing start',
          json: <String, Object?>{...activityJson()}..remove('start'),
        ),
        (
          name: 'bad date',
          json: <String, Object?>{...activityJson(), 'start': 'not-a-date'},
        ),
        (
          name: 'invalid calendar date',
          json: <String, Object?>{
            ...activityJson(),
            'start': '2026-02-30T09:00:00.000Z',
          },
        ),
        (
          name: 'end before start',
          json: <String, Object?>{
            ...activityJson(),
            'end': '2026-01-01T08:59:59.000Z',
          },
        ),
        (
          name: 'unknown type',
          json: <String, Object?>{...activityJson(), 'type': 'mystery'},
        ),
        (
          name: 'unknown source',
          json: <String, Object?>{...activityJson(), 'source': 'mystery'},
        ),
        (
          name: 'fractional steps',
          json: <String, Object?>{...activityJson(), 'steps': 2.5},
        ),
        (
          name: 'negative steps',
          json: <String, Object?>{...activityJson(), 'steps': -1},
        ),
        (
          name: 'non-finite energy',
          json: <String, Object?>{...activityJson(), 'energyKcal': double.nan},
        ),
        (
          name: 'negative distance',
          json: <String, Object?>{...activityJson(), 'distanceMeters': -0.1},
        ),
        (
          name: 'missing steps payload',
          json: <String, Object?>{...activityJson()}..remove('steps'),
        ),
        (
          name: 'missing distance payload',
          json: <String, Object?>{
            ...activityJson(),
            'type': 'distance',
            'steps': null,
          },
        ),
        (
          name: 'missing energy payload',
          json: <String, Object?>{
            ...activityJson(),
            'type': 'activeEnergy',
            'steps': null,
          },
        ),
      ];
      for (final testCase in cases) {
        expect(
          () => ActivitySample.fromJson(testCase.json),
          throwsA(isA<FormatException>()),
          reason: testCase.name,
        );
      }
    });

    test('rejects unknown sleep stage and provenance', () {
      final cases = <Map<String, Object?>>[
        <String, Object?>{...sleepJson(), 'stage': 'dreaming'},
        <String, Object?>{...sleepJson(), 'source': 'mystery'},
        <String, Object?>{...sleepJson()}..remove('stage'),
        <String, Object?>{...sleepJson(), 'end': '2026-01-01T22:00:00.000Z'},
      ];
      for (final json in cases) {
        expect(
          () => SleepSample.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects missing, zero, negative, and non-finite heart rate', () {
      final cases = <Map<String, Object?>>[
        <String, Object?>{...heartJson()}..remove('bpm'),
        <String, Object?>{...heartJson(), 'bpm': 0},
        <String, Object?>{...heartJson(), 'bpm': -1},
        <String, Object?>{...heartJson(), 'bpm': double.infinity},
        <String, Object?>{...heartJson(), 'bpm': '72'},
        <String, Object?>{...heartJson(), 'source': 'mystery'},
      ];
      for (final json in cases) {
        expect(
          () => HeartRateSample.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects invalid values when encoding', () {
      final invalidActivity = ActivitySample(
        start: DateTime.utc(2026, 1, 2),
        end: DateTime.utc(2026, 1, 1),
        type: ActivityType.workout,
        source: DataSource.manual,
      );
      final invalidHeartRate = HeartRateSample(
        timestamp: DateTime.utc(2026),
        bpm: double.nan,
        source: DataSource.manual,
      );
      expect(invalidActivity.toJson, throwsA(isA<FormatException>()));
      expect(invalidHeartRate.toJson, throwsA(isA<FormatException>()));
    });
  });

  group('DataSource', () {
    test('best-effort helper round-trips and falls back to manual', () {
      for (final source in DataSource.values) {
        expect(DataSource.fromKey(source.key), source);
      }
      expect(DataSource.fromKey('nope'), DataSource.manual);
      expect(DataSource.fromKey(null), DataSource.manual);
    });
  });
}
