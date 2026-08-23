import 'cgm_models.dart';
import 'health_event.dart';

/// Version identifier for the deterministic meal-response calculation.
///
/// Persist this value with any later storage or UI integration so a result can
/// always be traced back to the calculation rules that produced it.
const String mealResponseCalculationVersion = 'meal-response-v1';

/// A glucose reading with the stable identifier of its source record.
///
/// [CgmReading] deliberately does not impose a persistence identifier. The
/// analytics layer needs one so it can point every result back to the exact
/// local samples that supported it.
class IdentifiedGlucoseReading {
  const IdentifiedGlucoseReading({required this.id, required this.reading});

  /// Stable local or imported record identifier. It is never displayed by the
  /// analytics API and must not contain a sensor identifier.
  final String id;

  final CgmReading reading;
}

/// Why a meal response is not ready to summarize.
///
/// These states describe local data coverage only. A [sufficient] response
/// still does not establish that a meal caused a glucose change.
enum MealResponseStatus {
  /// No eligible post-meal readings were available in the response window.
  noPostMealReadings,

  /// The pre-meal baseline is too sparse.
  insufficientBaseline,

  /// The response window has fewer readings than the configured minimum.
  insufficientPostMealReadings,

  /// The response does not cover enough of the configured duration.
  insufficientCoverage,

  /// At least one gap is larger than the configured maximum.
  excessiveGap,

  /// More than one input record had the same instant in a relevant window.
  ///
  /// The engine deterministically selects one record for inspection but fails
  /// closed rather than presenting a derived meal response.
  duplicateTimestamps,

  /// A response combines multiple glucose record sources while the policy
  /// requires a single source.
  mixedSources,

  /// Baseline, count, coverage, cadence, and source requirements are met.
  sufficient;

  String get key => name;
}

/// Aggregate state for a set of meal responses.
enum MealResponseSummaryStatus {
  /// No meal journal events were in the requested input.
  noMeals,

  /// Meals were present, but none had an eligible post-meal reading.
  noGlucoseReadings,

  /// Meals and readings exist, but no meal has enough data for a summary.
  insufficientData,

  /// At least one meal is sufficient and at least one is incomplete.
  partial,

  /// Every analysed meal has a sufficient response summary.
  ready;

  String get key => name;
}

/// Conservative windows and data-quality requirements for meal responses.
class MealResponsePolicy {
  const MealResponsePolicy({
    this.baselineWindow = const Duration(minutes: 30),
    this.responseWindow = const Duration(hours: 2),
    this.minimumBaselineReadings = 2,
    this.minimumPostMealReadings = 3,
    this.minimumCoverage = 0.5,
    this.maximumGap = const Duration(minutes: 30),
    this.includeProvisionalReadings = false,
    this.allowMixedSources = false,
  }) : assert(minimumBaselineReadings > 0),
       assert(minimumPostMealReadings > 0),
       assert(minimumCoverage >= 0 && minimumCoverage <= 1);

  /// Time before a meal used to estimate its local baseline.
  final Duration baselineWindow;

  /// Maximum time after a meal used for response readings.
  final Duration responseWindow;

  /// Minimum non-provisional readings required for the baseline.
  final int minimumBaselineReadings;

  /// Minimum non-provisional post-meal readings required for a response.
  final int minimumPostMealReadings;

  /// Minimum fraction of [responseWindow] observed before a response is ready.
  final double minimumCoverage;

  /// Largest permitted gap from the meal to the first sample, between samples,
  /// or from the final sample to the end of the response window.
  final Duration maximumGap;

  /// Whether display-provisional readings may be included.
  final bool includeProvisionalReadings;

  /// Whether a response may combine multiple [CgmRecordSource] values.
  ///
  /// The default is false because source-priority/overlap policy belongs to the
  /// data-spine work. Callers may opt in only after they have an explicit,
  /// reviewed source policy.
  final bool allowMixedSources;
}

