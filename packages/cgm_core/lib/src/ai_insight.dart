import 'ai/ai_output_contract.dart';
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

/// One rendered AI observation with its exact local evidence mapping.
///
/// [text] is rendered by OpenGlucose from validated structured claims. It is
/// persisted beside the source evidence so later views can show which numeric
/// values supported each individual statement rather than only a flattened
/// evidence list for the whole insight.
class AiInsightStatement {
  const AiInsightStatement({
    required this.text,
    required this.evidence,
    required this.numericClaims,
  });

  final String text;
  final List<EvidenceRef> evidence;
  final List<AiNumericClaim> numericClaims;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'evidence': evidence.map((item) => item.toJson()).toList(growable: false),
    'numericClaims': numericClaims
        .map((claim) => claim.toJson())
        .toList(growable: false),
  };

  factory AiInsightStatement.fromJson(Map<String, Object?> json) {
    final rawEvidence = json['evidence'];
    final rawClaims = json['numericClaims'];
    final text = json['text'];
    if (text is! String ||
        text.trim().isEmpty ||
        rawEvidence is! List ||
        rawClaims is! List) {
      throw const AiOutputValidationException(
        'Stored AI statement did not use a validated evidence mapping.',
      );
    }
    final evidence = <EvidenceRef>[];
    for (final item in rawEvidence) {
      if (item is! Map) {
        throw const AiOutputValidationException(
          'Stored AI statement did not use a validated evidence mapping.',
        );
      }
      evidence.add(
        EvidenceRef.fromJson(
          item.map<String, Object?>((key, value) => MapEntry('$key', value)),
        ),
      );
    }
    final claims = <AiNumericClaim>[];
    for (final item in rawClaims) {
      if (item is! Map) {
        throw const AiOutputValidationException(
          'Stored AI statement did not use a validated evidence mapping.',
        );
      }
      claims.add(
        AiNumericClaim.fromJson(
          item.map<String, Object?>((key, value) => MapEntry('$key', value)),
        ),
      );
    }
    if (evidence.length != 1 || claims.length != 1) {
      throw const AiOutputValidationException(
        'Stored AI statement did not use a validated evidence mapping.',
      );
    }
    final evidenceById = <String, EvidenceRef>{
      for (final item in evidence) item.id: item,
    };
    for (final claim in claims) {
      final source = evidenceById[claim.evidenceId];
      if (source == null ||
          source.unit != claim.unit ||
          !_sameNumericValue(source.value, claim.value)) {
        throw const AiOutputValidationException(
          'Stored AI statement did not use a validated evidence mapping.',
        );
      }
    }
    if (text != _renderStoredStatement(evidence.single)) {
      throw const AiOutputValidationException(
        'Stored AI statement did not use a validated evidence mapping.',
      );
    }
    return AiInsightStatement(
      text: text,
      evidence: evidence,
      numericClaims: claims,
    );
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
    this.evidence = const <EvidenceRef>[],
    this.statements = const <AiInsightStatement>[],
    this.provenance,
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

  /// Deterministic evidence that each persisted AI observation must cite.
  final List<EvidenceRef> evidence;

  /// Statement-level evidence and numeric mappings for validated AI output.
  final List<AiInsightStatement> statements;

  /// Prompt, provider, model, and runtime provenance for reproducibility.
  final AiGenerationProvenance? provenance;

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
    List<EvidenceRef>? evidence,
    List<AiInsightStatement>? statements,
    AiGenerationProvenance? provenance,
    bool clearWindow = false,
    bool clearConfidence = false,
    bool clearModel = false,
    bool clearProvenance = false,
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
      statements: statements ?? this.statements,
      provenance: clearProvenance ? null : (provenance ?? this.provenance),
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
    'statements': statements
        .map((statement) => statement.toJson())
        .toList(growable: false),
    'provenance': provenance?.toJson(),
  };

  factory AiInsight.fromJson(Map<String, Object?> json) {
    DateTime? parseOpt(Object? value) {
      if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
      return null;
    }

    List<EvidenceRef> parseEvidence(Object? value) {
      if (value is! List) return const <EvidenceRef>[];
      final evidence = <EvidenceRef>[];
      for (final item in value) {
        if (item is! Map) continue;
        try {
          evidence.add(
            EvidenceRef.fromJson(
              item.map<String, Object?>(
                (key, nestedValue) => MapEntry('$key', nestedValue),
              ),
            ),
          );
        } on AiOutputValidationException {
          // Legacy/corrupt records remain readable without pretending they
          // carry validated evidence.
        }
      }
      return evidence;
    }

    AiGenerationProvenance? parseProvenance(Object? value) {
      if (value is! Map) return null;
      return AiGenerationProvenance.fromJson(
        value.map<String, Object?>(
          (key, nestedValue) => MapEntry('$key', nestedValue),
        ),
      );
    }

    List<AiInsightStatement> parseStatements(Object? value) {
      if (value is! List) return const <AiInsightStatement>[];
      final statements = <AiInsightStatement>[];
      for (final item in value) {
        if (item is! Map) continue;
        try {
          statements.add(
            AiInsightStatement.fromJson(
              item.map<String, Object?>(
                (key, nestedValue) => MapEntry('$key', nestedValue),
              ),
            ),
          );
        } on AiOutputValidationException {
          // Corrupt statement mappings remain unreadable rather than being
          // shown as evidence-bound output.
        }
      }
      return statements;
    }

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
      evidence: parseEvidence(json['evidence']),
      statements: parseStatements(json['statements']),
      provenance: parseProvenance(json['provenance']),
    );
  }
}

bool _sameNumericValue(num left, num right) {
  final delta = (left.toDouble() - right.toDouble()).abs();
  return delta <= 0.000001;
}

String _renderStoredStatement(EvidenceRef evidence) =>
    'Recorded ${evidence.label.toLowerCase()}: '
    '${_formatStoredValue(evidence.value)} ${evidence.unit} in this window.';

String _formatStoredValue(num value) {
  if (value is int || value.toDouble() == value.toDouble().roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}
