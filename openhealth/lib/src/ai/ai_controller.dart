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

  /// Builds an [InsightService] bound to the active provider and the local
  /// repository.
  Future<InsightService> buildInsightService() async {
    final provider = await buildProvider();
    return InsightService(repository: _repository, provider: provider);
  }

  /// Generates an insight over the last [window] of [readings], returning the
  /// persisted [AiInsight] (or `null` when AI is disabled). Throws
  /// [AiGenerationException] on failure — callers should catch and surface it.
  Future<AiInsight?> generateRecentInsight({
    required List<CgmReading> readings,
    Duration window = const Duration(hours: 24),
    GlucoseUnit unit = GlucoseUnit.mgdl,
    DateTime? now,
  }) async {
    final service = await buildInsightService();
    final end = now ?? DateTime.now();
    return service.generateSummaryInsight(
      readings: readings,
      windowStart: end.subtract(window),
      windowEnd: end,
      unit: unit,
    );
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

  /// The recipient and exact aggregate categories a real generation can send.
  ///
  /// This is intentionally separate from [testRemoteConnection], whose
  /// synthetic request has no data categories.
  Future<AiRemoteGenerationDisclosure?> remoteGenerationDisclosure() async {
    final settings = _store.loadSettings();
    final key = await _store.readApiKey();
    if (!settings.enabled || key == null || key.trim().isEmpty) return null;
    final config = _configFor(settings, key);
    final hostname = config.endpointHostname;
    if (!config.isValid || hostname == null) return null;
    return AiRemoteGenerationDisclosure(
      endpointHostname: hostname,
      dataCategories: <String>[
        AiDataCategory.contextWindow.label,
        AiDataCategory.glucoseAggregates.label,
        AiDataCategory.journalEventCounts.label,
        (StringBuffer(
          AiDataCategory.journalCarbohydrateAggregate.label,
        )..write(' when present')).toString(),
      ],
    );
  }

  static AiProviderConfig _configFor(AiSettings settings, String key) =>
      AiProviderConfig(
        baseUrl: settings.baseUrl,
        apiKey: key,
        model: settings.model,
        authScheme: settings.authScheme,
      );
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
