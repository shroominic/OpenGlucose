import 'ai/ai_disclaimer.dart';
import 'observations.dart';
import 'timeline.dart';

/// The category of an [AiInsight].
///
/// Drives how the insight is rendered and lets callers filter the kinds of
/// AI-generated guidance they want to surface.
enum AiInsightCategory {
  /// A correlation the model spotted (e.g. "high-carb dinners spike you").
  pattern,

  /// A concrete, actionable suggestion.
  recommendation,

  /// A summary over a window (daily/weekly recap).
  summary,

  /// A flagged anomaly worth the user's attention.
  anomaly,

  /// Anything that does not fit the other categories.
  custom;

  /// Stable string key used for serialization.
  String get key => name;

  /// Parses an [AiInsightCategory] from its [key], falling back to [custom]
  /// for unknown or missing values so deserialization never throws.
  static AiInsightCategory fromKey(String? key) {
    if (key == null) return AiInsightCategory.custom;
    for (final value in AiInsightCategory.values) {
      if (value.name == key) return value;
    }
    return AiInsightCategory.custom;
  }
}

/// An AI-generated insight derived from the user's timeline (CGM readings,
/// events, and imported samples).
///
/// Insights are local-first artifacts: they are produced on-device (or by a
/// user-configured model) and persisted so the journal/AI surface can show a
/// history of guidance without recomputing it. The [window] records the span
/// of data the insight was derived from, so it can be re-anchored on the
/// timeline and invalidated when that span changes.
class AiInsight implements TimelineEntry {
  const AiInsight({
    required this.id,
    required this.createdAt,
    required this.category,
    required this.title,
    this.body = '',
    this.windowStart,
    this.windowEnd,
    this.confidence,
    this.model,
    this.tags = const <String>[],
    this.evidence = const <ObservationEvidence>[],
    this.safetyBoundary = AiDisclaimer.short,
  });

  /// Stable unique identifier (caller-supplied; e.g. a UUID).
  final String id;

  /// When the insight was generated.
  final DateTime createdAt;

  /// The category of insight.
  final AiInsightCategory category;

  /// Short headline shown in the UI.
  final String title;

  /// Optional longer explanation/body text.
  final String body;

  /// Start of the timeline window this insight was derived from, if any.
  final DateTime? windowStart;

  /// End of the timeline window this insight was derived from, if any.
  final DateTime? windowEnd;

  /// Optional model confidence in `[0, 1]`.
  final double? confidence;

  /// Optional identifier of the model that produced the insight.
  final String? model;

  /// Free-form tags for filtering and grouping.
  final List<String> tags;

  /// Typed local aggregates that support this insight.
  ///
  /// Generated insights always include at least one evidence item. Empty
  /// evidence remains accepted for backwards-compatible restoration of older
  /// persisted records; callers should gate newly rendered/generated output
  /// on [hasEvidence].
  final List<ObservationEvidence> evidence;

  /// Safety boundary persisted alongside model text so it cannot be separated
  /// from the wellness framing when an insight is exported or rendered later.
  final String safetyBoundary;

  bool get hasEvidence => evidence.isNotEmpty;

  bool get isWellnessBounded => safetyBoundary.trim().isNotEmpty;

  @override
  DateTime get timelineTimestamp => createdAt;

  @override
  TimelineEntryKind get timelineKind => TimelineEntryKind.aiInsight;

  AiInsight copyWith({
    String? id,
    DateTime? createdAt,
    AiInsightCategory? category,
    String? title,
    String? body,
    DateTime? windowStart,
    DateTime? windowEnd,
    double? confidence,
    String? model,
    List<String>? tags,
    List<ObservationEvidence>? evidence,
    String? safetyBoundary,
    bool clearWindow = false,
    bool clearConfidence = false,
    bool clearModel = false,
  }) {
    return AiInsight(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      category: category ?? this.category,
      title: title ?? this.title,
      body: body ?? this.body,
      windowStart: clearWindow ? null : (windowStart ?? this.windowStart),
      windowEnd: clearWindow ? null : (windowEnd ?? this.windowEnd),
      confidence: clearConfidence ? null : (confidence ?? this.confidence),
      model: clearModel ? null : (model ?? this.model),
      tags: tags ?? this.tags,
      evidence: evidence ?? this.evidence,
      safetyBoundary: safetyBoundary ?? this.safetyBoundary,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'category': category.key,
    'title': title,
    'body': body,
    'windowStart': windowStart?.toIso8601String(),
    'windowEnd': windowEnd?.toIso8601String(),
    'confidence': confidence,
    'model': model,
    'tags': tags,
    'evidence': evidence.map((item) => item.toJson()).toList(growable: false),
    'safetyBoundary': safetyBoundary,
  };

  factory AiInsight.fromJson(Map<String, Object?> json) {
    DateTime? parseOpt(Object? value) {
      if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
      return null;
    }

    final evidenceJson = json['evidence'];
    final evidence = evidenceJson is List
        ? evidenceJson
              .whereType<Map>()
              .map(
                (item) => ObservationEvidence.fromJson(
                  item.map((key, value) => MapEntry('$key', value)),
                ),
              )
              .toList(growable: false)
        : const <ObservationEvidence>[];
    return AiInsight(
      id: json['id'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      category: AiInsightCategory.fromKey(json['category'] as String?),
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      windowStart: parseOpt(json['windowStart']),
      windowEnd: parseOpt(json['windowEnd']),
      confidence: (json['confidence'] as num?)?.toDouble(),
      model: json['model'] as String?,
      tags: ((json['tags'] as List<dynamic>?) ?? const <dynamic>[])
          .map((value) => '$value')
          .toList(growable: false),
      evidence: evidence,
      safetyBoundary: json['safetyBoundary'] as String? ?? AiDisclaimer.short,
    );
  }
}
