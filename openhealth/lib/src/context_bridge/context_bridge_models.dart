import 'package:cgm_core/cgm_core.dart';

import 'context_attachment_fact.dart';

/// Lifecycle state for the app-owned local context cache.
///
/// This says only whether this bridge has assembled a local snapshot. It does
/// not describe platform permission, an import state, or a clinical finding.
enum ContextBridgeLoadState { idle, loading, ready, unavailable }

/// Availability of the active-sensor reading stream used by the bridge.
///
/// The bridge keeps display-safe final readings separate from eligibility for a
/// deterministic observed-rise candidate. A mixed source set can still be
/// source-labelled for a future reader surface, but it never qualifies a
/// candidate here.
enum ContextBridgeGlucoseAvailability {
  noActiveSession,
  noPostWarmupReadings,
  available,
}

/// Why the optional context-attachment suggestion is absent or available.
///
/// The statuses are data-quality and product-policy states. They never
/// identify a cause of a glucose change and must not be shown as medical
/// advice.
enum ContextBridgeSuggestionAvailability {
  /// The default: no product policy has opted in to suggestions.
  disabledByPolicy,

  noActiveSession,
  noEligibleReadings,
  invalidReading,
  unsupportedReadingSource,
  provisionalReading,
  futureReading,
  unprovenPostWarmupReading,
  duplicateTimestamp,
  mixedSources,
  notQualified,
  attachmentAlreadyRecorded,
  attachmentFactsUnavailable,
  available,
}

/// Honest local-cache state for context records in the requested range.
///
/// [noLocalRecords] does not mean that a platform permission was denied, a
/// source has no records, or an importer is enabled. This bridge never asks a
/// platform for data and cannot make those claims.
enum ContextBridgeContextAvailability {
  noLocalRecords,
  available,
  partial,
  unavailable,
}

/// The bounded time range held by a [ContextBridgeSnapshot].
///
/// [end] is inclusive for the snapshot. Repository callers translate it to a
/// half-open [TimeWindow] internally.
class ContextBridgeWindow {
  ContextBridgeWindow({required this.start, required this.end})
    : assert(!end.isBefore(start), 'end must not be before start');

  final DateTime start;
  final DateTime end;

  bool contains(DateTime instant) {
    final normalized = instant.toUtc();
    return !normalized.isBefore(start.toUtc()) &&
        !normalized.isAfter(end.toUtc());
  }

  bool intersects(DateTime intervalStart, DateTime intervalEnd) {
    final normalizedStart = intervalStart.toUtc();
    final normalizedEnd = intervalEnd.toUtc();
    return !normalizedEnd.isBefore(start.toUtc()) &&
        !normalizedStart.isAfter(end.toUtc());
  }
}

/// One display-safe active-sensor glucose reading.
///
/// [id] is a bridge-generated opaque identifier. It never contains a sensor
/// serial, Bluetooth address, raw packet, or external platform identifier.
class ContextBridgeReading {
  const ContextBridgeReading({
    required this.id,
    required this.recordedAt,
    required this.valueMgdl,
    required this.source,
  });

  final String id;
  final DateTime recordedAt;
  final double valueMgdl;
  final CgmRecordSource source;
}

/// Families of non-glucose context preserved in the local bridge snapshot.
enum ContextBridgeImportedKind { activity, sleep, heartRate }

/// One source-labelled imported item without platform provenance fields.
///
/// Imported platform IDs, source app/device metadata, and raw record payloads
/// remain in the local repository. The UI boundary receives only this opaque
/// ID, timing, normalized kind, and values that describe the user-visible
/// context item.
class ContextBridgeImportedItem {
  const ContextBridgeImportedItem({
    required this.id,
    required this.kind,
    required this.start,
    required this.end,
    required this.source,
    this.activityType,
    this.sleepStage,
    this.heartRateBpm,
    this.recordingMethod = HealthRecordingMethod.unknown,
  });

  final String id;
  final ContextBridgeImportedKind kind;
  final DateTime start;
  final DateTime end;
  final DataSource source;
  final ActivityType? activityType;
  final SleepStage? sleepStage;
  final double? heartRateBpm;
  final HealthRecordingMethod recordingMethod;
}

