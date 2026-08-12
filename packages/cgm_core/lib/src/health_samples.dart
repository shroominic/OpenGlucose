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

  Map<String, Object?> toJson() => <String, Object?>{
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'type': type.key,
    'source': source.key,
    'steps': steps,
    'energyKcal': energyKcal,
    'distanceMeters': distanceMeters,
    'workoutLabel': workoutLabel,
  };

  factory ActivitySample.fromJson(Map<String, Object?> json) {
    final start = _parseDate(json['start']);
    return ActivitySample(
      start: start,
      end: _parseDate(json['end'], fallback: start),
      type: ActivityType.fromKey(json['type'] as String?),
      source: DataSource.fromKey(json['source'] as String?),
      steps: (json['steps'] as num?)?.toInt(),
      energyKcal: (json['energyKcal'] as num?)?.toDouble(),
      distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
      workoutLabel: json['workoutLabel'] as String?,
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

  Map<String, Object?> toJson() => <String, Object?>{
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'stage': stage.key,
    'source': source.key,
  };

  factory SleepSample.fromJson(Map<String, Object?> json) {
    final start = _parseDate(json['start']);
    return SleepSample(
      start: start,
      end: _parseDate(json['end'], fallback: start),
      stage: SleepStage.fromKey(json['stage'] as String?),
      source: DataSource.fromKey(json['source'] as String?),
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

  Map<String, Object?> toJson() => <String, Object?>{
    'timestamp': timestamp.toIso8601String(),
    'bpm': bpm,
    'source': source.key,
  };

  factory HeartRateSample.fromJson(Map<String, Object?> json) {
    return HeartRateSample(
      timestamp: _parseDate(json['timestamp']),
      bpm: (json['bpm'] as num?)?.toDouble() ?? 0,
      source: DataSource.fromKey(json['source'] as String?),
    );
  }
}

/// Parses an ISO-8601 date value, falling back to [fallback] (or the Unix
/// epoch in UTC) so deserialization never throws on bad/missing input.
DateTime _parseDate(Object? value, {DateTime? fallback}) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  return fallback ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
