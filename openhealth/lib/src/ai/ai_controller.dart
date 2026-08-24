import 'package:cgm_core/cgm_core.dart';

import 'ai_settings.dart';
import 'ai_settings_store.dart';
import 'http_transport.dart';

/// Wires persisted [AiSettings] + the secure BYO API key into a concrete
/// [AiProvider] and a ready-to-use [InsightService].
///
/// This is the app-side glue between the privacy-first `cgm_core` AI foundation
/// and the on-device data: it keeps the key in memory only for the duration of
/// building a provider, and returns a [NullAiProvider] whenever AI is disabled
/// or no key is set — so the disabled path provably performs no network I/O.
class AiController {
  AiController({
    required AiSettingsStore store,
    required HealthRepository repository,
    AiTransport? transport,
  }) : _store = store,
       _repository = repository,
       _transport = transport ?? HttpAiTransport().call;

  final AiSettingsStore _store;
  final HealthRepository _repository;
  final AiTransport _transport;

  AiSettings get settings => _store.loadSettings();

  Future<bool> hasApiKey() => _store.hasApiKey();

  /// Builds the active provider from current settings + secure key.
  ///
  /// Returns a [NullAiProvider] when AI is disabled or no key is present.
  Future<AiProvider> buildProvider() async {
    final settings = _store.loadSettings();
    if (!settings.enabled) return const NullAiProvider();
    final key = await _store.readApiKey();
    if (key == null || key.trim().isEmpty) {
      return const NullAiProvider(reason: AiAvailabilityReason.missingApiKey);
    }

    final config = _configFor(settings, key);
    if (!config.isValid) {
      return NullAiProvider(
        reason: AiAvailabilityReason.invalidConfiguration,
        detail: config.validationError,
      );
    }

    return HttpChatAiProvider(
      config: config,
      transport: _transport,
    );
  }

  /// Creates the exact aggregate snapshot that a user can review before it is
  /// sent to the configured endpoint. This method does not call a provider.
  Future<AiRecentInsightPreparation?> prepareRecentInsightGeneration({
    required List<CgmReading> readings,
    Duration window = const Duration(hours: 24),
    GlucoseUnit unit = GlucoseUnit.mgdl,
    DateTime? now,
  }) async {
    final provider = await buildProvider();
    if (!provider.isEnabled) return null;
    final endpoint = _remoteEndpoint(provider);
    if (endpoint == null) {
      throw const AiGenerationException(
        'AI provider is not a configured remote observation endpoint.',
      );
    }
    final service = InsightService(repository: _repository, provider: provider);
    final end = now ?? DateTime.now();
    final prepared = await service.prepareSummaryInsight(
      readings: readings,
      windowStart: end.subtract(window),
      windowEnd: end,
      unit: unit,
    );
    if (prepared == null) return null;
    return AiRecentInsightPreparation._(
      summary: prepared,
      endpoint: endpoint,
      model: provider.modelId,
      disclosure: AiRemoteGenerationDisclosure(
        endpointHostname: endpoint.host,
        endpoint: endpoint.toString(),
        dataCategories: prepared.context.dataCategories
            .map((category) => category.label)
            .toList(growable: false),
      ),
    );
  }

  /// Issues a one-use receipt after the user reviews the preparation disclosure.
  ///
  /// The receipt is bound to the exact endpoint, model, aggregate snapshot,
  /// and declared data categories. It is consumed before a provider call.
  AiRemoteGenerationConsentReceipt confirmRemoteGeneration(
    AiRecentInsightPreparation preparation,
  ) => AiRemoteGenerationConsentReceipt._(
    preparationToken: preparation._token,
    endpoint: preparation._endpoint.toString(),
    model: preparation._model,
    snapshot: preparation._snapshot,
    categories: preparation._categories,
  );

  /// Generates a prepared insight only with an unconsumed exact receipt.
  ///
  /// This is the sole real-generation boundary in the app. The synthetic
  /// [testRemoteConnection] method remains separate and has no health data.
  Future<AiInsight?> generateRecentInsight({
    required AiRecentInsightPreparation preparation,
    required AiRemoteGenerationConsentReceipt consentReceipt,
  }) async {
    final provider = await buildProvider();
    if (!provider.isEnabled) return null;
    final endpoint = _remoteEndpoint(provider);
    if (endpoint == null) {
      throw const AiGenerationException(
        'AI provider is not a configured remote observation endpoint.',
      );
    }
    consentReceipt._consume(
      preparation: preparation,
      endpoint: endpoint.toString(),
      model: provider.modelId,
    );
    final service = InsightService(repository: _repository, provider: provider);
    return service.generatePreparedSummaryInsight(preparation._summary);
  }

