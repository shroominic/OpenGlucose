import 'dart:convert';
import 'dart:math' as math;

import 'ai_provider.dart';
import 'glucose_summary.dart';

/// The versioned wire contract between OpenGlucose and an AI provider.
const int aiObservationContractVersion = 1;

/// The version of the local prompt template used for reproducibility.
const String aiPromptTemplateVersion = 'observation-evidence-v1';

/// A class of aggregate data that may leave the device after explicit consent.
enum AiDataCategory {
  contextWindow,
  glucoseAggregates,
  journalEventCounts,
  journalCarbohydrateAggregate;

  String get label => switch (this) {
    AiDataCategory.contextWindow => 'time window',
    AiDataCategory.glucoseAggregates => 'aggregate glucose statistics',
    AiDataCategory.journalEventCounts => 'journal event counts',
    AiDataCategory.journalCarbohydrateAggregate => 'total logged carbohydrates',
  };
}

/// The deterministic analytics source of an [EvidenceRef].
enum AiEvidenceKind { glucoseAggregate, journalAggregate }

/// A deterministic value that can ground an AI observation.
///
/// No raw glucose records, free-text journal content, identifiers, or API keys
/// are represented by this contract.
class EvidenceRef {
  const EvidenceRef({
    required this.id,
    required this.kind,
    required this.label,
    required this.value,
    required this.unit,
    required this.windowStart,
    required this.windowEnd,
    required this.sampleCount,
  });

  final String id;
  final AiEvidenceKind kind;
  final String label;
  final num value;
  final String unit;
  final DateTime windowStart;
  final DateTime windowEnd;
  final int sampleCount;

  String? get validationError {
    if (!RegExp(r'^[a-z][a-z0-9._-]{2,80}$').hasMatch(id)) {
      return 'Evidence IDs must use stable lowercase dotted identifiers.';
    }
    if (label.trim().isEmpty || label.length > 120) {
      return 'Evidence labels must be present and bounded.';
    }
    if (!value.isFinite) return 'Evidence values must be finite.';
    if (unit.trim().isEmpty || unit.length > 32) {
      return 'Evidence units must be present and bounded.';
    }
    if (!windowEnd.isAfter(windowStart)) {
      return 'Evidence windows must have a positive duration.';
    }
    if (sampleCount < 0) return 'Evidence sample counts cannot be negative.';
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'label': label,
    'value': value,
    'unit': unit,
    'windowStart': windowStart.toIso8601String(),
    'windowEnd': windowEnd.toIso8601String(),
    'sampleCount': sampleCount,
  };

  factory EvidenceRef.fromJson(Map<String, Object?> json) {
    final value = json['value'];
    final start = DateTime.tryParse(json['windowStart'] as String? ?? '');
    final end = DateTime.tryParse(json['windowEnd'] as String? ?? '');
    if (value is! num || start == null || end == null) {
      throw const AiOutputValidationException(
        'Evidence did not match the OpenGlucose contract.',
      );
    }
    final kind = AiEvidenceKind.values.where(
      (candidate) => candidate.name == json['kind'],
    );
    if (kind.isEmpty) {
      throw const AiOutputValidationException(
        'Evidence did not identify a deterministic source.',
      );
    }
    final reference = EvidenceRef(
      id: json['id'] as String? ?? '',
      kind: kind.single,
      label: json['label'] as String? ?? '',
      value: value,
      unit: json['unit'] as String? ?? '',
      windowStart: start,
      windowEnd: end,
      sampleCount: json['sampleCount'] as int? ?? -1,
    );
    final error = reference.validationError;
    if (error != null) throw AiOutputValidationException(error);
    return reference;
  }
}

/// A versioned, redacted context snapshot created from deterministic analytics.
class MetabolicContextSnapshot {
  const MetabolicContextSnapshot({
    required this.windowStart,
    required this.windowEnd,
    required this.locale,
    required this.evidence,
    this.formatVersion = aiObservationContractVersion,
  });