/// The exact data-quality trace for one deterministic meal-response result.
///
/// This type contains record identifiers, windows, cadence, gaps, sources, and
/// the calculation version. It does not copy raw glucose series, journal text,
/// or any conclusion about causality.
class MealResponseEvidence {
  const MealResponseEvidence({
    required this.calculationVersion,
    required this.mealEventId,
    required this.baselineStart,
    required this.mealAt,
    required this.responseEnd,
    required this.baselineSampleIds,
    required this.postMealSampleIds,
    required this.sources,
    required this.activeSampleSpan,
    required this.observedResponseSpan,
    required this.firstPostMealDelay,
    required this.trailingGap,
    required this.largestGap,
    required this.averagePostMealCadence,
    required this.duplicateTimestampCount,
    required this.excludedProvisionalSampleCount,
    required this.excludedFutureSampleCount,
  });

  final String calculationVersion;
  final String mealEventId;
  final DateTime baselineStart;
  final DateTime mealAt;
  final DateTime responseEnd;
  final List<String> baselineSampleIds;
  final List<String> postMealSampleIds;
  final List<CgmRecordSource> sources;

  /// Span from first to last accepted post-meal sample.
  final Duration activeSampleSpan;

  /// Span from the meal timestamp to the final accepted post-meal sample.
  final Duration observedResponseSpan;

  final Duration firstPostMealDelay;
  final Duration trailingGap;
  final Duration largestGap;

  /// Mean spacing between accepted post-meal samples, or null for fewer than
  /// two samples.
  final Duration? averagePostMealCadence;

  final int duplicateTimestampCount;
  final int excludedProvisionalSampleCount;
  final int excludedFutureSampleCount;

  int get readingCount => baselineSampleIds.length + postMealSampleIds.length;

  bool get hasMixedSources => sources.length > 1;
}

/// A local, non-causal response summary for one meal journal event.
class MealResponse {
  const MealResponse({
    required this.mealId,
    required this.mealAt,
    required this.status,
    required this.baselineReadingCount,
    required this.postMealReadingCount,
    required this.coveragePercent,
    required this.evidence,
    this.carbsGrams,
    this.baselineMgdl,
    this.peakMgdl,
    this.peakDeltaMgdl,
    this.timeToPeak,
    this.observedDeltaAreaMgdlMinutes,
  });

  /// Stable local identifier of the source meal event.
  final String mealId;

  /// Timestamp of the meal event, normalised to UTC.
  final DateTime mealAt;

  final MealResponseStatus status;
  final int baselineReadingCount;
  final int postMealReadingCount;

  /// Portion of the configured response window observed, 0–100.
  final double coveragePercent;

  /// The exact windows, source records, and qualification context.
  final MealResponseEvidence evidence;

  /// Optional carbohydrates entered with the meal.
  final double? carbsGrams;

  /// Mean glucose in the baseline window, when baseline data exists.
  final double? baselineMgdl;

  /// Highest glucose in the bounded response window, when data exists.
  final double? peakMgdl;

  /// Peak minus baseline in mg/dL. Present only for a sufficient response.
  final double? peakDeltaMgdl;

  /// Time from the meal event to the response peak. Present only when enough
  /// data qualifies the response.
  final Duration? timeToPeak;

  /// Trapezoidal observed area of glucose delta above/below the local baseline,
  /// in mg/dL-minutes. It does not extrapolate across missing samples and is
  /// present only for a sufficient response.
  final double? observedDeltaAreaMgdlMinutes;

  bool get isSufficient => status == MealResponseStatus.sufficient;
}

/// Aggregate local meal-response analytics for a bounded set of meals.
class MealResponseSummary {
  const MealResponseSummary({
    required this.status,
    required this.responses,
    required this.mealCount,
    required this.sufficientMealCount,
    required this.postMealReadingCount,
    required this.averageCoveragePercent,
    required this.averagePeakDeltaMgdl,
    required this.averageTimeToPeak,
    required this.policy,
    this.safetyBoundary = mealResponseSafetyBoundary,
  });

  final MealResponseSummaryStatus status;
  final List<MealResponse> responses;
  final int mealCount;
  final int sufficientMealCount;
  final int postMealReadingCount;
  final double? averageCoveragePercent;
  final double? averagePeakDeltaMgdl;
  final Duration? averageTimeToPeak;
  final MealResponsePolicy policy;

