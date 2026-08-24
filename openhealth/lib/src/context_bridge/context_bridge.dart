import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../app_controller.dart';
import '../journal/fast_journal_store.dart';
import '../persistence/health_repository_lifecycle.dart';
import 'context_attachment_fact.dart';
import 'context_bridge_models.dart';

/// Supplies time at the composition edge and in deterministic tests.
typedef ContextBridgeClock = DateTime Function();

/// Conservative local cache limits for the production context bridge.
///
/// This is a cache/query policy, not a glucose or medical policy. The bridge
/// has no unbounded repository query and keeps enough interval lead-in for a
/// sleep or workout that started just before the selected cache window.
class ContextBridgeCachePolicy {
  const ContextBridgeCachePolicy({
    this.window = const Duration(days: 7),
    this.intervalLeadIn = const Duration(days: 1),
    this.maxDiaryEntries = 250,
  });

  final Duration window;
  final Duration intervalLeadIn;
  final int maxDiaryEntries;
}

/// Explicit product policy for enabling one non-clinical observation prompt.
///
/// The default is [ContextBridgeSuggestionPolicy.disabled]. There is no
/// default rise threshold: a product surface must explicitly choose and
/// disclose its own
/// non-clinical observation policy before the bridge can expose a suggestion.
class ContextBridgeSuggestionPolicy {
  const ContextBridgeSuggestionPolicy.disabled()
    : recentRisePolicy = null,
      disclosure = null;

  factory ContextBridgeSuggestionPolicy.nonClinicalObservedRise({
    required RecentObservedRisePolicy recentRisePolicy,
    required String disclosure,
  }) {
    final normalized = disclosure.trim();
    final lower = normalized.toLowerCase();
    if (normalized.isEmpty ||
        (!lower.contains('non-clinical') && !lower.contains('not medical'))) {
      throw ArgumentError.value(
        disclosure,
        'disclosure',
        'must explicitly state that this is non-clinical or not medical',
      );
    }
    return ContextBridgeSuggestionPolicy._(
      recentRisePolicy: recentRisePolicy,
      disclosure: normalized,
    );
  }

  const ContextBridgeSuggestionPolicy._({
    required this.recentRisePolicy,
    required this.disclosure,
  });

  final RecentObservedRisePolicy? recentRisePolicy;

  /// Product-owned non-clinical copy. It is retained here so enabling a prompt
  /// is never an accidental configuration-only change.
  final String? disclosure;

  bool get isEnabled => recentRisePolicy != null;
}

/// App-owned local data coordinator for optional glucose context.
///
/// The coordinator listens only to already-running app state and an optional
/// local-context change signal. It never requests Health permissions, starts
/// an import, schedules background work, calls AI, or lets widgets access the
/// repository. Consumers read [snapshot], then explicitly invoke [reload]
/// after a local mutation if they do not have a signal to supply here.
class ContextBridge extends ChangeNotifier {
  ContextBridge({
    required CgmAppController controller,
    required AppHealthRepositoryLifecycle repositoryLifecycle,
    this.contextChangeSignal,
    ContextBridgeClock? clock,
    this.cachePolicy = const ContextBridgeCachePolicy(),
    this.suggestionPolicy = const ContextBridgeSuggestionPolicy.disabled(),
  }) : assert(
         !cachePolicy.window.isNegative && cachePolicy.window != Duration.zero,
         'ContextBridgeCachePolicy.window must be positive.',
       ),
       assert(
         !cachePolicy.intervalLeadIn.isNegative,
         'ContextBridgeCachePolicy.intervalLeadIn must not be negative.',
       ),
       assert(
         cachePolicy.maxDiaryEntries > 0,
         'ContextBridgeCachePolicy.maxDiaryEntries must be positive.',
       ),
       _controller = controller,
       _repositoryLifecycle = repositoryLifecycle,
       _clock = clock ?? DateTime.now,
       _snapshot = ContextBridgeSnapshot.idle(
         (clock ?? DateTime.now)().toUtc(),
       );