  final int formatVersion;
  final DateTime windowStart;
  final DateTime windowEnd;
  final String locale;
  final List<EvidenceRef> evidence;

  /// Exact categories this contract can send after the user confirms.
  List<AiDataCategory> get dataCategories {
    final categories = <AiDataCategory>[
      AiDataCategory.contextWindow,
      AiDataCategory.glucoseAggregates,
    ];
    if (evidence.any((item) => item.id.startsWith('journal.'))) {
      categories.add(AiDataCategory.journalEventCounts);
    }
    if (evidence.any((item) => item.id == 'journal.total_carbs_grams')) {
      categories.add(AiDataCategory.journalCarbohydrateAggregate);
    }
    return categories;
  }

  String? get validationError {
    if (formatVersion != aiObservationContractVersion) {
      return 'Unsupported metabolic context contract version.';
    }
    if (!windowEnd.isAfter(windowStart)) {
      return 'Metabolic context needs a positive time window.';
    }
    if (locale.trim().isEmpty || locale.length > 35) {
      return 'Metabolic context needs a bounded locale.';
    }
    if (evidence.isEmpty) {
      return 'Metabolic context needs deterministic evidence.';
    }
    final ids = <String>{};
    for (final item in evidence) {
      final error = item.validationError;
      if (error != null) return error;
      if (!ids.add(item.id)) return 'Metabolic context has duplicate evidence.';
      if (item.windowStart.isBefore(windowStart) ||
          item.windowEnd.isAfter(windowEnd)) {
        return 'Evidence must remain inside the supplied context window.';
      }
    }
    return null;
  }

