import 'cgm_models.dart';
import 'health_event.dart';

/// Why a meal response is not ready to summarize.
///
/// These states describe local data coverage only. A ready response still
/// does not establish that a meal caused a glucose change.
enum MealResponseStatus {
  /// No eligible post-meal readings were available in the response window.
  noPostMealReadings,

  /// Post-meal readings exist, but the pre-meal baseline is too sparse.
  noBaseline,

  /// The response window has fewer readings than the configured minimum.
  insufficientPostMealReadings,

  /// The response window does not cover enough of the configured duration.
  insufficientCoverage,

  /// Baseline, count, and window coverage are sufficient for this summary.
  sufficient;

  String get key => name;
}

/// Aggregate state for a set of meal responses.
enum MealResponseSummaryStatus {
  /// No meal journal events were in the requested input.
  noMeals,

  /// Meals were present, but none had an eligible post-meal reading.
  noGlucoseReadings,

  /// Meals or readings exist, but no meal has enough data for a summary.
  insufficientData,

  /// At least one meal is sufficient, but one or more meals are incomplete.
  partial,

  /// Every meal has sufficient data for a response summary.
  ready;

  String get key => name;
}

/// Conservative windows and minimums used by [MealResponseAnalytics].
class MealResponsePolicy {
  const MealResponsePolicy({
    this.baselineWindow = const Duration(minutes: 30),
    this.responseWindow = const Duration(hours: 2),
    this.minimumBaselineReadings = 2,
    this.minimumPostMealReadings = 3,
    this.minimumCoverage = 0.5,
    this.includeProvisionalReadings = false,
  }) : assert(minimumBaselineReadings > 0),
       assert(minimumPostMealReadings > 0),
       assert(minimumCoverage >= 0 && minimumCoverage <= 1);

  /// Time before the meal used to estimate the local baseline.
  final Duration baselineWindow;

  /// Maximum time after the meal used for response readings.
  final Duration responseWindow;

  /// Minimum non-provisional baseline readings required for a delta.
  final int minimumBaselineReadings;

  /// Minimum non-provisional post-meal readings required for a delta.
  final int minimumPostMealReadings;

  /// Minimum fraction of [responseWindow] observed before a response is ready.
  final double minimumCoverage;

  /// Whether readings marked as display-provisional may be used.
  final bool includeProvisionalReadings;
}

/// A local, non-causal response summary for one meal journal event.
class MealResponse {
  const MealResponse({
    required this.mealId,
    required this.mealAt,
    required this.status,
    required this.baselineReadingCount,
    required this.postMealReadingCount,
    required this.observedDuration,
    required this.coveragePercent,
    this.description,
    this.carbsGrams,
    this.baselineMgdl,
    this.peakMgdl,
    this.peakDeltaMgdl,
    this.timeToPeak,
  });

  /// Stable local identifier of the source meal event.
  final String mealId;

  /// Timestamp of the meal event.
  final DateTime mealAt;

  /// Optional meal description retained for a compact local UI.
  final String? description;

  /// Optional carbohydrates entered with the meal.
  final double? carbsGrams;

  final MealResponseStatus status;
  final int baselineReadingCount;
  final int postMealReadingCount;
  final Duration observedDuration;

  /// Portion of the configured response window that has been observed, 0–100.
  final double coveragePercent;

  /// Mean glucose in the baseline window, only when baseline data is present.
  final double? baselineMgdl;

  /// Highest glucose in the bounded response window, when post-meal data exists.
  final double? peakMgdl;

  /// Peak minus baseline in mg/dL. Only populated for [sufficient] responses.
  final double? peakDeltaMgdl;

  /// Time from the meal event to the response peak. Only populated for
  /// [sufficient] responses.
  final Duration? timeToPeak;

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
const mealResponseSafetyBoundary =
    'Local glucose and meal timing observations are not causal or medical advice.';

/// Deterministic, provider-free pairing of meals with CGM readings.
///
/// The engine uses a 30-minute pre-meal baseline and a two-hour response
/// window by default. It reports data coverage and conservative insufficiency
/// states rather than filling gaps or suggesting that a meal caused a change.
abstract final class MealResponseAnalytics {
  static MealResponseSummary analyze({
    required List<HealthEvent> events,
    required List<CgmReading> readings,
    MealResponsePolicy policy = const MealResponsePolicy(),
    DateTime? now,
  }) {
    _validatePolicy(policy);
    final reference = now?.toUtc();
    final meals = events
        .where(
          (event) =>
              event.type == HealthEventType.meal &&
              (reference == null || !event.timestamp.isAfter(reference)),
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

    final eligibleReadings = _eligibleReadings(
      readings,
      includeProvisional: policy.includeProvisionalReadings,
      now: reference,
    );
    final responses = orderedMeals
        .map((meal) => _analyzeMeal(meal, eligibleReadings, policy))
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
          : _average(
              sufficient
                  .map((response) => response.peakDeltaMgdl!)
                  .toList(growable: false),
            ),
      averageTimeToPeak: sufficient.isEmpty
          ? null
          : _averageDuration(
              sufficient
                  .map((response) => response.timeToPeak!)
                  .toList(growable: false),
            ),
      policy: policy,
    );
  }

