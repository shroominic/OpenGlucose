import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

/// Context categories that may be imported into the local body timeline.
enum HealthContextType {
  steps,
  workout,
  sleep,
  heartRate,
  activeEnergy,
  distance,
}

/// User-controlled import switches. Every switch is opt-in at the call site;
/// the importer never broadens a request beyond these categories.
class HealthContextImportSettings {
  const HealthContextImportSettings({
    this.steps = true,
    this.workouts = true,
    this.sleep = true,
    this.heartRate = true,
    this.activeEnergy = true,
    this.distance = true,
  });

  final bool steps;
  final bool workouts;
  final bool sleep;
  final bool heartRate;
  final bool activeEnergy;
  final bool distance;

  Set<HealthContextType> get enabledTypes => <HealthContextType>{
    if (steps) HealthContextType.steps,
    if (workouts) HealthContextType.workout,
    if (sleep) HealthContextType.sleep,
    if (heartRate) HealthContextType.heartRate,
    if (activeEnergy) HealthContextType.activeEnergy,
    if (distance) HealthContextType.distance,
  };

  HealthContextImportSettings copyWith({
    bool? steps,
    bool? workouts,
    bool? sleep,
    bool? heartRate,
    bool? activeEnergy,
    bool? distance,
  }) => HealthContextImportSettings(
    steps: steps ?? this.steps,
    workouts: workouts ?? this.workouts,
    sleep: sleep ?? this.sleep,
    heartRate: heartRate ?? this.heartRate,
    activeEnergy: activeEnergy ?? this.activeEnergy,
    distance: distance ?? this.distance,
  );
}

enum HealthContextImportStatus {
  ok,
  noData,
  notSupported,
  notAuthorized,
  failed,
}

class HealthContextImportResult {
  const HealthContextImportResult({
    required this.status,
    this.requested = 0,
    this.fetched = 0,
    this.imported = 0,
    this.skipped = 0,
    this.message,
  });

  final HealthContextImportStatus status;
  final int requested;
  final int fetched;
  final int imported;
  final int skipped;
  final String? message;

  bool get isSuccess => status == HealthContextImportStatus.ok;
}

/// Platform-neutral seam around the `health` package.
///
/// Tests and demo surfaces inject [FakeHealthContextReader] rather than
/// constructing [Health], so no real health account or permission is required
/// to validate mapping and persistence behavior.
abstract interface class HealthContextReader {
  DataSource get source;
  bool get isSupported;

  Future<bool> requestAuthorization(List<HealthDataType> types);

  Future<List<HealthDataPoint>> read({
    required List<HealthDataType> types,
    required DateTime start,
    required DateTime end,
  });
}

/// Adapter for the existing `health` plugin. It performs only read access and
/// does not enable background delivery; callers explicitly request a bounded
/// foreground sync window.
class HealthPackageContextReader implements HealthContextReader {
  HealthPackageContextReader({
    Health? health,
    DataSource? source,
    bool Function()? supportCheck,
  }) : _health = health ?? Health(),
       _source = source ?? _defaultSource(),
       _supportCheck = supportCheck ?? _defaultSupportCheck,
       _configured = false;

  final Health _health;
  final DataSource _source;
  final bool Function() _supportCheck;
  bool _configured;

  @override
  DataSource get source => _source;

  @override
  bool get isSupported => _supportCheck();

  static DataSource _defaultSource() {
    if (Platform.isAndroid) return DataSource.healthConnect;
    return DataSource.appleHealth;
  }

  static bool _defaultSupportCheck() => Platform.isIOS || Platform.isAndroid;

  Future<void> _ensureConfigured() async {
    if (_configured || !isSupported) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types) async {
    if (!isSupported || types.isEmpty) return false;
    await _ensureConfigured();
    final permissions = List<HealthDataAccess>.filled(
      types.length,
      HealthDataAccess.READ,
    );
    final current = await _health.hasPermissions(
      types,
      permissions: permissions,
    );
    if (current == true) return true;
    return _health.requestAuthorization(types, permissions: permissions);
  }