  /// Creates aggregate evidence from the existing deterministic summary layer.
  factory MetabolicContextSnapshot.fromGlucoseSummary(
    GlucoseSummary summary, {
    String locale = 'en',
  }) {
    final start = summary.windowStart;
    final end = summary.windowEnd;
    final glucoseUnit = summary.unit.label;
    final evidence = <EvidenceRef>[
      EvidenceRef(
        id: 'glucose.reading_count',
        kind: AiEvidenceKind.glucoseAggregate,
        label: 'Glucose reading count',
        value: summary.readingCount,
        unit: 'readings',
        windowStart: start,
        windowEnd: end,
        sampleCount: summary.readingCount,
      ),
      if (summary.average != null)
        EvidenceRef(
          id: 'glucose.average',
          kind: AiEvidenceKind.glucoseAggregate,
          label: 'Average glucose',
          value: summary.average!,
          unit: glucoseUnit,
          windowStart: start,
          windowEnd: end,
          sampleCount: summary.readingCount,
        ),
      if (summary.minimum != null)
        EvidenceRef(
          id: 'glucose.minimum',
          kind: AiEvidenceKind.glucoseAggregate,
          label: 'Minimum glucose',
          value: summary.minimum!,
          unit: glucoseUnit,
          windowStart: start,
          windowEnd: end,
          sampleCount: summary.readingCount,
        ),
      if (summary.maximum != null)
        EvidenceRef(
          id: 'glucose.maximum',
          kind: AiEvidenceKind.glucoseAggregate,
          label: 'Maximum glucose',
          value: summary.maximum!,
          unit: glucoseUnit,
          windowStart: start,
          windowEnd: end,
          sampleCount: summary.readingCount,
        ),
      if (summary.standardDeviation != null)
        EvidenceRef(
          id: 'glucose.standard_deviation',
          kind: AiEvidenceKind.glucoseAggregate,
          label: 'Glucose standard deviation',
          value: summary.standardDeviation!,
          unit: glucoseUnit,
          windowStart: start,
          windowEnd: end,
          sampleCount: summary.readingCount,
        ),
      if (summary.timeInRangePercent != null)
        EvidenceRef(
          id: 'glucose.time_in_range_percent',
          kind: AiEvidenceKind.glucoseAggregate,
          label: 'Time in configured range',
          value: summary.timeInRangePercent!,
          unit: 'percent',
          windowStart: start,
          windowEnd: end,
          sampleCount: summary.readingCount,
        ),
      if (summary.timeBelowRangePercent != null)
        EvidenceRef(
          id: 'glucose.time_below_range_percent',
          kind: AiEvidenceKind.glucoseAggregate,
          label: 'Time below configured range',
          value: summary.timeBelowRangePercent!,
          unit: 'percent',
          windowStart: start,
          windowEnd: end,
          sampleCount: summary.readingCount,
        ),
      if (summary.timeAboveRangePercent != null)
        EvidenceRef(
          id: 'glucose.time_above_range_percent',
          kind: AiEvidenceKind.glucoseAggregate,
          label: 'Time above configured range',
          value: summary.timeAboveRangePercent!,
          unit: 'percent',
          windowStart: start,
          windowEnd: end,
          sampleCount: summary.readingCount,
        ),
      EvidenceRef(
        id: 'journal.meal_count',
        kind: AiEvidenceKind.journalAggregate,
        label: 'Logged meal count',
        value: summary.mealCount,
        unit: 'events',
        windowStart: start,
        windowEnd: end,
        sampleCount: summary.mealCount,
      ),
      EvidenceRef(
        id: 'journal.exercise_count',
        kind: AiEvidenceKind.journalAggregate,
        label: 'Logged exercise count',
        value: summary.exerciseCount,
        unit: 'events',
        windowStart: start,
        windowEnd: end,
        sampleCount: summary.exerciseCount,
      ),
      EvidenceRef(
        id: 'journal.note_count',
        kind: AiEvidenceKind.journalAggregate,
        label: 'Logged note count',
        value: summary.noteCount,
        unit: 'events',
        windowStart: start,
        windowEnd: end,
        sampleCount: summary.noteCount,
      ),
      if (summary.totalCarbsGrams != null)
        EvidenceRef(
          id: 'journal.total_carbs_grams',
          kind: AiEvidenceKind.journalAggregate,
          label: 'Total logged carbohydrates',
          value: summary.totalCarbsGrams!,
          unit: 'g',
          windowStart: start,
          windowEnd: end,
          sampleCount: summary.mealCount,
        ),
    ];
    return MetabolicContextSnapshot(
      windowStart: start,
      windowEnd: end,
      locale: locale,
      evidence: evidence,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': formatVersion,
    'windowStart': windowStart.toIso8601String(),
    'windowEnd': windowEnd.toIso8601String(),
    'locale': locale,
    'evidence': evidence.map((item) => item.toJson()).toList(growable: false),
  };

  /// Canonical prompt payload. It contains only aggregate deterministic data.
  String encodeForPrompt() => jsonEncode(toJson());
}

/// A numeric assertion inside an observation sentence.
class AiNumericClaim {
  const AiNumericClaim({
    required this.evidenceId,
    required this.value,
    required this.unit,
  });

  final String evidenceId;
  final num value;
  final String unit;

  Map<String, Object?> toJson() => <String, Object?>{
    'evidenceId': evidenceId,
    'value': value,
    'unit': unit,
  };

  factory AiNumericClaim.fromJson(Map<String, Object?> json) {
    final value = json['value'];
    if (value is! num) {
      throw const AiOutputValidationException(
        'AI numeric claims must contain a number.',
      );
    }
    return AiNumericClaim(
      evidenceId: json['evidenceId'] as String? ?? '',
      value: value,
      unit: json['unit'] as String? ?? '',
    );
  }
}

/// A single, evidence-bound wellness statement.
class ObservationStatement {
  const ObservationStatement({
    required this.text,
    required this.evidenceIds,
    this.numericClaims = const <AiNumericClaim>[],
  });

  final String text;
  final List<String> evidenceIds;
  final List<AiNumericClaim> numericClaims;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'evidenceIds': evidenceIds,
    'numericClaims': numericClaims
        .map((claim) => claim.toJson())
        .toList(growable: false),
  };

