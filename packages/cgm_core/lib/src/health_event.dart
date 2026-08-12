import 'timeline.dart';

/// The category of a [HealthEvent].
///
/// Drives both how the optional [HealthEvent.payload] is interpreted and how
/// the event is rendered in the journal/timeline UI.
enum HealthEventType {
  /// Food/drink intake — typically carries a [MealPayload].
  meal,

  /// Physical activity — typically carries an [ExercisePayload].
  exercise,

  /// A free-text note — typically carries a [NotePayload].
  note,

  /// Insulin dose — typically carries a [DosePayload].
  insulin,

  /// Non-insulin medication — typically carries a [DosePayload].
  medication,

  /// Anything that does not fit the other categories.
  custom;

  /// Stable string key used for serialization.
  String get key => name;

  /// Parses a [HealthEventType] from its [key], falling back to [custom] for
  /// unknown or missing values so deserialization never throws.
  static HealthEventType fromKey(String? key) {
    if (key == null) return HealthEventType.custom;
    for (final value in HealthEventType.values) {
      if (value.name == key) return value;
    }
    return HealthEventType.custom;
  }
}

/// Optional structured data attached to a [HealthEvent].
///
/// Each concrete subtype corresponds to a family of [HealthEventType]s. The
/// payload is serialized to a tagged JSON object (`{'kind': ..., ...}`) so it
/// can be round-tripped without losing its concrete type.
sealed class HealthEventPayload {
  const HealthEventPayload();

  /// Tag identifying the concrete payload kind in serialized form.
  String get kind;

  /// Serializes this payload to a JSON-compatible map, including its [kind].
  Map<String, Object?> toJson();

  /// Reconstructs a payload from its tagged JSON [json].
  ///
  /// Returns `null` for `null` or unrecognized payloads so an event with no
  /// (or future/unknown) payload deserializes cleanly.
  static HealthEventPayload? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    return switch (json['kind']) {
      'meal' => MealPayload.fromJson(json),
      'exercise' => ExercisePayload.fromJson(json),
      'note' => NotePayload.fromJson(json),
      'dose' => DosePayload.fromJson(json),
      _ => null,
    };
  }
}

/// Nutrition macros for a [HealthEventType.meal] event. All fields optional —
/// users may log only what they know.
class MealPayload extends HealthEventPayload {
  const MealPayload({
    this.carbsGrams,
    this.proteinGrams,
    this.fatGrams,
    this.caloriesKcal,
    this.description,
  });

  /// Carbohydrates in grams.
  final double? carbsGrams;

  /// Protein in grams.
  final double? proteinGrams;

  /// Fat in grams.
  final double? fatGrams;

  /// Total energy in kilocalories.
  final double? caloriesKcal;

  /// Free-text description of the meal.
  final String? description;

  @override
  String get kind => 'meal';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'carbsGrams': carbsGrams,
    'proteinGrams': proteinGrams,
    'fatGrams': fatGrams,
    'caloriesKcal': caloriesKcal,
    'description': description,
  };

  factory MealPayload.fromJson(Map<String, Object?> json) {
    return MealPayload(
      carbsGrams: (json['carbsGrams'] as num?)?.toDouble(),
      proteinGrams: (json['proteinGrams'] as num?)?.toDouble(),
      fatGrams: (json['fatGrams'] as num?)?.toDouble(),
      caloriesKcal: (json['caloriesKcal'] as num?)?.toDouble(),
      description: json['description'] as String?,
    );
  }
}

/// Subjective intensity of an [ExercisePayload].
enum ExerciseIntensity {
  light,
  moderate,
  vigorous;

  String get key => name;

  static ExerciseIntensity? fromKey(String? key) {
    if (key == null) return null;
    for (final value in ExerciseIntensity.values) {
      if (value.name == key) return value;
    }
    return null;
  }
}

/// Details for a [HealthEventType.exercise] event.
class ExercisePayload extends HealthEventPayload {
  const ExercisePayload({
    this.activity,
    this.duration,
    this.intensity,
    this.energyKcal,
  });

  /// Free-text activity label (e.g. `'running'`).
  final String? activity;

