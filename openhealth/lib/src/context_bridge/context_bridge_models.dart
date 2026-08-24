import 'package:cgm_core/cgm_core.dart';

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
    required this.id,
    required this.calculationVersion,
    required this.episodeStart,
    required this.peakAt,
    required this.attachmentWindowStart,
    required this.attachmentWindowEnd,
    required this.safetyBoundary,
  });

  final String id;
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
  final ContextBridgeContextAvailability diaryAvailability;
  final ContextBridgeSuggestionAvailability suggestionAvailability;
  final bool suggestionsEnabled;
  final DateTime? refreshedAt;
  final List<ContextBridgeReading> glucoseReadings;
  final List<ContextBridgeImportedItem> importedItems;
  final List<ContextBridgeDiaryItem> diaryItems;
  final ContextBridgeAttachmentSuggestion? attachmentSuggestion;

  ContextBridgeSnapshot copyWith({
    ContextBridgeLoadState? loadState,
    ContextBridgeWindow? window,
    ContextBridgeGlucoseAvailability? glucoseAvailability,
    ContextBridgeContextAvailability? importedAvailability,
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