  @override
  Future<List<HealthDataPoint>> read({
    required List<HealthDataType> types,
    required DateTime start,
    required DateTime end,
  }) async {
    if (!isSupported || types.isEmpty) return const <HealthDataPoint>[];
    await _ensureConfigured();
    return _health.getHealthDataFromTypes(
      types: types,
      preferredUnits: _preferredUnits(types),
      startTime: start,
      endTime: end,
    );
  }

  static Map<HealthDataType, HealthDataUnit> _preferredUnits(
    Iterable<HealthDataType> types,
  ) {
    final units = <HealthDataType, HealthDataUnit>{};
    for (final type in types) {
      switch (type) {
        case HealthDataType.ACTIVE_ENERGY_BURNED:
        case HealthDataType.TOTAL_CALORIES_BURNED:
          units[type] = HealthDataUnit.KILOCALORIE;
        case HealthDataType.DISTANCE_WALKING_RUNNING:
          units[type] = HealthDataUnit.METER;
        case HealthDataType.HEART_RATE:
        case HealthDataType.RESTING_HEART_RATE:
          units[type] = HealthDataUnit.BEATS_PER_MINUTE;
        case HealthDataType.STEPS:
          units[type] = HealthDataUnit.COUNT;
        // The plugin enum has many values outside the importer contract.
        // ignore: no_default_cases
        default:
          break;
      }
    }
    return units;
  }
}

/// Maps platform records into normalized, source-attributed core models and
/// persists them in one local repository operation per category.
class HealthContextImporter {
  HealthContextImporter({required this.reader, required this.repository});

  final HealthContextReader reader;
  final HealthRepository repository;

