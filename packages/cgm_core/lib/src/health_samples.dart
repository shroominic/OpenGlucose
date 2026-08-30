import 'timeline.dart';

/// A platform that supplies records which can be imported into OpenGlucose.
///
/// This is deliberately narrower than [DataSource]. A manual record can have
/// a [DataSource.manual] source, but it does not have a platform-owned stable
/// external identity to reconcile on later imports.
enum HealthSourcePlatform {
  /// Apple's HealthKit store.
  appleHealth,

  /// Android Health Connect.
  healthConnect;

  /// Stable storage key.
  String get key => name;

  /// The normalized source used by health samples from this platform.
  DataSource get dataSource => switch (this) {
    HealthSourcePlatform.appleHealth => DataSource.appleHealth,
    HealthSourcePlatform.healthConnect => DataSource.healthConnect,
  };

  /// Returns the import platform for an imported [source], or `null` for a
  /// non-imported source such as [DataSource.manual].
  static HealthSourcePlatform? fromDataSource(DataSource source) =>
      switch (source) {
        DataSource.appleHealth => HealthSourcePlatform.appleHealth,
        DataSource.healthConnect => HealthSourcePlatform.healthConnect,
        DataSource.manual => null,
      };

  static HealthSourcePlatform fromKey(String? key) {
    for (final value in HealthSourcePlatform.values) {
      if (value.key == key) return value;
    }
    throw FormatException('Unsupported health source platform: $key');
  }
}

/// The platform recording method for an imported health record.
///
/// Platform-specific values are normalized by an importer before they reach
/// this contract. [unknown] means that the platform did not provide a method;
/// it does not mean that OpenGlucose inferred one.
enum HealthRecordingMethod {
  unknown,
  automatic,
  manual;

  /// Stable storage key.
  String get key => name;

  static HealthRecordingMethod fromKey(String? key) {
    for (final value in HealthRecordingMethod.values) {
      if (value.key == key) return value;
    }
    throw FormatException('Unsupported health recording method: $key');
  }
}

/// A stable platform-owned identity for one imported health record.
///
/// [externalId] is kept only in the local health store. It must not be sent to
/// logs, analytics, exports, or user-facing surfaces. The same identity is
/// deterministic across repeated bounded imports and is the only supported
/// way to replace or tombstone an imported sample.
class HealthImportIdentity {
  const HealthImportIdentity({
    required this.platform,
    required this.externalId,
  });

  /// Platform that issued [externalId].
  final HealthSourcePlatform platform;

  /// Stable record identifier supplied by [platform].
  final String externalId;

  /// A deterministic key for in-memory de-duplication.
  ///
  /// This key is not for display or logging. Storage implementations should
  /// use the two typed fields as a composite unique key where possible.
  String get stableKey {
    _validateNonBlank(externalId, 'externalId');
    return '${platform.key.length}:${platform.key}$externalId';
  }

  Map<String, Object?> toJson() {
    _validateNonBlank(externalId, 'externalId');
    return <String, Object?>{
      'platform': platform.key,
      'externalId': externalId,
    };
  }

  factory HealthImportIdentity.fromJson(Map<String, Object?> json) {
    final externalId = _readRequiredString(json, 'externalId');
    _validateNonBlank(externalId, 'externalId');
    return HealthImportIdentity(
      platform: HealthSourcePlatform.fromKey(
        _readRequiredString(json, 'platform'),
      ),
      externalId: externalId,
    );
  }
}

/// Source provenance retained for an imported health sample or tombstone.
///
/// The normalized sample carries its observed interval. This object records
/// why the sample exists: the platform record identity, the source app/device,
/// recording method, and optional platform revision. Values are local-only
/// restricted metadata and must not appear in logs, exports, or UI by default.
class HealthSampleProvenance {
  const HealthSampleProvenance({
    required this.identity,
    this.sourceApplicationId,
    this.sourceName,
    this.sourceDevice,
    this.sourceDeviceModel,
    this.recordingMethod = HealthRecordingMethod.unknown,
    this.sourceRevision,
    this.isDeleted = false,
  });

  /// Stable identity used to reconcile repeated imports.
  final HealthImportIdentity identity;

  /// Source bundle identifier (Apple) or package name (Android), if supplied.
  final String? sourceApplicationId;

  /// Source application or device name, if supplied by the platform.
  final String? sourceName;

  /// Source device identifier or display name, if supplied by the platform.
  final String? sourceDevice;

  /// Source device model, if supplied by the platform.
  final String? sourceDeviceModel;

