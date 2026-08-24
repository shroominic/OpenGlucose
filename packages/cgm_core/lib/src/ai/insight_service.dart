import '../ai_insight.dart';
import '../cgm_models.dart';
import '../glucose_analytics.dart';
import '../health_repository.dart';
import 'ai_disclaimer.dart';
import 'ai_output_contract.dart';
import 'ai_provider.dart';
import 'glucose_summary.dart';
import 'http_chat_ai_provider.dart';

/// A local, immutable generation snapshot prepared before any remote request.
///
/// Hosts can show the exact [context.dataCategories] to the user and bind a
/// consent receipt to this object before they call a provider. It contains only
/// deterministic aggregates, never raw readings or journal text.
class AiSummaryInsightPreparation {
  const AiSummaryInsightPreparation({
    required this.context,
    required this.windowStart,
    required this.windowEnd,
    required this.category,
  });

  final MetabolicContextSnapshot context;
  final DateTime windowStart;
  final DateTime windowEnd;
  final AiInsightCategory category;
}

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
    final preparation = await prepareSummaryInsight(
      readings: readings,
      windowStart: windowStart,
      windowEnd: windowEnd,
      unit: unit,
      category: category,
      locale: locale,
    );
    if (preparation == null) return null;
    return generatePreparedSummaryInsight(preparation);
  }

  /// Prepares one local, aggregate-only insight snapshot without provider I/O.
  ///
  /// A host can disclose the exact snapshot categories and obtain a consent
  /// receipt before calling [generatePreparedSummaryInsight].
  Future<AiSummaryInsightPreparation?> prepareSummaryInsight({
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
    return AiSummaryInsightPreparation(
      context: context,
      windowStart: windowStart,
      windowEnd: windowEnd,
      category: category,
    );
  }

  /// Calls the provider and persists an insight from a previously prepared
  /// local snapshot.
  ///
  /// Hosts must enforce their consent boundary before calling this method.
  Future<AiInsight?> generatePreparedSummaryInsight(
    AiSummaryInsightPreparation preparation,
  ) async {
    if (!_provider.isEnabled) return null;

    final capability = _capabilityFor(_provider);
    if (!capability.isAvailable || !capability.supportsStructuredOutput) {
      throw const AiGenerationException(
        'AI provider cannot produce structured evidence-bound observations.',
      );
    }
    final contextError = preparation.context.validationError;
    if (contextError != null) throw AiOutputValidationException(contextError);
    final request = AiRequest(
      model: _provider.modelId ?? capability.model ?? 'gpt-4o-mini',
      messages: buildMessagesForContext(preparation.context),
      purpose: AiRequestPurpose.observation,
      structuredOutputVersion: aiObservationContractVersion,
      maxTokens: capability.resourceLimits.maxOutputTokens,
    );
    final response = await _provider.generate(request);
    final draft = AiOutputContract.decodeAndValidate(
      response: response,
      context: preparation.context,
    );
    if (draft.kind == ObservationDraftKind.refusal) {
      throw const AiGenerationException(
        'AI provider declined to create an evidence-bound observation.',
      );
    }

    final evidenceById = <String, EvidenceRef>{
      for (final evidence in preparation.context.evidence)
        evidence.id: evidence,
    };
    final statements = draft.statements
        .map((statement) {
          final statementEvidence = statement.evidenceIds
              .map((id) => evidenceById[id]!)
              .toList(growable: false);
          // The contract permits a small comparison tolerance for provider
          // JSON number formatting. Persist only the exact local values,
          // however, so future display and disk round trips cannot retain a
          // provider-rounded (or zero-adjacent) numeric claim.
          final canonicalClaims = statement.numericClaims
              .map((claim) {
                final evidence = evidenceById[claim.evidenceId]!;
                return AiNumericClaim(
                  evidenceId: evidence.id,
                  value: evidence.value,
                  unit: evidence.unit,
                );
              })
              .toList(growable: false);
          return AiInsightStatement(
            text: statement.render(evidenceById),
            evidence: statementEvidence,
            numericClaims: canonicalClaims,
          );
        })
        .toList(growable: false);
    final citedEvidence = statements
        .expand((statement) => statement.evidence)
        .toSet()
        .toList(growable: false);
    final body = statements.map((statement) => statement.text).join('\n\n');
    final insight = AiInsight(
      id: _idFactory(),
      createdAt: _clock(),
      category: preparation.category,
      title: _titleFor(preparation.category),
      body:
          (StringBuffer(body)
                ..write('\n\n')
                ..write(AiDisclaimer.short))
              .toString(),
      windowStart: preparation.windowStart,
      windowEnd: preparation.windowEnd,
      model: _provider.modelId,
      tags: const <String>[AiDisclaimer.tag, 'ai-generated', 'evidence-bound'],
      evidence: citedEvidence,
      statements: statements,
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
