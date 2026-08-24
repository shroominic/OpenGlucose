import 'package:cgm_core/cgm_core.dart';

/// The three local event types available from the fast journal.
enum FastJournalKind {
  meal,
  activity,
  sleep,
  ;

  HealthEventType get eventType => switch (this) {
    FastJournalKind.meal => HealthEventType.meal,
    FastJournalKind.activity => HealthEventType.exercise,
    FastJournalKind.sleep => HealthEventType.sleep,
  };

  String get label => switch (this) {
    FastJournalKind.meal => 'Meal',
    FastJournalKind.activity => 'Activity',
    FastJournalKind.sleep => 'Sleep',
  };
}

/// A local, user-authored event before it is persisted to [HealthRepository].
class FastJournalDraft {
  const FastJournalDraft({
    required this.kind,
    required this.startedAt,
    this.label,
    this.duration,
  });

  final FastJournalKind kind;
  final DateTime startedAt;
  final String? label;
  final Duration? duration;

  String? get normalizedLabel {
    final value = label?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  HealthEventPayload? toPayload() {
    final value = normalizedLabel;
    if (value != null && value.length > _maxJournalLabelLength) {
      throw const FormatException(
        'Use at most $_maxJournalLabelLength characters.',
      );
    }
    if (duration != null && duration!.isNegative) {
      throw const FormatException('Duration must not be negative.');
    }
    return switch (kind) {
      FastJournalKind.meal => MealPayload(description: value),
      FastJournalKind.activity => ExercisePayload(
        activity: value,
        duration: duration,
      ),
      FastJournalKind.sleep => SleepPayload(
        description: value,
        duration: duration,
      ),
    };
  }
}

/// One observed relative rise episode that can be linked to a local entry.
///
/// This is observational data only. It does not say why the rise happened.
class RecentGlucoseRise {
  const RecentGlucoseRise({
    required this.startedAt,
    required this.lastObservedAt,
    required this.highestMgdl,
  });

  final DateTime startedAt;
  final DateTime lastObservedAt;
  final double highestMgdl;

  /// Basic integrity only. The injected policy owns data sufficiency.
  bool get hasValidEvidence =>
      !lastObservedAt.isBefore(startedAt) &&
      highestMgdl.isFinite &&
      highestMgdl > 0;

  GlucoseRiseReference get reference => GlucoseRiseReference(
    startedAt: startedAt,
    lastObservedAt: lastObservedAt,
    highestMgdl: highestMgdl,
  );
}

/// Supplies the one newest, data-sufficient recent rise from local analytics.
///
/// Return `null` until a deterministic analytics policy supplies a qualified
/// candidate. The controller never interprets raw glucose readings itself.
typedef FastJournalRecentRiseProvider =
    RecentGlucoseRise? Function(
      DateTime now,
    );

/// The production-safe provider until reviewed local analytics supplies one.
RecentGlucoseRise? noRecentGlucoseRise(DateTime _) => null;

/// Supplies a local event ID. Tests can inject a deterministic implementation.
typedef FastJournalIdFactory = String Function();

/// Supplies the current time. Tests can inject a deterministic implementation.
typedef FastJournalClock = DateTime Function();

/// Local-only persistence and deterministic rise-linking for the fast journal.
///
/// This controller never imports health-platform data, calls a model, or sends
/// data over a network. It stores manual [HealthEvent] records in the existing
/// local [HealthRepository].
class FastJournalController {
  FastJournalController({
    required HealthRepository repository,
    FastJournalRecentRiseProvider recentRise = noRecentGlucoseRise,
    FastJournalIdFactory? idFactory,
    FastJournalClock? clock,
  }) : _repository = repository,
       _recentRise = recentRise,
       _idFactory = idFactory ?? _newFastJournalId,
       _clock = clock ?? DateTime.now;