  /// Tests the configured remote endpoint with a fixed synthetic request.
  ///
  /// It sends no glucose values, journal events, notes, identifiers, or
  /// evidence. It also does not create an [AiInsight].
  Future<AiConnectionTestResult> testRemoteConnection() async {
    final provider = await buildProvider();
    if (!provider.isEnabled) {
      throw const AiGenerationException(
        'Enable a valid OpenAI-compatible provider and add a key first.',
      );
    }
    final response = await provider.generate(
      AiRequest(
        purpose: AiRequestPurpose.connectionTest,
        // Exercise the configured model while keeping the request synthetic.
        // A made-up model ID would make a healthy endpoint look broken.
        model: provider.modelId ?? 'gpt-4o-mini',
        maxTokens: 32,
        messages: const <AiMessage>[
          AiMessage.system(
            'This is an OpenGlucose synthetic connection test. '
            'Do not infer or discuss health data.',
          ),
          AiMessage.user('Return the exact word: connected'),
        ],
      ),
    );
    final capability = provider is AiCapabilityDescribingProvider
        ? (provider as AiCapabilityDescribingProvider).capability
        : AiProviderCapability.disabled;
    return AiConnectionTestResult(
      provider: capability,
      responseReceived: response.isNotEmpty,
    );
  }

  static AiProviderConfig _configFor(AiSettings settings, String key) =>
      AiProviderConfig(
        baseUrl: settings.baseUrl,
        apiKey: key,
        model: settings.model,
        authScheme: settings.authScheme,
      );

  static Uri? _remoteEndpoint(AiProvider provider) =>
      provider is HttpChatAiProvider ? provider.config.endpoint : null;
}

/// An opaque, prepared aggregate snapshot for one real-generation attempt.
///
/// It exposes only the safe human-readable disclosure. The exact snapshot is
/// private so callers cannot alter the data after a consent prompt.
class AiRecentInsightPreparation {
  AiRecentInsightPreparation._({
    required AiSummaryInsightPreparation summary,
    required Uri endpoint,
    required String? model,
    required AiRemoteGenerationDisclosure disclosure,
  }) : _summary = summary,
       _endpoint = endpoint,
       _model = model,
       _disclosure = disclosure,
       _snapshot = summary.context.encodeForPrompt(),
       _categories = List<AiDataCategory>.unmodifiable(
         summary.context.dataCategories,
       );

  final Object _token = Object();
  final AiSummaryInsightPreparation _summary;
  final Uri _endpoint;
  final String? _model;
  final AiRemoteGenerationDisclosure _disclosure;
  final String _snapshot;
  final List<AiDataCategory> _categories;

  AiRemoteGenerationDisclosure get disclosure => _disclosure;
}

/// One-use, non-persisted proof that the user reviewed a prepared request.
class AiRemoteGenerationConsentReceipt {
  AiRemoteGenerationConsentReceipt._({
    required Object preparationToken,
    required String endpoint,
    required String? model,
    required String snapshot,
    required List<AiDataCategory> categories,
  }) : _preparationToken = preparationToken,
       _endpoint = endpoint,
       _model = model,
       _snapshot = snapshot,
       _categories = List<AiDataCategory>.unmodifiable(categories);

  final Object _preparationToken;
  final String _endpoint;
  final String? _model;
  final String _snapshot;
  final List<AiDataCategory> _categories;
  bool _consumed = false;

  void _consume({
    required AiRecentInsightPreparation preparation,
    required String endpoint,
    required String? model,
  }) {
    if (_consumed ||
        !identical(_preparationToken, preparation._token) ||
        _endpoint != endpoint ||
        _model != model ||
        _snapshot != preparation._snapshot ||
        !_sameCategories(_categories, preparation._categories)) {
      throw const AiGenerationException(
        'Remote generation consent is not valid for this request.',
      );
    }
    _consumed = true;
  }
}

bool _sameCategories(List<AiDataCategory> left, List<AiDataCategory> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// A non-persisted result of a synthetic remote configuration test.
class AiConnectionTestResult {
  const AiConnectionTestResult({
    required this.provider,
    required this.responseReceived,
  });

  final AiProviderCapability provider;
  final bool responseReceived;
}
