import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openglucose/src/health_context_import.dart';

HealthDataPoint _point({
  required String uuid,
  required HealthDataType type,
  required DateTime from,
  DateTime? to,
  num value = 1,
  HealthPlatformType platform = HealthPlatformType.appleHealth,
  WorkoutSummary? workoutSummary,
}) => HealthDataPoint(
  uuid: uuid,
  value: NumericHealthValue(numericValue: value),
  type: type,
  unit: HealthDataUnit.UNKNOWN_UNIT,
  dateFrom: from,
  dateTo: to ?? from,
  sourcePlatform: platform,
  sourceDeviceId: 'device-fixture',
  sourceId: 'com.example.health',
  sourceName: 'Fixture Health',
  recordingMethod: RecordingMethod.automatic,
  workoutSummary: workoutSummary,
);

void main() {
  test('imports source-aware context and de-duplicates UUIDs', () async {
    final start = DateTime.utc(2026, 1, 1);
    final reader = FakeHealthContextReader(
      points: [
        _point(
          uuid: 'steps-1',
          type: HealthDataType.STEPS,
          from: start.add(const Duration(hours: 8)),
          to: start.add(const Duration(hours: 9)),
          value: 1200,
        ),
        // Same source UUID appears twice in a bounded platform read.
        _point(
          uuid: 'steps-1',
          type: HealthDataType.STEPS,
          from: start.add(const Duration(hours: 8)),
          to: start.add(const Duration(hours: 9)),
          value: 1200,
        ),
        _point(
          uuid: 'sleep-1',
          type: HealthDataType.SLEEP_DEEP,
          from: start,
          to: start.add(const Duration(hours: 2)),
        ),
        _point(
          uuid: 'hr-1',
          type: HealthDataType.HEART_RATE,
          from: start.add(const Duration(hours: 10)),
          value: 72,
        ),
        _point(
          uuid: 'workout-1',
          type: HealthDataType.WORKOUT,
          from: start.add(const Duration(hours: 12)),
          to: start.add(const Duration(hours: 13)),
          workoutSummary: WorkoutSummary(
            workoutType: 'cycling',
            totalDistance: 5000,
            totalEnergyBurned: 250,
            totalSteps: 100,
          ),
        ),
      ],
    );
    final repository = InMemoryHealthRepository();
    final result = await HealthContextImporter(
      reader: reader,
      repository: repository,
    ).sync(start: start, end: start.add(const Duration(days: 1)));

    expect(result.status, HealthContextImportStatus.ok);
    expect(result.fetched, 5);
    expect(result.imported, 4);
    expect(result.skipped, 1);
    expect(reader.authorizationCalls, 1);
    expect(reader.readCalls, 1);

    final activity = await repository.queryActivitySamples();
    expect(activity, hasLength(2));
    expect(activity.first.metadata?.externalId, 'steps-1');
    expect(activity.first.metadata?.sourceId, 'com.example.health');
    expect(activity.last.workoutLabel, 'cycling');
    expect(
      (await repository.querySleepSamples()).single.stage,
      SleepStage.deep,
    );
    expect((await repository.queryHeartRateSamples()).single.bpm, 72);
  });

  test(
    'a repeated sync replaces a source record instead of duplicating it',
    () async {
      final at = DateTime.utc(2026, 1, 1, 8);
      final reader = FakeHealthContextReader(
        points: [
          _point(
            uuid: 'steps-1',
            type: HealthDataType.STEPS,
            from: at,
            to: at.add(const Duration(hours: 1)),
            value: 100,
          ),
        ],
      );
      final repository = InMemoryHealthRepository();
      final importer = HealthContextImporter(
        reader: reader,
        repository: repository,
      );
      await importer.sync(start: at, end: at.add(const Duration(hours: 2)));
      reader.points[0].value = NumericHealthValue(numericValue: 200);
      await importer.sync(start: at, end: at.add(const Duration(hours: 2)));

      final samples = await repository.queryActivitySamples();
      expect(samples, hasLength(1));
      expect(samples.single.steps, 200);
    },
  );

  test('denied access never reads or mutates local state', () async {
    final reader = FakeHealthContextReader(
      points: const <HealthDataPoint>[],
      authorized: false,
    );
    final repository = InMemoryHealthRepository();
    final result = await HealthContextImporter(
      reader: reader,
      repository: repository,
    ).sync(start: DateTime.utc(2026), end: DateTime.utc(2026, 1, 2));

    expect(result.status, HealthContextImportStatus.notAuthorized);
    expect(reader.readCalls, 0);
    expect(await repository.queryActivitySamples(), isEmpty);
  });

  test('settings request only selected types', () async {
    final reader = FakeHealthContextReader(points: const <HealthDataPoint>[]);
    await HealthContextImporter(
      reader: reader,
      repository: InMemoryHealthRepository(),
    ).sync(
      start: DateTime.utc(2026),
      end: DateTime.utc(2026, 1, 2),
      settings: const HealthContextImportSettings(
        steps: false,
        workouts: false,
        sleep: false,
        heartRate: true,
        activeEnergy: false,
        distance: false,
      ),
    );
    expect(reader.lastRequestedTypes, [HealthDataType.HEART_RATE]);
  });
}
