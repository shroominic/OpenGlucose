import 'cgm_models.dart';
import 'glucose_analytics.dart';
import 'health_event.dart';
import 'health_samples.dart';
import 'timeline.dart';

/// A stable category for an explainable, deterministic observation.
///
/// Observations are deliberately narrower than clinical interpretations. They
/// describe what the local data contains and leave any meaning or action to
/// the user. In particular, an observation must not be used as a diagnosis,
/// treatment recommendation, dose calculation, or emergency alert.
enum ObservationKind {
  coverage,
  glucoseLevel,
  glucoseRange,
  variability,
  spike,
  mealContext,
  activityContext,
  sleepContext,
  heartRateContext;

  String get key => name;

  static ObservationKind fromKey(String? key) {
    for (final value in values) {
      if (value.name == key) return value;
    }
    return ObservationKind.coverage;
  }
}

/// The type of aggregate used to support an observation.
enum EvidenceKind {
  glucose,
  event,
  activity,
  sleep,
  heartRate,
  coverage;

  String get key => name;

  static EvidenceKind fromKey(String? key) {
    for (final value in values) {
      if (value.name == key) return value;
    }
    return EvidenceKind.coverage;
  }
}

/// A typed, privacy-minimized pointer to the data supporting an observation.
///
/// Evidence stores aggregates and counts, never a raw glucose series or note
/// body. The stable [id] is safe to include in a prompt and lets a caller
/// render exactly which local facts support an AI-generated insight.
class ObservationEvidence {
  const ObservationEvidence({
    required this.id,
    required this.kind,
    required this.label,
    required this.windowStart,
    required this.windowEnd,
    required this.sampleCount,
    this.value,
    this.unit,
    this.source,
  });

  final String id;
  final EvidenceKind kind;
  final String label;
  final DateTime windowStart;
  final DateTime windowEnd;
  final int sampleCount;
  final double? value;
  final String? unit;
  final String? source;

  Map<String, Object?> toJson() {
    _validate();
    return <String, Object?>{
      'formatVersion': _observationFormatVersion,
      'id': id,
      'kind': kind.key,
      'label': label,
      'windowStart': windowStart.toUtc().toIso8601String(),
      'windowEnd': windowEnd.toUtc().toIso8601String(),
      'sampleCount': sampleCount,
      'value': value,
      'unit': unit,
      'source': source,
    };
  }

  factory ObservationEvidence.fromJson(Map<String, Object?> json) {
    final start = _readDate(json, 'windowStart');
    final end = _readDate(json, 'windowEnd');
    final sampleCount = json['sampleCount'];
    if (sampleCount is! int || sampleCount < 0) {
      throw const FormatException('sampleCount must be a non-negative int');
    }
    final value = (json['value'] as num?)?.toDouble();
    if (value != null && !value.isFinite) {
      throw const FormatException('value must be finite');
    }
    final id = json['id'];
    final label = json['label'];
    if (id is! String || id.isEmpty || label is! String || label.isEmpty) {
      throw const FormatException('evidence id and label must be non-empty');
    }
    return ObservationEvidence(
      id: id,
      kind: EvidenceKind.fromKey(json['kind'] as String?),
      label: label,
      windowStart: start,
      windowEnd: end,
      sampleCount: sampleCount,
      value: value,
      unit: _readOptionalString(json, 'unit'),
      source: _readOptionalString(json, 'source'),
    );
  }

  void _validate() {
    if (id.isEmpty || label.isEmpty) {
      throw const FormatException('evidence id and label must be non-empty');
    }
    if (sampleCount < 0) {
      throw const FormatException('sampleCount must be non-negative');
    }
    if (windowEnd.isBefore(windowStart)) {
      throw const FormatException(
        'evidence windowEnd must be after windowStart',
      );
    }
    if (value != null && !value!.isFinite) {
      throw const FormatException('value must be finite');
    }
  }
}

/// A deterministic observation over a bounded local timeline window.
class MetabolicObservation {
  const MetabolicObservation({
    required this.id,
    required this.kind,
    required this.title,
    required this.summary,
    required this.windowStart,
    required this.windowEnd,
    required this.evidence,
    this.caveat = _defaultObservationCaveat,
  });

  final String id;
  final ObservationKind kind;
  final String title;
  final String summary;
  final DateTime windowStart;
  final DateTime windowEnd;
  final List<ObservationEvidence> evidence;
  final String caveat;

  /// Every observation is explainable by at least one local aggregate.
  bool get isEvidenceBacked => evidence.isNotEmpty;

