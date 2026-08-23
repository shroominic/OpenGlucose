import '../ai_insight.dart';
import '../cgm_models.dart';
import '../glucose_analytics.dart';
import '../health_repository.dart';
import 'ai_disclaimer.dart';
import 'ai_output_contract.dart';
import 'ai_provider.dart';
import 'glucose_summary.dart';
import 'http_chat_ai_provider.dart';

/// Generates structured, evidence-bound AI observations from local data.
///
/// A provider is called only after deterministic coverage and evidence are
/// available. Free-form output, unknown citations, unsupported numeric claims,
/// unsafe language, and refusals never become persisted insights.
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

  bool get isEnabled => _provider.isEnabled;

  /// Generates one validated observation over the specified window.
  ///
  /// Returns null before any I/O when AI is disabled. A sparse window, a
  /// provider without structured output, an invalid response, or a refusal
  /// throws and leaves the repository unchanged.
  Future<AiInsight?> generateSummaryInsight({
    required List<CgmReading> readings,
    required DateTime windowStart,
    required DateTime windowEnd,
    GlucoseUnit unit = GlucoseUnit.mgdl,
    AiInsightCategory category = AiInsightCategory.summary,
    String locale = 'en',
  }) async {
    if (!_provider.isEnabled) return null;

    final capability = _capabilityFor(_provider);
    if (!capability.isAvailable || !capability.supportsStructuredOutput) {
      throw const AiGenerationException(
        'AI provider cannot produce structured evidence-bound observations.',
      );
    }

    final events = await _repository.queryEvents(
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

    final context = MetabolicContextSnapshot.fromGlucoseSummary(
      summary,
      locale: locale,
    );
    final request = AiRequest(
      model: _provider.modelId ?? capability.model ?? 'gpt-4o-mini',
      messages: buildMessagesForContext(context),
      purpose: AiRequestPurpose.observation,
      structuredOutputVersion: aiObservationContractVersion,
      maxTokens: capability.resourceLimits.maxOutputTokens,
    );
    final response = await _provider.generate(request);
    final draft = AiOutputContract.decodeAndValidate(
      response: response,
      context: context,
    );
    if (draft.kind == ObservationDraftKind.refusal) {
      throw const AiGenerationException(
        'AI provider declined to create an evidence-bound observation.',
      );
    }

    final citedIds = draft.statements
        .expand((statement) => statement.evidenceIds)
        .toSet();
    final citedEvidence = context.evidence
        .where((evidence) => citedIds.contains(evidence.id))
        .toList(growable: false);
    final body = draft.statements
        .map((statement) => statement.text.trim())
        .join('\n\n');
    final insight = AiInsight(
      id: _idFactory(),
      createdAt: _clock(),
      category: category,
      title: _titleFor(category),
      body:
          (StringBuffer(body)
                ..write('\n\n')
                ..write(AiDisclaimer.short))
              .toString(),
      windowStart: windowStart,
      windowEnd: windowEnd,
      model: _provider.modelId,
      tags: const <String>[AiDisclaimer.tag, 'ai-generated', 'evidence-bound'],
      evidence: citedEvidence,
      provenance: AiGenerationProvenance.fromCapability(
        capability,
        endpointHostname: _endpointHostname(_provider),
      ),
    );
    await _repository.upsertInsight(insight);
    return insight;
  }

  /// Builds guarded messages from a summary for compatibility with callers
  /// that have not yet constructed a snapshot.
  static List<AiMessage> buildMessages(
    GlucoseSummary summary, {
    String locale = 'en',
  }) => buildMessagesForContext(
    MetabolicContextSnapshot.fromGlucoseSummary(summary, locale: locale),
  );

  /// Builds guarded messages that contain only the deterministic snapshot.
  static List<AiMessage> buildMessagesForContext(
    MetabolicContextSnapshot context,
  ) => <AiMessage>[
    const AiMessage.system(AiDisclaimer.systemGuardrail),
    AiMessage.user(AiOutputContract.buildPrompt(context)),
  ];

  /// Renders the evidence-only prompt from a summary.
  static String buildPrompt(GlucoseSummary summary, {String locale = 'en'}) =>
      AiOutputContract.buildPrompt(
        MetabolicContextSnapshot.fromGlucoseSummary(summary, locale: locale),
      );

  static AiProviderCapability _capabilityFor(AiProvider provider) {
    if (provider is AiCapabilityDescribingProvider) {
      return (provider as AiCapabilityDescribingProvider).capability;
    }
    return const AiProviderCapability(
      kind: AiProviderKind.disabled,
      executionLocation: AiExecutionLocation.none,
      availabilityReason: AiAvailabilityReason.unsupportedProtocol,
      supportsStructuredOutput: false,
      locale: 'und',
      resourceLimits: AiResourceLimits(),
      availabilityDetail: 'Provider does not declare capabilities.',
    );
  }

  static String? _endpointHostname(AiProvider provider) {
    if (provider is HttpChatAiProvider) {
      return provider.config.endpointHostname;
    }
    return null;
  }

  static String _titleFor(AiInsightCategory category) => switch (category) {
    AiInsightCategory.summary => 'Glucose summary',
    AiInsightCategory.pattern => 'Pattern observation',
    AiInsightCategory.recommendation => 'Self-experiment idea',
    AiInsightCategory.anomaly => 'Flagged observation',
    AiInsightCategory.custom => 'AI insight',
  };

  static String _defaultIdFactory() => (StringBuffer(
    'insight-',
  )..write(DateTime.now().microsecondsSinceEpoch)).toString();
}