  Future<HealthContextImportResult> sync({
    required DateTime start,
    required DateTime end,
    HealthContextImportSettings settings = const HealthContextImportSettings(),
  }) async {
    if (!end.isAfter(start)) {
      return const HealthContextImportResult(
        status: HealthContextImportStatus.failed,
        message: 'Import window must end after it starts.',
      );
    }
    if (!reader.isSupported) {
      return const HealthContextImportResult(
        status: HealthContextImportStatus.notSupported,
        message: 'This platform does not provide a health-data store.',
      );
    }

    final types = _healthTypes(settings);
    if (types.isEmpty) {
      return const HealthContextImportResult(
        status: HealthContextImportStatus.noData,
        message: 'No health-data categories are enabled.',
      );
    }

    try {
      if (!await reader.requestAuthorization(types)) {
        return HealthContextImportResult(
          status: HealthContextImportStatus.notAuthorized,
          requested: types.length,
          message: 'Health-data access was not granted.',
        );
      }
      final points = await reader.read(types: types, start: start, end: end);
      final mapped = _mapUnique(points, reader.source);
      await repository.upsertActivitySamples(mapped.activity);
      await repository.upsertSleepSamples(mapped.sleep);
      await repository.upsertHeartRateSamples(mapped.heartRate);
      final imported =
          mapped.activity.length +
          mapped.sleep.length +
          mapped.heartRate.length;
      final skipped = points.length - mapped.fetchedUnique;
      return HealthContextImportResult(
        status: imported == 0
            ? HealthContextImportStatus.noData
            : HealthContextImportStatus.ok,
        requested: types.length,
        fetched: points.length,
        imported: imported,
        skipped: skipped < 0 ? 0 : skipped,
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Health context import failed (${error.runtimeType}).');
      debugPrintStack(stackTrace: stackTrace);
      return const HealthContextImportResult(
        status: HealthContextImportStatus.failed,
        message: 'Health data could not be imported on this device.',
      );
    }
  }

  static List<HealthDataType> _healthTypes(
    HealthContextImportSettings settings,
  ) {
    final types = <HealthDataType>[];
    if (settings.steps) types.add(HealthDataType.STEPS);
    if (settings.workouts) types.add(HealthDataType.WORKOUT);
    if (settings.sleep) {
      types.addAll(<HealthDataType>[
        HealthDataType.SLEEP_AWAKE,
        HealthDataType.SLEEP_AWAKE_IN_BED,
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_ASLEEP,
        HealthDataType.SLEEP_IN_BED,
        HealthDataType.SLEEP_UNKNOWN,
      ]);
    }
    if (settings.heartRate) types.add(HealthDataType.HEART_RATE);
    if (settings.activeEnergy) {
      types.add(HealthDataType.ACTIVE_ENERGY_BURNED);
    }
    if (settings.distance) {
      types.add(HealthDataType.DISTANCE_WALKING_RUNNING);
    }
    return types;
  }

  static _MappedContext _mapUnique(
    List<HealthDataPoint> points,
    DataSource source,
  ) {
    final seen = <String>{};
    final activity = <ActivitySample>[];
    final sleep = <SleepSample>[];
    final heartRate = <HeartRateSample>[];
    var fetchedUnique = 0;
    for (final point in points) {
      final externalId = point.uuid.trim();
      if (externalId.isEmpty) continue;
      final metadata = HealthSampleMetadata(
        externalId: externalId,
        sourceId: _nullIfBlank(point.sourceId),
        sourceName: _nullIfBlank(point.sourceName),
        deviceId: _nullIfBlank(point.sourceDeviceId),
        deviceModel: _nullIfBlank(point.deviceModel),
        recordingMethod: point.recordingMethod.name,
      );
      final key = metadata.identityKey(source);
      if (!seen.add(key)) continue;
      fetchedUnique += 1;
      final mapped = _mapPoint(point, source, metadata);
      if (mapped is ActivitySample) activity.add(mapped);
      if (mapped is SleepSample) sleep.add(mapped);
      if (mapped is HeartRateSample) heartRate.add(mapped);
    }
    return _MappedContext(
      activity: activity,
      sleep: sleep,
      heartRate: heartRate,
      fetchedUnique: fetchedUnique,
    );
  }

  static TimelineEntry? _mapPoint(
    HealthDataPoint point,
    DataSource source,
    HealthSampleMetadata metadata,
  ) {
    final start = point.dateFrom.toUtc();
    final end = point.dateTo.toUtc();
    if (end.isBefore(start)) return null;
    switch (point.type) {
      case HealthDataType.STEPS:
        final steps = _nonNegativeInt(point.value);
        return steps == null
            ? null
            : ActivitySample(
                start: start,
                end: end,
                type: ActivityType.steps,
                source: source,
                steps: steps,
                metadata: metadata,
              );
      case HealthDataType.WORKOUT:
        final summary = point.workoutSummary;
        return ActivitySample(
          start: start,
          end: end,
          type: ActivityType.workout,
          source: source,
          steps: _finiteNonNegativeInt(summary?.totalSteps),
          energyKcal: _finiteNonNegative(summary?.totalEnergyBurned),
          distanceMeters: _finiteNonNegative(summary?.totalDistance),
          workoutLabel: _nullIfBlank(summary?.workoutType),
          metadata: metadata,
        );
      case HealthDataType.ACTIVE_ENERGY_BURNED:
      case HealthDataType.TOTAL_CALORIES_BURNED:
        final energy = _numeric(point.value);
        return energy == null || energy < 0
            ? null
            : ActivitySample(
                start: start,
                end: end,
                type: ActivityType.activeEnergy,
                source: source,
                energyKcal: energy,
                metadata: metadata,
              );
      case HealthDataType.DISTANCE_WALKING_RUNNING:
        final distance = _numeric(point.value);
        return distance == null || distance < 0
            ? null
            : ActivitySample(
                start: start,
                end: end,
                type: ActivityType.distance,
                source: source,
                distanceMeters: distance,
                metadata: metadata,
              );
      case HealthDataType.HEART_RATE:
      case HealthDataType.RESTING_HEART_RATE:
        final bpm = _numeric(point.value);
        return bpm == null || bpm <= 0
            ? null
            : HeartRateSample(
                timestamp: start,
                bpm: bpm,
                source: source,
                metadata: metadata,
              );
      case HealthDataType.SLEEP_AWAKE:
      case HealthDataType.SLEEP_AWAKE_IN_BED:
      case HealthDataType.SLEEP_DEEP:
      case HealthDataType.SLEEP_LIGHT:
      case HealthDataType.SLEEP_REM:
      case HealthDataType.SLEEP_ASLEEP:
      case HealthDataType.SLEEP_IN_BED:
      case HealthDataType.SLEEP_UNKNOWN:
      case HealthDataType.SLEEP_OUT_OF_BED:
        final stage = _sleepStage(point.type);
        return SleepSample(
          start: start,
          end: end,
          stage: stage,
          source: source,
          metadata: metadata,
        );
      // Unsupported platform records fail closed rather than being guessed.
      // ignore: no_default_cases
      default:
        return null;
    }
  }

  static SleepStage _sleepStage(HealthDataType type) {
    switch (type) {
      case HealthDataType.SLEEP_AWAKE:
      case HealthDataType.SLEEP_AWAKE_IN_BED:
        return SleepStage.awake;
      case HealthDataType.SLEEP_DEEP:
        return SleepStage.deep;
      case HealthDataType.SLEEP_LIGHT:
        return SleepStage.light;
      case HealthDataType.SLEEP_REM:
        return SleepStage.rem;
      case HealthDataType.SLEEP_IN_BED:
        return SleepStage.inBed;
      case HealthDataType.SLEEP_ASLEEP:
      case HealthDataType.SLEEP_UNKNOWN:
      case HealthDataType.SLEEP_OUT_OF_BED:
        return SleepStage.asleep;
      // Sleep categories are intentionally the only values mapped here.
      // ignore: no_default_cases
      default:
        return SleepStage.asleep;
    }
  }

  static double? _numeric(HealthValue value) {
    if (value is! NumericHealthValue) return null;
    final number = value.numericValue.toDouble();
    return number.isFinite ? number : null;
  }

  static int? _nonNegativeInt(HealthValue value) {
    final valueAsDouble = _numeric(value);
    return _finiteNonNegativeInt(valueAsDouble);
  }

  static int? _finiteNonNegativeInt(num? value) {
    if (value == null) return null;
    final number = value.toDouble();
    if (!number.isFinite || number < 0) return null;
    return number.round();
  }

  static double? _finiteNonNegative(num? value) {
    if (value == null) return null;
    final number = value.toDouble();
    return number.isFinite && number >= 0 ? number : null;
  }

  static String? _nullIfBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class _MappedContext {
  const _MappedContext({
    required this.activity,
    required this.sleep,
    required this.heartRate,
    required this.fetchedUnique,
  });

  final List<ActivitySample> activity;
  final List<SleepSample> sleep;
  final List<HeartRateSample> heartRate;
  final int fetchedUnique;
}

/// Deterministic reader for unit/widget tests. It never calls platform APIs.
class FakeHealthContextReader implements HealthContextReader {
  FakeHealthContextReader({
    required this.points,
    this.source = DataSource.appleHealth,
    this.supported = true,
    this.authorized = true,
  });

  final List<HealthDataPoint> points;
  @override
  final DataSource source;
  bool supported;
  bool authorized;
  int authorizationCalls = 0;
  int readCalls = 0;
  List<HealthDataType>? lastRequestedTypes;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types) async {
    authorizationCalls += 1;
    lastRequestedTypes = List<HealthDataType>.unmodifiable(types);
    return supported && authorized;
  }

  @override
  Future<List<HealthDataPoint>> read({
    required List<HealthDataType> types,
    required DateTime start,
    required DateTime end,
  }) async {
    readCalls += 1;
    return points
        .where(
          (point) =>
              types.contains(point.type) &&
              !point.dateFrom.isBefore(start) &&
              point.dateFrom.isBefore(end),
        )
        .toList(growable: false);
  }
}