  Map<String, Object?> toJson() {
    if (id.isEmpty || title.isEmpty || summary.isEmpty) {
      throw const FormatException('observation fields must be non-empty');
    }
    if (windowEnd.isBefore(windowStart)) {
      throw const FormatException(
        'observation windowEnd must be after windowStart',
      );
    }
    if (!isEvidenceBacked) {
      throw const FormatException('observation must include evidence');
    }
    return <String, Object?>{
      'formatVersion': _observationFormatVersion,
      'id': id,
      'kind': kind.key,
      'title': title,
      'summary': summary,
      'windowStart': windowStart.toUtc().toIso8601String(),
      'windowEnd': windowEnd.toUtc().toIso8601String(),
      'evidence': evidence.map((item) => item.toJson()).toList(growable: false),
      'caveat': caveat,
    };
  }

  factory MetabolicObservation.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    final summary = json['summary'];
    if (id is! String ||
        id.isEmpty ||
        title is! String ||
        title.isEmpty ||
        summary is! String ||
        summary.isEmpty) {
      throw const FormatException('observation fields must be non-empty');
    }
    final evidenceJson = json['evidence'];
    if (evidenceJson is! List) {
      throw const FormatException('observation evidence must be a list');
    }
    final evidence = evidenceJson
        .whereType<Map>()
        .map(
          (item) => ObservationEvidence.fromJson(
            item.map((key, value) => MapEntry('$key', value)),
          ),
        )
        .toList(growable: false);
    if (evidence.isEmpty) {
      throw const FormatException('observation must include evidence');
    }
    return MetabolicObservation(
      id: id,
      kind: ObservationKind.fromKey(json['kind'] as String?),
      title: title,
      summary: summary,
      windowStart: _readDate(json, 'windowStart'),
      windowEnd: _readDate(json, 'windowEnd'),
      evidence: evidence,
      caveat: _readOptionalString(json, 'caveat') ?? _defaultObservationCaveat,
    );
  }
}

