import 'package:cgm_core/cgm_core.dart';

/// A bridge-generated opaque identifier for one version of an observed-rise
/// candidate.
///
/// Candidate identity can change when the newest peak changes. It is retained
/// for local audit only; durable one-time claims must use
/// [ContextBridgeEpisodeKey] instead.
class ContextBridgeCandidateId {
  ContextBridgeCandidateId(String value)
    : value = _requireOpaqueLink(value, _candidatePattern, 'candidate ID'),
      isBridgeGenerated = true;

  const ContextBridgeCandidateId._legacy(this.value)
    : isBridgeGenerated = false;

  final String value;

  /// False only for a schema-four record read for migration compatibility.
  ///
  /// Legacy records do not contain a session-scoped episode key, so they are
  /// never accepted for a new one-time claim.
  final bool isBridgeGenerated;
}

/// A bridge-generated opaque key for one session-scoped observed episode.
///
/// The bridge derives this key only from its private active-session key and
/// the episode start. It intentionally excludes the mutable candidate peak.
class ContextBridgeEpisodeKey {
  ContextBridgeEpisodeKey(String value)
    : value = _requireOpaqueLink(value, _episodePattern, 'episode key'),
      isBridgeGenerated = true;

  const ContextBridgeEpisodeKey._legacy(this.value) : isBridgeGenerated = false;

  final String value;

  /// False only for a schema-four record read for migration compatibility.
  final bool isBridgeGenerated;
}

/// A durable local fact that a manual diary entry was timed near one observed
/// glucose episode.
///
/// This is deliberately separate from `health_events` and its legacy JSON
/// format. It contains opaque local linkage keys and bounded timestamps only;
/// it stores no glucose values, raw packets, sensor identifiers, or external
/// platform identifiers. It does not say that the diary entry caused a rise.
class ContextAttachmentFact {
  ContextAttachmentFact({
    required this.id,
    required this.journalEntryId,
    required this.candidateId,
    required this.episodeKey,
    required this.calculationVersion,
    required this.episodeStart,
    required this.peakAt,
    required this.attachmentWindowStart,
    required this.attachmentWindowEnd,
    required this.occurredAt,
  }) : _legacyFormat = false;

  ContextAttachmentFact._legacy({
    required this.id,
    required this.journalEntryId,
    required String candidateId,
    required this.calculationVersion,
    required this.episodeStart,
    required this.peakAt,
    required this.attachmentWindowStart,
    required this.attachmentWindowEnd,
    required this.occurredAt,
  }) : candidateId = ContextBridgeCandidateId._legacy(candidateId),
       // Schema-four facts lack the private session key required to derive a
       // valid episode key. Keep a non-claimable placeholder so callers can
       // still inspect or delete the row without fabricating session scope.
       episodeKey = ContextBridgeEpisodeKey._legacy(candidateId),
       _legacyFormat = true;

  /// Current strict additive attachment format.
  static const int formatVersion = 2;
  static const int _legacyFormatVersion = 1;

  final String id;
  final String journalEntryId;
  final ContextBridgeCandidateId candidateId;
  final ContextBridgeEpisodeKey episodeKey;
  final String calculationVersion;
  final DateTime episodeStart;
  final DateTime peakAt;
  final DateTime attachmentWindowStart;
  final DateTime attachmentWindowEnd;
  final DateTime occurredAt;
  final bool _legacyFormat;

  /// True only when this row carries the strict session-scoped episode key.
  bool get isStableEpisodeClaim =>
      !_legacyFormat &&
      candidateId.isBridgeGenerated &&
      episodeKey.isBridgeGenerated;

  /// Validates and serializes the additive persistence contract.
  Map<String, Object?> toJson() {
    if (_legacyFormat) return _toLegacyJson();
    _validateStable();
    return <String, Object?>{
      'formatVersion': formatVersion,
      'id': id,
      'journalEntryId': journalEntryId,
      'candidateId': candidateId.value,
      'episodeKey': episodeKey.value,
      'calculationVersion': calculationVersion,
      'episodeStart': episodeStart.toUtc().toIso8601String(),
      'peakAt': peakAt.toUtc().toIso8601String(),
      'attachmentWindowStart': attachmentWindowStart.toUtc().toIso8601String(),
      'attachmentWindowEnd': attachmentWindowEnd.toUtc().toIso8601String(),
      'occurredAt': occurredAt.toUtc().toIso8601String(),
    };
  }

