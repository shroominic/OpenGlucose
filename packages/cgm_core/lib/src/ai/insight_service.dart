import '../ai_insight.dart';
import '../cgm_models.dart';
import '../glucose_analytics.dart';
import '../health_event.dart';
import '../health_repository.dart';
import '../observations.dart';
import 'ai_disclaimer.dart';
import 'ai_output_contract.dart';
import 'ai_provider.dart';
import 'glucose_summary.dart';

/// Generates AI insights from the user's *local* health data and persists them.
///
/// Flow:
/// 1. Read journal [HealthEvent]s for the window from the [HealthRepository]
///    (glucose readings are passed in by the caller, which owns reading
///    history).
/// 2. Reduce both to a privacy-conscious [GlucoseSummary] — aggregate stats,
///    not raw per-minute dumps.
/// 3. Build a guard-railed prompt (wellness framing baked in) and call the
///    injected [AiProvider].
/// 4. Persist the result as an [AiInsight] tagged with the wellness disclaimer
///    and provenance (model id), via [HealthRepository.upsertInsight].
///
/// Errors are surfaced as [AiGenerationException] but never crash the app: the
/// caller decides how to present a failure. When the provider is disabled, the
/// service short-circuits without any I/O.
class InsightService {
  InsightService({
    required HealthRepository repository,
    required AiProvider provider,
    String Function()? idFactory,
    DateTime Function()? clock,
  }) : _repository = repository,
       _provider = provider,
       _idFactory = idFactory ?? _defaultIdFactory,
       _clock = clock ?? DateTime.now;

  final HealthRepository _repository;
  final AiProvider _provider;
  final String Function() _idFactory;
  final DateTime Function() _clock;

  /// Whether the underlying provider is configured to generate.
  bool get isEnabled => _provider.isEnabled;

  /// Generates a single summary insight over `[windowStart, windowEnd]` from
  /// the supplied [readings] plus the journal events in that window, persists
  /// it, and returns it.
  ///
  /// Returns `null` when AI is disabled. Throws [AiGenerationException] on a
  /// generation/network failure (the caller is expected to catch and surface
  /// it gracefully).
  Future<AiInsight?> generateSummaryInsight({
    required List<CgmReading> readings,
    required DateTime windowStart,
    required DateTime windowEnd,
    GlucoseUnit unit = GlucoseUnit.mgdl,
    AiInsightCategory category = AiInsightCategory.summary,
  }) async {
    if (!_provider.isEnabled) return null;

    final events = await _repository.queryEvents(
      window: TimeWindow(start: windowStart, end: windowEnd),
    );
    final activitySamples = await _repository.queryActivitySamples(
      window: TimeWindow(start: windowStart, end: windowEnd),
    );
    final sleepSamples = await _repository.querySleepSamples(
      window: TimeWindow(start: windowStart, end: windowEnd),
    );
    final heartRateSamples = await _repository.queryHeartRateSamples(
      window: TimeWindow(start: windowStart, end: windowEnd),
    );
    final windowReadings = readings
        .where((reading) {
          final at = reading.recordedAt;
          if (at == null) return false;
          return !at.isBefore(windowStart) && at.isBefore(windowEnd);
        })
        .toList(growable: false);

    final summary = GlucoseSummary.fromData(
      windowStart: windowStart,
      windowEnd: windowEnd,
      readings: windowReadings,
      events: events,
      unit: unit,
    );

    final windowDuration = windowEnd.difference(windowStart);
    final coverageTimeframe = windowDuration <= const Duration(days: 1)
        ? AnalyticsTimeframe.last24h
        : windowDuration <= const Duration(days: 7)
        ? AnalyticsTimeframe.last7d
        : AnalyticsTimeframe.last14d;
    final coverage = GlucoseAnalytics.assessCoverage(
      windowReadings,
      coverageTimeframe,
      now: windowEnd,
    );
    if (!summary.hasData || !coverage.isSufficient) {
      throw const AiGenerationException(
        'Not enough glucose data in this window to generate an insight.',
      );
    }

    final observations = MetabolicObservationEngine.generate(
      readings: windowReadings,
      events: events,
      activitySamples: activitySamples,
      sleepSamples: sleepSamples,
      heartRateSamples: heartRateSamples,
      windowStart: windowStart,
      windowEnd: windowEnd,
      unit: unit,
    );
    final evidenceById = <String, ObservationEvidence>{
      for (final observation in observations)
        for (final evidence in observation.evidence) evidence.id: evidence,
    };
    if (evidenceById.isEmpty) {
      throw const AiGenerationException(
        'No evidence is available for an AI insight.',
      );
    }

    final request = AiRequest(
      model: _provider.modelId ?? 'gpt-4o-mini',
      messages: buildMessages(summary, observations: observations),
    );

    final body = AiOutputContract.validate(await _provider.generate(request));

    final insight = AiInsight(
      id: _idFactory(),
      createdAt: _clock(),
      category: category,
      title: _titleFor(category, summary),
      body: '$body\n\n${AiDisclaimer.short}',
      windowStart: windowStart,
      windowEnd: windowEnd,
      model: _provider.modelId,
      tags: const <String>[AiDisclaimer.tag, 'ai-generated'],
      evidence: evidenceById.values.toList(growable: false),
      safetyBoundary: AiDisclaimer.short,
    );

    await _repository.upsertInsight(insight);
    return insight;
  }