  final CgmAppController _controller;
  final AppHealthRepositoryLifecycle _repositoryLifecycle;
  final Listenable? contextChangeSignal;
  final ContextBridgeClock _clock;
  final ContextBridgeCachePolicy cachePolicy;
  final ContextBridgeSuggestionPolicy suggestionPolicy;

  ContextBridgeSnapshot _snapshot;
  Future<void> _reloadTail = Future<void>.value();
  var _requestGeneration = 0;
  var _started = false;
  var _disposed = false;

  /// The latest immutable local-only cache. Widgets read this value only;
  /// repository access stays within [reload].
  ContextBridgeSnapshot get snapshot => _snapshot;

  /// Starts the one app-owned listener set and loads an initial local cache.
  Future<void> start() {
    if (_disposed) return Future<void>.value();
    if (!_started) {
      _started = true;
      _controller.addListener(_onControllerChanged);
      contextChangeSignal?.addListener(_onContextDataChanged);
    }
    return reload();
  }

  /// Refreshes the cached bridge snapshot from local state only.
  ///
  /// This does not initiate platform imports or background work. It is safe to
  /// call after a completed local diary write or a completed importer write.
  Future<void> reload() {
    if (_disposed) return Future<void>.value();
    final request = ++_requestGeneration;
    final now = _clock().toUtc();
    final pendingInput = _collectGlucose(now);
    _publish(
      ContextBridgeSnapshot(
        loadState: ContextBridgeLoadState.loading,
        window: _windowFor(now),
        glucoseAvailability: pendingInput.glucoseAvailability,
        importedAvailability: ContextBridgeContextAvailability.unavailable,
        diaryAvailability: ContextBridgeContextAvailability.unavailable,
        suggestionAvailability: suggestionPolicy.isEnabled
            ? pendingInput.suggestionBlocker
            : ContextBridgeSuggestionAvailability.disabledByPolicy,
        suggestionsEnabled: suggestionPolicy.isEnabled,
        glucoseReadings: pendingInput.readings,
      ),
    );
    final scheduled = _reloadTail.then((_) => _reloadOne(request));
    _reloadTail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return scheduled;
  }

