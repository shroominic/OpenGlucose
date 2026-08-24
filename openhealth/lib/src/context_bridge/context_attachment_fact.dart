import 'package:cgm_core/cgm_core.dart';

/// A durable local fact that a manual diary entry was timed near one observed
/// glucose episode.
///
/// This is deliberately separate from `health_events` and its legacy JSON
/// format. It contains opaque local linkage keys and bounded timestamps only;
/// it stores no glucose values, raw packets, sensor identifiers, or external
/// platform identifiers. It does not say that the diary entry caused a rise.
class ContextAttachmentFact {
  const ContextAttachmentFact({
    required this.id,
    required this.journalEntryId,
    required this.candidateId,
    required this.calculationVersion,
    required this.episodeStart,
    required this.peakAt,
    required this.attachmentWindowStart,
    required this.attachmentWindowEnd,
    required this.occurredAt,
  });

  static const int formatVersion = 1;

  final String id;
  final String journalEntryId;
  final String candidateId;
  final String calculationVersion;
  final DateTime episodeStart;
  final DateTime peakAt;
  final DateTime attachmentWindowStart;
  final DateTime attachmentWindowEnd;
  final DateTime occurredAt;

  /// Validates and serializes the stable additive persistence contract.
  Map<String, Object?> toJson() {
    _validate();
    return <String, Object?>{
      'formatVersion': formatVersion,
      'id': id,
      'journalEntryId': journalEntryId,
      'candidateId': candidateId,
      'calculationVersion': calculationVersion,
      'episodeStart': episodeStart.toUtc().toIso8601String(),
      'peakAt': peakAt.toUtc().toIso8601String(),
      'attachmentWindowStart': attachmentWindowStart.toUtc().toIso8601String(),
      'attachmentWindowEnd': attachmentWindowEnd.toUtc().toIso8601String(),
      'occurredAt': occurredAt.toUtc().toIso8601String(),
    };
  }

  factory ContextAttachmentFact.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json);
    final version = json['formatVersion'];
    if (version is! int || version != formatVersion) {
      throw FormatException('Unsupported context attachment format: $version');
    }
    final result = ContextAttachmentFact(
      id: _requiredString(json, 'id'),
      journalEntryId: _requiredString(json, 'journalEntryId'),
      candidateId: _requiredString(json, 'candidateId'),
      calculationVersion: _requiredString(json, 'calculationVersion'),
      episodeStart: _requiredUtcDate(json, 'episodeStart'),
      peakAt: _requiredUtcDate(json, 'peakAt'),
      attachmentWindowStart: _requiredUtcDate(json, 'attachmentWindowStart'),
      attachmentWindowEnd: _requiredUtcDate(json, 'attachmentWindowEnd'),
      occurredAt: _requiredUtcDate(json, 'occurredAt'),
    );
    result._validate();
    return result;
  }

  void _validate() {
    for (final value in <String>[
      id,
      journalEntryId,
      candidateId,
      calculationVersion,
    ]) {
      if (value.trim().isEmpty) {
        throw const FormatException(
          'Context attachment identifiers must not be blank.',
        );
      }
    }
    final start = attachmentWindowStart.toUtc();
    final episode = episodeStart.toUtc();
    final peak = peakAt.toUtc();
    final end = attachmentWindowEnd.toUtc();
    final occurred = occurredAt.toUtc();
    if (episode.isBefore(start) ||
        peak.isBefore(episode) ||
        end.isBefore(peak)) {
      throw const FormatException(
        'Context attachment episode is outside its bounded window.',
      );
    }
    if (occurred.isBefore(start) || occurred.isAfter(end)) {
      throw const FormatException(
        'Context attachment time is outside its bounded window.',
      );
    }
  }
}

/// Additive local persistence for [ContextAttachmentFact] records.
///
/// A repository implementation must retain the journal link and candidate key
/// locally. Consumers use a bounded query; this is not a cloud-sync contract.
abstract interface class ContextAttachmentFactStore {
  Future<void> saveContextAttachmentFact(ContextAttachmentFact fact);

  Future<List<ContextAttachmentFact>> queryContextAttachmentFacts({
    TimeWindow window = TimeWindow.all,
    String? candidateId,
  });
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty String');
  }
  return value;
}

DateTime _requiredUtcDate(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    throw FormatException('$key must be an ISO-8601 timestamp with a timezone');
  }
  return parsed.toUtc();
}

void _requireExactKeys(Map<String, Object?> json) {
  const expected = <String>{
    'formatVersion',
    'id',
    'journalEntryId',
    'candidateId',
    'calculationVersion',
    'episodeStart',
    'peakAt',
    'attachmentWindowStart',
    'attachmentWindowEnd',
    'occurredAt',
  };
  if (json.length != expected.length ||
      json.keys.any((key) => !expected.contains(key))) {
    throw const FormatException('Unsupported context attachment fields');
  }
}