  factory ObservationStatement.fromJson(Map<String, Object?> json) {
    final ids = json['evidenceIds'];
    final claims = json['numericClaims'];
    if (ids is! List || claims != null && claims is! List) {
      throw const AiOutputValidationException(
        'AI statements must contain evidence IDs and numeric claims.',
      );
    }
    return ObservationStatement(
      text: json['text'] as String? ?? '',
      evidenceIds: ids.map((value) => '$value').toList(growable: false),
      numericClaims: (claims as List? ?? const <Object?>[])
          .map((item) {
            if (item is! Map) {
              throw const AiOutputValidationException(
                'AI numeric claims must be JSON objects.',
              );
            }
            return AiNumericClaim.fromJson(
              item.map<String, Object?>(
                (key, value) => MapEntry('$key', value),
              ),
            );
          })
          .toList(growable: false),
    );
  }
}

/// The only two model responses accepted by the observation contract.
enum ObservationDraftKind { observation, refusal }

/// Typed model output. Free-form prose is never persisted as an AI insight.
class ObservationDraft {
  const ObservationDraft.observation({
    required this.statements,
    this.formatVersion = aiObservationContractVersion,
  }) : kind = ObservationDraftKind.observation,
       refusalReason = null;

  const ObservationDraft.refusal({
    required this.refusalReason,
    this.formatVersion = aiObservationContractVersion,
  }) : kind = ObservationDraftKind.refusal,
       statements = const <ObservationStatement>[];

  final int formatVersion;
  final ObservationDraftKind kind;
  final List<ObservationStatement> statements;
  final String? refusalReason;

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': formatVersion,
    'kind': kind.name,
    if (kind == ObservationDraftKind.observation)
      'statements': statements
          .map((statement) => statement.toJson())
          .toList(growable: false),
    if (kind == ObservationDraftKind.refusal) 'refusalReason': refusalReason,
  };

  factory ObservationDraft.decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error) {
      throw AiOutputValidationException(
        'AI response did not use the required structured contract.',
        cause: error,
      );
    }
    if (decoded is! Map) {
      throw const AiOutputValidationException(
        'AI response did not use a JSON object.',
      );
    }
    final json = decoded.map<String, Object?>(
      (key, value) => MapEntry('$key', value),
    );
    final version = json['formatVersion'];
    final kind = json['kind'];
    if (version is! int || kind is! String) {
      throw const AiOutputValidationException(
        'AI response omitted a contract version or response kind.',
      );
    }
    if (kind == ObservationDraftKind.observation.name) {
      final statements = json['statements'];
      if (statements is! List) {
        throw const AiOutputValidationException(
          'AI observation omitted its statements.',
        );
      }
      return ObservationDraft.observation(
        formatVersion: version,
        statements: statements
            .map((item) {
              if (item is! Map) {
                throw const AiOutputValidationException(
                  'AI statements must be JSON objects.',
                );
              }
              return ObservationStatement.fromJson(
                item.map<String, Object?>(
                  (key, value) => MapEntry('$key', value),
                ),
              );
            })
            .toList(growable: false),
      );
    }
    if (kind == ObservationDraftKind.refusal.name) {
      final reason = json['refusalReason'];
      if (reason is! String) {
        throw const AiOutputValidationException(
          'AI refusal omitted a safe reason code.',
        );
      }
      return ObservationDraft.refusal(
        formatVersion: version,
        refusalReason: reason,
      );
    }
    throw const AiOutputValidationException(
      'AI response used an unsupported response kind.',
    );
  }

  void validateAgainst(MetabolicContextSnapshot context) {
    final contextError = context.validationError;
    if (contextError != null) throw AiOutputValidationException(contextError);
    if (formatVersion != aiObservationContractVersion) {
      throw const AiOutputValidationException(
        'AI response used an unsupported contract version.',
      );
    }
    if (kind == ObservationDraftKind.refusal) {
      if (!_safeRefusalReasons.contains(refusalReason) ||
          statements.isNotEmpty) {
        throw const AiOutputValidationException(
          'AI response used an unsupported refusal.',
        );
      }
      return;
    }
    if (statements.isEmpty || statements.length > 4) {
      throw const AiOutputValidationException(
        'AI observations must contain between one and four statements.',
      );
    }
    final evidenceById = <String, EvidenceRef>{
      for (final item in context.evidence) item.id: item,
    };
    for (final statement in statements) {
      final safetyError = AiSafetyPolicy.validationError(statement.text);
      if (safetyError != null) throw AiOutputValidationException(safetyError);
      if (statement.evidenceIds.isEmpty) {
        throw const AiOutputValidationException(
          'Every AI statement needs deterministic evidence.',
        );
      }
      final statementEvidence = statement.evidenceIds.toSet();
      if (statementEvidence.length != statement.evidenceIds.length) {
        throw const AiOutputValidationException(
          'AI statements cannot repeat an evidence reference.',
        );
      }
      for (final id in statementEvidence) {
        if (!evidenceById.containsKey(id)) {
          throw const AiOutputValidationException(
            'AI statement cited unsupported evidence.',
          );
        }
      }
      for (final claim in statement.numericClaims) {
        final evidence = evidenceById[claim.evidenceId];
        if (evidence == null || !statementEvidence.contains(claim.evidenceId)) {
          throw const AiOutputValidationException(
            'AI numeric claim cited unsupported evidence.',
          );
        }
        if (claim.unit != evidence.unit ||
            !_sameNumber(claim.value, evidence.value)) {
          throw const AiOutputValidationException(
            'AI numeric claim did not match deterministic evidence.',
          );
        }
      }
      final claimedNumbers = statement.numericClaims
          .map((claim) => claim.value.toDouble())
          .toList(growable: false);
      for (final literal in _numbersIn(statement.text)) {
        if (!claimedNumbers.any((claim) => _sameNumber(literal, claim))) {
          throw const AiOutputValidationException(
            'AI statement contained an unsupported numeric claim.',
          );
        }
      }
    }
  }

  static const Set<String> _safeRefusalReasons = <String>{
    'insufficient_evidence',
    'safety_boundary',
    'provider_unavailable',
    'unsupported_request',
  };
}