  Future<void> _reloadOne(int request) async {
    if (_disposed || request != _requestGeneration) return;
    final now = _clock().toUtc();
    final window = _windowFor(now);
    final glucose = _collectGlucose(now);
    try {
      final repository = await _repositoryLifecycle.acquire();
      if (_isSuperseded(request, glucose.sessionKey)) return;

      final repositoryWindow = _halfOpenWindow(window);
      final intervalWindow = TimeWindow(
        start: window.start.subtract(cachePolicy.intervalLeadIn),
        end: repositoryWindow.end,
      );
      final activityFuture = _attempt(
        () => repository.queryActivitySamples(window: intervalWindow),
      );
      final sleepFuture = _attempt(
        () => repository.querySleepSamples(window: intervalWindow),
      );
      final heartRateFuture = _attempt(
        () => repository.queryHeartRateSamples(window: repositoryWindow),
      );
      final journalStore = repository is FastJournalStore
          ? repository as FastJournalStore
          : null;
      final journalFuture = journalStore == null
          ? Future<_LoadResult<List<FastJournalEntry>>>.value(
              const _LoadResult<List<FastJournalEntry>>.unavailable(),
            )
          : _attempt(
              () => journalStore.queryFastJournalEntries(
                window: repositoryWindow,
                limit: cachePolicy.maxDiaryEntries,
              ),
            );
      final attachmentStore = repository is ContextAttachmentFactStore
          ? repository as ContextAttachmentFactStore
          : null;
      final factsFuture = suggestionPolicy.isEnabled && attachmentStore != null
          ? _attempt(
              () => attachmentStore.queryContextAttachmentFacts(
                window: repositoryWindow,
              ),
            )
          : Future<_LoadResult<List<ContextAttachmentFact>>>.value(
              const _LoadResult<List<ContextAttachmentFact>>.unavailable(),
            );

      final activityResult = await activityFuture;
      final sleepResult = await sleepFuture;
      final heartRateResult = await heartRateFuture;
      final journalResult = await journalFuture;
      final factResult = await factsFuture;
      if (_isSuperseded(request, glucose.sessionKey)) return;

      final imported = _mapImportedItems(
        activities: activityResult.value ?? const <ActivitySample>[],
        sleep: sleepResult.value ?? const <SleepSample>[],
        heartRate: heartRateResult.value ?? const <HeartRateSample>[],
        window: window,
        now: now,
      );
      final diary = _mapDiaryItems(
        journalResult.value ?? const <FastJournalEntry>[],
        window: window,
        now: now,
      );
      final suggestion = _suggestionFor(
        glucose: glucose,
        journalEntries: journalResult.value ?? const <FastJournalEntry>[],
        facts: factResult.value,
        now: now,
      );

      _publish(
        ContextBridgeSnapshot(
          loadState: ContextBridgeLoadState.ready,
          window: window,
          glucoseAvailability: glucose.glucoseAvailability,
          importedAvailability: _importedAvailability(
            activity: activityResult,
            sleep: sleepResult,
            heartRate: heartRateResult,
            mapped: imported,
          ),
          diaryAvailability: _diaryAvailability(journalResult, diary),
          suggestionAvailability: suggestion.availability,
          suggestionsEnabled: suggestionPolicy.isEnabled,
          refreshedAt: now,
          glucoseReadings: glucose.readings,
          importedItems: imported.items,
          diaryItems: diary.items,
          attachmentSuggestion: suggestion.value,
        ),
      );
    } on Object {
      if (_isSuperseded(request, glucose.sessionKey)) return;
      _publish(
        ContextBridgeSnapshot(
          loadState: ContextBridgeLoadState.unavailable,
          window: window,
          glucoseAvailability: glucose.glucoseAvailability,
          importedAvailability: ContextBridgeContextAvailability.unavailable,
          diaryAvailability: ContextBridgeContextAvailability.unavailable,
          suggestionAvailability: suggestionPolicy.isEnabled
              ? ContextBridgeSuggestionAvailability.attachmentFactsUnavailable
              : ContextBridgeSuggestionAvailability.disabledByPolicy,
          suggestionsEnabled: suggestionPolicy.isEnabled,
          glucoseReadings: glucose.readings,
        ),
      );
    }
  }

