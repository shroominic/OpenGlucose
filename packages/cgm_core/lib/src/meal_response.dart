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

  /// One or more display-provisional readings were accepted for inspection.
  ///
  /// This status is deliberately not sufficient. A caller may opt in to retain
  /// provisional samples in the evidence, but it must not present their
  /// derived response metrics as a normal qualified result.
  provisionalReadings,

  /// Baseline, count, coverage, cadence, source, and finality requirements
  /// are met.
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
       assert(minimumPostMealReadings > 0);

  /// Time before a meal used to estimate its local baseline.
  final Duration baselineWindow;

  /// Maximum time after a meal used for response readings.
  final Duration responseWindow;

  /// Minimum non-provisional readings required for the baseline.
  final int minimumBaselineReadings;

  /// Minimum non-provisional post-meal readings required for a response.
  final int minimumPostMealReadings;

  /// Minimum fraction of [responseWindow] observed before a response is ready.
  ///
  /// [MealResponseAnalytics.analyze] rejects non-finite values and values
  /// outside the inclusive 0–1 range.
  final double minimumCoverage;

  /// Largest permitted gap from the meal to the first sample, between samples,
  /// or from the final sample to the end of the response window.
  final Duration maximumGap;

  /// Whether display-provisional readings may be retained for inspection.
  ///
  /// An accepted provisional reading always produces
  /// [MealResponseStatus.provisionalReadings], so it never makes a response
  /// sufficient. This option lets a caller inspect the evidence without
  /// treating provisional data as a normal response summary.
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
    required this.acceptedProvisionalBaselineSampleCount,
    required this.acceptedProvisionalPostMealSampleCount,
    required this.excludedProvisionalBaselineSampleCount,
    required this.excludedProvisionalPostMealSampleCount,
    required this.excludedFutureBaselineSampleCount,
    required this.excludedFuturePostMealSampleCount,
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

  /// Accepted display-provisional samples in the baseline window.
  final int acceptedProvisionalBaselineSampleCount;

  /// Accepted display-provisional samples in the post-meal response window.
  final int acceptedProvisionalPostMealSampleCount;

  /// Provisional samples excluded from the baseline window by the policy.
  final int excludedProvisionalBaselineSampleCount;

  /// Provisional samples excluded from the post-meal window by the policy.
  final int excludedProvisionalPostMealSampleCount;

  /// Future samples excluded from the baseline window relative to `now`.
  final int excludedFutureBaselineSampleCount;

  /// Future samples excluded from the post-meal window relative to `now`.
  final int excludedFuturePostMealSampleCount;

  int get readingCount => baselineSampleIds.length + postMealSampleIds.length;

  bool get hasMixedSources => sources.length > 1;

  /// Whether any selected sample was display-provisional.
  ///
  /// When true, the response status is
  /// [MealResponseStatus.provisionalReadings] and is never sufficient.
  bool get hasAcceptedProvisionalReadings => acceptedProvisionalSampleCount > 0;

  /// Total accepted display-provisional samples across this meal's windows.
  int get acceptedProvisionalSampleCount =>
      acceptedProvisionalBaselineSampleCount +
      acceptedProvisionalPostMealSampleCount;

  /// Total excluded provisional samples across this meal's windows.
  int get excludedProvisionalSampleCount =>
      excludedProvisionalBaselineSampleCount +
      excludedProvisionalPostMealSampleCount;

  /// Total excluded future samples across this meal's windows.
  int get excludedFutureSampleCount =>
      excludedFutureBaselineSampleCount + excludedFuturePostMealSampleCount;
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
    _validateMealIds(orderedMeals);
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

    final eligibleReadings = _eligibleReadings(
      readings,
      includeProvisional: policy.includeProvisionalReadings,
      now: reference,
    );
    final responses = orderedMeals
        .map(
          (meal) => _analyzeMeal(
            meal,
            eligibleReadings,
            policy,
            allReadings: readings,
            now: reference,
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
        !policy.minimumCoverage.isFinite ||
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

  static void _validateMealIds(List<HealthEvent> meals) {
    final ids = <String>{};
    for (final meal in meals) {
      final normalizedId = meal.id.trim();
      if (normalizedId.isEmpty || !ids.add(normalizedId)) {
        throw ArgumentError.value(
          meal.id,
          'events',
          'every selected meal id must be non-empty and unique',
        );
      }
    }
  }

  static MealResponse _analyzeMeal(
    HealthEvent meal,
    List<IdentifiedGlucoseReading> readings,
    MealResponsePolicy policy, {
    required List<IdentifiedGlucoseReading> allReadings,
    required DateTime? now,
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
    final exclusions = _excludedWindowCounts(
      allReadings,
      baselineStart: baselineStart,
      mealAt: mealAt,
      responseEnd: responseEnd,
      includeProvisional: policy.includeProvisionalReadings,
      now: now,
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
      acceptedProvisionalSampleCount:
          baseline.acceptedProvisionalSampleCount +
          postMeal.acceptedProvisionalSampleCount,
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
      acceptedProvisionalBaselineSampleCount:
          baseline.acceptedProvisionalSampleCount,
      acceptedProvisionalPostMealSampleCount:
          postMeal.acceptedProvisionalSampleCount,
      excludedProvisionalBaselineSampleCount:
          exclusions.provisionalBaselineCount,
      excludedProvisionalPostMealSampleCount:
          exclusions.provisionalPostMealCount,
      excludedFutureBaselineSampleCount: exclusions.futureBaselineCount,
      excludedFuturePostMealSampleCount: exclusions.futurePostMealCount,
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
    required int acceptedProvisionalSampleCount,
    required bool hasMixedSources,
    required MealResponsePolicy policy,
  }) {
    if (acceptedProvisionalSampleCount > 0) {
      return MealResponseStatus.provisionalReadings;
    }
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
    if (!coveragePercent.isFinite ||
        coveragePercent < policy.minimumCoverage * 100) {
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

  static List<IdentifiedGlucoseReading> _eligibleReadings(
    List<IdentifiedGlucoseReading> readings, {
    required bool includeProvisional,
    required DateTime? now,
  }) {
    final output = <IdentifiedGlucoseReading>[];
    for (final sample in readings) {
      final at = sample.reading.recordedAt;
      if (at == null ||
          !sample.reading.valueMgdl.isFinite ||
          sample.reading.valueMgdl <= 0) {
        continue;
      }
      if (now != null && at.toUtc().isAfter(now)) {
        continue;
      }
      if (!includeProvisional && sample.reading.isDisplayProvisional) {
        continue;
      }
      output.add(sample);
    }
    output.sort(_compareSamples);
    return List<IdentifiedGlucoseReading>.unmodifiable(output);
  }

  static _ExcludedWindowCounts _excludedWindowCounts(
    List<IdentifiedGlucoseReading> readings, {
    required DateTime baselineStart,
    required DateTime mealAt,
    required DateTime responseEnd,
    required bool includeProvisional,
    required DateTime? now,
  }) {
    var provisionalBaselineCount = 0;
    var provisionalPostMealCount = 0;
    var futureBaselineCount = 0;
    var futurePostMealCount = 0;

    for (final sample in readings) {
      final at = sample.reading.recordedAt;
      if (at == null ||
          !sample.reading.valueMgdl.isFinite ||
          sample.reading.valueMgdl <= 0) {
        continue;
      }
      final timestamp = at.toUtc();
      final isBaseline =
          !timestamp.isBefore(baselineStart) && timestamp.isBefore(mealAt);
      final isPostMeal =
          !timestamp.isBefore(mealAt) && !timestamp.isAfter(responseEnd);
      if (!isBaseline && !isPostMeal) continue;

      if (now != null && timestamp.isAfter(now)) {
        if (isBaseline) {
          futureBaselineCount++;
        } else {
          futurePostMealCount++;
        }
        continue;
      }
      if (!includeProvisional && sample.reading.isDisplayProvisional) {
        if (isBaseline) {
          provisionalBaselineCount++;
        } else {
          provisionalPostMealCount++;
        }
      }
    }

    return _ExcludedWindowCounts(
      provisionalBaselineCount: provisionalBaselineCount,
      provisionalPostMealCount: provisionalPostMealCount,
      futureBaselineCount: futureBaselineCount,
      futurePostMealCount: futurePostMealCount,
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
      return _SelectedWindow(
        samples: List<IdentifiedGlucoseReading>.unmodifiable(window),
        duplicateTimestampCount: 0,
        acceptedProvisionalSampleCount: _provisionalSampleCount(window),
      );
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
      acceptedProvisionalSampleCount: _provisionalSampleCount(samples),
    );
  }

  static int _provisionalSampleCount(List<IdentifiedGlucoseReading> samples) =>
      samples.where((sample) => sample.reading.isDisplayProvisional).length;

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

class _SelectedWindow {
  const _SelectedWindow({
    required this.samples,
    required this.duplicateTimestampCount,
    required this.acceptedProvisionalSampleCount,
  });

  final List<IdentifiedGlucoseReading> samples;
  final int duplicateTimestampCount;
  final int acceptedProvisionalSampleCount;
}

class _ExcludedWindowCounts {
  const _ExcludedWindowCounts({
    required this.provisionalBaselineCount,
    required this.provisionalPostMealCount,
    required this.futureBaselineCount,
    required this.futurePostMealCount,
  });

  final int provisionalBaselineCount;
  final int provisionalPostMealCount;
  final int futureBaselineCount;
  final int futurePostMealCount;
}