/// Produces explainable observations from local glucose and context data.
///
/// This engine is intentionally deterministic and provider-free. It makes no
/// causal or clinical claims; context observations only report logged overlap
/// and coverage so users can decide what to explore themselves.
abstract final class MetabolicObservationEngine {
  static List<MetabolicObservation> generate({
    required List<CgmReading> readings,
    required List<HealthEvent> events,
    required DateTime windowStart,
    required DateTime windowEnd,
    List<ActivitySample> activitySamples = const <ActivitySample>[],
    List<SleepSample> sleepSamples = const <SleepSample>[],
    List<HeartRateSample> heartRateSamples = const <HeartRateSample>[],
    GlucoseRangeBounds bounds = GlucoseRangeBounds.standard,
    GlucoseUnit unit = GlucoseUnit.mgdl,
  }) {
    if (windowEnd.isBefore(windowStart)) {
      throw ArgumentError.value(
        windowEnd,
        'windowEnd',
        'must not be before start',
      );
    }
    final windowReadings = readings
        .where((reading) {
          final at = reading.recordedAt;
          return at != null &&
              !at.isBefore(windowStart) &&
              at.isBefore(windowEnd);
        })
        .toList(growable: false);
    final windowEvents = events
        .where((event) => _inWindow(event.timestamp, windowStart, windowEnd))
        .toList(growable: false);
    final windowActivity = activitySamples
        .where(
          (sample) =>
              _overlaps(sample.start, sample.end, windowStart, windowEnd),
        )
        .toList(growable: false);
    final windowSleep = sleepSamples
        .where(
          (sample) =>
              _overlaps(sample.start, sample.end, windowStart, windowEnd),
        )
        .toList(growable: false);
    final windowHeartRate = heartRateSamples
        .where((sample) => _inWindow(sample.timestamp, windowStart, windowEnd))
        .toList(growable: false);

    final output = <MetabolicObservation>[
      _coverageObservation(
        readings: windowReadings,
        windowStart: windowStart,
        windowEnd: windowEnd,
      ),
    ];
    if (windowReadings.isNotEmpty) {
      final stats = GlucoseAnalytics.summarize(
        windowReadings,
        timeframe: _timeframeFor(windowEnd.difference(windowStart)),
        bounds: bounds,
        preFiltered: true,
      );
      output
        ..add(
          _levelObservation(
            stats: stats,
            windowStart: windowStart,
            windowEnd: windowEnd,
            unit: unit,
          ),
        )
        ..add(
          _rangeObservation(
            stats: stats,
            windowStart: windowStart,
            windowEnd: windowEnd,
            bounds: bounds,
          ),
        );
      if (stats.standardDeviationMgdl != null) {
        output.add(
          _variabilityObservation(
            stats: stats,
            windowStart: windowStart,
            windowEnd: windowEnd,
          ),
        );
      }
      if (stats.spikeCount > 0) {
        output.add(
          _spikeObservation(
            stats: stats,
            windowStart: windowStart,
            windowEnd: windowEnd,
            bounds: bounds,
          ),
        );
      }
    }
    final meals = windowEvents.where(
      (event) => event.type == HealthEventType.meal,
    );
    if (meals.isNotEmpty) {
      output.add(
        _mealObservation(
          meals: meals.toList(growable: false),
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
      );
    }
    if (windowActivity.isNotEmpty) {
      output.add(
        _activityObservation(
          samples: windowActivity,
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
      );
    }
    if (windowSleep.isNotEmpty) {
      output.add(
        _sleepObservation(
          samples: windowSleep,
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
      );
    }
    if (windowHeartRate.isNotEmpty) {
      output.add(
        _heartRateObservation(
          samples: windowHeartRate,
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
      );
    }
    return output;
  }

  static MetabolicObservation _coverageObservation({
    required List<CgmReading> readings,
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    final coverage = GlucoseAnalytics.assessCoverage(
      readings,
      _timeframeFor(windowEnd.difference(windowStart)),
      now: windowEnd,
    );
    final activeDays = coverage.activeDays;
    final summary = readings.isEmpty
        ? 'No timestamped glucose readings are available in this window.'
        : '${coverage.readingCount} timestamped readings across $activeDays '
              '${activeDays == 1 ? 'active day' : 'active days'}.';
    return MetabolicObservation(
      id: _observationId(ObservationKind.coverage, windowStart, windowEnd),
      kind: ObservationKind.coverage,
      title: 'Glucose coverage',
      summary: summary,
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: <ObservationEvidence>[
        _evidence(
          id: 'coverage:readings:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.coverage,
          label: 'Timestamped glucose readings',
          value: coverage.readingCount.toDouble(),
          unit: 'readings',
          sampleCount: coverage.readingCount,
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
        _evidence(
          id: 'coverage:active-days:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.coverage,
          label: 'Active days with readings',
          value: activeDays.toDouble(),
          unit: 'days',
          sampleCount: coverage.readingCount,
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
      ],
    );
  }

  static MetabolicObservation _levelObservation({
    required GlucoseStats stats,
    required DateTime windowStart,
    required DateTime windowEnd,
    required GlucoseUnit unit,
  }) {
    final average = unit.convertFromMgdl(stats.averageMgdl!);
    return MetabolicObservation(
      id: _observationId(ObservationKind.glucoseLevel, windowStart, windowEnd),
      kind: ObservationKind.glucoseLevel,
      title: 'Typical glucose level',
      summary:
          'Average glucose was ${_format(average)} ${unit.label} '
          'across ${stats.readingCount} readings.',
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: <ObservationEvidence>[
        _evidence(
          id: 'glucose:average:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.glucose,
          label: 'Average glucose',
          value: average,
          unit: unit.label,
          sampleCount: stats.readingCount,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: 'cgm',
        ),
      ],
    );
  }

  static MetabolicObservation _rangeObservation({
    required GlucoseStats stats,
    required DateTime windowStart,
    required DateTime windowEnd,
    required GlucoseRangeBounds bounds,
  }) {
    return MetabolicObservation(
      id: _observationId(ObservationKind.glucoseRange, windowStart, windowEnd),
      kind: ObservationKind.glucoseRange,
      title: 'Glucose range distribution',
      summary:
          '${_format(stats.timeInRangePercent, digits: 1)}% of readings '
          'were between ${_format(bounds.lowMgdl)} and '
          '${_format(bounds.highMgdl)} mg/dL; '
          '${_format(stats.timeAboveRangePercent, digits: 1)}% were above.',
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: <ObservationEvidence>[
        _evidence(
          id: 'glucose:in-range:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.glucose,
          label: 'Readings in the configured range',
          value: stats.timeInRangePercent,
          unit: '%',
          sampleCount: stats.readingCount,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: 'cgm',
        ),
        _evidence(
          id: 'glucose:above-range:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.glucose,
          label: 'Readings above the configured range',
          value: stats.timeAboveRangePercent,
          unit: '%',
          sampleCount: stats.readingCount,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: 'cgm',
        ),
      ],
    );
  }

  static MetabolicObservation _variabilityObservation({
    required GlucoseStats stats,
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    final standardDeviation = stats.standardDeviationMgdl!;
    final coefficientOfVariation = stats.coefficientOfVariationPercent;
    final evidence = <ObservationEvidence>[
      _evidence(
        id: 'glucose:sd:${_windowKey(windowStart, windowEnd)}',
        kind: EvidenceKind.glucose,
        label: 'Population standard deviation',
        value: standardDeviation,
        unit: 'mg/dL',
        sampleCount: stats.readingCount,
        windowStart: windowStart,
        windowEnd: windowEnd,
        source: 'cgm',
      ),
    ];
    if (coefficientOfVariation != null) {
      evidence.add(
        _evidence(
          id: 'glucose:cv:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.glucose,
          label: 'Coefficient of variation',
          value: coefficientOfVariation,
          unit: '%',
          sampleCount: stats.readingCount,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: 'cgm',
        ),
      );
    }
    return MetabolicObservation(
      id: _observationId(ObservationKind.variability, windowStart, windowEnd),
      kind: ObservationKind.variability,
      title: 'Glucose variability',
      summary:
          'The population standard deviation was '
          '${_format(standardDeviation)} mg/dL '
          '(${_format(coefficientOfVariation, digits: 1)}% '
          'coefficient of variation).',
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: evidence,
    );
  }

  static MetabolicObservation _spikeObservation({
    required GlucoseStats stats,
    required DateTime windowStart,
    required DateTime windowEnd,
    required GlucoseRangeBounds bounds,
  }) {
    return MetabolicObservation(
      id: _observationId(ObservationKind.spike, windowStart, windowEnd),
      kind: ObservationKind.spike,
      title: 'Above-range excursions',
      summary:
          '${stats.spikeCount} upward excursion${stats.spikeCount == 1 ? '' : 's'} '
          'crossed ${_format(bounds.highMgdl)} mg/dL.',
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: <ObservationEvidence>[
        _evidence(
          id: 'glucose:spikes:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.glucose,
          label: 'Upward excursions above the configured range',
          value: stats.spikeCount.toDouble(),
          unit: 'excursions',
          sampleCount: stats.readingCount,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: 'cgm',
        ),
      ],
    );
  }

  static MetabolicObservation _mealObservation({
    required List<HealthEvent> meals,
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    var carbs = 0.0;
    var hasCarbs = false;
    for (final meal in meals) {
      final payload = meal.payload;
      if (payload is MealPayload && payload.carbsGrams != null) {
        carbs += payload.carbsGrams!;
        hasCarbs = true;
      }
    }
    final label = hasCarbs ? 'Logged carbohydrates' : 'Meal entries';
    return MetabolicObservation(
      id: _observationId(ObservationKind.mealContext, windowStart, windowEnd),
      kind: ObservationKind.mealContext,
      title: 'Meal context',
      summary: hasCarbs
          ? '${meals.length} meal entries totaling ${_format(carbs)} g carbs.'
          : '${meals.length} meal entries were logged in this window.',
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: <ObservationEvidence>[
        _evidence(
          id: 'events:meals:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.event,
          label: label,
          value: hasCarbs ? carbs : meals.length.toDouble(),
          unit: hasCarbs ? 'g' : 'entries',
          sampleCount: meals.length,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: 'journal',
        ),
      ],
    );
  }

  static MetabolicObservation _activityObservation({
    required List<ActivitySample> samples,
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    final steps = samples.fold<int>(
      0,
      (sum, sample) => sum + (sample.steps ?? 0),
    );
    final energy = samples.fold<double>(
      0,
      (sum, sample) => sum + (sample.energyKcal ?? 0),
    );
    final duration = samples.fold<Duration>(
      Duration.zero,
      (sum, sample) =>
          sum +
          _clampedDuration(sample.start, sample.end, windowStart, windowEnd),
    );
    final hasSteps = steps > 0;
    final hasEnergy = energy > 0;
    final label = hasSteps
        ? 'Imported steps'
        : hasEnergy
        ? 'Imported active energy'
        : 'Imported activity duration';
    final value = hasSteps
        ? steps.toDouble()
        : hasEnergy
        ? energy
        : duration.inMinutes.toDouble();
    final unit = hasSteps
        ? 'steps'
        : hasEnergy
        ? 'kcal'
        : 'minutes';
    return MetabolicObservation(
      id: _observationId(
        ObservationKind.activityContext,
        windowStart,
        windowEnd,
      ),
      kind: ObservationKind.activityContext,
      title: 'Activity context',
      summary: hasSteps
          ? '$steps steps were imported across ${samples.length} activity samples.'
          : hasEnergy
          ? '${_format(energy)} kcal of active energy were imported.'
          : '${duration.inMinutes} minutes of activity were imported.',
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: <ObservationEvidence>[
        _evidence(
          id: 'activity:context:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.activity,
          label: label,
          value: value,
          unit: unit,
          sampleCount: samples.length,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: _sourceLabel(samples.map((sample) => sample.source)),
        ),
      ],
    );
  }

  static MetabolicObservation _sleepObservation({
    required List<SleepSample> samples,
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    final duration = samples.fold<Duration>(
      Duration.zero,
      (sum, sample) =>
          sum +
          _clampedDuration(sample.start, sample.end, windowStart, windowEnd),
    );
    return MetabolicObservation(
      id: _observationId(ObservationKind.sleepContext, windowStart, windowEnd),
      kind: ObservationKind.sleepContext,
      title: 'Sleep context',
      summary:
          '${duration.inMinutes} minutes of imported sleep-stage data '
          'across ${samples.length} samples.',
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: <ObservationEvidence>[
        _evidence(
          id: 'sleep:context:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.sleep,
          label: 'Imported sleep duration',
          value: duration.inMinutes.toDouble(),
          unit: 'minutes',
          sampleCount: samples.length,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: _sourceLabel(samples.map((sample) => sample.source)),
        ),
      ],
    );
  }

  static MetabolicObservation _heartRateObservation({
    required List<HeartRateSample> samples,
    required DateTime windowStart,
    required DateTime windowEnd,
  }) {
    final average =
        samples.fold<double>(0, (sum, sample) => sum + sample.bpm) /
        samples.length;
    return MetabolicObservation(
      id: _observationId(
        ObservationKind.heartRateContext,
        windowStart,
        windowEnd,
      ),
      kind: ObservationKind.heartRateContext,
      title: 'Heart-rate context',
      summary:
          'Average imported heart rate was ${_format(average)} bpm '
          'across ${samples.length} samples.',
      windowStart: windowStart,
      windowEnd: windowEnd,
      evidence: <ObservationEvidence>[
        _evidence(
          id: 'heart-rate:average:${_windowKey(windowStart, windowEnd)}',
          kind: EvidenceKind.heartRate,
          label: 'Average heart rate',
          value: average,
          unit: 'bpm',
          sampleCount: samples.length,
          windowStart: windowStart,
          windowEnd: windowEnd,
          source: _sourceLabel(samples.map((sample) => sample.source)),
        ),
      ],
    );
  }

  static ObservationEvidence _evidence({
    required String id,
    required EvidenceKind kind,
    required String label,
    required double value,
    required String unit,
    required int sampleCount,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? source,
  }) {
    return ObservationEvidence(
      id: id,
      kind: kind,
      label: label,
      value: value,
      unit: unit,
      sampleCount: sampleCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      source: source,
    );
  }

  static bool _inWindow(DateTime timestamp, DateTime start, DateTime end) =>
      !timestamp.isBefore(start) && timestamp.isBefore(end);

  static bool _overlaps(
    DateTime start,
    DateTime end,
    DateTime windowStart,
    DateTime windowEnd,
  ) => end.isAfter(windowStart) && start.isBefore(windowEnd);

  static Duration _clampedDuration(
    DateTime start,
    DateTime end,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    final clampedStart = start.isBefore(windowStart) ? windowStart : start;
    final clampedEnd = end.isAfter(windowEnd) ? windowEnd : end;
    return clampedEnd.isAfter(clampedStart)
        ? clampedEnd.difference(clampedStart)
        : Duration.zero;
  }

  static AnalyticsTimeframe _timeframeFor(Duration duration) {
    if (duration <= const Duration(days: 1)) return AnalyticsTimeframe.last24h;
    if (duration <= const Duration(days: 7)) return AnalyticsTimeframe.last7d;
    return AnalyticsTimeframe.last14d;
  }

  static String _observationId(
    ObservationKind kind,
    DateTime start,
    DateTime end,
  ) => 'observation:${kind.key}:${_windowKey(start, end)}';

  static String _windowKey(DateTime start, DateTime end) =>
      '${start.toUtc().microsecondsSinceEpoch}-${end.toUtc().microsecondsSinceEpoch}';

  static String _format(double? value, {int digits = 0}) =>
      value == null ? 'n/a' : value.toStringAsFixed(digits);

  static String _sourceLabel(Iterable<DataSource> sources) {
    final keys = sources.map((source) => source.key).toSet().toList()..sort();
    return keys.join(',');
  }
}

const int _observationFormatVersion = 1;
const String _defaultObservationCaveat =
    'Descriptive wellness observation only; context overlap does not prove causation or a medical conclusion.';

DateTime _readDate(Map<String, Object?> json, String key) {
  final value = json[key];
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw FormatException('$key must be an ISO-8601 date');
  return parsed;
}

String? _readOptionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a String or null');
  return value;
}