  _GlucoseInput _collectGlucose(DateTime now) {
    final snapshot = _controller.snapshot;
    final activeSession = _activeContextSession(snapshot, now);
    if (snapshot == null || activeSession == null) {
      return const _GlucoseInput.noActiveSession();
    }

    final sourceReadings = snapshot.history.isNotEmpty
        ? snapshot.history
        : <CgmReading>[if (snapshot.latestReading case final latest?) latest];
    final window = _windowFor(now);
    final valid = <_ValidatedReading>[];
    var blocker = ContextBridgeSuggestionAvailability.notQualified;
    for (final reading in sourceReadings) {
      switch (_warmupPlacement(reading, activeSession)) {
        case _WarmupPlacement.beforeWarmup:
          continue;
        case _WarmupPlacement.unknown:
          blocker = _preferBlocker(
            blocker,
            ContextBridgeSuggestionAvailability.unprovenPostWarmupReading,
          );
          continue;
        case _WarmupPlacement.postWarmup:
          break;
      }
      final recordedAt = reading.recordedAt?.toUtc();
      if (recordedAt == null ||
          !reading.valueMgdl.isFinite ||
          reading.valueMgdl <= 0) {
        blocker = _preferBlocker(
          blocker,
          ContextBridgeSuggestionAvailability.invalidReading,
        );
        continue;
      }
      if (!_isDisplaySafeSource(reading.source)) {
        blocker = _preferBlocker(
          blocker,
          ContextBridgeSuggestionAvailability.unsupportedReadingSource,
        );
        continue;
      }
      if (reading.isDisplayProvisional) {
        blocker = _preferBlocker(
          blocker,
          ContextBridgeSuggestionAvailability.provisionalReading,
        );
        continue;
      }
      if (recordedAt.isAfter(now)) {
        blocker = _preferBlocker(
          blocker,
          ContextBridgeSuggestionAvailability.futureReading,
        );
        continue;
      }
      if (!window.contains(recordedAt)) continue;
      final id = _opaqueId(
        'reading|${activeSession.key}|${recordedAt.microsecondsSinceEpoch}|'
        '${reading.source.name}|${reading.sensorMinute ?? ''}|'
        '${reading.valueMgdl.toStringAsFixed(6)}',
      );
      valid.add(
        _ValidatedReading(
          context: ContextBridgeReading(
            id: id,
            recordedAt: recordedAt,
            valueMgdl: reading.valueMgdl,
            source: reading.source,
          ),
          candidate: IdentifiedGlucoseReading(
            id: id,
            reading: CgmReading(
              valueMgdl: reading.valueMgdl,
              source: reading.source,
              recordedAt: recordedAt,
            ),
          ),
        ),
      );
    }

    valid.sort((left, right) {
      final byTime = left.context.recordedAt.compareTo(
        right.context.recordedAt,
      );
      return byTime != 0 ? byTime : left.context.id.compareTo(right.context.id);
    });
    final duplicateTimes = <int>{};
    for (var index = 1; index < valid.length; index += 1) {
      if (valid[index - 1].context.recordedAt.isAtSameMomentAs(
        valid[index].context.recordedAt,
      )) {
        duplicateTimes
          ..add(valid[index - 1].context.recordedAt.microsecondsSinceEpoch)
          ..add(valid[index].context.recordedAt.microsecondsSinceEpoch);
      }
    }
    if (duplicateTimes.isNotEmpty) {
      blocker = _preferBlocker(
        blocker,
        ContextBridgeSuggestionAvailability.duplicateTimestamp,
      );
    }
    final deduplicated = valid
        .where(
          (item) => !duplicateTimes.contains(
            item.context.recordedAt.microsecondsSinceEpoch,
          ),
        )
        .toList(growable: false);
    if (deduplicated.map((item) => item.context.source).toSet().length > 1) {
      blocker = _preferBlocker(
        blocker,
        ContextBridgeSuggestionAvailability.mixedSources,
      );
    }
    return _GlucoseInput(
      sessionKey: activeSession.key,
      glucoseAvailability: deduplicated.isEmpty
          ? ContextBridgeGlucoseAvailability.noPostWarmupReadings
          : ContextBridgeGlucoseAvailability.available,
      readings: List<ContextBridgeReading>.unmodifiable(
        deduplicated.map((item) => item.context),
      ),
      candidateReadings: List<IdentifiedGlucoseReading>.unmodifiable(
        deduplicated.map((item) => item.candidate),
      ),
      suggestionBlocker: deduplicated.isEmpty
          ? _preferBlocker(
              ContextBridgeSuggestionAvailability.noEligibleReadings,
              blocker,
            )
          : blocker,
    );
  }

