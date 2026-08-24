import 'fast_journal_store.dart';

/// A local, user-authored entry before it is persisted to [FastJournalStore].
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

  FastJournalEntry toEntry({required String id}) {
    final entry = FastJournalEntry(
      id: id,
      kind: kind,
      occurredAt: startedAt.toUtc(),
      label: normalizedLabel,
      duration: duration,
    );
    // Validate before work starts so callers receive an actionable error.
    entry.toJson();
    return entry;
  }
}

/// One observed relative rise episode that can be linked to a local entry.
///
/// This is observational data only. It does not say why the rise happened.
/// Its provider supplies an explicit half-open window during which a manually
/// selected occurrence time can be linked.
class RecentGlucoseRise {
  const RecentGlucoseRise({
    required this.startedAt,
    required this.lastObservedAt,
    required this.highestMgdl,
    required this.linkWindowStart,
    required this.linkWindowEnd,
  });

  final DateTime startedAt;
  final DateTime lastObservedAt;
  final double highestMgdl;

  /// Inclusive start of the provider-approved event-time link window.
  final DateTime linkWindowStart;

  /// Exclusive end of the provider-approved event-time link window.
  final DateTime linkWindowEnd;

  /// Basic integrity only. The injected policy owns data sufficiency.
  bool get hasValidEvidence =>
      !lastObservedAt.isBefore(startedAt) &&
      !linkWindowEnd.isBefore(linkWindowStart) &&
      !linkWindowEnd.isAtSameMomentAs(linkWindowStart) &&
      highestMgdl.isFinite &&
      highestMgdl > 0;

  /// Whether a user-selected event time falls in this candidate's explicit
  /// half-open link window.
  bool canLinkAt(DateTime occurredAt) {
    final point = occurredAt.toUtc();
    return !point.isBefore(linkWindowStart.toUtc()) &&
        point.isBefore(linkWindowEnd.toUtc());
  }

  FastJournalRiseReference get reference => FastJournalRiseReference(
    startedAt: startedAt,
    lastObservedAt: lastObservedAt,
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
/// data over a network. It stores manual entries only through an isolated
/// [FastJournalStore] protocol. A store owns the atomic, newest-rise claim.
class FastJournalController {
  FastJournalController({
    required FastJournalStore store,
    FastJournalRecentRiseProvider recentRise = noRecentGlucoseRise,
    FastJournalIdFactory? idFactory,
    FastJournalClock? clock,
  }) : _store = store,
       _recentRise = recentRise,
       _idFactory = idFactory ?? _newFastJournalId,
       _clock = clock ?? DateTime.now;

  static const int maxDiaryEntries = 20;

  final FastJournalStore _store;
  final FastJournalRecentRiseProvider _recentRise;
  final FastJournalIdFactory _idFactory;
  final FastJournalClock _clock;

  List<FastJournalEntry> _entries = const <FastJournalEntry>[];
  RecentGlucoseRise? _latestEligibleRise;
  Future<void> _saveTail = Future<void>.value();

  /// The newest manual meal, activity, and sleep entries, newest first.
  List<FastJournalEntry> get entries =>
      List<FastJournalEntry>.unmodifiable(_entries);

  /// The one current rise that is eligible for an optional local link.
  ///
  /// `null` means analytics has not supplied a data-sufficient recent rise, or
  /// that the newest candidate has already been linked to a journal entry.
  RecentGlucoseRise? get latestEligibleRise => _latestEligibleRise;

  /// The current candidate only when [occurredAt] is in its provider-approved
  /// event-time window.
  RecentGlucoseRise? latestEligibleRiseFor(DateTime occurredAt) {
    final rise = _latestEligibleRise;
    if (rise == null || !rise.canLinkAt(occurredAt)) return null;
    return rise;
  }

  /// Refreshes the compact diary and the one eligible observed rise.
  Future<void> load() async {
    final entries = await _store.queryFastJournalEntries(
      limit: maxDiaryEntries,
    );
    _entries = entries;

    final eligible = selectLatestEligibleRise(
      newestQualifyingRise: _recentRise(_clock()),
      referencedRises: entries
          .map((entry) => entry.riseReference)
          .whereType<FastJournalRiseReference>(),
    );
    _latestEligibleRise =
        eligible == null ||
            await _store.isFastJournalRiseClaimed(
              riseStartedAt: eligible.startedAt,
            )
        ? null
        : eligible;
  }

  /// Persists a manual entry and optionally links it to the single eligible
  /// observed rise. The link records proximity only; it never claims cause.
  ///
  /// Saves on one controller are serialized. The store additionally makes the
  /// cross-controller/SQLite rise claim atomic, so the same newest rise cannot
  /// be linked twice when two save requests overlap.
  Future<FastJournalEntry> save(
    FastJournalDraft draft, {
    bool attachToLatestRise = false,
  }) {
    final scheduled = _saveTail.then(
      (_) => _saveOne(draft, attachToLatestRise: attachToLatestRise),
    );
    _saveTail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return scheduled;
  }

  Future<FastJournalEntry> _saveOne(
    FastJournalDraft draft, {
    required bool attachToLatestRise,
  }) async {
    if (attachToLatestRise) {
      // Re-evaluate immediately before persistence. A new reading can arrive
      // while the quick-add sheet is open, and only the newest episode is
      // eligible for an observational link.
      await load();
    }
    final id = _idFactory();
    if (id.trim().isEmpty) {
      throw StateError('Fast journal ID factory returned an empty ID.');
    }
    final entry = draft.toEntry(id: id);
    final requestedRise = attachToLatestRise
        ? latestEligibleRiseFor(entry.occurredAt)?.reference
        : null;
    final persisted = await _store.saveFastJournalEntry(
      entry: entry,
      requestedRise: requestedRise,
    );
    await load();
    return persisted;
  }

  /// Selects the injected newest qualified rise when its data is internally
  /// valid and it has not yet been linked to a manual event.
  ///
  /// The provider owns qualification, including data sufficiency, recency, and
  /// the explicit event-time link window. This controller deliberately
  /// contains no glucose threshold or trend-detection policy.
  ///
  /// The episode key is [RecentGlucoseRise.startedAt], not its changing peak.
  /// This prevents a second event from linking to the same ongoing episode as
  /// more readings arrive. It makes no statement about the cause of a rise.
  static RecentGlucoseRise? selectLatestEligibleRise({
    required RecentGlucoseRise? newestQualifyingRise,
    required Iterable<FastJournalRiseReference> referencedRises,
  }) {
    final latest = newestQualifyingRise;
    if (latest == null || !latest.hasValidEvidence) return null;
    final isReferenced = referencedRises.any(
      (reference) => reference.startedAt.toUtc().isAtSameMomentAs(
        latest.startedAt.toUtc(),
      ),
    );
    return isReferenced ? null : latest;
  }
}

var _nextFastJournalId = 0;

String _newFastJournalId() {
  _nextFastJournalId++;
  return 'journal-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
      '$_nextFastJournalId';
}