  factory ContextAttachmentFact.fromJson(Map<String, Object?> json) {
    final version = json['formatVersion'];
    if (version == _legacyFormatVersion) {
      return ContextAttachmentFact._fromLegacyJson(json);
    }
    if (version != formatVersion) {
      throw FormatException('Unsupported context attachment format: $version');
    }
    _requireExactKeys(json, _currentFields);
    final result = ContextAttachmentFact(
      id: _requiredString(json, 'id'),
      journalEntryId: _requiredString(json, 'journalEntryId'),
      candidateId: ContextBridgeCandidateId(
        _requiredString(json, 'candidateId'),
      ),
      episodeKey: ContextBridgeEpisodeKey(_requiredString(json, 'episodeKey')),
      calculationVersion: _requiredString(json, 'calculationVersion'),
      episodeStart: _requiredUtcDate(json, 'episodeStart'),
      peakAt: _requiredUtcDate(json, 'peakAt'),
      attachmentWindowStart: _requiredUtcDate(json, 'attachmentWindowStart'),
      attachmentWindowEnd: _requiredUtcDate(json, 'attachmentWindowEnd'),
      occurredAt: _requiredUtcDate(json, 'occurredAt'),
    );
    result._validateStable();
    return result;
  }

  factory ContextAttachmentFact._fromLegacyJson(Map<String, Object?> json) {
    _requireExactKeys(json, _legacyFields);
    final result = ContextAttachmentFact._legacy(
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
    result._validateShared();
    return result;
  }

  Map<String, Object?> _toLegacyJson() {
    _validateShared();
    return <String, Object?>{
      'formatVersion': _legacyFormatVersion,
      'id': id,
      'journalEntryId': journalEntryId,
      'candidateId': candidateId.value,
      'calculationVersion': calculationVersion,
      'episodeStart': episodeStart.toUtc().toIso8601String(),
      'peakAt': peakAt.toUtc().toIso8601String(),
      'attachmentWindowStart': attachmentWindowStart.toUtc().toIso8601String(),
      'attachmentWindowEnd': attachmentWindowEnd.toUtc().toIso8601String(),
      'occurredAt': occurredAt.toUtc().toIso8601String(),
    };
  }

  void _validateStable() {
    if (!candidateId.isBridgeGenerated || !episodeKey.isBridgeGenerated) {
      throw const FormatException(
        'Context attachment links must be bridge-generated opaque identifiers.',
      );
    }
    _validateShared();
  }

  void _validateShared() {
    for (final value in <String>[id, journalEntryId, calculationVersion]) {
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
  /// Atomically claims [ContextAttachmentFact.episodeKey].
  ///
  /// Returns [fact] only when this call makes the first durable claim for the
  /// session-scoped episode. It returns null when a journal row or episode has
  /// already been claimed. An unrelated duplicate fact ID is a storage error,
  /// not a claimed episode. Implementations must make this decision in one
  /// transaction so concurrent presentation actions cannot create two facts.
  Future<ContextAttachmentFact?> claimContextAttachmentFact(
    ContextAttachmentFact fact,
  );

  Future<List<ContextAttachmentFact>> queryContextAttachmentFacts({
    TimeWindow window = TimeWindow.all,
    ContextBridgeEpisodeKey? episodeKey,
  });
}

const Set<String> _legacyFields = <String>{
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

const Set<String> _currentFields = <String>{
  'formatVersion',
  'id',
  'journalEntryId',
  'candidateId',
  'episodeKey',
  'calculationVersion',
  'episodeStart',
  'peakAt',
  'attachmentWindowStart',
  'attachmentWindowEnd',
  'occurredAt',
};

final RegExp _candidatePattern = RegExp(r'^ctx-candidate-[0-9a-f]{24}$');
final RegExp _episodePattern = RegExp(r'^ctx-episode-[0-9a-f]{24}$');

String _requireOpaqueLink(String value, RegExp pattern, String label) {
  if (!pattern.hasMatch(value)) {
    throw FormatException('Unsupported bridge-generated $label.');
  }
  return value;
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

void _requireExactKeys(Map<String, Object?> json, Set<String> expected) {
  if (json.length != expected.length ||
      json.keys.any((key) => !expected.contains(key))) {
    throw const FormatException('Unsupported context attachment fields');
  }
}