  _SuggestionResult _suggestionFor({
    required _GlucoseInput glucose,
    required List<FastJournalEntry> journalEntries,
    required List<ContextAttachmentFact>? facts,
    required DateTime now,
  }) {
    if (!suggestionPolicy.isEnabled) {
      return const _SuggestionResult.disabled();
    }
    if (glucose.suggestionBlocker !=
        ContextBridgeSuggestionAvailability.notQualified) {
      return _SuggestionResult(glucose.suggestionBlocker);
    }
    final policy = suggestionPolicy.recentRisePolicy;
    if (policy == null) return const _SuggestionResult.disabled();
    final assessment = RecentObservedRiseAnalytics.assess(
      readings: glucose.candidateReadings,
      now: now,
      policy: policy,
    );
    final candidate = assessment.candidate;
    if (candidate == null) {
      return const _SuggestionResult(
        ContextBridgeSuggestionAvailability.notQualified,
      );
    }
    if (facts == null) {
      return const _SuggestionResult(
        ContextBridgeSuggestionAvailability.attachmentFactsUnavailable,
      );
    }
    final sessionKey = glucose.sessionKey;
    if (sessionKey == null) {
      return const _SuggestionResult(
        ContextBridgeSuggestionAvailability.noActiveSession,
      );
    }
    final candidateId = ContextBridgeCandidateId(
      _opaqueLinkId(
        'candidate',
        'candidate|$sessionKey|${candidate.id}',
      ),
    );
    // The episode key is stable when a later observed peak changes the
    // analytics candidate. It is scoped by the private active-session key so
    // equal timestamps from different sensors cannot share a durable claim.
    final episodeKey = ContextBridgeEpisodeKey(
      _opaqueLinkId(
        'episode',
        'episode|$sessionKey|'
            '${candidate.episodeStart.toUtc().microsecondsSinceEpoch}',
      ),
    );
    final legacyAttached = journalEntries.any((entry) {
      final reference = entry.riseReference;
      return reference != null &&
          reference.startedAt.toUtc().isAtSameMomentAs(candidate.episodeStart);
    });
    final factAttached = facts.any(
      (fact) =>
          fact.isStableEpisodeClaim &&
          fact.episodeKey.value == episodeKey.value,
    );
    if (legacyAttached || factAttached) {
      return const _SuggestionResult(
        ContextBridgeSuggestionAvailability.attachmentAlreadyRecorded,
      );
    }
    return _SuggestionResult(
      ContextBridgeSuggestionAvailability.available,
      ContextBridgeAttachmentSuggestion(
        candidateId: candidateId,
        episodeKey: episodeKey,
        calculationVersion: candidate.evidence.calculationVersion,
        episodeStart: candidate.episodeStart,
        peakAt: candidate.peakAt,
        attachmentWindowStart: candidate.attachmentWindowStart,
        attachmentWindowEnd: candidate.attachmentWindowEnd,
        safetyBoundary: candidate.safetyBoundary,
      ),
    );
  }

  _MappedImportedItems _mapImportedItems({
    required List<ActivitySample> activities,
    required List<SleepSample> sleep,
    required List<HeartRateSample> heartRate,
    required ContextBridgeWindow window,
    required DateTime now,
  }) {
    final items = <ContextBridgeImportedItem>[];
    var omitted = false;
    for (final activity in activities) {
      final mapped = _mapActivity(activity, window: window, now: now);
      if (mapped == null) {
        omitted = true;
      } else {
        items.add(mapped);
      }
    }
    for (final sample in sleep) {
      final mapped = _mapSleep(sample, window: window, now: now);
      if (mapped == null) {
        omitted = true;
      } else {
        items.add(mapped);
      }
    }
    for (final sample in heartRate) {
      final mapped = _mapHeartRate(sample, window: window, now: now);
      if (mapped == null) {
        omitted = true;
      } else {
        items.add(mapped);
      }
    }
    items.sort((left, right) {
      final byTime = left.start.compareTo(right.start);
      return byTime != 0 ? byTime : left.id.compareTo(right.id);
    });
    return _MappedImportedItems(
      List<ContextBridgeImportedItem>.unmodifiable(items),
      omitted: omitted,
    );
  }

  ContextBridgeImportedItem? _mapActivity(
    ActivitySample sample, {
    required ContextBridgeWindow window,
    required DateTime now,
  }) {
    final identity = _safeImportedIdentity(sample.source, sample.provenance);
    final start = sample.start.toUtc();
    final end = sample.end.toUtc();
    if (identity == null ||
        end.isBefore(start) ||
        end.isAfter(now) ||
        !window.intersects(start, end)) {
      return null;
    }
    return ContextBridgeImportedItem(
      id: _opaqueId('activity|${sample.source.name}|$identity'),
      kind: ContextBridgeImportedKind.activity,
      start: start,
      end: end,
      source: sample.source,
      activityType: sample.type,
      recordingMethod: sample.provenance!.recordingMethod,
    );
  }