  /// Whether the source describes the record as automatic, manual, or unknown.
  final HealthRecordingMethod recordingMethod;

  /// Opaque source-side revision token, if supplied by the platform.
  final String? sourceRevision;

  /// Whether this provenance represents a source deletion tombstone.
  final bool isDeleted;

  Map<String, Object?> toJson() {
    _validateOptionalNonBlank(sourceApplicationId, 'sourceApplicationId');
    _validateOptionalNonBlank(sourceName, 'sourceName');
    _validateOptionalNonBlank(sourceDevice, 'sourceDevice');
    _validateOptionalNonBlank(sourceDeviceModel, 'sourceDeviceModel');
    _validateOptionalNonBlank(sourceRevision, 'sourceRevision');
    return <String, Object?>{
      'identity': identity.toJson(),
      'sourceApplicationId': sourceApplicationId,
      'sourceName': sourceName,
      'sourceDevice': sourceDevice,
      'sourceDeviceModel': sourceDeviceModel,
      'recordingMethod': recordingMethod.key,
      'sourceRevision': sourceRevision,
      'isDeleted': isDeleted,
    };
  }

  factory HealthSampleProvenance.fromJson(Map<String, Object?> json) {
    final identityValue = json['identity'];
    if (identityValue is! Map) {
      throw const FormatException('identity must be an object');
    }
    final deleted = json['isDeleted'];
    if (deleted != null && deleted is! bool) {
      throw const FormatException('isDeleted must be a bool or null');
    }
    return HealthSampleProvenance(
      identity: HealthImportIdentity.fromJson(
        Map<String, Object?>.from(identityValue),
      ),
      sourceApplicationId: _readOptionalNonBlank(json, 'sourceApplicationId'),
      sourceName: _readOptionalNonBlank(json, 'sourceName'),
      sourceDevice: _readOptionalNonBlank(json, 'sourceDevice'),
      sourceDeviceModel: _readOptionalNonBlank(json, 'sourceDeviceModel'),
      recordingMethod: HealthRecordingMethod.fromKey(
        _readOptionalString(json, 'recordingMethod') ??
            HealthRecordingMethod.unknown.key,
      ),
      sourceRevision: _readOptionalNonBlank(json, 'sourceRevision'),
      isDeleted: deleted as bool? ?? false,
    );
  }
}

/// A deletion reported by a source platform during incremental import.
///
/// A source can report a deletion without returning the original interval or
/// values. This object preserves that deletion by identity, so it must not be
/// represented by a fabricated [ActivitySample], [SleepSample], or
/// [HeartRateSample].
class HealthImportTombstone {
  const HealthImportTombstone({required this.kind, required this.provenance});

  /// The table/domain type in which the deleted record would have appeared.
  final HealthSampleKind kind;

  /// Provenance with [HealthSampleProvenance.isDeleted] set to `true`.
  final HealthSampleProvenance provenance;

  Map<String, Object?> toJson() {
    if (!provenance.isDeleted) {
      throw const FormatException(
        'Tombstone provenance must be marked deleted',
      );
    }
    return <String, Object?>{
      'kind': kind.key,
      'provenance': provenance.toJson(),
    };
  }

  factory HealthImportTombstone.fromJson(Map<String, Object?> json) {
    final provenanceValue = json['provenance'];
    if (provenanceValue is! Map) {
      throw const FormatException('provenance must be an object');
    }
    final tombstone = HealthImportTombstone(
      kind: HealthSampleKind.fromKey(_readRequiredString(json, 'kind')),
      provenance: HealthSampleProvenance.fromJson(
        Map<String, Object?>.from(provenanceValue),
      ),
    );
    tombstone.toJson();
    return tombstone;
  }
}

/// A normalized imported sample family.
enum HealthSampleKind {
  activity,
  sleep,
  heartRate;

  /// Stable storage key.
  String get key => name;

  static HealthSampleKind fromKey(String? key) {
    for (final value in HealthSampleKind.values) {
      if (value.key == key) return value;
    }
    throw FormatException('Unsupported health sample kind: $key');
  }
}

/// The kind of an [ActivitySample].
enum ActivityType {
  /// Step count over the sample interval.
  steps,

  /// A discrete workout session.
  workout,

  /// Distance traveled.
  distance,

  /// Active energy burned.
  activeEnergy,

  /// Anything else.
  other;

  String get key => name;

  static ActivityType fromKey(String? key) {
    if (key == null) return ActivityType.other;
    for (final value in ActivityType.values) {
      if (value.name == key) return value;
    }
    return ActivityType.other;
  }
}

