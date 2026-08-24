import 'cgm_models.dart';
import 'meal_response.dart' show IdentifiedGlucoseReading;

/// Version identifier for the deterministic recent-observed-rise contract.
///
/// Keep this value with any later persisted attachment so a local journal can
/// identify the exact rules that qualified it. This calculation does not
/// identify a cause of a glucose change.
const String recentObservedRiseCalculationVersion = 'recent-observed-rise-v1';

/// Required safety boundary for consumers of a [RecentObservedRiseCandidate].
const String recentObservedRiseSafetyBoundary =
    'A recent observed glucose rise does not identify its cause and is not medical advice.';

/// Why a recent-observed-rise assessment did not expose a candidate.
///
/// Every state other than [qualified] has a null candidate. The statuses are
/// deliberately about record quality and explicit policy rules; none make a
/// health or causal interpretation.
enum RecentObservedRiseAssessmentStatus {
  /// A single, newest eligible observed upward excursion is available.
  qualified,

  /// No records were supplied.
  noReadings,

  /// A local record identifier was empty.
  invalidReadingId,

  /// More than one input record used the same local identifier.
  duplicateReadingId,

  /// A record could not be placed on the time axis.
  missingTimestamp,

  /// A reading had a non-finite or non-positive glucose value.
  invalidGlucoseValue,

  /// At least one input record was later than the supplied evaluation time.
  futureReading,

  /// At least one input record was marked display-provisional.
  provisionalReading,

  /// No non-future record fell inside the configured lookback window.
  noRecentReadings,

  /// The most recent record is older than the configured freshness limit.
  staleLatestReading,

  /// The lookback window did not have enough records for an observation.
  insufficientWindowReadings,

  /// Two relevant records shared the same instant.
  duplicateTimestamps,

  /// Relevant records came from more than one CGM record source.
  mixedSources,

  /// A relevant-record gap, including the final gap to evaluation, was too
  /// large for the policy.
  excessiveGap,

  /// An observed upward excursion did not have enough samples or duration.
  insufficientEpisodeData,

  /// Observed upward excursions were below the caller-selected threshold.
  belowConfiguredRise,

  /// No completed, bounded upward excursion was observed.
  noObservedRise,

  /// The newest otherwise eligible excursion was no longer recent enough.
  candidateTooOld;

  String get key => name;
}

/// Explicit local-data qualification rules for [RecentObservedRiseAnalytics].
///
/// [minimumRiseMgdl] is required. The analytics layer intentionally provides
/// no default for a meaning of "big" or clinically important. A product
/// surface must choose and disclose its own non-clinical observation threshold
/// before it can request a candidate.
class RecentObservedRisePolicy {
  const RecentObservedRisePolicy({
    required this.minimumRiseMgdl,
    this.lookbackWindow = const Duration(hours: 3),
    this.maximumCandidateAge = const Duration(minutes: 60),
    this.maximumReadingAge = const Duration(minutes: 10),
    this.maximumGap = const Duration(minutes: 10),
    this.minimumWindowReadings = 5,
    this.minimumEpisodeReadings = 4,
    this.minimumEpisodeSpan = const Duration(minutes: 15),
    this.attachmentWindowBeforeEpisode = const Duration(minutes: 30),
    this.attachmentWindowAfterEpisode = const Duration(minutes: 15),
  }) : assert(minimumRiseMgdl > 0),
       assert(minimumWindowReadings > 1),
       assert(minimumEpisodeReadings > 1);

  /// Caller-selected observed increase in mg/dL required for qualification.
  ///
  /// This is a product observation threshold, not a clinical threshold and
  /// must not be used for treatment or diagnosis.
  final double minimumRiseMgdl;

  /// Only readings in `[now - lookbackWindow, now]` are considered.
  final Duration lookbackWindow;

  /// A candidate peak must be this recent relative to evaluation time.
  final Duration maximumCandidateAge;