  static const int maxDiaryEntries = 20;
  static const Set<HealthEventType> _journalTypes = <HealthEventType>{
    HealthEventType.meal,
    HealthEventType.exercise,
    HealthEventType.sleep,
  };

  final HealthRepository _repository;
  final FastJournalRecentRiseProvider _recentRise;
  final FastJournalIdFactory _idFactory;
  final FastJournalClock _clock;

  List<HealthEvent> _entries = const <HealthEvent>[];
  RecentGlucoseRise? _latestEligibleRise;

  /// The newest manual meal, activity, and sleep entries, newest first.
  List<HealthEvent> get entries => List<HealthEvent>.unmodifiable(_entries);

  /// The one current rise that is eligible for an optional local link.
  ///
  /// `null` means analytics has not supplied a data-sufficient recent rise, or
  /// that the newest candidate has already been linked to a journal entry.
  RecentGlucoseRise? get latestEligibleRise => _latestEligibleRise;

  /// Refreshes the compact diary and the one eligible observed rise.
  Future<void> load() async {
    final allEvents = await _repository.queryEvents();
    final journalEvents = allEvents
        .where(
          (event) =>
              event.source == DataSource.manual &&
              _journalTypes.contains(event.type),
        )
        .toList(growable: false);
    final newestFirst = journalEvents.reversed
        .take(maxDiaryEntries)
        .toList(growable: false);
    _entries = newestFirst;

    _latestEligibleRise = selectLatestEligibleRise(
      newestQualifyingRise: _recentRise(_clock()),
      referencedRises: allEvents
          .map((event) => event.riseReference)
          .whereType<GlucoseRiseReference>(),
    );
  }

  /// Persists a manual entry and optionally links it to the single eligible
  /// observed rise. The link records proximity only; it never claims cause.
  Future<HealthEvent> save(
    FastJournalDraft draft, {
    bool attachToLatestRise = false,
  }) async {
    if (attachToLatestRise) {
      // Re-evaluate immediately before persistence. A new reading can arrive
      // while the quick-add sheet is open, and only the newest episode is
      // eligible for an observational link.
      await load();
    }
    final payload = draft.toPayload();
    final id = _idFactory();
    if (id.trim().isEmpty) {
      throw StateError('Fast journal ID factory returned an empty ID.');
    }
    final event = HealthEvent(
      id: id,
      timestamp: draft.startedAt.toUtc(),
      type: draft.kind.eventType,
      payload: payload,
      riseReference: attachToLatestRise ? _latestEligibleRise?.reference : null,
      source: DataSource.manual,
    );
    await _repository.upsertEvent(event);
    await load();
    return event;
  }

  /// Selects the injected newest qualified rise when its data is internally
  /// valid and it has not yet been linked to a manual event.
  ///
  /// The provider owns qualification, including data sufficiency and recency.
  /// This controller deliberately contains no glucose threshold, time-window,
  /// or trend-detection policy.
  ///
  /// The episode key is [RecentGlucoseRise.startedAt], not its changing peak.
  /// This prevents a second event from linking to the same ongoing episode as
  /// more readings arrive. It makes no statement about the cause of a rise.
  static RecentGlucoseRise? selectLatestEligibleRise({
    required RecentGlucoseRise? newestQualifyingRise,
    required Iterable<GlucoseRiseReference> referencedRises,
  }) {
    final latest = newestQualifyingRise;
    if (latest == null || !latest.hasValidEvidence) return null;
    final referencedStarts = referencedRises
        .map((reference) => reference.startedAt.toUtc())
        .toList(growable: false);
    final isReferenced = referencedStarts.any(
      (startedAt) => startedAt.isAtSameMomentAs(latest.startedAt),
    );
    return isReferenced ? null : latest;
  }
}

var _nextFastJournalId = 0;

const _maxJournalLabelLength = 160;

String _newFastJournalId() {
  _nextFastJournalId++;
  return 'journal-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
      '$_nextFastJournalId';
}