  /// Required display caveat for all consumers of this derived signal.
  final String safetyBoundary;

  bool get hasSufficientData => sufficientMealCount > 0;
}

/// Required wellness framing for meal-response surfaces.
const String mealResponseSafetyBoundary =
    'Local glucose and meal timing observations are not causal or medical advice.';

/// Deterministic, provider-free pairing of meals with identified CGM readings.
///
/// The engine uses a 30-minute pre-meal baseline and two-hour response window
/// by default. It reports gaps, duplicates, source mixing, and insufficiency
/// instead of filling missing data or suggesting that a meal caused a change.
abstract final class MealResponseAnalytics {
  static MealResponseSummary analyze({
    required List<HealthEvent> events,
    required List<IdentifiedGlucoseReading> readings,
    MealResponsePolicy policy = const MealResponsePolicy(),
    DateTime? now,
  }) {
    _validatePolicy(policy);
    _validateReadingIds(readings);
    final reference = now?.toUtc();
    final meals = events
        .where(
          (event) =>
              event.type == HealthEventType.meal &&
              (reference == null ||
                  !event.timestamp.toUtc().isAfter(reference)),
        )
        .toList(growable: false);
    final orderedMeals = _stableMealOrder(meals);
    if (orderedMeals.isEmpty) {
      return MealResponseSummary(
        status: MealResponseSummaryStatus.noMeals,
        responses: const <MealResponse>[],
        mealCount: 0,
        sufficientMealCount: 0,
        postMealReadingCount: 0,
        averageCoveragePercent: null,
        averagePeakDeltaMgdl: null,
        averageTimeToPeak: null,
        policy: policy,
      );
    }

    final eligible = _eligibleReadings(
      readings,
      includeProvisional: policy.includeProvisionalReadings,
      now: reference,
    );
    final responses = orderedMeals
        .map(
          (meal) => _analyzeMeal(
            meal,
            eligible.readings,
            policy,
            excludedProvisionalSampleCount: eligible.excludedProvisionalCount,
            excludedFutureSampleCount: eligible.excludedFutureCount,
          ),
        )
        .toList(growable: false);
    final sufficient = responses.where((item) => item.isSufficient).toList();
    final status = _summaryStatus(responses, sufficient);
    final coverage = responses.isEmpty
        ? null
        : _average(responses.map((item) => item.coveragePercent));
    final responseCount = responses.fold<int>(
      0,
      (sum, response) => sum + response.postMealReadingCount,
    );
    return MealResponseSummary(
      status: status,
      responses: List<MealResponse>.unmodifiable(responses),
      mealCount: responses.length,
      sufficientMealCount: sufficient.length,
      postMealReadingCount: responseCount,
      averageCoveragePercent: coverage,
      averagePeakDeltaMgdl: sufficient.isEmpty
          ? null
          : _average(sufficient.map((response) => response.peakDeltaMgdl!)),
      averageTimeToPeak: sufficient.isEmpty
          ? null
          : _averageDuration(
              sufficient.map((response) => response.timeToPeak!),
            ),
      policy: policy,
    );
  }

  static void _validatePolicy(MealResponsePolicy policy) {
    if (policy.baselineWindow <= Duration.zero ||
        policy.responseWindow <= Duration.zero ||
        policy.maximumGap <= Duration.zero ||
        policy.maximumGap > policy.responseWindow ||
        policy.minimumBaselineReadings < 1 ||
        policy.minimumPostMealReadings < 1 ||
        policy.minimumCoverage < 0 ||
        policy.minimumCoverage > 1) {
      throw ArgumentError.value(
        policy,
        'policy',
        'contains an invalid meal-response requirement',
      );
    }
  }

  static void _validateReadingIds(List<IdentifiedGlucoseReading> readings) {
    final ids = <String>{};
    for (final sample in readings) {
      if (sample.id.trim().isEmpty || !ids.add(sample.id)) {
        throw ArgumentError.value(
          sample.id,
          'readings',
          'every glucose sample id must be non-empty and unique',
        );
      }
    }
  }