  static void _validatePolicy(MealResponsePolicy policy) {
    if (policy.baselineWindow <= Duration.zero ||
        policy.responseWindow <= Duration.zero ||
        policy.minimumBaselineReadings < 1 ||
        policy.minimumPostMealReadings < 1 ||
        policy.minimumCoverage < 0 ||
        policy.minimumCoverage > 1) {
      throw ArgumentError.value(
        policy,
        'policy',
        'baseline and response windows must be positive',
      );
    }
  }

  static MealResponse _analyzeMeal(
    HealthEvent meal,
    List<CgmReading> readings,
    MealResponsePolicy policy,
  ) {
    final mealAt = meal.timestamp.toUtc();
    final baselineStart = mealAt.subtract(policy.baselineWindow);
    final responseEnd = mealAt.add(policy.responseWindow);
    final baseline = readings
        .where((reading) {
          final at = reading.recordedAt!.toUtc();
          return !at.isBefore(baselineStart) && at.isBefore(mealAt);
        })
        .toList(growable: false);
    final responseReadings = readings
        .where((reading) {
          final at = reading.recordedAt!.toUtc();
          return !at.isBefore(mealAt) && !at.isAfter(responseEnd);
        })
        .toList(growable: false);
    final observedDuration = responseReadings.isEmpty
        ? Duration.zero
        : responseReadings.last.recordedAt!.toUtc().difference(mealAt);
    final boundedObserved = observedDuration < Duration.zero
        ? Duration.zero
        : observedDuration > policy.responseWindow
        ? policy.responseWindow
        : observedDuration;
    final coveragePercent =
        boundedObserved.inMicroseconds /
        policy.responseWindow.inMicroseconds *
        100;
    final baselineMgdl = baseline.isEmpty ? null : _averageReading(baseline);
    final peak = responseReadings.isEmpty ? null : _peak(responseReadings);
    final status = _mealStatus(
      baselineCount: baseline.length,
      responseCount: responseReadings.length,
      coveragePercent: coveragePercent,
      policy: policy,
    );
    final sufficient = status == MealResponseStatus.sufficient;
    final peakDelta = sufficient && baselineMgdl != null && peak != null
        ? peak.valueMgdl - baselineMgdl
        : null;
    final timeToPeak = sufficient && peak != null
        ? peak.recordedAt!.toUtc().difference(mealAt)
        : null;
    final payload = meal.payload;
    return MealResponse(
      mealId: meal.id,
      mealAt: mealAt,
      description: payload is MealPayload ? payload.description : null,
      carbsGrams: payload is MealPayload ? payload.carbsGrams : null,
      status: status,
      baselineReadingCount: baseline.length,
      postMealReadingCount: responseReadings.length,
      observedDuration: boundedObserved,
      coveragePercent: coveragePercent,
      baselineMgdl: baselineMgdl,
      peakMgdl: peak?.valueMgdl,
      peakDeltaMgdl: peakDelta,
      timeToPeak: timeToPeak,
    );
  }

  static MealResponseStatus _mealStatus({
    required int baselineCount,
    required int responseCount,
    required double coveragePercent,
    required MealResponsePolicy policy,
  }) {
    if (responseCount == 0) return MealResponseStatus.noPostMealReadings;
    if (baselineCount < policy.minimumBaselineReadings) {
      return MealResponseStatus.noBaseline;
    }
    if (responseCount < policy.minimumPostMealReadings) {
      return MealResponseStatus.insufficientPostMealReadings;
    }
    if (coveragePercent < policy.minimumCoverage * 100) {
      return MealResponseStatus.insufficientCoverage;
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
        final byTime = left.value.timestamp.compareTo(right.value.timestamp);
        return byTime == 0 ? left.key.compareTo(right.key) : byTime;
      });
    return indexed.map((entry) => entry.value).toList(growable: false);
  }

  static List<CgmReading> _eligibleReadings(
    List<CgmReading> readings, {
    required bool includeProvisional,
    required DateTime? now,
  }) {
    final seen = <int>{};
    final indexed =
        readings
            .asMap()
            .entries
            .where((entry) {
              final reading = entry.value;
              final at = reading.recordedAt;
              return at != null &&
                  (includeProvisional || !reading.isDisplayProvisional) &&
                  (now == null || !at.isAfter(now));
            })
            .toList(growable: false)
          ..sort((left, right) {
            final byTime = left.value.recordedAt!.compareTo(
              right.value.recordedAt!,
            );
            return byTime == 0 ? left.key.compareTo(right.key) : byTime;
          });
    final output = <CgmReading>[];
    for (final entry in indexed) {
      final key = entry.value.recordedAt!.toUtc().microsecondsSinceEpoch;
      if (seen.add(key)) output.add(entry.value);
    }
    return List<CgmReading>.unmodifiable(output);
  }

  static CgmReading _peak(List<CgmReading> readings) {
    var peak = readings.first;
    for (final reading in readings.skip(1)) {
      if (reading.valueMgdl > peak.valueMgdl) peak = reading;
    }
    return peak;
  }

  static double _averageReading(List<CgmReading> readings) => _average(
    readings.map((reading) => reading.valueMgdl).toList(growable: false),
  )!;

  static double? _average(Iterable<double> values) {
    final list = values.toList(growable: false);
    if (list.isEmpty) return null;
    return list.reduce((left, right) => left + right) / list.length;
  }

  static Duration _averageDuration(List<Duration> values) {
    final micros = values
        .map((value) => value.inMicroseconds)
        .reduce((left, right) => left + right);
    return Duration(microseconds: (micros / values.length).round());
  }
}