/// Availability for one generic imported source and context type.
///
/// This contains no platform record identity or source-app detail. It lets a
/// narrow reader surface avoid treating an omitted record from a hidden source
/// as partial data for a different visible source.
class ContextBridgeImportedSourceAvailability {
  const ContextBridgeImportedSourceAvailability({
    required this.source,
    required this.kind,
    required this.availability,
  });

  final DataSource source;
  final ContextBridgeImportedKind kind;
  final ContextBridgeContextAvailability availability;
}

/// One local, manually authored diary item suitable for a future context UI.
///
/// [id] is a bridge-generated opaque identifier. The original local diary ID
/// stays in the repository and is not surfaced through this model.
class ContextBridgeDiaryItem {
  const ContextBridgeDiaryItem({
    required this.id,
    required this.kind,
    required this.occurredAt,
    required this.hasObservationLink,
    this.label,
    this.duration,
  });

  final String id;
  final String kind;
  final DateTime occurredAt;
  final String? label;
  final Duration? duration;

  /// This records only a local timing relationship, never a cause.
  final bool hasObservationLink;
}

/// One optional, evidence-bound invitation to add local diary context.
///
/// It is intentionally a time-bounded attachment opportunity rather than a
/// glucose interpretation. Consumers must retain [safetyBoundary] verbatim
/// when they render an action based on it.
class ContextBridgeAttachmentSuggestion {
  const ContextBridgeAttachmentSuggestion({
    required this.candidateId,
    required this.episodeKey,
    required this.calculationVersion,
    required this.episodeStart,
    required this.peakAt,
    required this.attachmentWindowStart,
    required this.attachmentWindowEnd,
    required this.safetyBoundary,
  });

  /// Opaque ID for this candidate revision. A later peak can change it.
  final ContextBridgeCandidateId candidateId;

  /// Stable opaque key for the active-session episode.
  ///
  /// A durable attachment claim uses this key rather than [candidateId].
  final ContextBridgeEpisodeKey episodeKey;

  /// Compatibility shorthand for presentation code that needs the candidate
  /// revision ID. Durable storage must use [episodeKey].
  String get id => candidateId.value;
  final String calculationVersion;
  final DateTime episodeStart;
  final DateTime peakAt;
  final DateTime attachmentWindowStart;
  final DateTime attachmentWindowEnd;
  final String safetyBoundary;

  bool canAttachAt(DateTime occurredAt) {
    final value = occurredAt.toUtc();
    return !value.isBefore(attachmentWindowStart.toUtc()) &&
        !value.isAfter(attachmentWindowEnd.toUtc());
  }
}

/// Immutable, local-only data assembled by the app-owned context bridge.
///
/// The snapshot is intentionally presentation-neutral. It does not contain a
/// sensor name, serial, storage key, packet payload, external import ID, or
/// raw provenance object. Widgets can read this cached value without making
/// repository calls.
class ContextBridgeSnapshot {
  const ContextBridgeSnapshot({
    required this.loadState,
    required this.window,
    required this.glucoseAvailability,
    required this.importedAvailability,
    required this.diaryAvailability,
    required this.suggestionAvailability,
    required this.suggestionsEnabled,
    this.importedActivityAvailability,
    this.importedSleepAvailability,
    this.importedSourceAvailabilities =
        const <ContextBridgeImportedSourceAvailability>[],
    this.refreshedAt,
    this.glucoseReadings = const <ContextBridgeReading>[],
    this.importedItems = const <ContextBridgeImportedItem>[],
    this.diaryItems = const <ContextBridgeDiaryItem>[],
    this.attachmentSuggestion,
  });

  factory ContextBridgeSnapshot.idle(DateTime now) => ContextBridgeSnapshot(
    loadState: ContextBridgeLoadState.idle,
    window: ContextBridgeWindow(start: now, end: now),
    glucoseAvailability: ContextBridgeGlucoseAvailability.noActiveSession,
    importedAvailability: ContextBridgeContextAvailability.unavailable,
    diaryAvailability: ContextBridgeContextAvailability.unavailable,
    suggestionAvailability:
        ContextBridgeSuggestionAvailability.disabledByPolicy,
    suggestionsEnabled: false,
  );

  final ContextBridgeLoadState loadState;
  final ContextBridgeWindow window;
  final ContextBridgeGlucoseAvailability glucoseAvailability;
  final ContextBridgeContextAvailability importedAvailability;