/// Validates model outputs and builds the canonical evidence-only prompt.
abstract final class AiOutputContract {
  static const String promptContract =
      'Return only JSON matching OpenGlucose observation contract version 1. '
      'Use kind observation with one to four statements. Every statement needs '
      'evidenceIds from the supplied evidence. Every number in a statement '
      'needs numericClaims with the same evidenceId, value, and unit. Do not '
      'invent facts, causal claims, measurements, diagnoses, treatment, '
      'medication or insulin guidance, emergency guidance, or instructions. '
      'Use cautious wellness language. If no safe observation is possible, '
      'return kind refusal with one safe refusalReason. The payload has no raw '
      'readings or journal note text.';

  static ObservationDraft decodeAndValidate({
    required String response,
    required MetabolicContextSnapshot context,
  }) {
    final draft = ObservationDraft.decode(response);
    draft.validateAgainst(context);
    return draft;
  }

  static String buildPrompt(MetabolicContextSnapshot context) {
    final error = context.validationError;
    if (error != null) throw AiOutputValidationException(error);
    return (StringBuffer('Summarize evidence for self-experimentation only. ')
          ..write(promptContract)
          ..writeln()
          ..write(
            'Deterministic evidence payload follows. '
            'Do not use any other facts.',
          )
          ..writeln()
          ..write(context.encodeForPrompt()))
        .toString();
  }
}