  static MealResponse _analyzeMeal(
    HealthEvent meal,
    List<IdentifiedGlucoseReading> readings,
    MealResponsePolicy policy, {
    required int excludedProvisionalSampleCount,
    required int excludedFutureSampleCount,
  }) {
    final mealAt = meal.timestamp.toUtc();
    final baselineStart = mealAt.subtract(policy.baselineWindow);
    final responseEnd = mealAt.add(policy.responseWindow);
    final baseline = _selectWindow(
      readings,
      start: baselineStart,
      end: mealAt,
      includeEnd: false,
    );
    final postMeal = _selectWindow(
      readings,
      start: mealAt,
      end: responseEnd,
      includeEnd: true,
    );
    final responseTimes = postMeal.samples
        .map((sample) => sample.reading.recordedAt!.toUtc())
        .toList(growable: false);
    final first = responseTimes.isEmpty ? null : responseTimes.first;
    final last = responseTimes.isEmpty ? null : responseTimes.last;
    final activeSampleSpan = responseTimes.length < 2
        ? Duration.zero
        : last!.difference(first!);
    final observedResponseSpan = last == null
        ? Duration.zero
        : last.difference(mealAt);
    final firstPostMealDelay = first == null
        ? Duration.zero
        : first.difference(mealAt);
    final trailingGap = last == null
        ? policy.responseWindow
        : responseEnd.difference(last);
    final largestGap = _largestGap(
      mealAt: mealAt,
      responseEnd: responseEnd,
      responseTimes: responseTimes,
    );
    final sourceSet = <CgmRecordSource>{
      ...baseline.samples.map((sample) => sample.reading.source),
      ...postMeal.samples.map((sample) => sample.reading.source),
    };
    final sources = sourceSet.toList(growable: false)
      ..sort((left, right) => left.name.compareTo(right.name));
    final duplicateCount =
        baseline.duplicateTimestampCount + postMeal.duplicateTimestampCount;
    final coveragePercent =
        observedResponseSpan.inMicroseconds /
        policy.responseWindow.inMicroseconds *
        100;
    final baselineMgdl = baseline.samples.isEmpty
        ? null
        : _averageReading(baseline.samples);
    final peak = postMeal.samples.isEmpty ? null : _peak(postMeal.samples);
    final status = _mealStatus(
      baselineCount: baseline.samples.length,
      responseCount: postMeal.samples.length,
      coveragePercent: coveragePercent,
      largestGap: largestGap,
      duplicateTimestampCount: duplicateCount,
      hasMixedSources: sources.length > 1,
      policy: policy,
    );
    final isSufficient = status == MealResponseStatus.sufficient;
    final payload = meal.payload;
    final evidence = MealResponseEvidence(
      calculationVersion: mealResponseCalculationVersion,
      mealEventId: meal.id,
      baselineStart: baselineStart,
      mealAt: mealAt,
      responseEnd: responseEnd,
      baselineSampleIds: List<String>.unmodifiable(
        baseline.samples.map((sample) => sample.id),
      ),
      postMealSampleIds: List<String>.unmodifiable(
        postMeal.samples.map((sample) => sample.id),
      ),
      sources: List<CgmRecordSource>.unmodifiable(sources),
      activeSampleSpan: activeSampleSpan,
      observedResponseSpan: observedResponseSpan,
      firstPostMealDelay: firstPostMealDelay,
      trailingGap: trailingGap,
      largestGap: largestGap,
      averagePostMealCadence: _averageCadence(responseTimes),
      duplicateTimestampCount: duplicateCount,
      excludedProvisionalSampleCount: excludedProvisionalSampleCount,
      excludedFutureSampleCount: excludedFutureSampleCount,
    );
    return MealResponse(
      mealId: meal.id,
      mealAt: mealAt,
      status: status,
      baselineReadingCount: baseline.samples.length,
      postMealReadingCount: postMeal.samples.length,
      coveragePercent: coveragePercent,
      evidence: evidence,
      carbsGrams: payload is MealPayload ? payload.carbsGrams : null,
      baselineMgdl: baselineMgdl,
      peakMgdl: peak?.reading.valueMgdl,
      peakDeltaMgdl: isSufficient && baselineMgdl != null && peak != null
          ? peak.reading.valueMgdl - baselineMgdl
          : null,
      timeToPeak: isSufficient && peak != null
          ? peak.reading.recordedAt!.toUtc().difference(mealAt)
          : null,
      observedDeltaAreaMgdlMinutes: isSufficient && baselineMgdl != null
          ? _observedDeltaArea(postMeal.samples, baselineMgdl)
          : null,
    );
  }