  ContextBridgeImportedItem? _mapSleep(
    SleepSample sample, {
    required ContextBridgeWindow window,
    required DateTime now,
  }) {
    final identity = _safeImportedIdentity(sample.source, sample.provenance);
    final start = sample.start.toUtc();
    final end = sample.end.toUtc();
    if (identity == null ||
        end.isBefore(start) ||
        end.isAfter(now) ||
        !window.intersects(start, end)) {
      return null;
    }
    return ContextBridgeImportedItem(
      id: _opaqueId('sleep|${sample.source.name}|$identity'),
      kind: ContextBridgeImportedKind.sleep,
      start: start,
      end: end,
      source: sample.source,
      sleepStage: sample.stage,
      recordingMethod: sample.provenance!.recordingMethod,
    );
  }

  ContextBridgeImportedItem? _mapHeartRate(
    HeartRateSample sample, {
    required ContextBridgeWindow window,
    required DateTime now,
  }) {
    final identity = _safeImportedIdentity(sample.source, sample.provenance);
    final timestamp = sample.timestamp.toUtc();
    if (identity == null ||
        timestamp.isAfter(now) ||
        !window.contains(timestamp) ||
        !sample.bpm.isFinite ||
        sample.bpm <= 0) {
      return null;
    }
    return ContextBridgeImportedItem(
      id: _opaqueId('heart-rate|${sample.source.name}|$identity'),
      kind: ContextBridgeImportedKind.heartRate,
      start: timestamp,
      end: timestamp,
      source: sample.source,
      heartRateBpm: sample.bpm,
      recordingMethod: sample.provenance!.recordingMethod,
    );
  }

  _MappedDiaryItems _mapDiaryItems(
    List<FastJournalEntry> entries, {
    required ContextBridgeWindow window,
    required DateTime now,
  }) {
    final items = <ContextBridgeDiaryItem>[];
    var omitted = false;
    for (final entry in entries) {
      final occurredAt = entry.occurredAt.toUtc();
      if (entry.id.trim().isEmpty ||
          occurredAt.isAfter(now) ||
          !window.contains(occurredAt)) {
        omitted = true;
        continue;
      }
      items.add(
        ContextBridgeDiaryItem(
          id: _opaqueId('diary|${entry.id}'),
          kind: entry.kind.name,
          occurredAt: occurredAt,
          label: entry.label,
          duration: entry.duration,
          hasObservationLink: entry.riseReference != null,
        ),
      );
    }
    items.sort((left, right) {
      final byTime = left.occurredAt.compareTo(right.occurredAt);
      return byTime != 0 ? byTime : left.id.compareTo(right.id);
    });
    return _MappedDiaryItems(
      List<ContextBridgeDiaryItem>.unmodifiable(items),
      omitted: omitted,
    );
  }

  ContextBridgeContextAvailability _importedAvailability({
    required _LoadResult<List<ActivitySample>> activity,
    required _LoadResult<List<SleepSample>> sleep,
    required _LoadResult<List<HeartRateSample>> heartRate,
    required _MappedImportedItems mapped,
  }) {
    final everyUnavailable =
        !activity.isAvailable && !sleep.isAvailable && !heartRate.isAvailable;
    if (everyUnavailable) {
      return ContextBridgeContextAvailability.unavailable;
    }
    final anyUnavailable =
        !activity.isAvailable || !sleep.isAvailable || !heartRate.isAvailable;
    if (anyUnavailable || mapped.omitted) {
      return ContextBridgeContextAvailability.partial;
    }
    return mapped.items.isEmpty
        ? ContextBridgeContextAvailability.noLocalRecords
        : ContextBridgeContextAvailability.available;
  }

  ContextBridgeContextAvailability _diaryAvailability(
    _LoadResult<List<FastJournalEntry>> result,
    _MappedDiaryItems mapped,
  ) {
    if (!result.isAvailable) {
      return ContextBridgeContextAvailability.unavailable;
    }
    if (mapped.omitted) return ContextBridgeContextAvailability.partial;
    return mapped.items.isEmpty
        ? ContextBridgeContextAvailability.noLocalRecords
        : ContextBridgeContextAvailability.available;
  }