  /// Builds the guard-railed message list for a summary [summary].
  ///
  /// Exposed for unit testing of prompt construction. The system message bakes
  /// in the wellness guardrail; the user message carries only aggregate stats.
  static List<AiMessage> buildMessages(
    GlucoseSummary summary, {
    List<MetabolicObservation> observations = const <MetabolicObservation>[],
  }) {
    return <AiMessage>[
      const AiMessage.system(AiDisclaimer.systemGuardrail),
      AiMessage.user(buildPrompt(summary, observations: observations)),
    ];
  }

  /// Renders the privacy-conscious user prompt from a [summary].
  ///
  /// Only aggregate numbers and event *counts* are included — never raw
  /// readings or free-text note bodies — so the minimum necessary data leaves
  /// the device on a BYO-key call.
  static String buildPrompt(
    GlucoseSummary summary, {
    List<MetabolicObservation> observations = const <MetabolicObservation>[],
  }) {
    String fmt(double? value, {int digits = 0}) =>
        value == null ? 'n/a' : value.toStringAsFixed(digits);
    final unit = summary.unit.label;
    final hours = summary.windowEnd.difference(summary.windowStart).inHours;

    final buffer = StringBuffer()
      ..writeln(
        'Summarize patterns in my self-tracked glucose data for self-experimentation.',
      )
      ..writeln('Window: about $hours hours, ${summary.readingCount} readings.')
      ..writeln('Average glucose: ${fmt(summary.average)} $unit')
      ..writeln('Range: ${fmt(summary.minimum)}–${fmt(summary.maximum)} $unit')
      ..writeln('Variability (SD): ${fmt(summary.standardDeviation)} $unit')
      ..writeln(
        'Time in 70–180 mg/dL range: ${fmt(summary.timeInRangePercent, digits: 1)}% '
        '(below ${fmt(summary.timeBelowRangePercent, digits: 1)}%, '
        'above ${fmt(summary.timeAboveRangePercent, digits: 1)}%)',
      )
      ..writeln(
        'Logged events: ${summary.mealCount} meals, '
        '${summary.exerciseCount} workouts, ${summary.noteCount} notes'
        '${summary.totalCarbsGrams == null ? '' : ', ${fmt(summary.totalCarbsGrams)}g carbs total'}.',
      )
      ..writeln(
        'Give 2-4 short, non-prescriptive observations a curious self-experimenter '
        'might explore. No medical advice, no diagnosis, no dosing.',
      )
      ..writeln(AiOutputContract.promptContract);
    if (observations.isNotEmpty) {
      buffer
        ..writeln(
          'Evidence available (use these labels; do not invent values):',
        )
        ..writeAll(
          observations.expand((observation) sync* {
            for (final evidence in observation.evidence) {
              final value = evidence.value == null
                  ? 'n/a'
                  : evidence.value!.toStringAsFixed(1);
              yield '- ${evidence.id}: ${evidence.label} = $value '
                  '${evidence.unit ?? ''} (${evidence.sampleCount} samples)\\n';
            }
          }),
        );
    }
    return buffer.toString();
  }

  static String _titleFor(AiInsightCategory category, GlucoseSummary summary) {
    return switch (category) {
      AiInsightCategory.summary => 'Glucose summary',
      AiInsightCategory.pattern => 'Pattern observation',
      AiInsightCategory.recommendation => 'Self-experiment idea',
      AiInsightCategory.anomaly => 'Flagged observation',
      AiInsightCategory.custom => 'AI insight',
    };
  }

  static String _defaultIdFactory() =>
      'insight-${DateTime.now().microsecondsSinceEpoch}';
}