  /// How long the activity lasted.
  final Duration? duration;

  /// Subjective intensity.
  final ExerciseIntensity? intensity;

  /// Active energy burned in kilocalories.
  final double? energyKcal;

  @override
  String get kind => 'exercise';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'activity': activity,
    'durationMs': duration?.inMilliseconds,
    'intensity': intensity?.key,
    'energyKcal': energyKcal,
  };

  factory ExercisePayload.fromJson(Map<String, Object?> json) {
    final durationMs = (json['durationMs'] as num?)?.toInt();
    return ExercisePayload(
      activity: json['activity'] as String?,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      intensity: ExerciseIntensity.fromKey(json['intensity'] as String?),
      energyKcal: (json['energyKcal'] as num?)?.toDouble(),
    );
  }
}

/// A free-text note for a [HealthEventType.note] event.
class NotePayload extends HealthEventPayload {
  const NotePayload({required this.text});

  /// The note body.
  final String text;

  @override
  String get kind => 'note';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'text': text,
  };

  factory NotePayload.fromJson(Map<String, Object?> json) {
    return NotePayload(text: json['text'] as String? ?? '');
  }
}

/// A dose of insulin or medication for [HealthEventType.insulin] /
/// [HealthEventType.medication] events.
class DosePayload extends HealthEventPayload {
  const DosePayload({this.name, this.amount, this.unit});

  /// Name of the substance (e.g. `'metformin'`, `'rapid-acting'`).
  final String? name;

  /// Dose amount, in [unit].
  final double? amount;

  /// Unit of [amount] (e.g. `'U'`, `'mg'`).
  final String? unit;

  @override
  String get kind => 'dose';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'name': name,
    'amount': amount,
    'unit': unit,
  };

  factory DosePayload.fromJson(Map<String, Object?> json) {
    return DosePayload(
      name: json['name'] as String?,
      amount: (json['amount'] as num?)?.toDouble(),
      unit: json['unit'] as String?,
    );
  }
}

/// A normalized, user-authored or imported event on the health timeline.
///
/// This is the foundation the journaling feature builds on: meals, exercise,
/// notes, doses, and arbitrary custom entries all share this shape. Events are
/// fully serializable and slot onto the shared timeline alongside CGM readings
/// and imported samples via [TimelineEntry].
class HealthEvent implements TimelineEntry {
  const HealthEvent({
    required this.id,
    required this.timestamp,
    required this.type,
    this.payload,
    this.tags = const <String>[],
    this.source = DataSource.manual,
  });

  /// Stable unique identifier (caller-supplied; e.g. a UUID).
  final String id;

  /// When the event occurred.
  final DateTime timestamp;

  /// The category of event.
  final HealthEventType type;

  /// Optional structured details whose concrete type depends on [type].
  final HealthEventPayload? payload;

  /// Free-form tags for filtering and grouping.
  final List<String> tags;

  /// Where this event originated.
  final DataSource source;

  @override
  DateTime get timelineTimestamp => timestamp;

  @override
  TimelineEntryKind get timelineKind => TimelineEntryKind.event;

  HealthEvent copyWith({
    String? id,
    DateTime? timestamp,
    HealthEventType? type,
    HealthEventPayload? payload,
    List<String>? tags,
    DataSource? source,
    bool clearPayload = false,
  }) {
    return HealthEvent(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      type: type ?? this.type,
      payload: clearPayload ? null : (payload ?? this.payload),
      tags: tags ?? this.tags,
      source: source ?? this.source,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'type': type.key,
    'payload': payload?.toJson(),
    'tags': tags,
    'source': source.key,
  };

  factory HealthEvent.fromJson(Map<String, Object?> json) {
    return HealthEvent(
      id: json['id'] as String? ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      type: HealthEventType.fromKey(json['type'] as String?),
      payload: HealthEventPayload.fromJson(
        json['payload'] as Map<String, Object?>?,
      ),
      tags: ((json['tags'] as List<dynamic>?) ?? const <dynamic>[])
          .map((value) => '$value')
          .toList(growable: false),
      source: DataSource.fromKey(json['source'] as String?),
    );
  }
}
