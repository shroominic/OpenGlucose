import 'timeline.dart';

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
    return ActivitySample(
      start: start,
      end: end,
      type: type,
      source: _readDataSource(json),
      steps: steps,
      energyKcal: energyKcal,
      distanceMeters: distanceMeters,
      workoutLabel: _readOptionalString(json, 'workoutLabel'),
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
  });

  /// Interval start.
  final DateTime start;

  /// Interval end (must be at or after [start]).
  final DateTime end;

  /// The sleep stage during this interval.
  final SleepStage stage;

  /// Where this sample came from.
  final DataSource source;

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
  }) {
    return SleepSample(
      start: start ?? this.start,
      end: end ?? this.end,
      stage: stage ?? this.stage,
      source: source ?? this.source,
    );
  }

  Map<String, Object?> toJson() {
    _validateInterval(start, end);
    return <String, Object?>{
      'formatVersion': _healthSampleFormatVersion,
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'stage': stage.key,
      'source': source.key,
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
    return SleepSample(
      start: start,
      end: end,
      stage: _readSleepStage(json),
      source: _readDataSource(json),
    );
  }
}

/// An imported instantaneous heart-rate sample.
class HeartRateSample implements TimelineEntry {
  const HeartRateSample({
    required this.timestamp,
    required this.bpm,
    required this.source,
  });

  /// When the measurement was taken.
  final DateTime timestamp;

  /// Beats per minute.
  final double bpm;

  /// Where this sample came from.
  final DataSource source;

  @override
  DateTime get timelineTimestamp => timestamp;

  @override
  TimelineEntryKind get timelineKind => TimelineEntryKind.heartRate;

  HeartRateSample copyWith({
    DateTime? timestamp,
    double? bpm,
    DataSource? source,
  }) {
    return HeartRateSample(
      timestamp: timestamp ?? this.timestamp,
      bpm: bpm ?? this.bpm,
      source: source ?? this.source,
    );
  }

  Map<String, Object?> toJson() {
    _validatePositiveFiniteDouble(bpm, 'bpm');
    return <String, Object?>{
      'formatVersion': _healthSampleFormatVersion,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'bpm': bpm,
      'source': source.key,
    };
  }

  factory HeartRateSample.fromJson(Map<String, Object?> json) {
    return HeartRateSample(
      timestamp: _readRequiredUtcDate(
        json,
        'timestamp',
        formatVersion: _readHealthSampleFormatVersion(json),
      ),
      bpm: _readRequiredPositiveDouble(json, 'bpm'),
      source: _readDataSource(json),
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