/// An imported activity sample: steps, workouts, distance, or active energy
/// over an interval. Sensor- and source-agnostic.
class ActivitySample implements TimelineEntry {
  const ActivitySample({
    required this.start,
    required this.end,
    required this.type,
    required this.source,
    this.steps,
    this.energyKcal,
    this.distanceMeters,
    this.workoutLabel,
    this.provenance,
  });

  /// Interval start.
  final DateTime start;

  /// Interval end (must be at or after [start]).
  final DateTime end;

  /// What this sample measures.
  final ActivityType type;

  /// Where this sample came from.
  final DataSource source;

  /// Step count, when applicable.
  final int? steps;

  /// Active energy burned in kilocalories, when applicable.
  final double? energyKcal;

  /// Distance covered in meters, when applicable.
  final double? distanceMeters;

  /// Free-text workout label (e.g. `'cycling'`), for [ActivityType.workout].
  final String? workoutLabel;

  /// Optional local-only import provenance.
  ///
  /// `null` preserves compatibility with manual and legacy samples. When
  /// present, [provenance.identity.platform] must match [source].
  final HealthSampleProvenance? provenance;

  /// Duration of the sample interval.
  Duration get duration => end.difference(start);

  @override
  DateTime get timelineTimestamp => start;

  @override
  TimelineEntryKind get timelineKind => TimelineEntryKind.activity;

  ActivitySample copyWith({
    DateTime? start,
    DateTime? end,
    ActivityType? type,
    DataSource? source,
    int? steps,
    double? energyKcal,
    double? distanceMeters,
    String? workoutLabel,
    HealthSampleProvenance? provenance,
  }) {
    return ActivitySample(
      start: start ?? this.start,
      end: end ?? this.end,
      type: type ?? this.type,
      source: source ?? this.source,
      steps: steps ?? this.steps,
      energyKcal: energyKcal ?? this.energyKcal,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      workoutLabel: workoutLabel ?? this.workoutLabel,
      provenance: provenance ?? this.provenance,
    );
  }

  Map<String, Object?> toJson() {
    _validateInterval(start, end);
    _validateActivityValues(
      type: type,
      steps: steps,
      energyKcal: energyKcal,
      distanceMeters: distanceMeters,
    );
    _validateSampleProvenance(source, provenance);
    return <String, Object?>{
      'formatVersion': _healthSampleFormatVersion,
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'type': type.key,
      'source': source.key,
      'steps': steps,
      'energyKcal': energyKcal,
      'distanceMeters': distanceMeters,
      'workoutLabel': workoutLabel,
      'provenance': provenance?.toJson(),
    };
  }

  factory ActivitySample.fromJson(Map<String, Object?> json) {
    final formatVersion = _readHealthSampleFormatVersion(json);
    final start = _readRequiredUtcDate(
      json,
      'start',
      formatVersion: formatVersion,
    );
    final end = _readRequiredUtcDate(json, 'end', formatVersion: formatVersion);
    final type = _readActivityType(json);
    final steps = _readOptionalNonNegativeInt(json, 'steps');
    final energyKcal = _readOptionalNonNegativeDouble(json, 'energyKcal');
    final distanceMeters = _readOptionalNonNegativeDouble(
      json,
      'distanceMeters',
    );
    _validateInterval(start, end);
    _validateActivityValues(
      type: type,
      steps: steps,
      energyKcal: energyKcal,
      distanceMeters: distanceMeters,
    );
    final source = _readDataSource(json);
    final provenance = _readOptionalProvenance(json);
    _validateSampleProvenance(source, provenance);
    return ActivitySample(
      start: start,
      end: end,
      type: type,
      source: source,
      steps: steps,
      energyKcal: energyKcal,
      distanceMeters: distanceMeters,
      workoutLabel: _readOptionalString(json, 'workoutLabel'),
      provenance: provenance,
    );
  }
}

/// A sleep stage classification over an interval.
enum SleepStage {
  awake,
  light,
  deep,
  rem,

  /// Asleep without a specific stage breakdown.
  asleep,
  inBed;

  String get key => name;

  static SleepStage fromKey(String? key) {
    if (key == null) return SleepStage.asleep;
    for (final value in SleepStage.values) {
      if (value.name == key) return value;
    }
    return SleepStage.asleep;
  }
}

/// An imported sleep sample: a single stage over an interval.
class SleepSample implements TimelineEntry {
  const SleepSample({
    required this.start,
    required this.end,
    required this.stage,
    required this.source,
    this.provenance,
  });

  /// Interval start.
  final DateTime start;

  /// Interval end (must be at or after [start]).
  final DateTime end;