  /// The newest record must be this fresh to make any candidate available.
  final Duration maximumReadingAge;

  /// Largest allowed time gap between adjacent relevant records or from the
  /// newest record to evaluation time.
  final Duration maximumGap;

  /// Minimum records required inside the full lookback window.
  final int minimumWindowReadings;

  /// Minimum records from an observed episode start through its peak.
  final int minimumEpisodeReadings;

  /// Minimum observed duration from an episode start through its peak.
  final Duration minimumEpisodeSpan;

  /// How far before an episode start a later journal attachment may be timed.
  final Duration attachmentWindowBeforeEpisode;

  /// How far after the observed peak a later journal attachment may be timed.
  ///
  /// The resulting range never extends past the evaluation time.
  final Duration attachmentWindowAfterEpisode;
}

/// Immutable qualification evidence for a [RecentObservedRiseCandidate].
///
/// It holds local record IDs and derived quality information only. It does not
/// contain raw sensor packets, journal text, an inferred cause, or a medical
/// interpretation.
class RecentObservedRiseEvidence {
  RecentObservedRiseEvidence({
    required this.calculationVersion,
    required this.evaluatedAt,
    required this.lookbackStart,
    required this.latestReadingId,
    required this.latestReadingAt,
    required this.startReadingId,
    required this.peakReadingId,
    required List<String> qualifiedWindowReadingIds,
    required List<String> episodeReadingIds,
    required this.source,
    required this.episodeReadingCount,
    required this.episodeSpan,
    required this.largestGap,
    required this.latestReadingAge,
    required this.policy,
  }) : qualifiedWindowReadingIds = List<String>.unmodifiable(
         qualifiedWindowReadingIds,
       ),
       episodeReadingIds = List<String>.unmodifiable(episodeReadingIds);

  final String calculationVersion;
  final DateTime evaluatedAt;
  final DateTime lookbackStart;
  final String latestReadingId;
  final DateTime latestReadingAt;
  final String startReadingId;
  final String peakReadingId;

  /// Every record that passed the source, freshness, and continuity gate.
  final List<String> qualifiedWindowReadingIds;

  /// Records from the observed start through the selected peak, inclusive.
  final List<String> episodeReadingIds;

  /// The one unambiguous source of every qualified record.
  final CgmRecordSource source;
  final int episodeReadingCount;
  final Duration episodeSpan;
  final Duration largestGap;
  final Duration latestReadingAge;

  /// The exact explicit policy that qualified this local observation.
  final RecentObservedRisePolicy policy;
}

/// One bounded, local observed upward excursion that met an explicit policy.
///
/// A candidate is suitable only as an optional invitation to add context to a
/// journal. It is not a claim that a meal, activity, sleep, or any other event
/// caused the reading change.
class RecentObservedRiseCandidate {
  const RecentObservedRiseCandidate({
    required this.id,
    required this.episodeStart,
    required this.peakAt,
    required this.observedRiseMgdl,
    required this.attachmentWindowStart,
    required this.attachmentWindowEnd,
    required this.evidence,
    this.safetyBoundary = recentObservedRiseSafetyBoundary,
  });

  /// Stable identity derived from the calculation version and endpoint IDs.
  ///
  /// It is intentionally independent of the evaluation clock so the same
  /// locally persisted samples identify the same observed excursion.
  final String id;

  /// Observed local trough at the start of the excursion.
  final DateTime episodeStart;

  /// Observed local peak at the end of the excursion.
  final DateTime peakAt;

  /// Peak minus start reading, in mg/dL.
  final double observedRiseMgdl;

  /// Earliest permitted time for an optional later journal attachment.
  final DateTime attachmentWindowStart;

  /// Latest permitted time for an optional later journal attachment.
  final DateTime attachmentWindowEnd;

  final RecentObservedRiseEvidence evidence;
  final String safetyBoundary;