  ContextBridgeWindow _windowFor(DateTime now) => ContextBridgeWindow(
    start: now.subtract(cachePolicy.window),
    end: now,
  );

  TimeWindow _halfOpenWindow(ContextBridgeWindow window) => TimeWindow(
    start: window.start,
    // Repository timestamp indices use milliseconds, so one millisecond keeps
    // an item recorded exactly at [window.end] in the inclusive cache.
    end: window.end.add(const Duration(milliseconds: 1)),
  );

  bool _isSuperseded(int request, String? expectedSessionKey) {
    if (_disposed || request != _requestGeneration) return true;
    return _activeContextSession(
          _controller.snapshot,
          _clock().toUtc(),
        )?.key !=
        expectedSessionKey;
  }

  void _onControllerChanged() {
    if (_started && !_disposed) unawaited(reload());
  }

  void _onContextDataChanged() {
    if (_started && !_disposed) unawaited(reload());
  }

  void _publish(ContextBridgeSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) {
      _controller.removeListener(_onControllerChanged);
      contextChangeSignal?.removeListener(_onContextDataChanged);
    }
    super.dispose();
  }
}

class _GlucoseInput {
  const _GlucoseInput({
    required this.sessionKey,
    required this.glucoseAvailability,
    required this.readings,
    required this.candidateReadings,
    required this.suggestionBlocker,
  });

  const _GlucoseInput.noActiveSession()
    : sessionKey = null,
      glucoseAvailability = ContextBridgeGlucoseAvailability.noActiveSession,
      readings = const <ContextBridgeReading>[],
      candidateReadings = const <IdentifiedGlucoseReading>[],
      suggestionBlocker = ContextBridgeSuggestionAvailability.noActiveSession;

  final String? sessionKey;
  final ContextBridgeGlucoseAvailability glucoseAvailability;
  final List<ContextBridgeReading> readings;
  final List<IdentifiedGlucoseReading> candidateReadings;
  final ContextBridgeSuggestionAvailability suggestionBlocker;
}

class _ValidatedReading {
  const _ValidatedReading({required this.context, required this.candidate});

  final ContextBridgeReading context;
  final IdentifiedGlucoseReading candidate;
}

class _SuggestionResult {
  const _SuggestionResult(this.availability, [this.value]);

  const _SuggestionResult.disabled()
    : availability = ContextBridgeSuggestionAvailability.disabledByPolicy,
      value = null;

  final ContextBridgeSuggestionAvailability availability;
  final ContextBridgeAttachmentSuggestion? value;
}

class _MappedImportedItems {
  const _MappedImportedItems(this.items, {required this.omitted});

  final List<ContextBridgeImportedItem> items;
  final bool omitted;
}

class _MappedDiaryItems {
  const _MappedDiaryItems(this.items, {required this.omitted});

  final List<ContextBridgeDiaryItem> items;
  final bool omitted;
}

class _LoadResult<T> {
  const _LoadResult.available(this.value) : isAvailable = true;

  const _LoadResult.unavailable() : value = null, isAvailable = false;

  final T? value;
  final bool isAvailable;
}

Future<_LoadResult<T>> _attempt<T>(Future<T> Function() operation) async {
  try {
    return _LoadResult<T>.available(await operation());
  } on Object {
    return _LoadResult<T>.unavailable();
  }
}

class _ContextActiveSession {
  const _ContextActiveSession({
    required this.key,
    required this.sessionStart,
    required this.warmupMinutes,
  });

  final String key;
  final DateTime sessionStart;
  final int warmupMinutes;
}

enum _WarmupPlacement { beforeWarmup, postWarmup, unknown }