  /// The sleep stage during this interval.
  final SleepStage stage;

  /// Where this sample came from.
  final DataSource source;

  /// Optional local-only import provenance.
  final HealthSampleProvenance? provenance;

  /// Duration of the sleep interval.
  Duration get duration => end.difference(start);

  @override
  DateTime get timelineTimestamp => start;

  @override
  TimelineEntryKind get timelineKind => TimelineEntryKind.sleep;

  SleepSample copyWith({
    DateTime? start,
    DateTime? end,
    SleepStage? stage,
    DataSource? source,
    HealthSampleProvenance? provenance,
  }) {
    return SleepSample(
      start: start ?? this.start,
      end: end ?? this.end,
      stage: stage ?? this.stage,
      source: source ?? this.source,
      provenance: provenance ?? this.provenance,
    );
  }

  Map<String, Object?> toJson() {
    _validateInterval(start, end);
    _validateSampleProvenance(source, provenance);
    return <String, Object?>{
      'formatVersion': _healthSampleFormatVersion,
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'stage': stage.key,
      'source': source.key,
      'provenance': provenance?.toJson(),
    };
  }

  factory SleepSample.fromJson(Map<String, Object?> json) {
    final formatVersion = _readHealthSampleFormatVersion(json);
    final start = _readRequiredUtcDate(
      json,
      'start',
      formatVersion: formatVersion,
    );
    final end = _readRequiredUtcDate(json, 'end', formatVersion: formatVersion);
    _validateInterval(start, end);
    final source = _readDataSource(json);
    final provenance = _readOptionalProvenance(json);
    _validateSampleProvenance(source, provenance);
    return SleepSample(
      start: start,
      end: end,
      stage: _readSleepStage(json),
      source: source,
      provenance: provenance,
    );
  }
}

/// An imported instantaneous heart-rate sample.
class HeartRateSample implements TimelineEntry {
  const HeartRateSample({
    required this.timestamp,
    required this.bpm,
    required this.source,
    this.provenance,
  });

  /// When the measurement was taken.
  final DateTime timestamp;

  /// Beats per minute.
  final double bpm;

  /// Where this sample came from.
  final DataSource source;

  /// Optional local-only import provenance.
  final HealthSampleProvenance? provenance;

  @override
  DateTime get timelineTimestamp => timestamp;

  @override
  TimelineEntryKind get timelineKind => TimelineEntryKind.heartRate;

  HeartRateSample copyWith({
    DateTime? timestamp,
    double? bpm,
    DataSource? source,
    HealthSampleProvenance? provenance,
  }) {
    return HeartRateSample(
      timestamp: timestamp ?? this.timestamp,
      bpm: bpm ?? this.bpm,
      source: source ?? this.source,
      provenance: provenance ?? this.provenance,
    );
  }

  Map<String, Object?> toJson() {
    _validatePositiveFiniteDouble(bpm, 'bpm');
    _validateSampleProvenance(source, provenance);
    return <String, Object?>{
      'formatVersion': _healthSampleFormatVersion,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'bpm': bpm,
      'source': source.key,
      'provenance': provenance?.toJson(),
    };
  }

  factory HeartRateSample.fromJson(Map<String, Object?> json) {
    final source = _readDataSource(json);
    final provenance = _readOptionalProvenance(json);
    _validateSampleProvenance(source, provenance);
    return HeartRateSample(
      timestamp: _readRequiredUtcDate(
        json,
        'timestamp',
        formatVersion: _readHealthSampleFormatVersion(json),
      ),
      bpm: _readRequiredPositiveDouble(json, 'bpm'),
      source: source,
      provenance: provenance,
    );
  }
}

const int _healthSampleFormatVersion = 1;

int _readHealthSampleFormatVersion(Map<String, Object?> json) {
  if (!json.containsKey('formatVersion')) return 0;
  final value = json['formatVersion'];
  if (value is int && (value == 0 || value == _healthSampleFormatVersion)) {
    return value;
  }
  throw FormatException('Unsupported health-sample formatVersion: $value');
}

String _readRequiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a String');
  return value;
}

String? _readOptionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a String or null');
  return value;
}

String? _readOptionalNonBlank(Map<String, Object?> json, String key) {
  final value = _readOptionalString(json, key);
  _validateOptionalNonBlank(value, key);
  return value;
}

HealthSampleProvenance? _readOptionalProvenance(Map<String, Object?> json) {
  final value = json['provenance'];
  if (value == null) return null;
  if (value is! Map) {
    throw const FormatException('provenance must be an object or null');
  }
  return HealthSampleProvenance.fromJson(Map<String, Object?>.from(value));
}