  static MealResponseStatus _mealStatus({
    required int baselineCount,
    required int responseCount,
    required double coveragePercent,
    required Duration largestGap,
    required int duplicateTimestampCount,
    required bool hasMixedSources,
    required MealResponsePolicy policy,
  }) {
    if (responseCount == 0) return MealResponseStatus.noPostMealReadings;
    if (duplicateTimestampCount > 0) {
      return MealResponseStatus.duplicateTimestamps;
    }
    if (hasMixedSources && !policy.allowMixedSources) {
      return MealResponseStatus.mixedSources;
    }
    if (baselineCount < policy.minimumBaselineReadings) {
      return MealResponseStatus.insufficientBaseline;
    }
    if (responseCount < policy.minimumPostMealReadings) {
      return MealResponseStatus.insufficientPostMealReadings;
    }
    if (coveragePercent < policy.minimumCoverage * 100) {
      return MealResponseStatus.insufficientCoverage;
    }
    if (largestGap > policy.maximumGap) {
      return MealResponseStatus.excessiveGap;
    }
    return MealResponseStatus.sufficient;
  }

  static MealResponseSummaryStatus _summaryStatus(
    List<MealResponse> responses,
    List<MealResponse> sufficient,
  ) {
    if (sufficient.isEmpty) {
      final hasPostMeal = responses.any(
        (response) => response.postMealReadingCount > 0,
      );
      return hasPostMeal
          ? MealResponseSummaryStatus.insufficientData
          : MealResponseSummaryStatus.noGlucoseReadings;
    }
    return sufficient.length == responses.length
        ? MealResponseSummaryStatus.ready
        : MealResponseSummaryStatus.partial;
  }

  static List<HealthEvent> _stableMealOrder(List<HealthEvent> meals) {
    final indexed = meals.asMap().entries.toList(growable: false)
      ..sort((left, right) {
        final byTime = left.value.timestamp.toUtc().compareTo(
          right.value.timestamp.toUtc(),
        );
        if (byTime != 0) return byTime;
        final byId = left.value.id.compareTo(right.value.id);
        return byId == 0 ? left.key.compareTo(right.key) : byId;
      });
    return indexed.map((entry) => entry.value).toList(growable: false);
  }

  static _EligibleReadings _eligibleReadings(
    List<IdentifiedGlucoseReading> readings, {
    required bool includeProvisional,
    required DateTime? now,
  }) {
    var excludedProvisional = 0;
    var excludedFuture = 0;
    final output = <IdentifiedGlucoseReading>[];
    for (final sample in readings) {
      final at = sample.reading.recordedAt;
      if (at == null ||
          !sample.reading.valueMgdl.isFinite ||
          sample.reading.valueMgdl <= 0) {
        continue;
      }
      if (now != null && at.toUtc().isAfter(now)) {
        excludedFuture++;
        continue;
      }
      if (!includeProvisional && sample.reading.isDisplayProvisional) {
        excludedProvisional++;
        continue;
      }
      output.add(sample);
    }
    output.sort(_compareSamples);
    return _EligibleReadings(
      readings: List<IdentifiedGlucoseReading>.unmodifiable(output),
      excludedProvisionalCount: excludedProvisional,
      excludedFutureCount: excludedFuture,
    );
  }