/// Central policy for output and prompt-injection safety checks.
abstract final class AiSafetyPolicy {
  static final List<RegExp> _unsafePatterns = <RegExp>[
    RegExp(
      r'\b(?:take|inject|increase|decrease|adjust|change)\s+(?:your\s+)?'
      r'(?:insulin|medication|dose)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:diagnos(?:e|is|tic)|prescrib(?:e|ing)|treatment)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:you have|this means you have)\s+'
      r'(?:diabetes|hypoglyc(?:emia)?|hyperglyc(?:emia)?)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:call\s+911|go\s+to\s+(?:the\s+)?emergency\s+room)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:ignore|disregard)\s+(?:all\s+)?'
      r'(?:previous|prior)\s+(?:instructions|rules)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:system\s+prompt|developer\s+message|jailbreak)\b',
      caseSensitive: false,
    ),
  ];

  static String? validationError(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > 600) {
      return 'AI statements must be present and bounded.';
    }
    if (trimmed.contains(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'))) {
      return 'AI statements contained unsupported control characters.';
    }
    if (_unsafePatterns.any((pattern) => pattern.hasMatch(trimmed))) {
      return 'AI response did not meet the wellness safety contract.';
    }
    return null;
  }
}

/// Reproducibility metadata persisted beside a validated observation.
class AiGenerationProvenance {
  const AiGenerationProvenance({
    required this.contractVersion,
    required this.promptTemplateVersion,
    required this.providerKind,
    required this.executionLocation,
    required this.locale,
    required this.model,
    required this.modelVersion,
    required this.runtimeVersion,
    this.endpointHostname,
  });

  final int contractVersion;
  final String promptTemplateVersion;
  final AiProviderKind providerKind;
  final AiExecutionLocation executionLocation;
  final String locale;
  final String? model;
  final String? modelVersion;
  final String runtimeVersion;
  final String? endpointHostname;

  factory AiGenerationProvenance.fromCapability(
    AiProviderCapability capability, {
    String? endpointHostname,
  }) => AiGenerationProvenance(
    contractVersion: aiObservationContractVersion,
    promptTemplateVersion: aiPromptTemplateVersion,
    providerKind: capability.kind,
    executionLocation: capability.executionLocation,
    locale: capability.locale,
    model: capability.model,
    modelVersion: capability.modelVersion,
    runtimeVersion: capability.runtimeVersion,
    endpointHostname: endpointHostname,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'contractVersion': contractVersion,
    'promptTemplateVersion': promptTemplateVersion,
    'providerKind': providerKind.name,
    'executionLocation': executionLocation.name,
    'locale': locale,
    'model': model,
    'modelVersion': modelVersion,
    'runtimeVersion': runtimeVersion,
    'endpointHostname': endpointHostname,
  };

  factory AiGenerationProvenance.fromJson(Map<String, Object?> json) {
    T enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) {
      for (final value in values) {
        if (value.name == raw) return value;
      }
      return fallback;
    }

    return AiGenerationProvenance(
      contractVersion: json['contractVersion'] as int? ?? 0,
      promptTemplateVersion: json['promptTemplateVersion'] as String? ?? '',
      providerKind: enumValue(
        AiProviderKind.values,
        json['providerKind'],
        AiProviderKind.disabled,
      ),
      executionLocation: enumValue(
        AiExecutionLocation.values,
        json['executionLocation'],
        AiExecutionLocation.none,
      ),
      locale: json['locale'] as String? ?? 'und',
      model: json['model'] as String?,
      modelVersion: json['modelVersion'] as String?,
      runtimeVersion: json['runtimeVersion'] as String? ?? 'unknown',
      endpointHostname: json['endpointHostname'] as String?,
    );
  }
}

class AiOutputValidationException extends AiGenerationException {
  const AiOutputValidationException(super.message, {super.cause});
}

bool _sameNumber(num first, num second) {
  final delta = (first.toDouble() - second.toDouble()).abs();
  return delta <= math.max(0.001, second.abs() * 0.001);
}

Iterable<double> _numbersIn(String text) sync* {
  final pattern = RegExp(r'[-+]?(?:\d+(?:\.\d+)?|\.\d+)');
  for (final match in pattern.allMatches(text)) {
    final parsed = double.tryParse(match.group(0)!);
    if (parsed != null) yield parsed;
  }
}