  /// Whether [at] can be attached to this candidate without escaping its
  /// evidence-bound time range.
  bool canAttachAt(DateTime at) {
    final instant = at.toUtc();
    return !instant.isBefore(attachmentWindowStart) &&
        !instant.isAfter(attachmentWindowEnd);
  }
}

/// Result of one deterministic recent-observed-rise assessment.
class RecentObservedRiseAssessment {
  const RecentObservedRiseAssessment({
    required this.status,
    required this.evaluatedAt,
    required this.lookbackStart,
    required this.inspectedReadingCount,
    required this.policy,
    this.candidate,
  }) : assert(
         (status == RecentObservedRiseAssessmentStatus.qualified) ==
             (candidate != null),
       );

  final RecentObservedRiseAssessmentStatus status;
  final DateTime evaluatedAt;
  final DateTime lookbackStart;
  final int inspectedReadingCount;
  final RecentObservedRisePolicy policy;
  final RecentObservedRiseCandidate? candidate;

  bool get hasCandidate => candidate != null;
}

/// Pure-Dart local analysis for one recent observed upward excursion.
///
/// The caller supplies the clock and the required [RecentObservedRisePolicy],
/// so the result is deterministic. The algorithm fails closed when records are
/// stale, sparse, gapped, provisional, future-dated, duplicate-timestamped, or
/// source-mixed. It never infers why a rise occurred.
abstract final class RecentObservedRiseAnalytics {
  static RecentObservedRiseAssessment assess({
    required Iterable<IdentifiedGlucoseReading> readings,
    required DateTime now,
    required RecentObservedRisePolicy policy,
  }) {
    _validatePolicy(policy);
    final evaluatedAt = now.toUtc();
    final lookbackStart = evaluatedAt.subtract(policy.lookbackWindow);
    final supplied = readings.toList(growable: false);
    if (supplied.isEmpty) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.noReadings,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: 0,
        policy: policy,
      );
    }

    final ids = <String>{};
    for (final identified in supplied) {
      if (identified.id.trim().isEmpty) {
        return _assessment(
          status: RecentObservedRiseAssessmentStatus.invalidReadingId,
          evaluatedAt: evaluatedAt,
          lookbackStart: lookbackStart,
          inspectedReadingCount: supplied.length,
          policy: policy,
        );
      }
      if (!ids.add(identified.id)) {
        return _assessment(
          status: RecentObservedRiseAssessmentStatus.duplicateReadingId,
          evaluatedAt: evaluatedAt,
          lookbackStart: lookbackStart,
          inspectedReadingCount: supplied.length,
          policy: policy,
        );
      }
      final reading = identified.reading;
      if (reading.recordedAt == null) {
        return _assessment(
          status: RecentObservedRiseAssessmentStatus.missingTimestamp,
          evaluatedAt: evaluatedAt,
          lookbackStart: lookbackStart,
          inspectedReadingCount: supplied.length,
          policy: policy,
        );
      }
      if (!reading.valueMgdl.isFinite || reading.valueMgdl <= 0) {
        return _assessment(
          status: RecentObservedRiseAssessmentStatus.invalidGlucoseValue,
          evaluatedAt: evaluatedAt,
          lookbackStart: lookbackStart,
          inspectedReadingCount: supplied.length,
          policy: policy,
        );
      }
      if (reading.recordedAt!.toUtc().isAfter(evaluatedAt)) {
        return _assessment(
          status: RecentObservedRiseAssessmentStatus.futureReading,
          evaluatedAt: evaluatedAt,
          lookbackStart: lookbackStart,
          inspectedReadingCount: supplied.length,
          policy: policy,
        );
      }
      if (reading.isDisplayProvisional) {
        return _assessment(
          status: RecentObservedRiseAssessmentStatus.provisionalReading,
          evaluatedAt: evaluatedAt,
          lookbackStart: lookbackStart,
          inspectedReadingCount: supplied.length,
          policy: policy,
        );
      }
    }

    final windowed =
        supplied
            .where((identified) {
              final at = identified.reading.recordedAt!.toUtc();
              return !at.isBefore(lookbackStart) && !at.isAfter(evaluatedAt);
            })
            .toList(growable: false)
          ..sort(_compareReadings);
    if (windowed.isEmpty) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.noRecentReadings,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: 0,
        policy: policy,
      );
    }

    if (_hasDuplicateTimestamps(windowed)) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.duplicateTimestamps,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: windowed.length,
        policy: policy,
      );
    }

    final sources = windowed
        .map((identified) => identified.reading.source)
        .toSet();
    if (sources.length != 1) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.mixedSources,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: windowed.length,
        policy: policy,
      );
    }

    final latest = windowed.last;
    final latestAt = latest.reading.recordedAt!.toUtc();
    final latestAge = evaluatedAt.difference(latestAt);
    if (latestAge > policy.maximumReadingAge) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.staleLatestReading,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: windowed.length,
        policy: policy,
      );
    }

    if (windowed.length < policy.minimumWindowReadings) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.insufficientWindowReadings,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: windowed.length,
        policy: policy,
      );
    }

    final largestGap = _largerDuration(_largestGap(windowed), latestAge);
    if (largestGap > policy.maximumGap) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.excessiveGap,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: windowed.length,
        policy: policy,
      );
    }

    final selection = _selectNewestEpisode(windowed, policy);
    if (selection == null) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.noObservedRise,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: windowed.length,
        policy: policy,
      );
    }
    final newestEligible = selection.newestEligible;
    if (newestEligible == null) {
      // At least one observed episode existed, but no single episode met every
      // explicit quality rule. Report the newest completed episode rather than
      // combining quality facts from separate episodes.
      return _assessment(
        status: selection.newestStatus,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: windowed.length,
        policy: policy,
      );
    }
    final peakAt = newestEligible.peak.reading.recordedAt!.toUtc();
    if (evaluatedAt.difference(peakAt) > policy.maximumCandidateAge) {
      return _assessment(
        status: RecentObservedRiseAssessmentStatus.candidateTooOld,
        evaluatedAt: evaluatedAt,
        lookbackStart: lookbackStart,
        inspectedReadingCount: windowed.length,
        policy: policy,
      );
    }

    final startAt = newestEligible.start.reading.recordedAt!.toUtc();
    final attachmentEnd = _earlierOf(
      peakAt.add(policy.attachmentWindowAfterEpisode),
      evaluatedAt,
    );
    final evidence = RecentObservedRiseEvidence(
      calculationVersion: recentObservedRiseCalculationVersion,
      evaluatedAt: evaluatedAt,
      lookbackStart: lookbackStart,
      latestReadingId: latest.id,
      latestReadingAt: latestAt,
      startReadingId: newestEligible.start.id,
      peakReadingId: newestEligible.peak.id,
      qualifiedWindowReadingIds: windowed
          .map((identified) => identified.id)
          .toList(growable: false),
      episodeReadingIds: newestEligible.readings
          .map((identified) => identified.id)
          .toList(growable: false),
      source: latest.reading.source,
      episodeReadingCount: newestEligible.readings.length,
      episodeSpan: peakAt.difference(startAt),
      largestGap: largestGap,
      latestReadingAge: latestAge,
      policy: policy,
    );
    final candidate = RecentObservedRiseCandidate(
      id: _candidateId(newestEligible.start.id, newestEligible.peak.id),
      episodeStart: startAt,
      peakAt: peakAt,
      observedRiseMgdl: newestEligible.riseMgdl,
      attachmentWindowStart: startAt.subtract(
        policy.attachmentWindowBeforeEpisode,
      ),
      attachmentWindowEnd: attachmentEnd,
      evidence: evidence,
    );
    return _assessment(
      status: RecentObservedRiseAssessmentStatus.qualified,
      evaluatedAt: evaluatedAt,
      lookbackStart: lookbackStart,
      inspectedReadingCount: windowed.length,
      policy: policy,
      candidate: candidate,
    );
  }

  static RecentObservedRiseAssessment _assessment({
    required RecentObservedRiseAssessmentStatus status,
    required DateTime evaluatedAt,
    required DateTime lookbackStart,
    required int inspectedReadingCount,
    required RecentObservedRisePolicy policy,
    RecentObservedRiseCandidate? candidate,
  }) {
    return RecentObservedRiseAssessment(
      status: status,
      evaluatedAt: evaluatedAt,
      lookbackStart: lookbackStart,
      inspectedReadingCount: inspectedReadingCount,
      policy: policy,
      candidate: candidate,
    );
  }

  static _EpisodeSelection? _selectNewestEpisode(
    List<IdentifiedGlucoseReading> readings,
    RecentObservedRisePolicy policy,
  ) {
    final episodes = <_ObservedEpisode>[];
    int? latestTroughIndex;
    for (var index = 1; index < readings.length; index += 1) {
      final previous = readings[index - 1].reading;
      final current = readings[index].reading;
      final next = index + 1 < readings.length
          ? readings[index + 1].reading
          : null;

      // The final value in a flat trough plateau is the stable episode start.
      // The first value cannot be a trough because its prior context is not in
      // the bounded observation window.
      final isTrough =
          next != null &&
          current.valueMgdl <= previous.valueMgdl &&
          next.valueMgdl > current.valueMgdl;
      if (isTrough) {
        latestTroughIndex = index;
      }

      // The final value in a flat peak plateau is the stable episode peak.
      final isPeak =
          current.valueMgdl >= previous.valueMgdl &&
          (next == null || current.valueMgdl > next.valueMgdl);
      final troughIndex = latestTroughIndex;
      if (!isPeak || troughIndex == null || troughIndex >= index) {
        continue;
      }

      final episodeReadings = readings.sublist(troughIndex, index + 1);
      episodes.add(
        _ObservedEpisode(
          start: readings[troughIndex],
          peak: readings[index],
          readings: episodeReadings,
          hasSufficientData:
              episodeReadings.length >= policy.minimumEpisodeReadings &&
              readings[index].reading.recordedAt!.toUtc().difference(
                    readings[troughIndex].reading.recordedAt!.toUtc(),
                  ) >=
                  policy.minimumEpisodeSpan,
          meetsRiseThreshold:
              readings[index].reading.valueMgdl -
                  readings[troughIndex].reading.valueMgdl >=
              policy.minimumRiseMgdl,
        ),
      );
    }
    if (episodes.isEmpty) {
      return null;
    }
    return _EpisodeSelection(episodes);
  }

  static int _compareReadings(
    IdentifiedGlucoseReading left,
    IdentifiedGlucoseReading right,
  ) {
    final byTime = left.reading.recordedAt!.toUtc().compareTo(
      right.reading.recordedAt!.toUtc(),
    );
    if (byTime != 0) return byTime;
    final bySource = left.reading.source.name.compareTo(
      right.reading.source.name,
    );
    if (bySource != 0) return bySource;
    return left.id.compareTo(right.id);
  }

  static bool _hasDuplicateTimestamps(List<IdentifiedGlucoseReading> readings) {
    for (var index = 1; index < readings.length; index += 1) {
      if (readings[index].reading.recordedAt!.toUtc().compareTo(
            readings[index - 1].reading.recordedAt!.toUtc(),
          ) ==
          0) {
        return true;
      }
    }
    return false;
  }

  static Duration _largestGap(List<IdentifiedGlucoseReading> readings) {
    var largest = Duration.zero;
    for (var index = 1; index < readings.length; index += 1) {
      final gap = readings[index].reading.recordedAt!.toUtc().difference(
        readings[index - 1].reading.recordedAt!.toUtc(),
      );
      if (gap > largest) largest = gap;
    }
    return largest;
  }

  static DateTime _earlierOf(DateTime left, DateTime right) {
    return left.isAfter(right) ? right : left;
  }

  static Duration _largerDuration(Duration left, Duration right) {
    return left >= right ? left : right;
  }

  static String _candidateId(String startReadingId, String peakReadingId) {
    // Length prefixes keep this identity unambiguous even when a record ID
    // contains the separator character. It is for local linkage, not display.
    return '$recentObservedRiseCalculationVersion:'
        '${startReadingId.length}:$startReadingId:'
        '${peakReadingId.length}:$peakReadingId';
  }

  static void _validatePolicy(RecentObservedRisePolicy policy) {
    if (!policy.minimumRiseMgdl.isFinite || policy.minimumRiseMgdl <= 0) {
      throw ArgumentError.value(
        policy.minimumRiseMgdl,
        'policy.minimumRiseMgdl',
        'must be a positive finite observed-rise threshold',
      );
    }
    _validatePositiveDuration(policy.lookbackWindow, 'policy.lookbackWindow');
    _validatePositiveDuration(
      policy.maximumCandidateAge,
      'policy.maximumCandidateAge',
    );
    _validatePositiveDuration(
      policy.maximumReadingAge,
      'policy.maximumReadingAge',
    );
    _validatePositiveDuration(policy.maximumGap, 'policy.maximumGap');
    if (policy.maximumCandidateAge > policy.lookbackWindow) {
      throw ArgumentError.value(
        policy.maximumCandidateAge,
        'policy.maximumCandidateAge',
        'must not exceed policy.lookbackWindow',
      );
    }
    if (policy.minimumWindowReadings < 2) {
      throw ArgumentError.value(
        policy.minimumWindowReadings,
        'policy.minimumWindowReadings',
        'must be at least 2',
      );
    }
    if (policy.minimumEpisodeReadings < 2) {
      throw ArgumentError.value(
        policy.minimumEpisodeReadings,
        'policy.minimumEpisodeReadings',
        'must be at least 2',
      );
    }
    if (policy.minimumEpisodeSpan.isNegative ||
        policy.attachmentWindowBeforeEpisode.isNegative ||
        policy.attachmentWindowAfterEpisode.isNegative) {
      throw ArgumentError('policy durations must not be negative');
    }
  }

  static void _validatePositiveDuration(Duration value, String name) {
    if (value.isNegative || value == Duration.zero) {
      throw ArgumentError.value(value, name, 'must be positive');
    }
  }
}