  static _SelectedWindow _selectWindow(
    List<IdentifiedGlucoseReading> readings, {
    required DateTime start,
    required DateTime end,
    required bool includeEnd,
  }) {
    final window = readings
        .where((sample) {
          final at = sample.reading.recordedAt!.toUtc();
          return !at.isBefore(start) &&
              (includeEnd ? !at.isAfter(end) : at.isBefore(end));
        })
        .toList(growable: false);
    if (window.length < 2) {
      return _SelectedWindow(samples: window, duplicateTimestampCount: 0);
    }
    final samples = <IdentifiedGlucoseReading>[];
    var duplicateTimestampCount = 0;
    DateTime? previous;
    for (final sample in window) {
      final timestamp = sample.reading.recordedAt!.toUtc();
      if (previous != null && timestamp == previous) {
        duplicateTimestampCount++;
        continue;
      }
      samples.add(sample);
      previous = timestamp;
    }
    return _SelectedWindow(
      samples: List<IdentifiedGlucoseReading>.unmodifiable(samples),
      duplicateTimestampCount: duplicateTimestampCount,
    );
  }

  static int _compareSamples(
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
    return bySource == 0 ? left.id.compareTo(right.id) : bySource;
  }

  static Duration _largestGap({
    required DateTime mealAt,
    required DateTime responseEnd,
    required List<DateTime> responseTimes,
  }) {
    if (responseTimes.isEmpty) return responseEnd.difference(mealAt);
    var largest = responseTimes.first.difference(mealAt);
    for (var index = 1; index < responseTimes.length; index++) {
      final gap = responseTimes[index].difference(responseTimes[index - 1]);
      if (gap > largest) largest = gap;
    }
    final trailing = responseEnd.difference(responseTimes.last);
    return trailing > largest ? trailing : largest;
  }

  static Duration? _averageCadence(List<DateTime> responseTimes) {
    if (responseTimes.length < 2) return null;
    var totalMicroseconds = 0;
    for (var index = 1; index < responseTimes.length; index++) {
      totalMicroseconds += responseTimes[index]
          .difference(responseTimes[index - 1])
          .inMicroseconds;
    }
    return Duration(
      microseconds: (totalMicroseconds / (responseTimes.length - 1)).round(),
    );
  }

  static IdentifiedGlucoseReading _peak(
    List<IdentifiedGlucoseReading> readings,
  ) {
    var peak = readings.first;
    for (final reading in readings.skip(1)) {
      if (reading.reading.valueMgdl > peak.reading.valueMgdl) peak = reading;
    }
    return peak;
  }

  static double _averageReading(List<IdentifiedGlucoseReading> readings) =>
      _average(readings.map((sample) => sample.reading.valueMgdl))!;

  static double _observedDeltaArea(
    List<IdentifiedGlucoseReading> readings,
    double baselineMgdl,
  ) {
    var area = 0.0;
    for (var index = 1; index < readings.length; index++) {
      final previous = readings[index - 1].reading;
      final current = readings[index].reading;
      final minutes =
          current.recordedAt!
              .toUtc()
              .difference(previous.recordedAt!.toUtc())
              .inMicroseconds /
          Duration.microsecondsPerMinute;
      final previousDelta = previous.valueMgdl - baselineMgdl;
      final currentDelta = current.valueMgdl - baselineMgdl;
      area += (previousDelta + currentDelta) / 2 * minutes;
    }
    return area;
  }

  static double? _average(Iterable<double> values) {
    final list = values.toList(growable: false);
    if (list.isEmpty) return null;
    return list.reduce((left, right) => left + right) / list.length;
  }

  static Duration _averageDuration(Iterable<Duration> values) {
    final list = values.toList(growable: false);
    final micros = list
        .map((value) => value.inMicroseconds)
        .reduce((left, right) => left + right);
    return Duration(microseconds: (micros / list.length).round());
  }
}

class _EligibleReadings {
  const _EligibleReadings({
    required this.readings,
    required this.excludedProvisionalCount,
    required this.excludedFutureCount,
  });

  final List<IdentifiedGlucoseReading> readings;
  final int excludedProvisionalCount;
  final int excludedFutureCount;
}

class _SelectedWindow {
  const _SelectedWindow({
    required this.samples,
    required this.duplicateTimestampCount,
  });

  final List<IdentifiedGlucoseReading> samples;
  final int duplicateTimestampCount;
}
