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
  /// callers that explicitly want a best-effort classification.
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
  /// Returns `null` for a `null` payload and throws a [FormatException] for an
  /// unrecognized or malformed payload.
  static HealthEventPayload? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    return switch (json['kind']) {
      'meal' => MealPayload.fromJson(json),
      'exercise' => ExercisePayload.fromJson(json),
      'note' => NotePayload.fromJson(json),
      'dose' => DosePayload.fromJson(json),
      _ => throw const FormatException('Unsupported health-event payload'),
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
  Map<String, Object?> toJson() {
    _validateOptionalNonNegativeDouble(carbsGrams, 'carbsGrams');
    _validateOptionalNonNegativeDouble(proteinGrams, 'proteinGrams');
    _validateOptionalNonNegativeDouble(fatGrams, 'fatGrams');
    _validateOptionalNonNegativeDouble(caloriesKcal, 'caloriesKcal');
    return <String, Object?>{
      'kind': kind,
      'carbsGrams': carbsGrams,
      'proteinGrams': proteinGrams,
      'fatGrams': fatGrams,
      'caloriesKcal': caloriesKcal,
      'description': description,
    };
  }

  factory MealPayload.fromJson(Map<String, Object?> json) {
    return MealPayload(
      carbsGrams: _readOptionalNonNegativeDouble(json, 'carbsGrams'),
      proteinGrams: _readOptionalNonNegativeDouble(json, 'proteinGrams'),
      fatGrams: _readOptionalNonNegativeDouble(json, 'fatGrams'),
      caloriesKcal: _readOptionalNonNegativeDouble(json, 'caloriesKcal'),
      description: _readOptionalString(json, 'description'),
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
  Map<String, Object?> toJson() {
    if (duration != null && duration!.isNegative) {
      throw const FormatException('durationMs must not be negative');
    }
    _validateOptionalNonNegativeDouble(energyKcal, 'energyKcal');
    return <String, Object?>{
      'kind': kind,
      'activity': activity,
      'durationMs': duration?.inMilliseconds,
      'intensity': intensity?.key,
      'energyKcal': energyKcal,
    };
  }

  factory ExercisePayload.fromJson(Map<String, Object?> json) {
    final durationMs = _readOptionalNonNegativeInt(json, 'durationMs');
    return ExercisePayload(
      activity: _readOptionalString(json, 'activity'),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      intensity: _readOptionalExerciseIntensity(json, 'intensity'),
      energyKcal: _readOptionalNonNegativeDouble(json, 'energyKcal'),
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
    return NotePayload(text: _readRequiredString(json, 'text'));
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
  Map<String, Object?> toJson() {
    _validateOptionalNonNegativeDouble(amount, 'amount');
    return <String, Object?>{
      'kind': kind,
      'name': name,
      'amount': amount,
      'unit': unit,
    };
  }

  factory DosePayload.fromJson(Map<String, Object?> json) {
    return DosePayload(
      name: _readOptionalString(json, 'name'),
      amount: _readOptionalNonNegativeDouble(json, 'amount'),
      unit: _readOptionalString(json, 'unit'),
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

  Map<String, Object?> toJson() {
    if (id.isEmpty) {
      throw const FormatException('id must not be empty');
    }
    _validatePayloadCompatibility(type, payload);
    return <String, Object?>{
      'formatVersion': _healthEventFormatVersion,
      'id': id,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'type': type.key,
      'payload': payload?.toJson(),
      'tags': tags,
      'source': source.key,
    };
  }

  factory HealthEvent.fromJson(Map<String, Object?> json) {
    final formatVersion = _readHealthEventFormatVersion(json);
    final type = _readHealthEventType(json);
    final payload = _readPayload(json);
    _validatePayloadCompatibility(type, payload);
    return HealthEvent(
      id: _readRequiredString(json, 'id', nonEmpty: true),
      timestamp: _readRequiredUtcDate(
        json,
        'timestamp',
        formatVersion: formatVersion,
      ),
      type: type,
      payload: payload,
      tags: _readTags(json),
      source: _readDataSource(json),
    );
  }
}

const int _healthEventFormatVersion = 1;

int _readHealthEventFormatVersion(Map<String, Object?> json) {
  if (!json.containsKey('formatVersion')) return 0;
  final value = json['formatVersion'];
  if (value is int && (value == 0 || value == _healthEventFormatVersion)) {
    return value;
  }
  throw FormatException('Unsupported health-event formatVersion: $value');
}

String _readRequiredString(
  Map<String, Object?> json,
  String key, {
  bool nonEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (nonEmpty && value.isEmpty)) {
    throw FormatException(
      '$key must be ${nonEmpty ? 'a non-empty ' : ''}String',
    );
  }
  return value;
}

String? _readOptionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a String or null');
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

int? _readOptionalNonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw FormatException('$key must be a non-negative integer or null');
  }
  return value;
}

ExerciseIntensity? _readOptionalExerciseIntensity(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a String or null');
  for (final intensity in ExerciseIntensity.values) {
    if (intensity.key == value) return intensity;
  }
  throw FormatException('Unsupported exercise intensity: $value');
}

HealthEventType _readHealthEventType(Map<String, Object?> json) {
  final value = _readRequiredString(json, 'type');
  for (final type in HealthEventType.values) {
    if (type.key == value) return type;
  }
  throw FormatException('Unsupported health-event type: $value');
}

DataSource _readDataSource(Map<String, Object?> json) {
  final value = _readRequiredString(json, 'source');
  for (final source in DataSource.values) {
    if (source.key == value) return source;
  }
  throw FormatException('Unsupported data source: $value');
}

HealthEventPayload? _readPayload(Map<String, Object?> json) {
  final value = json['payload'];
  if (value == null) return null;
  if (value is! Map<String, Object?>) {
    throw const FormatException('payload must be an object or null');
  }
  return HealthEventPayload.fromJson(value);
}

List<String> _readTags(Map<String, Object?> json) {
  final value = json['tags'];
  if (value == null) return const <String>[];
  if (value is! List<Object?> || value.any((tag) => tag is! String)) {
    throw const FormatException('tags must be a list of strings');
  }
  return value.cast<String>().toList(growable: false);
}

void _validatePayloadCompatibility(
  HealthEventType type,
  HealthEventPayload? payload,
) {
  final isCompatible = switch (type) {
    HealthEventType.meal => payload == null || payload is MealPayload,
    HealthEventType.exercise => payload == null || payload is ExercisePayload,
    HealthEventType.note => payload == null || payload is NotePayload,
    HealthEventType.insulin ||
    HealthEventType.medication => payload == null || payload is DosePayload,
    HealthEventType.custom => payload == null,
  };
  if (!isCompatible) {
    throw FormatException(
      'Payload ${payload.runtimeType} is invalid for $type',
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