void _validateNonBlank(String value, String key) {
  if (value.trim().isEmpty) {
    throw FormatException('$key must not be blank');
  }
}

void _validateOptionalNonBlank(String? value, String key) {
  if (value != null) _validateNonBlank(value, key);
}

void _validateSampleProvenance(
  DataSource source,
  HealthSampleProvenance? provenance,
) {
  if (provenance == null) return;
  provenance.toJson();
  if (provenance.identity.platform.dataSource != source) {
    throw const FormatException(
      'provenance identity platform must match sample source',
    );
  }
}

int? _readOptionalNonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw FormatException('$key must be a non-negative integer or null');
  }
  return value;
}

double? _readOptionalNonNegativeDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num) throw FormatException('$key must be numeric or null');
  final result = value.toDouble();
  _validateOptionalNonNegativeDouble(result, key);
  return result;
}

void _validateOptionalNonNegativeDouble(double? value, String key) {
  if (value != null && (!value.isFinite || value < 0)) {
    throw FormatException('$key must be finite and non-negative');
  }
}

double _readRequiredPositiveDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num) throw FormatException('$key must be numeric');
  final result = value.toDouble();
  _validatePositiveFiniteDouble(result, key);
  return result;
}

void _validatePositiveFiniteDouble(double value, String key) {
  if (!value.isFinite || value <= 0) {
    throw FormatException('$key must be finite and greater than zero');
  }
}

ActivityType _readActivityType(Map<String, Object?> json) {
  final value = _readRequiredString(json, 'type');
  for (final type in ActivityType.values) {
    if (type.key == value) return type;
  }
  throw FormatException('Unsupported activity type: $value');
}

SleepStage _readSleepStage(Map<String, Object?> json) {
  final value = _readRequiredString(json, 'stage');
  for (final stage in SleepStage.values) {
    if (stage.key == value) return stage;
  }
  throw FormatException('Unsupported sleep stage: $value');
}

DataSource _readDataSource(Map<String, Object?> json) {
  final value = _readRequiredString(json, 'source');
  for (final source in DataSource.values) {
    if (source.key == value) return source;
  }
  throw FormatException('Unsupported data source: $value');
}

void _validateInterval(DateTime start, DateTime end) {
  if (end.isBefore(start)) {
    throw const FormatException('end must be at or after start');
  }
}

void _validateActivityValues({
  required ActivityType type,
  required int? steps,
  required double? energyKcal,
  required double? distanceMeters,
}) {
  if (steps != null && steps < 0) {
    throw const FormatException('steps must be non-negative');
  }
  _validateOptionalNonNegativeDouble(energyKcal, 'energyKcal');
  _validateOptionalNonNegativeDouble(distanceMeters, 'distanceMeters');
  if (type == ActivityType.steps && steps == null) {
    throw const FormatException('steps are required for a steps sample');
  }
  if (type == ActivityType.distance && distanceMeters == null) {
    throw const FormatException(
      'distanceMeters is required for a distance sample',
    );
  }
  if (type == ActivityType.activeEnergy && energyKcal == null) {
    throw const FormatException(
      'energyKcal is required for an active-energy sample',
    );
  }
}

DateTime _readRequiredUtcDate(
  Map<String, Object?> json,
  String key, {
  required int formatVersion,
}) {
  final value = _readRequiredString(json, key);
  final match = RegExp(
    r'^([+-]?\d{4,6})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
    r'(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})?$',
  ).firstMatch(value);
  if (match == null || (formatVersion == 1 && match.group(8) == null)) {
    throw FormatException('$key must be an ISO-8601 timestamp with a timezone');
  }

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  final zone = match.group(8);
  final zoneHour = zone == null || zone == 'Z'
      ? 0
      : int.parse(zone.substring(1, 3));
  final zoneMinute = zone == null || zone == 'Z'
      ? 0
      : int.parse(zone.substring(4, 6));
  final validDay =
      month >= 1 && month <= 12 && day >= 1 && day <= _daysInMonth(year, month);
  if (!validDay ||
      hour > 23 ||
      minute > 59 ||
      second > 59 ||
      zoneHour > 23 ||
      zoneMinute > 59) {
    throw FormatException('$key contains an invalid date or time');
  }

  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$key is not a valid timestamp');
  return parsed.toUtc();
}

int _daysInMonth(int year, int month) => switch (month) {
  2 when year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) => 29,
  2 => 28,
  4 || 6 || 9 || 11 => 30,
  _ => 31,
};