  /// Availability for imported activity records only.
  ///
  /// Older callers can omit this field and retain the aggregate
  /// [importedAvailability] behaviour. New reader surfaces must use the
  /// type-specific values so an unrelated source failure cannot change the
  /// visible activity or sleep lane state.
  final ContextBridgeContextAvailability? importedActivityAvailability;

  /// Availability for imported sleep records only. See
  /// [importedActivityAvailability].
  final ContextBridgeContextAvailability? importedSleepAvailability;

  ContextBridgeContextAvailability get activityAvailability =>
      importedActivityAvailability ?? importedAvailability;

  ContextBridgeContextAvailability get sleepAvailability =>
      importedSleepAvailability ?? importedAvailability;

  /// The most specific availability known for a generic source and event
  /// type. A missing value means an older producer supplied only the
  /// type-wide aggregate, so callers must fail closed or use their reviewed
  /// backwards-compatible fallback.
  ContextBridgeContextAvailability? importedAvailabilityFor({
    required DataSource source,
    required ContextBridgeImportedKind kind,
  }) {
    for (final value in importedSourceAvailabilities) {
      if (value.source == source && value.kind == kind) {
        return value.availability;
      }
    }
    return null;
  }

  bool get hasImportedSourceAvailabilities =>
      importedSourceAvailabilities.isNotEmpty;

  final ContextBridgeContextAvailability diaryAvailability;
  final ContextBridgeSuggestionAvailability suggestionAvailability;
  final bool suggestionsEnabled;
  final DateTime? refreshedAt;
  final List<ContextBridgeReading> glucoseReadings;
  final List<ContextBridgeImportedItem> importedItems;
  final List<ContextBridgeImportedSourceAvailability>
  importedSourceAvailabilities;
  final List<ContextBridgeDiaryItem> diaryItems;
  final ContextBridgeAttachmentSuggestion? attachmentSuggestion;

  ContextBridgeSnapshot copyWith({
    ContextBridgeLoadState? loadState,
    ContextBridgeWindow? window,
    ContextBridgeGlucoseAvailability? glucoseAvailability,
    ContextBridgeContextAvailability? importedAvailability,
    ContextBridgeContextAvailability? importedActivityAvailability,
    ContextBridgeContextAvailability? importedSleepAvailability,
    List<ContextBridgeImportedSourceAvailability>? importedSourceAvailabilities,
    ContextBridgeContextAvailability? diaryAvailability,
    ContextBridgeSuggestionAvailability? suggestionAvailability,
    bool? suggestionsEnabled,
    DateTime? refreshedAt,
    List<ContextBridgeReading>? glucoseReadings,
    List<ContextBridgeImportedItem>? importedItems,
    List<ContextBridgeDiaryItem>? diaryItems,
    ContextBridgeAttachmentSuggestion? attachmentSuggestion,
    bool clearAttachmentSuggestion = false,
  }) => ContextBridgeSnapshot(
    loadState: loadState ?? this.loadState,
    window: window ?? this.window,
    glucoseAvailability: glucoseAvailability ?? this.glucoseAvailability,
    importedAvailability: importedAvailability ?? this.importedAvailability,
    importedActivityAvailability:
        importedActivityAvailability ?? this.importedActivityAvailability,
    importedSleepAvailability:
        importedSleepAvailability ?? this.importedSleepAvailability,
    importedSourceAvailabilities:
        List<ContextBridgeImportedSourceAvailability>.unmodifiable(
          importedSourceAvailabilities ?? this.importedSourceAvailabilities,
        ),
    diaryAvailability: diaryAvailability ?? this.diaryAvailability,
    suggestionAvailability:
        suggestionAvailability ?? this.suggestionAvailability,
    suggestionsEnabled: suggestionsEnabled ?? this.suggestionsEnabled,
    refreshedAt: refreshedAt ?? this.refreshedAt,
    glucoseReadings: List<ContextBridgeReading>.unmodifiable(
      glucoseReadings ?? this.glucoseReadings,
    ),
    importedItems: List<ContextBridgeImportedItem>.unmodifiable(
      importedItems ?? this.importedItems,
    ),
    diaryItems: List<ContextBridgeDiaryItem>.unmodifiable(
      diaryItems ?? this.diaryItems,
    ),
    attachmentSuggestion: clearAttachmentSuggestion
        ? null
        : (attachmentSuggestion ?? this.attachmentSuggestion),
  );
}