/// Returns a session only when the bridge can safely treat it as active.
///
/// This deliberately has a stricter contract than presentation helpers. The
/// bridge needs a stable session discriminator and a provable warmup boundary;
/// retained history alone is not enough for a local context cache.
_ContextActiveSession? _activeContextSession(
  CgmSessionSnapshot? snapshot,
  DateTime now,
) {
  if (snapshot == null ||
      snapshot.stage != CgmSyncStage.ready ||
      snapshot.sessionInfo.sessionStopped ||
      snapshot.health.expired ||
      snapshot.sensor.driverId.trim().isEmpty ||
      snapshot.sensor.storageKey.trim().isEmpty) {
    return null;
  }
  final sessionStart = snapshot.sessionInfo.sessionStart?.toUtc();
  final warmupMinutes = snapshot.sessionInfo.warmupMinutes;
  if (sessionStart == null ||
      sessionStart.isAfter(now.toUtc()) ||
      warmupMinutes < 0) {
    return null;
  }
  return _ContextActiveSession(
    key: _opaqueId(
      'session|${snapshot.sensor.driverId}|${snapshot.sensor.storageKey}|'
      '${sessionStart.microsecondsSinceEpoch}',
    ),
    sessionStart: sessionStart,
    warmupMinutes: warmupMinutes,
  );
}

/// Places a reading relative to warmup only when a source datum proves it.
///
/// Sensor-relative minutes are authoritative when present. Otherwise the
/// active session start plus a normalized timestamp prove placement. Unlike
/// `readingsAfterWarmup`, unknown placement is never retained by the bridge.
_WarmupPlacement _warmupPlacement(
  CgmReading reading,
  _ContextActiveSession session,
) {
  final sensorMinute = reading.sensorMinute;
  if (sensorMinute != null) {
    return sensorMinute >= session.warmupMinutes
        ? _WarmupPlacement.postWarmup
        : _WarmupPlacement.beforeWarmup;
  }
  final recordedAt = reading.recordedAt?.toUtc();
  if (recordedAt == null) return _WarmupPlacement.unknown;
  final warmupEndsAt = session.sessionStart.add(
    Duration(minutes: session.warmupMinutes),
  );
  return recordedAt.isBefore(warmupEndsAt)
      ? _WarmupPlacement.beforeWarmup
      : _WarmupPlacement.postWarmup;
}

bool _isDisplaySafeSource(CgmRecordSource source) => switch (source) {
  CgmRecordSource.vendor ||
  CgmRecordSource.standard ||
  CgmRecordSource.broadcast => true,
  CgmRecordSource.raw || CgmRecordSource.calibration => false,
};

String? _safeImportedIdentity(
  DataSource source,
  HealthSampleProvenance? provenance,
) {
  if (source == DataSource.manual ||
      provenance == null ||
      provenance.isDeleted) {
    return null;
  }
  final identity = provenance.identity;
  if (identity.platform.dataSource != source ||
      identity.externalId.trim().isEmpty) {
    return null;
  }
  return '${identity.platform.key}:${identity.externalId}';
}

ContextBridgeSuggestionAvailability _preferBlocker(
  ContextBridgeSuggestionAvailability current,
  ContextBridgeSuggestionAvailability candidate,
) {
  const priority = <ContextBridgeSuggestionAvailability, int>{
    ContextBridgeSuggestionAvailability.notQualified: 0,
    ContextBridgeSuggestionAvailability.mixedSources: 1,
    ContextBridgeSuggestionAvailability.duplicateTimestamp: 2,
    ContextBridgeSuggestionAvailability.futureReading: 3,
    ContextBridgeSuggestionAvailability.provisionalReading: 4,
    ContextBridgeSuggestionAvailability.unsupportedReadingSource: 5,
    ContextBridgeSuggestionAvailability.invalidReading: 6,
    ContextBridgeSuggestionAvailability.unprovenPostWarmupReading: 7,
  };
  final currentPriority = priority[current] ?? 0;
  final candidatePriority = priority[candidate] ?? 0;
  return candidatePriority > currentPriority ? candidate : current;
}

String _opaqueId(String value) {
  final digest = sha256.convert(
    utf8.encode('openglucose-context-bridge-v1|$value'),
  );
  return 'ctx-${digest.toString().substring(0, 24)}';
}

String _opaqueLinkId(String kind, String value) {
  final digest = sha256.convert(
    utf8.encode('openglucose-context-bridge-v1|$kind|$value'),
  );
  return 'ctx-$kind-${digest.toString().substring(0, 24)}';
}