class _ObservedEpisode {
  const _ObservedEpisode({
    required this.start,
    required this.peak,
    required this.readings,
    required this.hasSufficientData,
    required this.meetsRiseThreshold,
  });

  final IdentifiedGlucoseReading start;
  final IdentifiedGlucoseReading peak;
  final List<IdentifiedGlucoseReading> readings;
  final bool hasSufficientData;
  final bool meetsRiseThreshold;

  double get riseMgdl => peak.reading.valueMgdl - start.reading.valueMgdl;

  bool get isEligible => hasSufficientData && meetsRiseThreshold;
}

class _EpisodeSelection {
  const _EpisodeSelection(this.episodes);

  final List<_ObservedEpisode> episodes;

  _ObservedEpisode? get newestEligible {
    for (var index = episodes.length - 1; index >= 0; index -= 1) {
      final episode = episodes[index];
      if (episode.isEligible) return episode;
    }
    return null;
  }

  RecentObservedRiseAssessmentStatus get newestStatus {
    final newest = episodes.last;
    if (!newest.hasSufficientData) {
      return RecentObservedRiseAssessmentStatus.insufficientEpisodeData;
    }
    if (!newest.meetsRiseThreshold) {
      return RecentObservedRiseAssessmentStatus.belowConfiguredRise;
    }
    // This state is unreachable when [newestEligible] is null, but it keeps
    // the outcome total if this private selection rule is changed later.
    return RecentObservedRiseAssessmentStatus.noObservedRise;
  }
}
